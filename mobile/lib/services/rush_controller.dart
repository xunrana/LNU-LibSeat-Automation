/// 移动端全局约座、双馆寻座、入馆伴侣与自习书简状态控制器。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/captcha/captcha_service.dart';
import '../core/clock_sync.dart';
import '../core/libseat_client.dart';
import '../core/rate_limiter.dart';
import '../core/session_recorder.dart';
import '../logic/orchestrator.dart';
import '../logic/seat_strategy.dart';
import 'background_scheduler.dart';
import 'config_store.dart';
import 'notification_service.dart';

enum RushStepStage {
  idle,
  waiting,
  login,
  seatSearch,
  booking,
  success,
}

class LogEntry {
  final String timeStr;
  final String account;
  final String message;

  const LogEntry({
    required this.timeStr,
    required this.account,
    required this.message,
  });

  String get formatted => '[$timeStr] $message';
}

class StudyLetterSummary {
  final int totalVisits;
  final double totalHours;
  final String favoriteLocation;
  final int completedCount;

  const StudyLetterSummary({
    required this.totalVisits,
    required this.totalHours,
    required this.favoriteLocation,
    required this.completedCount,
  });
}

class AccountPassSnapshot {
  final String account;
  final String label; // '主号' 或 '副号'
  final UserProfile? profile;
  final List<ReservationRecord> activeReservations;
  final List<HistoryRecord> historyRecords;
  final String error;

  const AccountPassSnapshot({
    required this.account,
    required this.label,
    this.profile,
    this.activeReservations = const <ReservationRecord>[],
    this.historyRecords = const <HistoryRecord>[],
    this.error = '',
  });
}

class MobileRushController extends ChangeNotifier {
  final MobileConfigStore config;
  final OnnxCaptchaService captchaService = OnnxCaptchaService();

  CancelTokenSource? _activeStopToken;
  bool isRunning = false;
  RushStepStage rushStage = RushStepStage.idle;
  String statusLabel = '就绪';
  final List<LogEntry> logEntries = <LogEntry>[];
  CaptchaDiagnosticMeta? latestDiagnostic;
  final List<BookingSuccessEvent> recentSuccessEvents = <BookingSuccessEvent>[];

  BookingSuccessEvent? get lastSuccessEvent =>
      recentSuccessEvents.isNotEmpty ? recentSuccessEvents.last : null;

  // 寻座：全馆实时余座与单室网格
  bool radarLoading = false;
  String radarError = '';
  List<RoomStats> radarStats = <RoomStats>[];
  List<SeatCandidate> selectedRoomSeats = <SeatCandidate>[];
  String? selectedRadarRoomName;

  // 寻座：满员房间低频合规蹲守（每 60 秒轻查一次 stats2）
  Timer? _watchTimer;
  String? watchingCampus;
  String? watchingRoomName;
  int watchCheckCount = 0;

  // 入馆：当前预约、官方公告、历史足迹与自习书简（支持双账号合并与分账号查看）
  bool passLoading = false;
  String? cancellingReservationId;
  String passError = '';
  List<AccountPassSnapshot> accountPassSnapshots = <AccountPassSnapshot>[];
  List<ReservationRecord> activeReservations = <ReservationRecord>[];
  List<AnnouncementItem> announcements = <AnnouncementItem>[];
  List<HistoryRecord> historyRecords = <HistoryRecord>[];
  UserProfile? currentUserProfile;

  // 入馆：暂离防丢座倒计时 & 馆内专注计时器
  Timer? _tempLeaveTimer;
  int tempLeaveRemainingSec = 0;
  bool _tempLeaveFiveMinWarned = false;

  Timer? _focusTimer;
  int focusElapsedSec = 0;
  int focusTargetSec = 25 * 60;
  bool focusRunning = false;

  StreamSubscription<String>? _deepLinkSub;

  MobileRushController({required this.config}) {
    _deepLinkSub = BackgroundSchedulerService.instance.onDeepLinkCommand.listen(
      (cmd) {
        if (!isRunning) {
          appendLog('system', '收到系统自动化唤醒指令 ($cmd)，正在启动约座...');
          startRush();
        } else if (cmd.startsWith('exact_alarm')) {
          appendLog('system', '⏰ 系统闹钟已准点唤醒 CPU，隔夜守夜正常推进中');
        }
      },
    );
  }

