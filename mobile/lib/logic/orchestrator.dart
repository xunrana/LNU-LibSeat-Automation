/// 纯 API 多账号抢座调度与生命周期编排层（移动端 Isolate / Async 引擎）。
///
/// 与 Python 端 `logic/orchestrator.py` 完全对齐：
/// - 提前 15s (`06:29:45`) 预热登录 + 动态解析自习室与全房座号索引
/// - 提前 5s (`06:29:55`) 保活心跳 + 二次校准服务端时钟
/// - `06:30:00.200` 按服务端校准时间毫秒级触发开抢
/// - 支持维护期延迟重试与 Token 过期 (`code == "12"`) 自动重登
library;

import 'dart:async';
import 'dart:io';

import '../core/captcha/captcha_service.dart';
import '../core/clock_sync.dart';
import '../core/libseat_client.dart';
import '../core/protocol.dart';
import '../core/rate_limiter.dart';
import '../core/session_recorder.dart';
import 'booker.dart';
import 'seat_strategy.dart';

const int prepLeadSeconds = 15;
const int keepaliveLeadSeconds = 5;
const int maintenanceRetryIntervalSeconds = 120;
const int defaultFireOffsetMs = 200;
const int accountStaggerSeconds = 2;

class AccountTaskConfig {
  final String account;
  final String password;
  final String startTime;
  final String endTime;

  const AccountTaskConfig({
    required this.account,
    required this.password,
    required this.startTime,
    required this.endTime,
  });
}

class RushSessionConfig {
  final List<AccountTaskConfig> accounts;
  final String targetCampus;
  final String targetRoom;
  final List<RoomTarget> fallbackRooms;
  final List<String> preferSeats;
  final bool waitForSchedule;
  final int scheduleHour;
  final int scheduleMinute;
  final String apiBaseUrl;
  final int apiFireOffsetMs;
  final String webhookUrl;
  final Directory? baseLogDir;

  const RushSessionConfig({
    required this.accounts,
    required this.targetCampus,
    required this.targetRoom,
    this.fallbackRooms = const <RoomTarget>[],
    this.preferSeats = const <String>[],
    this.waitForSchedule = true,
    this.scheduleHour = 6,
    this.scheduleMinute = 30,
    this.apiBaseUrl = ProtocolConstants.defaultBaseUrl,
    this.apiFireOffsetMs = defaultFireOffsetMs,
    this.webhookUrl = '',
    this.baseLogDir,
  });
}

class BookingSuccessEvent {
  final String account;
  final String roomName;
  final String seatNo;
  final String startTime;
  final String endTime;
  final String reservationId;
  final String receipt;

  const BookingSuccessEvent({
    required this.account,
    required this.roomName,
    required this.seatNo,
    required this.startTime,
    required this.endTime,
    required this.reservationId,
    required this.receipt,
  });
}

DateTime currentBeijingTime() =>
    DateTime.now().toUtc().add(const Duration(hours: 8));

String formatBeijingTime(DateTime dt, {bool withMillis = false}) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  String pad3(int n) => n.toString().padLeft(3, '0');
  final base =
      '${dt.year}-${pad2(dt.month)}-${pad2(dt.day)} ${pad2(dt.hour)}:${pad2(dt.minute)}:${pad2(dt.second)}';
  return withMillis ? '$base.${pad3(dt.millisecond)}' : base;
}

String formatHms(DateTime dt) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '${pad2(dt.hour)}:${pad2(dt.minute)}:${pad2(dt.second)}';
}

/// 计算定时模式日程：过点自动顺延到次日。
RushSchedule buildCustomSchedule(
  int targetHour,
  int targetMinute, {
  DateTime? nowBeijing,
}) {
  final current = nowBeijing ?? currentBeijingTime();
  var fireAt = DateTime.utc(
    current.year,
    current.month,
    current.day,
    targetHour,
    targetMinute,
  );
  if (!current.isBefore(fireAt)) {
    fireAt = fireAt.add(const Duration(days: 1));
  }
  final prepAt = fireAt.subtract(const Duration(seconds: prepLeadSeconds));
  final keepaliveAt =
      fireAt.subtract(const Duration(seconds: keepaliveLeadSeconds));

  return RushSchedule(
    runDate: DateTime.utc(fireAt.year, fireAt.month, fireAt.day),
    prepAt: prepAt,
    keepaliveAt: keepaliveAt,
    fireAt: fireAt,
  );
}

