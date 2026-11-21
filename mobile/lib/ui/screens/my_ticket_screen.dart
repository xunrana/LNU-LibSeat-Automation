/// 频道 ③：入馆（复古撕边阅览座签 + 7日信用刻度 + 暂离/专注自习伴侣 + 官方公告 + 辽大自习书简）。
library;

import 'package:flutter/material.dart';

import '../../core/libseat_client.dart';
import '../../services/notification_service.dart';
import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/lnu_chrome.dart';
import '../widgets/lnu_ticket_and_relay.dart';

class MyTicketScreen extends StatefulWidget {
  final MobileRushController controller;
  final VoidCallback? onJumpToFindSeat;

  const MyTicketScreen({
    super.key,
    required this.controller,
    this.onJumpToFindSeat,
  });

  @override
  State<MyTicketScreen> createState() => _MyTicketScreenState();
}

class _MyTicketScreenState extends State<MyTicketScreen> {
  // 0 = 全部合并, 1 = 仅主号, 2 = 仅副号
  int _accountScope = 0;

  MobileRushController get controller => widget.controller;
  VoidCallback? get onJumpToFindSeat => widget.onJumpToFindSeat;

  String _formatDuration(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _tail4(String acc) {
    final s = acc.trim();
    return s.length > 4 ? s.substring(s.length - 4) : s;
  }

  String? _activeAccountFilter() {
    final acc1 = controller.config.account1.trim();
    final acc2 = controller.config.account2.trim();
    if (_accountScope == 1 && acc1.isNotEmpty) {
      return acc1;
    }
    if (_accountScope == 2 && acc2.isNotEmpty) {
      return acc2;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, controller.config]),
      builder: (context, _) {
        final dual = controller.config.useAccount2 ||
            controller.accountPassSnapshots.length > 1;
        if (!dual && _accountScope != 0) {
          _accountScope = 0;
        }
        final accFilter = dual ? _activeAccountFilter() : null;
        final records = controller.activeReservationsForAccount(accFilter);
        final announcements = controller.announcements;
        final letter = controller.computeStudyLetter(accountFilter: accFilter);

        return Column(
          children: <Widget>[
            LnuPaperHeader(
              title: '入 馆',
              subtitle: '阅览座签 · 馆方公告 · 自习伴侣',
              trailing: GestureDetector(
                onTap: controller.passLoading
                    ? null
                    : controller.refreshLibraryPassData,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: LnuColors.card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: LnuColors.borderDark),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (controller.passLoading)
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: LnuColors.ink,
                          ),
                        )
                      else
                        const Icon(
                          Icons.sync_rounded,
                          size: 15,
                          color: LnuColors.ink,
                        ),
                      const SizedBox(width: 5),
                      const Text(
                        '同步',
                        style: TextStyle(
                          color: LnuColors.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: <Widget>[
                  if (dual) ...<Widget>[
                    _buildAccountScopeBar(),
                    const SizedBox(height: 10),
                  ],
                  if (controller.passError.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: LnuColors.errLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        controller.passError,
                        style: const TextStyle(
                          color: LnuColors.err,
                          fontSize: 12.5,
                        ),
                      ),
                    ),

                  // 1. 复古纸质撕边电子入馆座签（支持双账号展示与直接退座）
                  if (records.isEmpty)
                    _buildCompactEmptyPassCard()
                  else
                    for (final rec in records) ...<Widget>[
                      Builder(
                        builder: (cardCtx) {
                          final plannedTimes = NotificationService
                              .planCheckinRemindersForRecord(rec)
                              .map((r) => r.triggerHmLabel)
                              .toList(growable: false);
                          return LnuTicketCard(
                            record: rec,
                            reminderEnabled:
                                controller.config.autoCheckinReminder,
                            reminderTimes: plannedTimes,
                            onReminderTap: () async {
                              final next =
                                  !controller.config.autoCheckinReminder;
                              final count =
                                  await controller.setAutoCheckinReminder(next);
                              if (!cardCtx.mounted) {
                                return;
                              }
                              final msg = next
                                  ? (plannedTimes.isNotEmpty
                                      ? '已开启签到提醒：将于 ${plannedTimes.join("、")} 准时弹窗（杀后台也生效）'
                                      : '已开启签到提醒（当前已注册 $count 个提醒闹钟）')
                                  : '已关闭签到前提醒，并撤回待触发的系统闹钟';
                              ScaffoldMessenger.of(cardCtx).showSnackBar(
                                SnackBar(content: Text(msg)),
                              );
                            },
                            accountTag: dual && rec.account.isNotEmpty
                                ? '${controller.accountRoleLabel(rec.account)} ${rec.account}'
                                : null,
                            cancelling: controller.cancellingReservationId ==
                                rec.reservationId,
                            onCancelTap: () => _confirmCancel(
                              context,
                              reservationId: rec.reservationId,
                              account: rec.account,
                              location: rec.location,
                              begin: rec.begin,
                              end: rec.end,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                    ],

                  const SizedBox(height: 10),

                  // 2. 7日信用 3 点刻度守护条（双账号时合并展示两个账号）
                  _buildCreditGuardCard(dual, accFilter),
                  const SizedBox(height: 10),

                  // 3. 馆内自习伴侣双卡：暂离防丢座倒计时 + 馆内专注计时器
                  Row(
                    children: <Widget>[
                      Expanded(child: _buildTempLeaveCard(context)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildFocusTimerCard(context)),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 4. 辽大图书馆官方公告（直连 /rest/v2/announce）
                  _buildAnnouncementCard(context, announcements),
                  const SizedBox(height: 10),

                  // 5. 我的辽大自习书简（直连 /rest/v2/history，兼容双账号合并与单号查看）
                  _buildStudyLetterCard(context, letter, dual, accFilter),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAccountScopeBar() {
    final acc1 = controller.config.account1.trim();
    final acc2 = controller.config.account2.trim();
    final tabs = <(int, String)>[
      (0, '全部合并'),
      (1, acc1.isNotEmpty ? '主号 · ${_tail4(acc1)}' : '主号'),
      (2, acc2.isNotEmpty ? '副号 · ${_tail4(acc2)}' : '副号'),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LnuColors.cardSunk,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LnuColors.border),
      ),
      child: Row(
        children: tabs.map((item) {
          final selected = _accountScope == item.$1;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _accountScope = item.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? LnuColors.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(
                  item.$2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : LnuColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCompactEmptyPassCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: LnuColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LnuColors.borderDark),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 40,
            height: 40,
            child: Image.asset(
              'assets/images/lnu_crest.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.menu_book_rounded,
                color: LnuColors.ink,
                size: 32,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '当前暂无有效阅览座签',
                  style: TextStyle(
                    color: LnuColors.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '约座成功后，凭证号与签到提醒将自动展示在此',
                  style: TextStyle(
                    color: LnuColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (onJumpToFindSeat != null)
            TextButton(
              onPressed: onJumpToFindSeat,
              child: const Text(
                '去寻座 →',
                style: TextStyle(
                  color: LnuColors.amberDeep,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCreditGuardCard(bool dual, String? accFilter) {
    final snaps = controller.accountPassSnapshots
        .where((s) => accFilter == null || s.account == accFilter)
        .toList();
    if (snaps.isEmpty) {
      final profile = controller.currentUserProfile;
      final violations = profile?.violationCount ?? 0;
      return _buildSingleCreditCard(
        label: '',
        username: profile?.username ?? '',
        violations: violations,
      );
    }
    if (snaps.length == 1) {
      final s = snaps.first;
      return _buildSingleCreditCard(
        label: dual ? s.label : '',
        username: s.profile?.username ?? s.account,
        violations: s.profile?.violationCount ?? 0,
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '七日违约信用（双号守护）',
              style: LnuTheme.serif(14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            for (var idx = 0; idx < snaps.length; idx++) ...<Widget>[
              if (idx > 0) const Divider(height: 14, color: LnuColors.border),
              _buildCreditRow(
                label: snaps[idx].label,
                username: snaps[idx].profile?.username ?? snaps[idx].account,
                violations: snaps[idx].profile?.violationCount ?? 0,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSingleCreditCard({
    required String label,
    required String username,
    required int violations,
  }) {
    final safe = violations < 2;
    final prefix = label.isNotEmpty ? '$label ' : '';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '七日违约信用',
                  style: LnuTheme.serif(14, weight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text(
                  username.isNotEmpty ? '${prefix}学号 $username' : '点击右上角同步',
                  style: const TextStyle(
                    color: LnuColors.textDim,
                    fontSize: 11.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '$violations / 3',
                  style: LnuTheme.mono(
                    13,
                    weight: FontWeight.w700,
                    color: safe ? LnuColors.ok : LnuColors.err,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                for (var i = 0; i < 3; i++) ...<Widget>[
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < violations
                          ? LnuColors.err
                          : LnuColors.bgPaper,
                      border: Border.all(
                        color: i < violations
                            ? LnuColors.err
                            : LnuColors.ok,
                        width: 1.8,
                      ),
                    ),
                  ),
                  if (i < 2)
                    Container(
                      width: 24,
                      height: 1.5,
                      color: LnuColors.borderDark,
                    ),
                ],
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    violations >= 3
                        ? '已触黑名单红线（暂停 7 天）'
                        : '签到宽限前后 30 分钟 · 满 3 次停权 7 天',
                    style: const TextStyle(
                      color: LnuColors.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreditRow({
    required String label,
    required String username,
    required int violations,
  }) {
    final safe = violations < 2;
    return Row(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: LnuColors.cardSunk,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: LnuColors.border),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: LnuColors.ink,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          username,
          style: LnuTheme.mono(12, color: LnuColors.textMuted),
        ),
        const SizedBox(width: 10),
        for (var i = 0; i < 3; i++) ...<Widget>[
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < violations ? LnuColors.err : LnuColors.bgPaper,
              border: Border.all(
                color: i < violations ? LnuColors.err : LnuColors.ok,
                width: 1.5,
              ),
            ),
          ),
          if (i < 2)
            Container(width: 12, height: 1.2, color: LnuColors.borderDark),
        ],
        const Spacer(),
        Text(
          '$violations / 3',
          style: LnuTheme.mono(
            12.5,
            weight: FontWeight.w700,
            color: safe ? LnuColors.ok : LnuColors.err,
          ),
        ),
      ],
    );
  }

  Widget _buildTempLeaveCard(BuildContext context) {
    final active = controller.tempLeaveRemainingSec > 0;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openTempLeavePicker(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.timer_outlined,
                    size: 18,
                    color: LnuColors.amberHot,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '暂离防丢座',
                    style: LnuTheme.serif(13.5, weight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                active
                    ? _formatDuration(controller.tempLeaveRemainingSec)
                    : '未计时',
                style: LnuTheme.mono(
                  20,
                  weight: FontWeight.w700,
                  color: active ? LnuColors.amberDeep : LnuColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                active ? '剩 5 分钟前自动提醒回馆' : '去食堂/接水前点此设闹钟',
                style: const TextStyle(
                  color: LnuColors.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFocusTimerCard(BuildContext context) {
    final running = controller.focusRunning;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => controller.toggleFocusTimer(),
        onLongPress: controller.resetFocusTimer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    running
                        ? Icons.pause_circle_outline_rounded
                        : Icons.menu_book_outlined,
                    size: 18,
                    color: LnuColors.ink,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '馆内专注',
                    style: LnuTheme.serif(13.5, weight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _formatDuration(controller.focusElapsedSec),
                style: LnuTheme.mono(
                  20,
                  weight: FontWeight.w700,
                  color: running ? LnuColors.ok : LnuColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                running ? '点按暂停 · 长按归零' : '轻点开始记录本次自习',
                style: const TextStyle(
                  color: LnuColors.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnnouncementCard(
    BuildContext context,
    List<AnnouncementItem> items,
  ) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.campaign_outlined,
                  size: 18,
                  color: LnuColors.ink,
                ),
                const SizedBox(width: 6),
                Text(
                  '馆方公告',
                  style: LnuTheme.serif(14.5, weight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  items.isEmpty ? '同步查看' : '共 ${items.length} 条',
                  style: const TextStyle(
                    color: LnuColors.textDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              const Text(
                '同步后自动拉取辽宁大学图书馆最新开闭馆与维护公告',
                style: TextStyle(color: LnuColors.textMuted, fontSize: 12.5),
              )
            else
              for (final item in items.take(3))
                InkWell(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: LnuColors.card,
                      title: Text(
                        item.title.length > 18 ? '图书馆公告' : item.title,
                        style: LnuTheme.serif(16, weight: FontWeight.w700),
                      ),
                      content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (item.title.length > 18 &&
                                item.title != item.content) ...<Widget>[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: LnuColors.amberGlow,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  item.title,
                                  style: const TextStyle(
                                    color: LnuColors.amberDeep,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            SelectableText(
                              item.content.isNotEmpty
                                  ? item.content
                                  : item.title,
                              style: const TextStyle(
                                color: LnuColors.text,
                                height: 1.65,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: LnuColors.amberHot,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LnuColors.text,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (item.date.isNotEmpty)
                          Text(
                            item.date,
                            style: LnuTheme.mono(
                              11,
                              color: LnuColors.textDim,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudyLetterCard(
    BuildContext context,
    StudyLetterSummary letter,
    bool dual,
    String? accFilter,
  ) {
    final scopeTag = !dual
        ? ''
        : (accFilter == null
            ? '双号合辑'
            : controller.accountRoleLabel(accFilter));
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openStudyLetterSheet(context, dual, accFilter),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.auto_stories_outlined,
                    size: 18,
                    color: LnuColors.amberHot,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '辽大自习书简',
                    style: LnuTheme.serif(14.5, weight: FontWeight.w700),
                  ),
                  if (scopeTag.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: LnuColors.amberGlow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        scopeTag,
                        style: const TextStyle(
                          color: LnuColors.amberDeep,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  const Text(
                    '查看足迹 ›',
                    style: TextStyle(
                      color: LnuColors.amberDeep,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  _statBlock('${letter.totalVisits}', '近期约座(次)'),
                  _statBlock(
                    letter.totalHours.toStringAsFixed(1),
                    '累计时长(h)',
                  ),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          letter.favoriteLocation,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LnuTheme.serif(14, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          '最常驻足自习室',
                          style: TextStyle(
                            color: LnuColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statBlock(String val, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            val,
            style: LnuTheme.mono(20, weight: FontWeight.w700, color: LnuColors.ink),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: LnuColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Future<void> _openTempLeavePicker(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: LnuColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('设置暂离回馆闹钟', style: LnuTheme.serif(17, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              '离开座位前记得在馆内刷卡暂离，并开启倒计时防止超时丢座违约。',
              style: TextStyle(color: LnuColors.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: LnuOutlineButton(
                    label: '25 分钟（常规）',
                    onPressed: () {
                      controller.startTempLeave(25);
                      Navigator.of(ctx).pop();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LnuAmberButton(
                    label: '55 分钟（用餐）',
                    onPressed: () {
                      controller.startTempLeave(55);
                      Navigator.of(ctx).pop();
                    },
                  ),
                ),
              ],
            ),
            if (controller.tempLeaveRemainingSec > 0) ...<Widget>[
              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: () {
                    controller.stopTempLeave();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text(
                    '我已回馆，停止暂离倒计时',
                    style: TextStyle(color: LnuColors.err),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openStudyLetterSheet(
    BuildContext context,
    bool dual,
    String? initialAccFilter,
  ) async {
    var sheetFilter = initialAccFilter;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LnuColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => ListenableBuilder(
          listenable: controller,
          builder: (_, __) {
            final letter = controller.computeStudyLetter(
              accountFilter: sheetFilter,
            );
            final list = controller.historyForAccount(sheetFilter);
            final acc1 = controller.config.account1.trim();
            final acc2 = controller.config.account2.trim();
            final sum1 = acc1.isNotEmpty
                ? controller.computeStudyLetter(accountFilter: acc1)
                : null;
            final sum2 = acc2.isNotEmpty
                ? controller.computeStudyLetter(accountFilter: acc2)
                : null;

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.78,
              maxChildSize: 0.92,
              builder: (_, scrollCtrl) => ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(18),
                children: <Widget>[
                  if (dual) ...<Widget>[
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: LnuColors.cardSunk,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: LnuColors.border),
                      ),
                      child: Row(
                        children: <(String?, String)>[
                          (null, '双号合辑'),
                          (acc1.isNotEmpty ? acc1 : null, '主号'),
                          (acc2.isNotEmpty ? acc2 : null, '副号'),
                        ].asMap().entries.map((entry) {
                          final idx = entry.key;
                          final val = entry.value.$1;
                          final label = entry.value.$2;
                          final selected = (idx == 0 && sheetFilter == null) ||
                              (idx == 1 &&
                                  acc1.isNotEmpty &&
                                  sheetFilter == acc1) ||
                              (idx == 2 &&
                                  acc2.isNotEmpty &&
                                  sheetFilter == acc2);
                          return Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setSheetState(() {
                                  sheetFilter = idx == 0 ? null : val;
                                });
                              },
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? LnuColors.ink
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : LnuColors.textMuted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // 复古宣纸书简卡片
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: LnuColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: LnuColors.borderDark, width: 1.2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '辽宁大学图书馆 · 自习书简',
                          style: LnuTheme.serif(17, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dual && sheetFilter == null
                              ? '明德精学 · 笃行致强（双号合辑）'
                              : (sheetFilter != null
                                  ? '${controller.accountRoleLabel(sheetFilter!)} · $sheetFilter'
                                  : '明德精学 · 笃行致强'),
                          style: const TextStyle(
                            color: LnuColors.amberDeep,
                            fontSize: 12,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const Divider(height: 22),
                        Text(
                          '近阶段共入馆约座 ${letter.totalVisits} 次，'
                          '累计伏案约 ${letter.totalHours.toStringAsFixed(1)} 小时。\n'
                          '最常相伴的一方书桌在「${letter.favoriteLocation}」。',
                          style: const TextStyle(
                            color: LnuColors.text,
                            fontSize: 14,
                            height: 1.75,
                          ),
                        ),
                        if (dual &&
                            sheetFilter == null &&
                            sum1 != null &&
                            sum2 != null) ...<Widget>[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: LnuColors.cardSunk,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    '主号：${sum1.totalVisits} 次 · ${sum1.totalHours.toStringAsFixed(1)}h',
                                    style: LnuTheme.mono(
                                      11.5,
                                      color: LnuColors.ink,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '副号：${sum2.totalVisits} 次 · ${sum2.totalHours.toStringAsFixed(1)}h',
                                    textAlign: TextAlign.right,
                                    style: LnuTheme.mono(
                                      11.5,
                                      color: LnuColors.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '历史预约明细（${list.length} 条）',
                    style: LnuTheme.serif(14.5, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          '暂无历史预约记录，点击入馆页右上角「同步」拉取',
                          style: TextStyle(
                            color: LnuColors.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final rec in list)
                      _buildHistoryRowCard(sheetCtx, rec, dual),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHistoryRowCard(
    BuildContext context,
    HistoryRecord rec,
    bool dual,
  ) {
    final isReservableCancel =
        rec.stat.toUpperCase() == 'RESERVE' && rec.id.trim().isNotEmpty;
    final isCancelling = controller.cancellingReservationId == rec.id;
    final rolePrefix = dual && rec.account.isNotEmpty
        ? '[${controller.accountRoleLabel(rec.account)}] '
        : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        title: Text(
          '$rolePrefix${rec.location.isNotEmpty ? rec.location : "图书馆座位"}',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        subtitle: Text(
          '${rec.date}  ${rec.begin}–${rec.end}',
          style: LnuTheme.mono(11.5, color: LnuColors.textMuted),
        ),
        trailing: isReservableCancel
            ? OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: LnuColors.err,
                  side: const BorderSide(color: LnuColors.err),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: isCancelling
                    ? null
                    : () => _confirmCancel(
                          context,
                          reservationId: rec.id,
                          account: rec.account,
                          location: rec.location,
                          begin: rec.begin,
                          end: rec.end,
                        ),
                child: Text(
                  isCancelling ? '取消中' : '取消预约',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : Text(
                rec.stat,
                style: TextStyle(
                  color: rec.stat.toUpperCase().contains('CANCEL')
                      ? LnuColors.textDim
                      : LnuColors.amberDeep,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  Future<void> _confirmCancel(
    BuildContext context, {
    required String reservationId,
    required String account,
    required String location,
    required String begin,
    required String end,
  }) async {
    final accLine = account.trim().isNotEmpty
        ? '账号：${controller.accountRoleLabel(account)}（$account）\n'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: LnuColors.card,
        title: Text('确认取消本次预约？', style: LnuTheme.serif(17)),
        content: Text(
          '${accLine}场馆：$location\n时段：$begin — $end\n\n注：每日最多允许取消 3 次。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保留座签'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LnuColors.err),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final res = await controller.cancelMyReservation(
      reservationId,
      account: account,
    );
    if (!context.mounted) {
      return;
    }
    final quota = res.totalCancelled != null
        ? '（今日已取消 ${res.totalCancelled}/${res.allowedCancel ?? 3} 次）'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? '已取消预约$quota'
              : (res.message.isNotEmpty ? '取消失败：${res.message}' : '取消预约失败，请稍后重试'),
        ),
      ),
    );
  }
}