  /// App 冷启动后检测是否由 Android 隔夜闹钟拉起，或上次隔夜守夜进程曾被系统回收需要自动接力。
  Future<void> checkAndResumePendingAlarmRush() async {
    if (isRunning) {
      return;
    }
    final action =
        await BackgroundSchedulerService.instance.consumePendingWakeupRush();
    if (action == PendingRushAction.none || isRunning) {
      return;
    }
    if (action == PendingRushAction.fireImmediately) {
      appendLog('system', '⏰ 隔夜闹钟冷启动唤醒已达放座时刻，立即切入极速约座！');
      await startRush(overrideScheduled: false);
    } else if (action == PendingRushAction.resumeScheduled) {
      appendLog('system', '⏰ 检测到待执行的隔夜守夜任务，自动接力恢复准点守夜...');
      await startRush(overrideScheduled: true);
    }
  }

  List<LogEntry> logsForFilter(int tabIndex) {
    if (tabIndex == 0) {
      return logEntries;
    }
    final targetAcc =
        tabIndex == 1 ? config.account1.trim() : config.account2.trim();
    if (targetAcc.isEmpty) {
      return const <LogEntry>[];
    }
    return logEntries
        .where((e) => e.account == targetAcc || e.message.contains('[$targetAcc]'))
        .toList(growable: false);
  }

  void appendLog(String account, String message) {
    final bj = currentBeijingTime();
    final entry = LogEntry(
      timeStr: formatHms(bj),
      account: account,
      message: message,
    );
    logEntries.add(entry);
    if (logEntries.length > 500) {
      logEntries.removeRange(0, logEntries.length - 500);
    }
    statusLabel = message;
    _inferStageFromLog(message);
    notifyListeners();
  }

  void _inferStageFromLog(String msg) {
    if (!isRunning) {
      return;
    }
    if (msg.contains('抢座成功') || msg.contains('预约成功')) {
      rushStage = RushStepStage.success;
    } else if (msg.contains('验证码') || msg.contains('freeBook') || msg.contains('提交')) {
      rushStage = RushStepStage.booking;
    } else if (msg.contains('目标自习室就绪') || msg.contains('实时空座') || msg.contains('🎯')) {
      rushStage = RushStepStage.seatSearch;
    } else if (msg.contains('登录') || msg.contains('保活')) {
      rushStage = RushStepStage.login;
    } else if (msg.contains('休眠') || msg.contains('等待')) {
      rushStage = RushStepStage.waiting;
    }
  }

  void clearLogs() {
    logEntries.clear();
    notifyListeners();
  }

  Future<void> warmupModels() async {
    if (captchaService.preloaded) {
      return;
    }
    final ok = await captchaService.preload(account: 'mobile');
    if (ok) {
      appendLog('system', '本地识图引擎已预热就绪');
    } else if (captchaService.lastPreloadError.isNotEmpty) {
      appendLog('system', '⚠️ 本地识图模型预热异常: ${captchaService.lastPreloadError}');
    }
  }

