/// 频道 ①：晨约（06:30 校园的早晨 · 抢座主台）。
///
/// 1:1 延续桌面端 `02_gui_main.png` 的辽大书院金石质感：
/// - 暖米白纸感顶栏 + 正式校徽 `lnu_crest.png` + `LNU LibSeat`（无版本号）+ 状态胶囊
/// - 顶部多套「自习方案卡」横向速切
/// - 居中手绘双线印章计时仪 `LnuCountdownRing`
/// - 桌面同款渐变银杏琥珀按钮 `立 即 约 座 →` + `夜 守` / `中 止`
/// - 运行时柔和展开的三步琥珀生命线（登录校准 ── 空座锁定 ── 落座）
/// - 紧凑可点击目标条（半屏弹窗 3 秒速改）+ 桌面同款深海蓝 `RUN LOG`
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../logic/orchestrator.dart';
import '../../services/background_scheduler.dart';
import '../../services/config_store.dart';
import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/lnu_chrome.dart';
import '../widgets/lnu_countdown_ring.dart';
import '../widgets/lnu_run_log.dart';
import 'nightstand_screen.dart';

class HomeRushScreen extends StatefulWidget {
  final MobileRushController controller;
  final VoidCallback? onJumpToPass;

  const HomeRushScreen({
    super.key,
    required this.controller,
    this.onJumpToPass,
  });

  @override
  State<HomeRushScreen> createState() => _HomeRushScreenState();
}

