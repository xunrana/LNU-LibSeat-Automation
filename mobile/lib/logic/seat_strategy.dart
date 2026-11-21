/// 选座策略、多自习室兜底规划与多账号防撞座协调器（纯逻辑，零网络/UI 依赖）。
///
/// 与 Python 端 `logic/seat_strategy.py` 100% 对齐。
library;

import 'dart:math';

enum SeatStatus {
  free,
  occupied,
  unavailable,
  unknown;

  String get label {
    switch (this) {
      case SeatStatus.free:
        return '空闲';
      case SeatStatus.occupied:
        return '占用';
      case SeatStatus.unavailable:
        return '不可用';
      case SeatStatus.unknown:
        return '未知';
    }
  }
}

class SeatCandidate {
  final String seatNo;
  final String seatId;
  final String roomId;
  final SeatStatus status;

  const SeatCandidate({
    required this.seatNo,
    this.seatId = '',
    this.roomId = '',
    this.status = SeatStatus.unknown,
  });

  SeatCandidate copyWith({
    String? seatNo,
    String? seatId,
    String? roomId,
    SeatStatus? status,
  }) {
    return SeatCandidate(
      seatNo: seatNo ?? this.seatNo,
      seatId: seatId ?? this.seatId,
      roomId: roomId ?? this.roomId,
      status: status ?? this.status,
    );
  }
}

class RoomTarget {
  final String campus;
  final String room;

  const RoomTarget(this.campus, this.room);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RoomTarget && other.campus == campus && other.room == room);

  @override
  int get hashCode => Object.hash(campus, room);

  @override
  String toString() => '$campus / $room';
}

/// 归一化座号：去除前导零（'001' -> '1'），混合编号（'A-06-1'）原样保留。
String normalizeSeatNo(String raw) {
  final s = raw.trim();
  if (s.isEmpty) {
    return '';
  }
  final isDigits = RegExp(r'^\d+$').hasMatch(s);
  if (isDigits) {
    return int.parse(s).toString();
  }
  return s;
}

/// 把 'HH:MM' / 'H:MM' 解析为自 00:00 起的分钟数；非法格式返回 null。
int? parseHhmmMinutes(String timeStr) {
  final parts = timeStr.trim().split(':');
  if (parts.length != 2) {
    return null;
  }
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) {
    return null;
  }
  if (hour < 0 || hour > 24 || minute < 0 || minute >= 60) {
    return null;
  }
  final total = hour * 60 + minute;
  return total <= 24 * 60 ? total : null;
}

/// 判断两个半开区间 `[start, end)` 是否重叠。
///
/// 边界相等（如 09:00-15:00 与 15:00-21:00）视为不重叠，允许无缝衔接占同一座。
bool timeRangesOverlap(
  String startA,
  String endA,
  String startB,
  String endB,
) {
  final sa = parseHhmmMinutes(startA);
  final ea = parseHhmmMinutes(endA);
  final sb = parseHhmmMinutes(startB);
  final eb = parseHhmmMinutes(endB);
  if (sa == null || ea == null || sb == null || eb == null) {
    return true;
  }
  if (ea <= sa || eb <= sb) {
    return true;
  }
  return sa < eb && sb < ea;
}

/// 构造去重且保序的 `[RoomTarget(campus, room), ...]` 目标自习室队列。
List<RoomTarget> buildRoomPlan(
  String primaryCampus,
  String primaryRoom, [
  List<RoomTarget> fallbackRooms = const <RoomTarget>[],
]) {
  final plan = <RoomTarget>[];
  final seen = <RoomTarget>{};

  void add(String campus, String room) {
    final c = campus.trim();
    final r = room.trim();
    if (r.isEmpty) {
      return;
    }
    final key = RoomTarget(c, r);
    if (seen.add(key)) {
      plan.add(key);
    }
  }

  add(primaryCampus, primaryRoom);
  for (final item in fallbackRooms) {
    add(item.campus, item.room);
  }
  return plan;
}

class PlannedSeatQueues {
  final List<SeatCandidate> preferred;
  final List<SeatCandidate> fallback;

  const PlannedSeatQueues({
    required this.preferred,
    required this.fallback,
  });
}

/// 根据用户首选列表与房间实时座位快照，生成 `(首选队列, 兜底队列)`。
PlannedSeatQueues planSeatCandidates(
  List<String> preferSeats,
  List<SeatCandidate> roomSeats, {
  bool skipOccupiedPreferred = true,
  bool shuffleFallback = true,
  Random? rng,
}) {
  final byNorm = <String, SeatCandidate>{};
  for (final seat in roomSeats) {
    final norm = normalizeSeatNo(seat.seatNo);
    if (norm.isNotEmpty && !byNorm.containsKey(norm)) {
      byNorm[norm] = seat.copyWith(seatNo: norm);
    }
  }

  final preferred = <SeatCandidate>[];
  final pickedNorms = <String>{};
  for (final raw in preferSeats) {
    final norm = normalizeSeatNo(raw);
    if (norm.isEmpty || pickedNorms.contains(norm)) {
      continue;
    }
    final candidate = byNorm[norm];
    if (candidate == null) {
      continue;
    }
    if (skipOccupiedPreferred &&
        (candidate.status == SeatStatus.occupied ||
            candidate.status == SeatStatus.unavailable)) {
      continue;
    }
    preferred.add(candidate);
    pickedNorms.add(norm);
  }

  final fallback = <SeatCandidate>[
    for (final entry in byNorm.entries)
      if (!pickedNorms.contains(entry.key) &&
          (entry.value.status == SeatStatus.free ||
              entry.value.status == SeatStatus.unknown))
        entry.value,
  ];
  if (shuffleFallback && fallback.length > 1) {
    fallback.shuffle(rng ?? Random());
  }

  return PlannedSeatQueues(preferred: preferred, fallback: fallback);
}

class _SeatClaim {
  final String account;
  final String startTime;
  final String endTime;

  const _SeatClaim({
    required this.account,
    required this.startTime,
    required this.endTime,
  });
}

/// 进程内多账号选座防撞协调器。
class SeatClaimCoordinator {
  final Map<String, List<_SeatClaim>> _claims = <String, List<_SeatClaim>>{};

  String _makeKey(String roomId, String seatNo) =>
      '$roomId::${normalizeSeatNo(seatNo)}';

  bool tryClaim(
    String account,
    String roomId,
    String seatNo,
    String startTime,
    String endTime,
  ) {
    final key = _makeKey(roomId, seatNo);
    final existing = _claims[key] ?? <_SeatClaim>[];
    for (final claim in existing) {
      if (claim.account == account) {
        return true;
      }
      if (timeRangesOverlap(
        claim.startTime,
        claim.endTime,
        startTime,
        endTime,
      )) {
        return false;
      }
    }
    existing.add(
      _SeatClaim(account: account, startTime: startTime, endTime: endTime),
    );
    _claims[key] = existing;
    return true;
  }

  void release(String account, String roomId, String seatNo) {
    final key = _makeKey(roomId, seatNo);
    final existing = _claims[key];
    if (existing == null) {
      return;
    }
    existing.removeWhere((c) => c.account == account);
    if (existing.isEmpty) {
      _claims.remove(key);
    }
  }

  void releaseAll(String account) {
    final emptyKeys = <String>[];
    for (final entry in _claims.entries) {
      entry.value.removeWhere((c) => c.account == account);
      if (entry.value.isEmpty) {
        emptyKeys.add(entry.key);
      }
    }
    for (final k in emptyKeys) {
      _claims.remove(k);
    }
  }
}