  /// 启动抢座（支持定时模式与立即模式）。
  Future<void> startRush({bool? overrideScheduled}) async {
    if (isRunning) {
      return;
    }
    await config.saveToDisk();
    final (valid, errMsg) = config.validate();
    if (!valid) {
      appendLog('system', errMsg);
      return;
    }

    isRunning = true;
    recentSuccessEvents.clear();
    final stopToken = CancelTokenSource();
    _activeStopToken = stopToken;

    final sessionCfg = config.toRushSessionConfig(
      overrideWaitForSchedule: overrideScheduled,
    );
    rushStage = sessionCfg.waitForSchedule
        ? RushStepStage.waiting
        : RushStepStage.login;
    notifyListeners();

    await BackgroundSchedulerService.instance.setKeepScreenAwake(true);
    final iosKeepAliveOk = await BackgroundSchedulerService.instance
        .startIosBackgroundKeepAlive();
    if (iosKeepAliveOk) {
      appendLog('system', '🌙 已激活 iOS 锁屏后台保活（锁屏/切后台不冻结，抢座结束后自动关闭）');
    }
    if (sessionCfg.waitForSchedule) {
      final sched = buildCustomSchedule(
        sessionCfg.scheduleHour,
        sessionCfg.scheduleMinute,
      );
      final guardRes = await BackgroundSchedulerService.instance
          .startAndroidForegroundRushService(
        prepAtBeijing: sched.prepAt,
        fireAtBeijing: sched.fireAt,
        targetSummary:
            '${sessionCfg.targetRoom} · ${formatHms(sched.fireAt)} 准点晨约',
      );
      if (guardRes.ok) {
        final wakeAt = sched.prepAt.subtract(const Duration(seconds: 20));
        final fgsDesc = guardRes.fgsStarted
            ? '前台守夜已挂起'
            : '前台服务降级(${guardRes.fgsMessage})';
        final alarmDesc = guardRes.alarmScheduled
            ? '${guardRes.alarmMode}(${formatHms(wakeAt)}/${formatHms(sched.prepAt)})'
            : '未挂闹钟(${guardRes.alarmMode})';
        appendLog(
          'system',
          '🛡️ 隔夜防杀实况：$fgsDesc · 唤醒闹钟=$alarmDesc · 动态锁+WiFi锁',
        );
        final status = await BackgroundSchedulerService.instance
            .getAndroidKeepAliveStatus();
        if (!status.ignoringBatteryOptimizations) {
          appendLog(
            'system',
            '⚠️ 未开启「允许后台高耗电/电池白名单」：vivo(OriginOS)/小米/华为/OPPO 锁屏后将冻结后台计时，请前往「我的 → 晨约守夜与后台保活」开启',
          );
        }
        if (!status.canScheduleExactAlarms) {
          appendLog(
            'system',
            '⚠️ 尚未授予精确闹钟权限，建议前往「我的 → 晨约守夜与后台保活」一键授权',
          );
        }
        if (!status.canUseFullScreenIntent) {
          appendLog(
            'system',
            '💡 建议开启「锁屏全屏唤醒(Android 14+)」，确保锁屏冻结态可准点拉起解冻',
          );
        }
      }
    }

    final orchestrator = MobileOrchestrator(
      captchaService: captchaService,
      onLog: appendLog,
      onCaptchaDiagnostic: (acc, diag) {
        latestDiagnostic = diag;
        notifyListeners();
      },
      onBookingSuccess: (event) async {
        recentSuccessEvents.removeWhere(
          (e) =>
              e.account == event.account &&
              (e.reservationId == event.reservationId ||
                  event.reservationId.isEmpty),
        );
        recentSuccessEvents.add(event);
        rushStage = RushStepStage.success;
        notifyListeners();
        final roleLabel =
            config.useAccount2 ? accountRoleLabel(event.account) : null;
        if (config.autoCheckinReminder) {
          final planned = NotificationService.planCheckinRemindersForEvent(
            event,
            roleLabel: roleLabel,
          );
          if (planned.isNotEmpty) {
            final times = planned.map((r) => r.triggerHmLabel).join(' / ');
            appendLog(event.account, '⏰ 已注册签到防违约提醒：$times');
          }
        }
        await NotificationService.instance.notifyBookingSuccess(
          event,
          receiverEmail: config.receiverEmail,
          webhookUrl: sessionCfg.webhookUrl,
          autoCheckinReminder: config.autoCheckinReminder,
          roleLabel: roleLabel,
        );
        unawaited(refreshLibraryPassData());
      },
    );

    try {
      await orchestrator.runAllAccounts(sessionCfg, stopToken);
    } finally {
      isRunning = false;
      _activeStopToken = null;
      if (rushStage != RushStepStage.success) {
        rushStage = RushStepStage.idle;
      }
      await BackgroundSchedulerService.instance
          .stopAndroidForegroundRushService();
      await BackgroundSchedulerService.instance.stopIosBackgroundKeepAlive();
      await BackgroundSchedulerService.instance.setKeepScreenAwake(false);
      notifyListeners();
    }
  }

  Future<void> stopRush() async {
    _activeStopToken?.cancel();
    appendLog('system', '已发送中止指令');
    await BackgroundSchedulerService.instance
        .stopAndroidForegroundRushService();
    await BackgroundSchedulerService.instance.stopIosBackgroundKeepAlive();
    await BackgroundSchedulerService.instance.setKeepScreenAwake(false);
    isRunning = false;
    rushStage = RushStepStage.idle;
    notifyListeners();
  }