class _HomeRushScreenState extends State<HomeRushScreen> {
  Timer? _tickTimer;
  DateTime _nowBj = currentBeijingTime();

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _nowBj = currentBeijingTime());
      }
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        widget.controller.config,
      ]),
      builder: (context, _) {
        final ctrl = widget.controller;
        final cfg = ctrl.config;
        final sched = buildCustomSchedule(
          cfg.schedHour,
          cfg.schedMin,
          nowBeijing: _nowBj,
        );
        final diffSecs = sched.fireAt.difference(_nowBj).inSeconds.clamp(0, 86400);
        final hh = _pad2(diffSecs ~/ 3600);
        final mm = _pad2((diffSecs % 3600) ~/ 60);
        final ss = _pad2(diffSecs % 60);
        final progress = 1.0 - (diffSecs / 86400.0).clamp(0.0, 1.0);

        // 状态胶囊文案与色点
        final String pillLabel;
        final Color pillDot;
        if (ctrl.isRunning) {
          pillLabel = cfg.scheduledMode && ctrl.rushStage == RushStepStage.waiting
              ? '守 夜'
              : '执 行 中';
          pillDot = LnuColors.amberHot;
        } else if (ctrl.lastSuccessEvent != null) {
          pillLabel = '已 落 座';
          pillDot = LnuColors.ok;
        } else {
          pillLabel = '就 绪';
          pillDot = LnuColors.ok;
        }

        // 圆环状态
        final SealRingMode ringMode;
        final String ringCenter;
        final String ringTop;
        final String ringBottom;
        if (ctrl.isRunning && ctrl.rushStage != RushStepStage.waiting) {
          ringMode = SealRingMode.running;
          ringCenter = '执 行 中';
          ringTop = '正  在  约  座';
          ringBottom = 'BEIJING ${_pad2(_nowBj.hour)}:${_pad2(_nowBj.minute)}:${_pad2(_nowBj.second)}';
        } else if (ctrl.lastSuccessEvent != null) {
          ringMode = SealRingMode.done;
          ringCenter = '已 落 座';
          ringTop = '约  座  完  成';
          ringBottom = '${ctrl.lastSuccessEvent!.roomName} · ${ctrl.lastSuccessEvent!.seatNo}号';
        } else if (cfg.scheduledMode) {
          ringMode = SealRingMode.scheduled;
          ringCenter = '$hh:$mm:$ss';
          ringTop = ctrl.isRunning ? '等  待  放  座' : '校  园  的  早  晨';
          ringBottom = 'BEIJING TIME  ${_pad2(cfg.schedHour)}:${_pad2(cfg.schedMin)}';
        } else {
          ringMode = SealRingMode.immediate;
          ringCenter = '立 即';
          ringTop = '立  即  模  式';
          ringBottom = '点 击 约 座 即 刻 执 行';
        }

        return Column(
          children: <Widget>[
            LnuPaperHeader(
              title: 'LNU LibSeat',
              subtitle: '辽宁大学图书馆',
              showCrest: true,
              trailing: LnuStatusPill(label: pillLabel, dotColor: pillDot),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                children: <Widget>[
                  // 1. 多套自习方案卡横滑速切条
                  _buildPresetStrip(context, cfg, ctrl.isRunning),
                  const SizedBox(height: 8),

                  // 2. 预约成功凭证横条（支持双号展示 + 直接在首页一键取消预约）
                  if (ctrl.recentSuccessEvents.isNotEmpty)
                    for (final ev in ctrl.recentSuccessEvents)
                      _buildSuccessStrip(context, ctrl, ev),

                  // 3. 英雄区：手绘双线印章计时仪
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: LnuCountdownRing(
                        mode: ringMode,
                        centerText: ringCenter,
                        topHint: ringTop,
                        bottomHint: ringBottom,
                        progress: progress,
                        size: 214,
                        onTap: ctrl.isRunning
                            ? null
                            : () {
                                cfg.scheduledMode = !cfg.scheduledMode;
                                cfg.saveToDisk();
                              },
                      ),
                    ),
                  ),

                  // 4. 桌面同款双模式切换胶囊（立即执行 / 定时 06:30）
                  Center(
                    child: _buildModePills(context, cfg, ctrl.isRunning),
                  ),
                  const SizedBox(height: 16),

                  // 5. 渐变银杏琥珀主按钮 + 素雅次按钮（夜守 / 中止）
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: LnuAmberButton(
                          label: ctrl.isRunning
                              ? '正  在  执  行'
                              : (cfg.scheduledMode
                                  ? '开  启  晨  约   →'
                                  : '立  即  约  座   →'),
                          onPressed: ctrl.isRunning
                              ? null
                              : () => _handleStartRushTap(context, ctrl, cfg),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (ctrl.isRunning)
                        LnuOutlineButton(
                          label: '中 止',
                          danger: true,
                          onPressed: ctrl.stopRush,
                        )
                      else if (cfg.scheduledMode)
                        LnuOutlineButton(
                          label: '夜 守',
                          icon: Icons.nights_stay_outlined,
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => NightstandScreen(controller: ctrl),
                              ),
                            );
                          },
                        )
                      else
                        const LnuOutlineButton(
                          label: '中 止',
                          danger: true,
                          onPressed: null,
                        ),
                    ],
                  ),

                  // 6. 运行中柔和浮现的三步琥珀生命线
                  if (ctrl.isRunning) ...<Widget>[
                    const SizedBox(height: 14),
                    _buildStepLifeline(ctrl.rushStage),
                  ],

                  const SizedBox(height: 14),

                  // 7. 紧凑目标速改卡片（轻点弹出半屏抽屉，3 秒调目标/首选座/时段）
                  _buildTargetSummaryCard(context, cfg, ctrl.isRunning),
                  const SizedBox(height: 12),

                  // 8. 桌面同款深海蓝 RUN LOG 卷轴终端
                  LnuRunLogTerminal(controller: ctrl, height: 158),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleStartRushTap(
    BuildContext context,
    MobileRushController ctrl,
    MobileConfigStore cfg,
  ) async {
    if (Platform.isAndroid && cfg.scheduledMode) {
      final st =
          await BackgroundSchedulerService.instance.getAndroidKeepAliveStatus();
      if (context.mounted && !st.ignoringBatteryOptimizations) {
        final action = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: LnuColors.card,
            title: Text(
              '请先开启后台高耗电 / 电池白名单',
              style: LnuTheme.serif(16.5, weight: FontWeight.w700),
            ),
            content: const Text(
              '检测到本机尚未放行后台电池优化。\n\n'
              'vivo (OriginOS) / 小米 / 华为 / OPPO 在锁屏后会立即触发「墓碑冻结」，导致定时抢座在锁屏期间暂停。\n\n'
              '建议先点下方按钮设为「允许后台高耗电 / 无限制」，并在应用权限里打开「自启动」「后台弹出界面」「锁屏显示」。',
              style: TextStyle(height: 1.55, fontSize: 13),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('start'),
                child: const Text('仍直接开始'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop('whitelist'),
                child: const Text('去开启白名单'),
              ),
            ],
          ),
        );
        if (action == 'whitelist') {
          await BackgroundSchedulerService.instance
              .requestIgnoreBatteryOptimizations();
          return;
        }
        if (action != 'start') {
          return;
        }
      }
    }
    await ctrl.startRush();
  }

  Widget _buildPresetStrip(
    BuildContext context,
    MobileConfigStore cfg,
    bool disabled,
  ) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          for (final preset in cfg.presets) ...<Widget>[
            GestureDetector(
              onTap: disabled ? null : () => cfg.applyPreset(preset),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: preset.id == cfg.activePresetId
                      ? LnuColors.ink
                      : LnuColors.card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: preset.id == cfg.activePresetId
                        ? LnuColors.ink
                        : LnuColors.border,
                  ),
                ),
                child: Text(
                  preset.name,
                  style: TextStyle(
                    color: preset.id == cfg.activePresetId
                        ? LnuColors.textInvert
                        : LnuColors.textMuted,
                    fontSize: 12,
                    fontWeight: preset.id == cfg.activePresetId
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: disabled ? null : () => _promptSavePreset(context, cfg),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: LnuColors.bgPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LnuColors.borderDark),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add_rounded, size: 15, color: LnuColors.amberHot),
                  SizedBox(width: 2),
                  Text(
                    '存方案',
                    style: TextStyle(
                      color: LnuColors.amberDeep,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessStrip(
    BuildContext context,
    MobileRushController ctrl,
    BookingSuccessEvent ev,
  ) {
    final dual = ctrl.config.useAccount2 || ctrl.recentSuccessEvents.length > 1;
    final rolePrefix = dual ? '[${ctrl.accountRoleLabel(ev.account)}] ' : '';
    final isCancelling =
        ev.reservationId.isNotEmpty &&
        ctrl.cancellingReservationId == ev.reservationId;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: LnuColors.ok.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LnuColors.ok.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.check_circle_outline_rounded,
            color: LnuColors.ok,
            size: 18,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: GestureDetector(
              onTap: widget.onJumpToPass,
              child: Text(
                '${rolePrefix}已落座 · ${ev.roomName} ${ev.seatNo}号（${ev.startTime}–${ev.endTime}）',
                style: const TextStyle(
                  color: LnuColors.inkDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (ev.reservationId.isNotEmpty)
            GestureDetector(
              onTap: isCancelling
                  ? null
                  : () => _confirmCancelFromHome(context, ctrl, ev),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: LnuColors.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: LnuColors.err.withValues(alpha: 0.7)),
                ),
                child: Text(
                  isCancelling ? '取消中...' : '取消预约',
                  style: const TextStyle(
                    color: LnuColors.err,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: widget.onJumpToPass,
            child: const Text(
              '座签 ›',
              style: TextStyle(
                color: LnuColors.ok,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCancelFromHome(
    BuildContext context,
    MobileRushController ctrl,
    BookingSuccessEvent ev,
  ) async {
    final role = ctrl.accountRoleLabel(ev.account);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: LnuColors.card,
        title: Text('确认取消本次预约？', style: LnuTheme.serif(17)),
        content: Text(
          '账号：$role（${ev.account}）\n'
          '场馆：${ev.roomName} ${ev.seatNo}号座\n'
          '时段：${ev.startTime} — ${ev.endTime}\n\n'
          '注：每日最多允许取消 3 次。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保留座位'),
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
    final res = await ctrl.cancelMyReservation(
      ev.reservationId,
      account: ev.account,
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
              ? '已取消 ${ev.roomName} ${ev.seatNo}号座$quota'
              : (res.message.isNotEmpty ? '取消失败：${res.message}' : '取消预约失败，请稍后重试'),
        ),
      ),
    );
  }

  Widget _buildModePills(
    BuildContext context,
    MobileConfigStore cfg,
    bool disabled,
  ) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LnuColors.cardSunk,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: LnuColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _modeChip(
            label: '立即执行',
            selected: !cfg.scheduledMode,
            onTap: disabled
                ? null
                : () {
                    cfg.scheduledMode = false;
                    cfg.saveToDisk();
                  },
          ),
          _modeChip(
            label: '定时 ${_pad2(cfg.schedHour)}:${_pad2(cfg.schedMin)}',
            selected: cfg.scheduledMode,
            onTap: disabled
                ? null
                : () async {
                    if (!cfg.scheduledMode) {
                      cfg.scheduledMode = true;
                      await cfg.saveToDisk();
                    } else {
                      final picked = await _show24hWheelTimePicker(
                        context,
                        initialHour: cfg.schedHour,
                        initialMinute: cfg.schedMin,
                      );
                      if (picked != null) {
                        cfg.schedHour = picked.$1;
                        cfg.schedMin = picked.$2;
                        await cfg.saveToDisk();
                      }
                    }
                  },
          ),
        ],
      ),
    );
  }

  Widget _modeChip({
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? LnuColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? LnuColors.textInvert : LnuColors.textMuted,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  Widget _buildStepLifeline(RushStepStage stage) {
    final stepIdx = switch (stage) {
      RushStepStage.waiting || RushStepStage.login => 0,
      RushStepStage.seatSearch => 1,
      RushStepStage.booking || RushStepStage.success => 2,
      RushStepStage.idle => 0,
    };

    const labels = <String>['登录校准', '空座锁定', '验证落座'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: LnuColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LnuColors.border),
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < labels.length; i++) ...<Widget>[
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= stepIdx ? LnuColors.amberHot : LnuColors.cardSunk,
              ),
              child: Text(
                '${i + 1}',
                style: TextStyle(
                  color: i <= stepIdx ? Colors.white : LnuColors.textDim,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              labels[i],
              style: TextStyle(
                color: i <= stepIdx ? LnuColors.ink : LnuColors.textDim,
                fontSize: 12,
                fontWeight: i == stepIdx ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            if (i < labels.length - 1)
              Expanded(
                child: Container(
                  height: 1.4,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: i < stepIdx ? LnuColors.amberHot : LnuColors.border,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildTargetSummaryCard(
    BuildContext context,
    MobileConfigStore cfg,
    bool disabled,
  ) {
    final shortCampus = cfg.campus.replaceAll('校区图书馆', '');
    final seatSummary = cfg.preferSeats.isEmpty
        ? '全室实时空座'
        : '首选 ${cfg.preferSeats.take(4).join(" → ")}${cfg.preferSeats.length > 4 ? " 等${cfg.preferSeats.length}座" : ""}';
    final accSummary = cfg.useAccount2
        ? '双号接力 (${cfg.start1}–${cfg.end1} / ${cfg.start2}–${cfg.end2})'
        : '${cfg.start1}–${cfg.end1}';

    return Material(
      color: LnuColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: LnuColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: disabled ? null : () => _openQuickEditSheet(context, cfg),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: <Widget>[
              Container(
                width: 3,
                height: 34,
                decoration: BoxDecoration(
                  color: LnuColors.amberHot,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '$shortCampus · ${cfg.room}',
                      style: LnuTheme.serif(
                        15,
                        weight: FontWeight.w700,
                        color: LnuColors.ink,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$seatSummary  ·  $accSummary',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LnuColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Text(
                '速改',
                style: TextStyle(
                  color: LnuColors.amberDeep,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: LnuColors.amberDeep,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openQuickEditSheet(
    BuildContext context,
    MobileConfigStore cfg,
  ) async {
    var pickCampus = cfg.campus;
    var pickRoom = cfg.room;
    final start1Ctrl = TextEditingController(text: cfg.start1);
    final end1Ctrl = TextEditingController(text: cfg.end1);
    final start2Ctrl = TextEditingController(text: cfg.start2);
    final end2Ctrl = TextEditingController(text: cfg.end2);
    var editingAccount = 1; // 1=主账号, 2=副账号
    // 显式使用有序列表维护首选座顺位（点击先后 = 抢座优先级）
    final selectedSeats = <String>[];
    for (final s in cfg.preferSeats) {
      if (!selectedSeats.contains(s)) {
        selectedSeats.add(s);
      }
    }

    const quickSlots = <(String, String, String)>[
      ('早八连堂', '08:00', '14:00'),
      ('上午自习', '09:00', '15:00'),
      ('十点连坐', '10:00', '16:00'),
      ('午后自习', '13:00', '19:00'),
      ('下午冲刺', '14:00', '20:00'),
      ('午晚连堂', '15:00', '21:00'),
      ('晚间自习', '18:00', '22:00'),
      ('此刻至闭馆', 'now', '22:00'),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LnuColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final campuses = cfg.catalog.campuses.keys.toList();
            final rooms = cfg.catalog.roomsForCampus(pickCampus);
            if (!rooms.contains(pickRoom) && rooms.isNotEmpty) {
              pickRoom = rooms.first;
            }
            final allSeats = cfg.catalog.seatsForRoom(pickRoom);
            final dual = cfg.useAccount2;
            final activeStartCtrl =
                (!dual || editingAccount == 1) ? start1Ctrl : start2Ctrl;
            final activeEndCtrl =
                (!dual || editingAccount == 1) ? end1Ctrl : end2Ctrl;

            return Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                16,
                18,
                MediaQuery.of(ctx).viewInsets.bottom + 18,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '快速调整目标',
                          style: LnuTheme.serif(17, weight: FontWeight.w700),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(sheetCtx).pop(),
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: campuses.contains(pickCampus)
                          ? pickCampus
                          : campuses.first,
                      decoration: const InputDecoration(labelText: '目标校区'),
                      items: campuses
                          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setSheetState(() {
                            pickCampus = v;
                            pickRoom = cfg.catalog.roomsForCampus(v).first;
                            selectedSeats.clear();
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: pickRoom,
                      decoration: const InputDecoration(labelText: '目标自习室'),
                      items: rooms
                          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setSheetState(() {
                            pickRoom = v;
                            selectedSeats.clear();
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    if (dual) ...<Widget>[
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: LnuColors.cardSunk,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: LnuColors.border),
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: GestureDetector(
                                onTap: () =>
                                    setSheetState(() => editingAccount = 1),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 7),
                                  decoration: BoxDecoration(
                                    color: editingAccount == 1
                                        ? LnuColors.ink
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '主号 ${start1Ctrl.text.trim()}–${end1Ctrl.text.trim()}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: editingAccount == 1
                                          ? Colors.white
                                          : LnuColors.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () =>
                                    setSheetState(() => editingAccount = 2),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 7),
                                  decoration: BoxDecoration(
                                    color: editingAccount == 2
                                        ? LnuColors.ink
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '副号 ${start2Ctrl.text.trim()}–${end2Ctrl.text.trim()}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: editingAccount == 2
                                          ? Colors.white
                                          : LnuColors.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text(
                      dual
                          ? '常用自习时段（当前修改：${editingAccount == 1 ? '主账号' : '副账号'}）'
                          : '常用自习时段',
                      style: const TextStyle(
                        color: LnuColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: quickSlots.map((slot) {
                        final isSelected =
                            activeStartCtrl.text.trim() == slot.$2 &&
                                activeEndCtrl.text.trim() == slot.$3;
                        return ActionChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: isSelected
                              ? LnuColors.amberGlow
                              : LnuColors.card,
                          side: BorderSide(
                            color: isSelected
                                ? LnuColors.amberDeep
                                : LnuColors.border,
                          ),
                          label: Text(
                            '${slot.$1} (${slot.$2}–${slot.$3})',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? LnuColors.amberDeep
                                  : LnuColors.text,
                            ),
                          ),
                          onPressed: () {
                            setSheetState(() {
                              activeStartCtrl.text = slot.$2;
                              activeEndCtrl.text = slot.$3;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: ValueKey<String>(
                              'quick_start_$editingAccount',
                            ),
                            controller: activeStartCtrl,
                            onChanged: (_) => setSheetState(() {}),
                            decoration: InputDecoration(
                              labelText: dual
                                  ? (editingAccount == 1
                                      ? '主账号开始时段'
                                      : '副账号开始时段')
                                  : '开始时段',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: ValueKey<String>('quick_end_$editingAccount'),
                            controller: activeEndCtrl,
                            onChanged: (_) => setSheetState(() {}),
                            decoration: InputDecoration(
                              labelText: dual
                                  ? (editingAccount == 1
                                      ? '主账号结束时段'
                                      : '副账号结束时段')
                                  : '结束时段',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        Text(
                          '${dual ? "共用首选座位" : "首选座位"} (${selectedSeats.isEmpty ? "留空抢全室空座" : "按点击顺位抢 · 已选 ${selectedSeats.length} 个"})',
                          style: const TextStyle(
                            color: LnuColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (selectedSeats.isNotEmpty)
                          GestureDetector(
                            onTap: () => setSheetState(selectedSeats.clear),
                            child: const Text(
                              '清空',
                              style: TextStyle(
                                color: LnuColors.amberDeep,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (selectedSeats.isEmpty)
                      const Text(
                        '按点击先后顺序依次尝试（1 → 2 → 3…），留空则抢全室实时空座',
                        style: TextStyle(
                          color: LnuColors.textDim,
                          fontSize: 11,
                        ),
                      )
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            for (var i = 0; i < selectedSeats.length; i++) ...<Widget>[
                              if (i > 0)
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Text(
                                    '→',
                                    style: TextStyle(
                                      color: LnuColors.textDim,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              GestureDetector(
                                key: ValueKey<String>(
                                  'prefer_order_chip_${selectedSeats[i]}',
                                ),
                                onTap: () {
                                  setSheetState(() {
                                    selectedSeats.removeAt(i);
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: LnuColors.amberGlow,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: LnuColors.amberHot,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4.5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: LnuColors.ink,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${i + 1}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            fontFeatures: <FontFeature>[
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${selectedSeats[i]}号',
                                        style: const TextStyle(
                                          color: LnuColors.ink,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      const Icon(
                                        Icons.close_rounded,
                                        size: 12,
                                        color: LnuColors.amberDeep,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 168,
                      child: GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 1.32,
                        ),
                        itemCount: allSeats.length,
                        itemBuilder: (_, idx) {
                          final s = allSeats[idx];
                          final orderIdx = selectedSeats.indexOf(s);
                          final picked = orderIdx >= 0;
                          return GestureDetector(
                            key: ValueKey<String>('prefer_seat_cell_$s'),
                            onTap: () {
                              setSheetState(() {
                                if (picked) {
                                  selectedSeats.removeAt(orderIdx);
                                } else {
                                  selectedSeats.add(s);
                                }
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: picked ? LnuColors.ink : LnuColors.card,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: picked
                                      ? LnuColors.amberHot
                                      : LnuColors.border,
                                  width: picked ? 1.2 : 1.0,
                                ),
                              ),
                              child: Stack(
                                children: <Widget>[
                                  Center(
                                    child: Padding(
                                      padding: picked
                                          ? const EdgeInsets.only(
                                              top: 5,
                                              right: 5,
                                            )
                                          : EdgeInsets.zero,
                                      child: Text(
                                        s,
                                        style: TextStyle(
                                          color: picked
                                              ? Colors.white
                                              : LnuColors.text,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (picked)
                                    Positioned(
                                      top: 2,
                                      right: 2,
                                      child: Container(
                                        key: ValueKey<String>(
                                          'prefer_seat_rank_$s',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 0.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: LnuColors.amberHot,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '${orderIdx + 1}',
                                          style: const TextStyle(
                                            color: LnuColors.ink,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            height: 1.1,
                                            fontFeatures: <FontFeature>[
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    LnuAmberButton(
                      label: '保  存  调  整',
                      onPressed: () {
                        cfg.campus = pickCampus;
                        cfg.room = pickRoom;
                        cfg.start1 = start1Ctrl.text.trim();
                        cfg.end1 = end1Ctrl.text.trim();
                        if (cfg.useAccount2) {
                          cfg.start2 = start2Ctrl.text.trim();
                          cfg.end2 = end2Ctrl.text.trim();
                        }
                        cfg.preferSeats = List<String>.from(selectedSeats);
                        cfg.saveToDisk();
                        Navigator.of(sheetCtx).pop();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    start1Ctrl.dispose();
    end1Ctrl.dispose();
    start2Ctrl.dispose();
    end2Ctrl.dispose();
  }

  Future<void> _promptSavePreset(
    BuildContext context,
    MobileConfigStore cfg,
  ) async {
    final nameCtrl = TextEditingController(
      text: cfg.room.length > 6 ? cfg.room.substring(0, 6) : cfg.room,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: LnuColors.card,
        title: Text('另存为自习方案', style: LnuTheme.serif(17)),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: '方案名称（如：考研早八、周末背书）',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed == true && nameCtrl.text.trim().isNotEmpty) {
      await cfg.saveCurrentAsPreset(nameCtrl.text.trim());
    }
    nameCtrl.dispose();
  }

  Future<(int, int)?> _show24hWheelTimePicker(
    BuildContext context, {
    required int initialHour,
    required int initialMinute,
  }) {
    return showModalBottomSheet<(int, int)>(
      context: context,
      backgroundColor: LnuColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _WheelTimePickerSheet(
        initialHour: initialHour.clamp(0, 23),
        initialMinute: initialMinute.clamp(0, 59),
      ),
    );
  }
}

class _WheelTimePickerSheet extends StatefulWidget {
  final int initialHour;
  final int initialMinute;

  const _WheelTimePickerSheet({
    required this.initialHour,
    required this.initialMinute,
  });

  @override
  State<_WheelTimePickerSheet> createState() => _WheelTimePickerSheetState();
}

class _WheelTimePickerSheetState extends State<_WheelTimePickerSheet> {
  late int _hour;
  late int _minute;
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minCtrl;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialHour;
    _minute = widget.initialMinute;
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: LnuColors.textMuted, fontSize: 15),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '选择定时时间 (24小时制)',
                      style: LnuTheme.serif(15.5, weight: FontWeight.w700),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop((_hour, _minute)),
                  child: const Text(
                    '确定',
                    style: TextStyle(
                      color: LnuColors.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 8, color: LnuColors.border),
            SizedBox(
              height: 210,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  IgnorePointer(
                    child: Container(
                      height: 44,
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: LnuColors.cardSunk,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: LnuColors.border),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: 112,
                        child: CupertinoPicker(
                          scrollController: _hourCtrl,
                          itemExtent: 44,
                          looping: true,
                          selectionOverlay: const SizedBox.shrink(),
                          onSelectedItemChanged: (idx) {
                            setState(() => _hour = idx % 24);
                          },
                          children: List<Widget>.generate(
                            24,
                            (i) => Center(
                              child: Text(
                                _pad2(i),
                                style: LnuTheme.mono(
                                  24,
                                  weight: FontWeight.w700,
                                  color: LnuColors.ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          ':',
                          style: LnuTheme.mono(
                            24,
                            weight: FontWeight.w700,
                            color: LnuColors.ink,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 112,
                        child: CupertinoPicker(
                          scrollController: _minCtrl,
                          itemExtent: 44,
                          looping: true,
                          selectionOverlay: const SizedBox.shrink(),
                          onSelectedItemChanged: (idx) {
                            setState(() => _minute = idx % 60);
                          },
                          children: List<Widget>.generate(
                            60,
                            (i) => Center(
                              child: Text(
                                _pad2(i),
                                style: LnuTheme.mono(
                                  24,
                                  weight: FontWeight.w700,
                                  color: LnuColors.ink,
                                ),
                              ),
                            ),
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
}