/// 绝对时间精确等待（支持服务端校准时钟与即时响应 stopToken）。
Future<bool> waitUntilBeijing(
  DateTime targetBeijing,
  String account,
  CancelTokenSource stopToken,
  String stageName,
  DateTime Function() nowBeijingFn, {
  LogCallback? onLog,
}) async {
  void log(String msg) => onLog?.call(account, '[$account] $msg');

  var now = nowBeijingFn();
  if (!now.isBefore(targetBeijing)) {
    return true;
  }

  final waitSeconds =
      targetBeijing.difference(now).inMicroseconds / 1000000.0;
  log(
    '⏳ 当前: ${formatBeijingTime(now, withMillis: true)} -> '
    '$stageName: ${formatBeijingTime(targetBeijing, withMillis: true)} '
    '(等待 ${waitSeconds.toStringAsFixed(2)}s)',
  );

  while (!stopToken.isCancelled) {
    now = nowBeijingFn();
    final remainingUs = targetBeijing.difference(now).inMicroseconds;
    if (remainingUs <= 0) {
      break;
    }

    Duration step;
    if (remainingUs > 5000000) {
      step = const Duration(seconds: 1);
    } else if (remainingUs > 500000) {
      step = const Duration(milliseconds: 100);
    } else if (remainingUs > 30000) {
      step = const Duration(milliseconds: 10);
    } else {
      step = const Duration(milliseconds: 2);
    }

    if (!await stopToken.sleepInterruptible(step)) {
      log('🛑 等待期间收到停止信号，退出等待');
      return false;
    }
  }

  if (stopToken.isCancelled) {
    return false;
  }

  log('🔥 $stageName 时间到！目标时刻 ${formatHms(targetBeijing)} 已触发。');
  return true;
}

typedef ClientFactory = LibSeatClient Function(SessionRecorder recorder);

class MobileOrchestrator {
  final CaptchaService captchaService;
  final LogCallback? onLog;
  final CaptchaDiagnosticCallback? onCaptchaDiagnostic;
  final Future<void> Function(BookingSuccessEvent event)? onBookingSuccess;

  MobileOrchestrator({
    required this.captchaService,
    this.onLog,
    this.onCaptchaDiagnostic,
    this.onBookingSuccess,
  });

  void _log(String account, String msg) {
    final tag = '[$account]';
    final formatted = msg.contains(tag) ? msg : '$tag $msg';
    onLog?.call(account, formatted);
  }