  HttpLibSeatClient _createClient() {
    return HttpLibSeatClient(
      baseUrl: config.apiBaseUrl,
      clockSync: ClockSync(),
      rateLimiter: RateLimiter(),
      loginOcrFn: captchaService.solveLoginCaptcha,
    );
  }

  /// 寻座：刷新指定校区全馆各楼层实时余座。
  Future<void> refreshRoomRadar({String? campusName, String? dateStr}) async {
    if (config.account1.trim().isEmpty || config.password1.trim().isEmpty) {
      radarError = '请先在「我的 → 校园卡账号」中填写学号与密码';
      notifyListeners();
      return;
    }

    radarLoading = true;
    radarError = '';
    notifyListeners();

    final client = _createClient();
    try {
      final loginRes = await client.login(
        config.account1.trim(),
        config.password1,
      );
      if (!loginRes.ok) {
        radarError = '登录未通过：${loginRes.message}';
        return;
      }
      currentUserProfile = loginRes.profile;
      final filters = await client.fetchFilters();
      final targetCampus = campusName ?? config.campus;
      var bid = filters.buildings[targetCampus];
      if (bid == null && filters.buildings.isNotEmpty) {
        bid = filters.buildings.values.first;
      }
      if (bid == null) {
        radarError = '未能获取校区楼宇列表';
        return;
      }

      final bj = client.clockSync.nowBeijing();
      String pad2(int n) => n.toString().padLeft(2, '0');
      final effectiveDate = dateStr ??
          (filters.dates.isNotEmpty
              ? filters.dates.first
              : '${bj.year}-${pad2(bj.month)}-${pad2(bj.day)}');

      final stats = await client.listRoomStats(bid, effectiveDate);
      radarStats = stats;
    } catch (exc) {
      radarError = '获取余座态势失败：$exc';
    } finally {
      client.close();
      radarLoading = false;
      notifyListeners();
    }
  }

  /// 寻座：拉取单个自习室的实时可视化座位图。
  Future<void> loadRoomSeatMap(String campusName, String roomName) async {
    if (config.account1.trim().isEmpty || config.password1.trim().isEmpty) {
      radarError = '请先填写学号与密码';
      notifyListeners();
      return;
    }

    radarLoading = true;
    radarError = '';
    selectedRadarRoomName = roomName;
    notifyListeners();

    final client = _createClient();
    try {
      final loginRes = await client.login(
        config.account1.trim(),
        config.password1,
      );
      if (!loginRes.ok) {
        radarError = '登录失败：${loginRes.message}';
        return;
      }

      final bj = client.clockSync.nowBeijing();
      String pad2(int n) => n.toString().padLeft(2, '0');
      final dateStr = '${bj.year}-${pad2(bj.month)}-${pad2(bj.day)}';

      final roomInfo = await client.resolveRoom(campusName, roomName, dateStr);
      if (roomInfo == null) {
        radarError = '未找到自习室：$roomName';
        return;
      }

      final seats = await client.listRoomSeats(roomInfo.roomId, dateStr);
      seats.sort((a, b) {
        final na = int.tryParse(a.seatNo);
        final nb = int.tryParse(b.seatNo);
        if (na != null && nb != null) {
          return na.compareTo(nb);
        }
        return a.seatNo.compareTo(b.seatNo);
      });
      selectedRoomSeats = seats;
    } catch (exc) {
      radarError = '拉取座位图失败：$exc';
    } finally {
      client.close();
      radarLoading = false;
      notifyListeners();
    }
  }

  /// 精准探测单个座位今日全部连续可约时段（如 `now — 14:00`、`20:00 — 22:00`）。
  Future<SeatTimeProbeResult> probeSeatAvailableWindows(String seatId) async {
    if (config.account1.trim().isEmpty || config.password1.trim().isEmpty) {
      return const SeatTimeProbeResult(error: '请先填写学号与密码');
    }
    final client = _createClient();
    try {
      final loginRes = await client.login(
        config.account1.trim(),
        config.password1,
      );
      if (!loginRes.ok) {
        return SeatTimeProbeResult(
          error: loginRes.message.isNotEmpty ? loginRes.message : '登录失败',
        );
      }
      final bj = client.clockSync.nowBeijing();
      String pad2(int n) => n.toString().padLeft(2, '0');
      final dateStr = '${bj.year}-${pad2(bj.month)}-${pad2(bj.day)}';
      final starts = await client.listSeatStartTimes(seatId, dateStr);
      if (starts.isEmpty) {
        return const SeatTimeProbeResult();
      }
      final windows = await discoverSeatAvailableWindows(
        starts: starts,
        fetchEndTimes: (startId) =>
            client.listSeatEndTimes(seatId, dateStr, startId),
      );
      return SeatTimeProbeResult(starts: starts, windows: windows);
    } catch (exc) {
      return SeatTimeProbeResult(error: '$exc');
    } finally {
      client.close();
    }
  }

