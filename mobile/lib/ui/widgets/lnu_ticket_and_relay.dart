/// 辽大特色组件：复古撕边「电子入馆座签」+ 08:00–22:00 双账号全天接力可视化甘特时间轴。
library;

import 'package:flutter/material.dart';

import '../../core/libseat_client.dart';
import '../../logic/seat_strategy.dart';
import '../theme/app_theme.dart';

/// 复古纸质撕边裁切器（左右两侧在虚线处挖出半圆形票据缺口）。
class _TicketNotchClipper extends CustomClipper<Path> {
  final double notchYRatio;
  final double notchRadius;

  const _TicketNotchClipper({
    this.notchYRatio = 0.64,
    this.notchRadius = 11.0,
  });

  @override
  Path getClip(Size size) {
    final ny = size.height * notchYRatio;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(16),
        ),
      );
    final leftNotch = Path()
      ..addOval(Rect.fromCircle(center: Offset(0, ny), radius: notchRadius));
    final rightNotch = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(size.width, ny), radius: notchRadius),
      );
    return Path.combine(
      PathOperation.difference,
      Path.combine(PathOperation.difference, path, leftNotch),
      rightNotch,
    );
  }

  @override
  bool shouldReclip(covariant _TicketNotchClipper oldClipper) =>
      oldClipper.notchYRatio != notchYRatio;
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final count = (constraints.maxWidth / 10).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List<Widget>.generate(
            count,
            (_) => Container(
              width: 5,
              height: 1,
              color: LnuColors.borderDark,
            ),
          ),
        );
      },
    );
  }
}

/// 复古辽大图书馆电子入馆座签卡片。
class LnuTicketCard extends StatelessWidget {
  final ReservationRecord record;
  final bool reminderEnabled;
  final List<String> reminderTimes;
  final VoidCallback? onReminderTap;
  final VoidCallback onCancelTap;
  final String? accountTag;
  final bool cancelling;

  const LnuTicketCard({
    super.key,
    required this.record,
    required this.reminderEnabled,
    this.reminderTimes = const <String>[],
    this.onReminderTap,
    required this.onCancelTap,
    this.accountTag,
    this.cancelling = false,
  });

  String _extractSeatDisplay(String location, String seatId) {
    final m = RegExp(r'(\d+)\s*号?$|([A-Za-z]-\d+-\d+)$').firstMatch(location.trim());
    if (m != null) {
      return (m.group(1) ?? m.group(2) ?? seatId).padLeft(3, '0');
    }
    return seatId.isNotEmpty ? seatId : '—';
  }

  String _extractRoomTitle(String location) {
    final cleaned = extractRoomNameFromLocation(location);
    return cleaned.isNotEmpty ? cleaned : '辽宁大学图书馆';
  }

