/// 服务端时钟校准（基于 HTTP Date 响应头 + RTT/2 补偿）。
///
/// 与 Python 端 `core/clock_sync.py` 完全对齐。
library;

import 'dart:io';

class ClockSample {
  final DateTime serverUtc;
  final DateTime localUtc;
  final double rttSeconds;
  final double offsetSeconds;

  const ClockSample({
    required this.serverUtc,
    required this.localUtc,
    required this.rttSeconds,
    required this.offsetSeconds,
  });
}

class ClockSync {
  final double warnOffsetSeconds;
  final double maxAcceptOffsetSeconds;
  final double staleAfterSeconds;
  final DateTime Function() _nowUtcFn;

  ClockSample? _bestSample;

  ClockSync({
    this.warnOffsetSeconds = 30.0,
    this.maxAcceptOffsetSeconds = 3600.0,
    this.staleAfterSeconds = 300.0,
    DateTime Function()? nowUtcFn,
  }) : _nowUtcFn = nowUtcFn ?? (() => DateTime.now().toUtc());

  bool get synced => _bestSample != null;

  double get offsetSeconds => _bestSample?.offsetSeconds ?? 0.0;

  ClockSample? get bestSample => _bestSample;

  void reset() {
    _bestSample = null;
  }

  /// 从 HTTP `Date` 响应头更新时钟偏移，返回本次采样或 null（解析/校验失败）。
  ClockSample? updateFromHttpDate(
    String? dateHeader, {
    double rttSeconds = 0.0,
    DateTime? localReceivedUtc,
  }) {
    if (dateHeader == null || dateHeader.trim().isEmpty) {
      return null;
    }

    DateTime serverUtc;
    try {
      serverUtc = HttpDate.parse(dateHeader.trim()).toUtc();
    } catch (_) {
      return null;
    }

    final recvUtc = (localReceivedUtc ?? _nowUtcFn()).toUtc();
    final safeRtt = rttSeconds < 0.0 ? 0.0 : rttSeconds;
    final halfRttUs = (safeRtt * 500000.0).round();
    final localMid = recvUtc.subtract(Duration(microseconds: halfRttUs));
    final offset =
        serverUtc.difference(localMid).inMicroseconds / 1000000.0;

    if (offset.abs() > maxAcceptOffsetSeconds) {
      return null;
    }

    final sample = ClockSample(
      serverUtc: serverUtc,
      localUtc: localMid,
      rttSeconds: safeRtt,
      offsetSeconds: offset,
    );

    final prev = _bestSample;
    var shouldReplace = prev == null;
    if (prev != null) {
      final age =
          localMid.difference(prev.localUtc).inMicroseconds / 1000000.0;
      if (age >= staleAfterSeconds || safeRtt <= prev.rttSeconds) {
        shouldReplace = true;
      }
    }
    if (shouldReplace) {
      _bestSample = sample;
    }
    return sample;
  }

  /// 返回经服务端偏移校准后的当前 UTC 时间。
  DateTime nowUtc() {
    final base = _nowUtcFn().toUtc();
    final offsetUs = (offsetSeconds * 1000000.0).round();
    return base.add(Duration(microseconds: offsetUs));
  }

  /// 返回经服务端偏移校准后的当前北京时间（UTC+8，以 UTC 字段承载北京时间数值便于直接读取 hour/minute/second）。
  DateTime nowBeijing() {
    return nowUtc().add(const Duration(hours: 8));
  }
}