  Directory? _createSessionDir(Directory? baseDir, String account) {
    if (baseDir == null) {
      return null;
    }
    final bj = currentBeijingTime();
    String pad2(int n) => n.toString().padLeft(2, '0');
    final ts = '${bj.year}${pad2(bj.month)}${pad2(bj.day)}_'
        '${pad2(bj.hour)}${pad2(bj.minute)}${pad2(bj.second)}';
    final dir = Directory('${baseDir.path}/sessions/${ts}_$account');
    try {
      dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<String> runApiSession({
    required AccountTaskConfig accountCfg,
    required RushSessionConfig sessionCfg,
    required CancelTokenSource stopToken,
    required SeatClaimCoordinator coordinator,
    RushSchedule? schedule,
    bool waitForFire = false,
    String? maintenanceMode,
    ClientFactory? clientFactory,
  }) async {
    final account = accountCfg.account;
    final sessionDir = _createSessionDir(sessionCfg.baseLogDir, account);
    final recorder = SessionRecorder(sessionDir: sessionDir, account: account);

    void sessionLog(String acc, String msg) {
      final tag = '[$acc]';
      final formatted = msg.contains(tag) ? msg : '$tag $msg';
      recorder.appendSessionLog(formatted);
      onLog?.call(acc, formatted);
    }

    final client = clientFactory != null
        ? clientFactory(recorder)
        : HttpLibSeatClient(
            baseUrl: sessionCfg.apiBaseUrl,
            clockSync: ClockSync(),
            rateLimiter: RateLimiter(),
            recorder: recorder,
            loginOcrFn: captchaService.solveLoginCaptcha,
          );

    try {
      sessionLog(account, '⚡ 纯 API 会话启动（手机端本地引擎）。');

      var effectiveMaint = maintenanceMode;
      if (effectiveMaint == null) {
        effectiveMaint = 'stop';
        if (waitForFire &&
            schedule != null &&
            currentBeijingTime().isBefore(schedule.fireAt)) {
          effectiveMaint = 'defer_until_fire';
        }
      }

      final loginRes = await client.login(
        account,
        accountCfg.password,
        stopToken: stopToken,
      );
      if (!loginRes.ok) {
        if (loginRes.reason == LoginFailureReason.maintenance) {
          if (effectiveMaint == 'defer_until_fire') {
            sessionLog(account, '⏸️ 收到维护提示，等待预约时刻重试登录: ${loginRes.message}');
            return 'maintenance_retry_at_fire';
          }
          if (effectiveMaint == 'retry_later') {
            sessionLog(account, '⏳ 系统维护中，稍后按间隔重试: ${loginRes.message}');
            return 'maintenance_retry_later';
          }
          sessionLog(account, '🛑 系统维护中，停止任务: ${loginRes.message}');
          return 'stopped';
        }
        if (loginRes.reason == LoginFailureReason.protocolDrift) {
          sessionLog(
            account,
            '🛑 检测到站点接口协议可能已变更: ${loginRes.message}（可在设置页导出脱敏日志排查）',
          );
          return 'stopped';
        }
        if (loginRes.reason == LoginFailureReason.stopped ||
            stopToken.isCancelled) {
          return 'stopped';
        }
        sessionLog(
          account,
          '❌ 纯 API 登录失败 (${loginRes.reason.name}): ${loginRes.message}',
        );
        return 'stopped';
      }

      final uid = loginRes.profile?.userId ?? '-';
      final offStr = client.clockSync.offsetSeconds.toStringAsFixed(3);
      sessionLog(account, '✅ 纯 API 登录成功！(userId=$uid, clock_offset=${offStr}s)');

      final roomPlan = buildRoomPlan(
        sessionCfg.targetCampus,
        sessionCfg.targetRoom,
        sessionCfg.fallbackRooms,
      );
      final booker = ApiSeatBooker(
        client: client,
        account: account,
        captchaService: captchaService,
        recorder: recorder,
        onLog: sessionLog,
        onCaptchaDiagnostic: onCaptchaDiagnostic,
      );

      AttackOutcome? outcome;
      for (var authRound = 0; authRound < 2; authRound++) {
        try {
          outcome = await booker.attackRooms(
            roomPlan: roomPlan,
            preferSeats: sessionCfg.preferSeats,
            startTime: accountCfg.startTime,
            endTime: accountCfg.endTime,
            schedule: (waitForFire && authRound == 0) ? schedule : null,
            stopToken: stopToken,
            coordinator: coordinator,
            waitUntilFn: (target, acc, token, stage, nowFn) =>
                waitUntilBeijing(
              target,
              acc,
              token,
              stage,
              nowFn,
              onLog: sessionLog,
            ),
            fireOffsetMs: sessionCfg.apiFireOffsetMs,
          );
          break;
        } on TokenExpiredException catch (exc) {
          if (authRound >= 1 || stopToken.isCancelled) {
            sessionLog(account, '🛑 Token 连续过期，终止会话: ${exc.message}');
            return 'stopped';
          }
          sessionLog(account, '🔄 检测到 Token 过期 (${exc.message})，正在自动重新登录...');
          final relogin = await client.login(
            account,
            accountCfg.password,
            stopToken: stopToken,
          );
          if (!relogin.ok) {
            sessionLog(account, '❌ 自动重新登录失败: ${relogin.message}');
            return 'stopped';
          }
        }
      }

      if (outcome != null &&
          outcome.outcome == 'success' &&
          outcome.bookResponse != null) {
        final bookRes = outcome.bookResponse!;
        final event = BookingSuccessEvent(
          account: account,
          roomName: outcome.resolvedRoomName.isNotEmpty
              ? outcome.resolvedRoomName
              : sessionCfg.targetRoom,
          seatNo: bookRes.seatNo,
          startTime: accountCfg.startTime,
          endTime: accountCfg.endTime,
          reservationId: bookRes.reservationId,
          receipt: bookRes.receipt,
        );
        await onBookingSuccess?.call(event);
        return 'success';
      }

      return 'stopped';
    } catch (exc) {
      sessionLog(account, '❌ 纯 API 会话异常: $exc');
      return 'stopped';
    } finally {
      client.close();
    }
  }

  Future<void> _runAccountTask({
    required AccountTaskConfig accountCfg,
    required RushSessionConfig sessionCfg,
    required CancelTokenSource stopToken,
    required int slotIndex,
    required SeatClaimCoordinator coordinator,
    ClientFactory? clientFactory,
  }) async {
    final account = accountCfg.account;
    final scheduled = sessionCfg.waitForSchedule;
    RushSchedule? schedule;

    if (scheduled) {
      schedule = buildCustomSchedule(
        sessionCfg.scheduleHour,
        sessionCfg.scheduleMinute,
      );
      _log(
        account,
        '🗓️ 日程: ${schedule.dateStr} | 预热登录 ${formatHms(schedule.prepAt)} '
        '→ 保活 ${formatHms(schedule.keepaliveAt)} → 准点开抢 ${formatHms(schedule.fireAt)}',
      );

      final prepAt = schedule.prepAt.add(
        Duration(seconds: slotIndex * accountStaggerSeconds),
      );
      final ok = await waitUntilBeijing(
        prepAt,
        account,
        stopToken,
        '准备启动纯 API 会话',
        currentBeijingTime,
        onLog: onLog,
      );
      if (!ok) {
        return;
      }

      var result = await runApiSession(
        accountCfg: accountCfg,
        sessionCfg: sessionCfg,
        stopToken: stopToken,
        coordinator: coordinator,
        schedule: schedule,
        waitForFire: true,
        clientFactory: clientFactory,
      );

      if (result == 'maintenance_retry_at_fire' && !stopToken.isCancelled) {
        final okFire = await waitUntilBeijing(
          schedule.fireAt,
          account,
          stopToken,
          '等待放座时刻重连',
          currentBeijingTime,
          onLog: onLog,
        );
        if (!okFire) {
          return;
        }
        _log(account, '🔄 到达预约时刻，重新登录并立即开抢。');
        result = await runApiSession(
          accountCfg: accountCfg,
          sessionCfg: sessionCfg,
          stopToken: stopToken,
          coordinator: coordinator,
          schedule: null,
          waitForFire: false,
          maintenanceMode: 'retry_later',
          clientFactory: clientFactory,
        );
      }

      while (result == 'maintenance_retry_later' && !stopToken.isCancelled) {
        final nextRetryAt = currentBeijingTime().add(
          const Duration(seconds: maintenanceRetryIntervalSeconds),
        );
        final okRetry = await waitUntilBeijing(
          nextRetryAt,
          account,
          stopToken,
          '系统维护间隔重试',
          currentBeijingTime,
          onLog: onLog,
        );
        if (!okRetry) {
          return;
        }
        result = await runApiSession(
          accountCfg: accountCfg,
          sessionCfg: sessionCfg,
          stopToken: stopToken,
          coordinator: coordinator,
          schedule: null,
          waitForFire: false,
          maintenanceMode: 'retry_later',
          clientFactory: clientFactory,
        );
      }

      _log(account, '🛑 抢座任务结束（结果: $result）。');
      return;
    }

    _log(account, '🚀 立即模式：纯 API 直连开抢（实时空座优先）。');
    if (stopToken.isCancelled) {
      return;
    }
    final result = await runApiSession(
      accountCfg: accountCfg,
      sessionCfg: sessionCfg,
      stopToken: stopToken,
      coordinator: coordinator,
      schedule: null,
      waitForFire: false,
      clientFactory: clientFactory,
    );
    _log(account, '🛑 抢座任务结束（结果: $result）。');
  }

  /// 多账号并发总控入口。
  Future<void> runAllAccounts(
    RushSessionConfig sessionCfg,
    CancelTokenSource stopToken, {
    ClientFactory? clientFactory,
  }) async {
    final validAccounts = sessionCfg.accounts
        .where((a) => a.account.trim().isNotEmpty && a.password.isNotEmpty)
        .take(2)
        .toList(growable: false);

    if (validAccounts.isEmpty) {
      _log('system', '❌ 请至少配置 1 个有效学号与密码');
      return;
    }

    _log(
      'system',
      'LNU LibSeat 约座引擎已启动',
    );
    _log(
      'system',
      '目标场馆：${sessionCfg.targetCampus} · ${sessionCfg.targetRoom}'
      '${sessionCfg.fallbackRooms.isNotEmpty ? "（含 ${sessionCfg.fallbackRooms.length} 间备选）" : ""}',
    );

    // 异步预热本地 Click1 + Click3 + OCR ONNX 模型
    unawaited(
      captchaService.preload(account: 'preload').then((ok) {
        if (ok) {
          _log('system', '本地识图模型预热就绪');
        } else if (captchaService.lastPreloadError.isNotEmpty) {
          _log('system', '⚠️ 本地识图模型预热异常: ${captchaService.lastPreloadError}');
        }
      }),
    );

    final coordinator = SeatClaimCoordinator();
    final tasks = <Future<void>>[
      for (var i = 0; i < validAccounts.length; i++)
        _runAccountTask(
          accountCfg: validAccounts[i],
          sessionCfg: sessionCfg,
          stopToken: stopToken,
          slotIndex: i,
          coordinator: coordinator,
          clientFactory: clientFactory,
        ),
    ];

    await Future.wait(tasks);
    _log('system', '🏁 所有账号任务已结束。');
  }
}