  @override
  Widget build(BuildContext context) {
    final seatNum = _extractSeatDisplay(record.location, record.seatId);
    final roomTitle = _extractRoomTitle(record.location);
    final receiptText =
        record.receipt.isNotEmpty ? '#${record.receipt}' : '#${record.reservationId}';

    return ClipPath(
      clipper: const _TicketNotchClipper(notchYRatio: 0.65),
      child: Container(
        decoration: BoxDecoration(
          color: LnuColors.card,
          border: Border.all(color: LnuColors.borderDark, width: 1.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: <Widget>[
            // 深海蓝烫金眉条
            Container(
              width: double.infinity,
              color: LnuColors.ink,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              child: Row(
                children: <Widget>[
                  Text(
                    accountTag != null && accountTag!.isNotEmpty
                        ? '阅览座签 · $accountTag'
                        : 'LIAONING UNIVERSITY · 阅览座签',
                    style: const TextStyle(
                      color: LnuColors.amberLight,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    record.onDate,
                    style: LnuTheme.mono(
                      11.5,
                      color: LnuColors.textInvert,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // 核心座号与场馆
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                children: <Widget>[
                  Text(
                    roomTitle,
                    textAlign: TextAlign.center,
                    style: LnuTheme.serif(
                      16,
                      weight: FontWeight.w700,
                      color: LnuColors.ink,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    seatNum,
                    style: LnuTheme.serif(
                      44,
                      weight: FontWeight.w800,
                      color: LnuColors.ink,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        record.begin.isNotEmpty ? record.begin : '--:--',
                        style: LnuTheme.mono(15, weight: FontWeight.w700),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '───────',
                          style: TextStyle(color: LnuColors.amberHot),
                        ),
                      ),
                      Text(
                        record.end.isNotEmpty ? record.end : '--:--',
                        style: LnuTheme.mono(15, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 虚线撕裂线
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _DashedDivider(),
            ),

            // 票根区：凭证编号、提醒标识与退座按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '凭证 $receiptText',
                        style: LnuTheme.mono(
                          12,
                          color: LnuColors.textMuted,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: LnuColors.ok.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          record.status.isNotEmpty ? record.status : '有效预约',
                          style: const TextStyle(
                            color: LnuColors.ok,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (record.message.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        record.message,
                        style: const TextStyle(
                          color: LnuColors.amberDeep,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _buildReminderBadge(),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: LnuColors.err,
                          side: const BorderSide(color: LnuColors.err),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                        onPressed: cancelling ? null : onCancelTap,
                        child: Text(
                          cancelling ? '取消中...' : '取消预约',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReminderBadge() {
    final upperStat = record.status.trim().toUpperCase();
    final alreadyCheckedIn = upperStat.isNotEmpty && upperStat != 'RESERVE';
    final String label;
    final IconData icon;
    final Color fgColor;

    if (alreadyCheckedIn) {
      label = '已签到 · 无需提醒';
      icon = Icons.verified_outlined;
      fgColor = LnuColors.ok;
    } else if (!reminderEnabled) {
      label = '签到提醒已关 · 点此开启';
      icon = Icons.notifications_off_outlined;
      fgColor = LnuColors.textMuted;
    } else if (reminderTimes.isNotEmpty) {
      label = '提醒 ${reminderTimes.join(" / ")}';
      icon = Icons.notifications_active_outlined;
      fgColor = LnuColors.ink;
    } else {
      label = '签到提醒已开 · 已近截止';
      icon = Icons.notifications_active_outlined;
      fgColor = LnuColors.amberDeep;
    }

    return Material(
      color: LnuColors.cardSunk,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: alreadyCheckedIn ? null : onReminderTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 15, color: fgColor),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 08:00 — 22:00 双账号全天接力可视化甘特时间轴。
class LnuRelayTimeline extends StatelessWidget {
  final String account1;
  final String start1;
  final String end1;
  final bool useAccount2;
  final String account2;
  final String start2;
  final String end2;

  const LnuRelayTimeline({
    super.key,
    required this.account1,
    required this.start1,
    required this.end1,
    required this.useAccount2,
    required this.account2,
    required this.start2,
    required this.end2,
  });

  static const int _dayStartMin = 7 * 60; // 07:00
  static const int _dayEndMin = 22 * 60 + 30; // 22:30

  double _toFraction(String hhmm, double fallback) {
    final m = parseHhmmMinutes(hhmm);
    if (m == null) {
      return fallback;
    }
    return ((m - _dayStartMin) / (_dayEndMin - _dayStartMin)).clamp(0.0, 1.0);
  }

  String _formatAccount(String raw) {
    final s = raw.trim();
    return s.isEmpty ? '未配置' : s;
  }

  @override
  Widget build(BuildContext context) {
    final s1 = _toFraction(start1, 0.06);
    final e1 = _toFraction(end1, 0.45);
    final s2 = _toFraction(start2, 0.45);
    final e2 = _toFraction(end2, 0.85);
    final overlap = useAccount2 && timeRangesOverlap(start1, end1, start2, end2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 时间刻度尺
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('07:00', style: TextStyle(fontSize: 10.5, color: LnuColors.textDim)),
            Text('12:00', style: TextStyle(fontSize: 10.5, color: LnuColors.textDim)),
            Text('17:00', style: TextStyle(fontSize: 10.5, color: LnuColors.textDim)),
            Text('22:30', style: TextStyle(fontSize: 10.5, color: LnuColors.textDim)),
          ],
        ),
        const SizedBox(height: 8),

        // 主账号条（溯源海蓝）
        _buildBarRow(
          label: '主号 ${_formatAccount(account1)}',
          timeText: '$start1–$end1',
          leftFrac: s1,
          rightFrac: e1 > s1 ? e1 : s1 + 0.08,
          barColor: LnuColors.ink,
        ),

        if (useAccount2) ...<Widget>[
          const SizedBox(height: 8),
          _buildBarRow(
            label: '副号 ${_formatAccount(account2)}',
            timeText: '$start2–$end2',
            leftFrac: s2,
            rightFrac: e2 > s2 ? e2 : s2 + 0.08,
            barColor: LnuColors.amberHot,
          ),
        ],

        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: (useAccount2
                    ? (overlap ? LnuColors.warn : LnuColors.ok)
                    : LnuColors.ink)
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            !useAccount2
                ? '单号模式 · 如需全天 08:00–22:00 接力自习，可在账号管理中开启副号'
                : (overlap
                    ? '主副号时段存在重叠 · 抢座时将自动错开兜底座避免内耗'
                    : '无缝全天接力 · 允许主副号同抢同一心仪座位'),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: !useAccount2
                  ? LnuColors.ink
                  : (overlap ? LnuColors.amberDeep : LnuColors.ok),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBarRow({
    required String label,
    required String timeText,
    required double leftFrac,
    required double rightFrac,
    required Color barColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: LnuColors.text,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeText,
              style: LnuTheme.mono(11.5, color: LnuColors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (_, constraints) {
            final totalW = constraints.maxWidth;
            final leftPx = totalW * leftFrac;
            final barW = ((rightFrac - leftFrac) * totalW).clamp(16.0, totalW);
            return Stack(
              children: <Widget>[
                Container(
                  height: 10,
                  width: totalW,
                  decoration: BoxDecoration(
                    color: LnuColors.cardSunk,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                Positioned(
                  left: leftPx,
                  child: Container(
                    height: 10,
                    width: barW,
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