  /// 兼容旧调用：返回最早一段可约的开始与结束时间列表。
  Future<(List<SeatTimeOption>, List<SeatTimeOption>)> probeSeatAvailableTimes(
    String seatId,
  ) async {
    final res = await probeSeatAvailableWindows(seatId);
    final firstEnds = res.windows.isNotEmpty
        ? res.windows.first.endOptions
        : const <SeatTimeOption>[];
    return (res.starts, firstEnds);
  }

  /// 寻座：对满员自习室开启低频合规「蹲空座」（每 60 秒轻查一次 stats2）。
  void startRoomWatch(String campusName, String roomName) {
    stopRoomWatch();
    watchingCampus = campusName;
    watchingRoomName = roomName;
    watchCheckCount = 0;
    notifyListeners();

    _watchTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (watchingRoomName == null) {
        return;
      }
      watchCheckCount += 1;
      await refreshRoomRadar(campusName: campusName);
      final hit = radarStats.where((r) => r.roomName == roomName).firstOrNull;
      if (hit != null && hit.freeSeats > 0) {
        final foundCount = hit.freeSeats;
        stopRoomWatch();
        await NotificationService.instance.showLocalNotification(
          id: 700,
          title: '空座释出 · $roomName',
          body: '$roomName 刚刚空出 $foundCount 个座位，快打开 LNU LibSeat 锁定！',
        );
      } else {
        notifyListeners();
      }
    });
  }

  void stopRoomWatch() {
    _watchTimer?.cancel();
    _watchTimer = null;
    watchingCampus = null;
    watchingRoomName = null;
    watchCheckCount = 0;
    notifyListeners();
  }

  /// 在寻座网格中选中某个绿色空座后，按所选时段当场锁座。
  Future<void> quickBookSingleSeat({
    required String campusName,
    required String roomName,
    required String seatNo,
    String? overrideStart,
    String? overrideEnd,
  }) async {
    config.campus = campusName;
    config.room = roomName;
    config.preferSeats = <String>[normalizeSeatNo(seatNo)];
    if (overrideStart != null && overrideStart.isNotEmpty) {
      config.start1 = overrideStart;
    }
    if (overrideEnd != null && overrideEnd.isNotEmpty) {
      config.end1 = overrideEnd;
    }
    await config.saveToDisk();
    await startRush(overrideScheduled: false);
  }

  bool get hasDualPassAccounts =>
      config.useAccount2 &&
      config.account2.trim().isNotEmpty &&
      config.password2.trim().isNotEmpty;

  String accountRoleLabel(String account) {
    final acc = account.trim();
    if (acc.isNotEmpty && acc == config.account2.trim()) {
      return '副号';
    }
    return '主号';
  }

  void _rebuildMergedPassLists() {
    final mergedActive = <ReservationRecord>[];
    final mergedHistory = <HistoryRecord>[];
    UserProfile? primaryProfile;
    for (final snap in accountPassSnapshots) {
      if (snap.label == '主号' && snap.profile != null) {
        primaryProfile = snap.profile;
      }
      mergedActive.addAll(snap.activeReservations);
      mergedHistory.addAll(snap.historyRecords);
    }
    mergedHistory.sort((a, b) {
      final dateCmp = b.date.compareTo(a.date);
      if (dateCmp != 0) {
        return dateCmp;
      }
      final beginCmp = b.begin.compareTo(a.begin);
      if (beginCmp != 0) {
        return beginCmp;
      }
      return b.id.compareTo(a.id);
    });
    currentUserProfile = primaryProfile ??
        accountPassSnapshots
            .where((s) => s.profile != null)
            .map((s) => s.profile)
            .firstOrNull;
    activeReservations = mergedActive;
    historyRecords = mergedHistory;
  }

  /// 入馆：同步主/副账号生效预约、图书馆官方公告、历史足迹与辽大自习书简。
  Future<void> refreshLibraryPassData() async {
    final targets = <(String label, String acc, String pwd)>[];
    if (config.account1.trim().isNotEmpty &&
        config.password1.trim().isNotEmpty) {
      targets.add(('主号', config.account1.trim(), config.password1));
    }
    if (hasDualPassAccounts) {
      final acc2 = config.account2.trim();
      if (acc2 != config.account1.trim()) {
        targets.add(('副号', acc2, config.password2));
      }
    }
    if (targets.isEmpty) {
      passError = '请先在「我的 → 校园卡账号」填写学号与密码';
      notifyListeners();
      return;
    }

    passLoading = true;
    passError = '';
    notifyListeners();

    final snapshots = <AccountPassSnapshot>[];
    final errors = <String>[];
    var fetchedAnnounce = false;

    try {
      for (final item in targets) {
        final (label, acc, pwd) = item;
        final client = _createClient();
        try {
          final loginRes = await client.login(acc, pwd);
          if (!loginRes.ok) {
            final msg = '$label($acc) 登录失败：${loginRes.message}';
            errors.add(msg);
            snapshots.add(
              AccountPassSnapshot(account: acc, label: label, error: msg),
            );
            continue;
          }
          final active = (await client.listActiveReservations())
              .map((r) => r.copyWithAccount(acc))
              .toList(growable: false);
          if (!fetchedAnnounce) {
            try {
              announcements = await client.fetchAnnouncements();
              fetchedAnnounce = true;
            } catch (_) {}
          }
          var hist = const <HistoryRecord>[];
          try {
            hist = (await client.fetchHistory(page: 1, pageSize: 50))
                .map((h) => h.copyWithAccount(acc))
                .toList(growable: false);
          } catch (_) {}
          snapshots.add(
            AccountPassSnapshot(
              account: acc,
              label: label,
              profile: loginRes.profile,
              activeReservations: active,
              historyRecords: hist,
            ),
          );
        } catch (exc) {
          final msg = '$label($acc) 同步失败：$exc';
          errors.add(msg);
          snapshots.add(
            AccountPassSnapshot(account: acc, label: label, error: msg),
          );
        } finally {
          client.close();
        }
      }
      accountPassSnapshots = snapshots;
      _rebuildMergedPassLists();
      passError = errors.join('\n');
      await syncCheckinReminders();
    } finally {
      passLoading = false;
      notifyListeners();
    }
  }

  /// 对账当前全部有效预约的系统签到闹钟（含主副双号，已签到/已取消自动撤回）。
  Future<int> syncCheckinReminders() {
    return NotificationService.instance.syncCheckinRemindersForReservations(
      activeReservations,
      enabled: config.autoCheckinReminder,
      roleLabelOf: config.useAccount2 ? accountRoleLabel : null,
    );
  }

  /// 切换「签到前防违约提醒」总开关，立即更新界面并向系统注册或撤回签到闹钟。
  Future<int> setAutoCheckinReminder(bool enabled) async {
    config.autoCheckinReminder = enabled;
    notifyListeners();
    await config.saveToDisk();
    final count = await syncCheckinReminders();
    notifyListeners();
    return count;
  }

  (String, String)? _resolveCredentialsForCancel(
    String reservationId,
    String? explicitAccount,
  ) {
    var targetAcc = (explicitAccount ?? '').trim();
    if (targetAcc.isEmpty) {
      for (final r in activeReservations) {
        if (r.reservationId == reservationId && r.account.trim().isNotEmpty) {
          targetAcc = r.account.trim();
          break;
        }
      }
    }
    if (targetAcc.isEmpty) {
      for (final e in recentSuccessEvents) {
        if (e.reservationId == reservationId && e.account.trim().isNotEmpty) {
          targetAcc = e.account.trim();
          break;
        }
      }
    }
    if (targetAcc.isEmpty) {
      for (final h in historyRecords) {
        if (h.id == reservationId && h.account.trim().isNotEmpty) {
          targetAcc = h.account.trim();
          break;
        }
      }
    }

    final acc1 = config.account1.trim();
    final acc2 = config.account2.trim();
    if (targetAcc.isNotEmpty &&
        targetAcc == acc2 &&
        config.password2.trim().isNotEmpty) {
      return (acc2, config.password2);
    }
    if (acc1.isNotEmpty && config.password1.trim().isNotEmpty) {
      return (acc1, config.password1);
    }
    if (acc2.isNotEmpty && config.password2.trim().isNotEmpty) {
      return (acc2, config.password2);
    }
    return null;
  }

  /// 直接在软件内取消预约（自动匹配主号或副号凭据，调用 `/rest/v2/cancel/{id}`）。
  Future<CancelReservationResult> cancelMyReservation(
    String reservationId, {
    String? account,
  }) async {
    final trimmedId = reservationId.trim();
    if (trimmedId.isEmpty) {
      const res = CancelReservationResult(ok: false, message: '缺少预约单号，无法取消');
      passError = res.message;
      notifyListeners();
      return res;
    }
    final creds = _resolveCredentialsForCancel(trimmedId, account);
    if (creds == null) {
      const res = CancelReservationResult(ok: false, message: '请先填写学号与密码');
      passError = res.message;
      notifyListeners();
      return res;
    }

    final (acc, pwd) = creds;
    passLoading = true;
    cancellingReservationId = trimmedId;
    passError = '';
    notifyListeners();

    final client = _createClient();
    try {
      final loginRes = await client.login(acc, pwd);
      if (!loginRes.ok) {
        final msg = '登录失败：${loginRes.message}';
        passError = msg;
        return CancelReservationResult(ok: false, message: msg);
      }
      final res = await client.cancelReservationDetail(trimmedId);
      if (res.ok) {
        final quotaHint = res.totalCancelled != null
            ? '，今日已取消 ${res.totalCancelled}/${res.allowedCancel ?? 3} 次'
            : '';
        appendLog(acc, '🗑️ 已取消预约（单号 $trimmedId$quotaHint）');

        recentSuccessEvents.removeWhere((e) => e.reservationId == trimmedId);
        if (recentSuccessEvents.isEmpty && !isRunning) {
          rushStage = RushStepStage.idle;
        }
        await NotificationService.instance
            .cancelCheckinRemindersForReservation(trimmedId);

        // 用同一个已登录会话立即刷新该账号的生效预约与历史记录
        final refreshedActive = (await client.listActiveReservations())
            .map((r) => r.copyWithAccount(acc))
            .toList(growable: false);
        var refreshedHistory = const <HistoryRecord>[];
        try {
          refreshedHistory = (await client.fetchHistory(page: 1, pageSize: 50))
              .map((h) => h.copyWithAccount(acc))
              .toList(growable: false);
        } catch (_) {}

        final idx =
            accountPassSnapshots.indexWhere((s) => s.account == acc);
        final updatedSnap = AccountPassSnapshot(
          account: acc,
          label: accountRoleLabel(acc),
          profile: loginRes.profile ??
              (idx >= 0 ? accountPassSnapshots[idx].profile : null),
          activeReservations: refreshedActive,
          historyRecords: refreshedHistory.isNotEmpty
              ? refreshedHistory
              : (idx >= 0
                  ? accountPassSnapshots[idx].historyRecords
                  : const <HistoryRecord>[]),
        );
        if (idx >= 0) {
          accountPassSnapshots = <AccountPassSnapshot>[
            ...accountPassSnapshots.sublist(0, idx),
            updatedSnap,
            ...accountPassSnapshots.sublist(idx + 1),
          ];
        } else {
          accountPassSnapshots = <AccountPassSnapshot>[
            ...accountPassSnapshots,
            updatedSnap,
          ];
        }
        _rebuildMergedPassLists();
        await syncCheckinReminders();
      } else {
        passError = res.message.isNotEmpty
            ? res.message
            : '取消预约未成功（请确认未超每日 3 次取消上限）';
      }
      return res;
    } catch (exc) {
      final msg = '取消预约异常：$exc';
      passError = msg;
      return CancelReservationResult(ok: false, message: msg);
    } finally {
      client.close();
      passLoading = false;
      cancellingReservationId = null;
      notifyListeners();
    }
  }

  List<ReservationRecord> activeReservationsForAccount(String? accountFilter) {
    final filter = (accountFilter ?? '').trim();
    if (filter.isEmpty) {
      return activeReservations;
    }
    return activeReservations
        .where((r) => r.account == filter)
        .toList(growable: false);
  }

  List<HistoryRecord> historyForAccount(String? accountFilter) {
    final filter = (accountFilter ?? '').trim();
    if (filter.isEmpty) {
      return historyRecords;
    }
    return historyRecords
        .where((h) => h.account == filter)
        .toList(growable: false);
  }

  /// 根据真实历史预约记录统计「辽大自习书简」报告（支持双账号合并或按单个账号筛选）。
  StudyLetterSummary computeStudyLetter({String? accountFilter}) {
    final records = historyForAccount(accountFilter);
    var totalMinutes = 0;
    var completed = 0;
    final locationFreq = <String, int>{};

    for (final rec in records) {
      final st = rec.stat.toUpperCase();
      if (!st.contains('CANCEL') && !st.contains('MISS')) {
        completed += 1;
        final s = parseHhmmMinutes(rec.begin);
        final e = parseHhmmMinutes(rec.end);
        if (s != null && e != null && e > s) {
          totalMinutes += (e - s);
        }
      }
      final shortLoc = extractRoomNameFromLocation(rec.location);
      if (shortLoc.isNotEmpty) {
        locationFreq[shortLoc] = (locationFreq[shortLoc] ?? 0) + 1;
      }
    }

    var favLoc = config.room;
    var bestCount = 0;
    for (final entry in locationFreq.entries) {
      if (entry.value > bestCount) {
        bestCount = entry.value;
        favLoc = entry.key;
      }
    }

    return StudyLetterSummary(
      totalVisits: records.length,
      totalHours: totalMinutes / 60.0,
      favoriteLocation: favLoc,
      completedCount: completed,
    );
  }

  /// 入馆伴侣：开启暂离防丢座倒计时（提前 5 分钟发本地推送催促回馆）。
  void startTempLeave(int minutes) {
    stopTempLeave();
    tempLeaveRemainingSec = minutes * 60;
    _tempLeaveFiveMinWarned = false;
    notifyListeners();

    _tempLeaveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (tempLeaveRemainingSec <= 1) {
        stopTempLeave();
        NotificationService.instance.showLocalNotification(
          id: 701,
          title: '暂离时间已到 · 请尽快回馆刷卡',
          body: '你的图书馆暂离保留时段即将结束，请及时返座签到以防丢座违约。',
        );
        return;
      }
      tempLeaveRemainingSec -= 1;
      if (!_tempLeaveFiveMinWarned && tempLeaveRemainingSec <= 300) {
        _tempLeaveFiveMinWarned = true;
        NotificationService.instance.showLocalNotification(
          id: 702,
          title: '距暂离超时仅剩 5 分钟',
          body: '请准备返回辽宁大学图书馆刷卡保留座位。',
        );
      }
      notifyListeners();
    });
  }

  void stopTempLeave() {
    _tempLeaveTimer?.cancel();
    _tempLeaveTimer = null;
    tempLeaveRemainingSec = 0;
    notifyListeners();
  }

  /// 入馆伴侣：专注番茄钟 / 沉浸计时器。
  void toggleFocusTimer({int? targetMinutes}) {
    if (targetMinutes != null) {
      focusTargetSec = targetMinutes * 60;
    }
    if (focusRunning) {
      _focusTimer?.cancel();
      _focusTimer = null;
      focusRunning = false;
      notifyListeners();
      return;
    }
    focusRunning = true;
    notifyListeners();
    _focusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      focusElapsedSec += 1;
      if (focusTargetSec > 0 && focusElapsedSec == focusTargetSec) {
        NotificationService.instance.showLocalNotification(
          id: 703,
          title: '专注段落达成 · 明德精学',
          body: '已在图书馆专注学习 ${focusTargetSec ~/ 60} 分钟，记得起身远眺休息片刻。',
        );
      }
      notifyListeners();
    });
  }

  void resetFocusTimer() {
    _focusTimer?.cancel();
    _focusTimer = null;
    focusRunning = false;
    focusElapsedSec = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    _activeStopToken?.cancel();
    _watchTimer?.cancel();
    _tempLeaveTimer?.cancel();
    _focusTimer?.cancel();
    captchaService.dispose();
    super.dispose();
  }
}
