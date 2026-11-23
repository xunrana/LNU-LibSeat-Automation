/// 纯 API 抢座引擎（零浏览器依赖，100% 手机端原生执行）。
///
/// 与 Python 端 `logic/booker.py` 100% 状态机对齐。
library;

import 'package:dio/dio.dart';

import '../core/captcha/captcha_service.dart';
import '../core/libseat_client.dart';
import '../core/protocol.dart';
import '../core/rate_limiter.dart';
import '../core/session_recorder.dart';
import 'result_classifier.dart';
import 'seat_strategy.dart';

const int maxCaptchaRetriesPerSeat = 8;
const int maxBusyRetriesPerSeat = 12;
const double openGraceWindowSeconds = 5.0;
const int maxOpenGraceRetries = 5;
const Duration openGraceBackoffDuration = Duration(milliseconds: 250);
// 对齐官网 Vue 前端 chunk0.js 硬编码延时：
// 1) loadCaptchaImg -> setTimeout(showConfirm=true, 1500)
// 2) orderSeatFun   -> setTimeout(freeBook, 2000)
// 3) /cap/captcha   -> 服务端 6 秒滑动窗口频控（系统繁忙, 请稍后: 06）
const Duration peakClick3MinSolveDuration = Duration(milliseconds: 1550);
const Duration peakClick3PostCheckDuration = Duration(milliseconds: 2050);
const Duration peakPostCheckStepDuration = Duration(milliseconds: 400);
const Duration peakPostCheckMaxDuration = Duration(milliseconds: 2800);
const Duration peakClick3RetryCooldownDuration = Duration(milliseconds: 6200);
const double serverCooldownPadSeconds = 0.60;

typedef LogCallback = void Function(String account, String message);
typedef CaptchaDiagnosticCallback = void Function(
  String account,
  CaptchaDiagnosticMeta diagnostic,
);

typedef WaitUntilFn = Future<bool> Function(
  DateTime targetBeijing,
  String account,
  CancelTokenSource stopToken,
  String stageName,
  DateTime Function() nowBeijingFn,
);

class RushSchedule {
  final DateTime runDate;
  final DateTime prepAt;
  final DateTime keepaliveAt;
  final DateTime fireAt;

  const RushSchedule({
    required this.runDate,
    required this.prepAt,
    required this.keepaliveAt,
    required this.fireAt,
  });

  String get dateStr {
    String pad2(int n) => n.toString().padLeft(2, '0');
    return '${runDate.year}-${pad2(runDate.month)}-${pad2(runDate.day)}';
  }
}

class AttackOutcome {
  final String outcome; // "success" | "stopped" | "all_failed"
  final BookResponse? bookResponse;
  final String resolvedRoomName;

  const AttackOutcome({
    required this.outcome,
    this.bookResponse,
    this.resolvedRoomName = '',
  });
}

class ApiSeatBooker {
  final LibSeatClient client;
  final String account;
  final CaptchaService captchaService;
  final SessionRecorder? recorder;
  final int maxCaptchaRetries;
  final int maxBusyRetries;
  final Duration graceBackoff;
  final Duration peakMinSolveDuration;
  final Duration peakPostCheckDuration;
  final Duration peakRetryCooldownDuration;
  final LogCallback? onLog;
  final CaptchaDiagnosticCallback? onCaptchaDiagnostic;
  final Stopwatch _sessionClock = Stopwatch()..start();
  int? _lastPeakCaptchaFetchElapsedMs;

  ApiSeatBooker({
    required this.client,
    required this.account,
    required this.captchaService,
    this.recorder,
    this.maxCaptchaRetries = maxCaptchaRetriesPerSeat,
    this.maxBusyRetries = maxBusyRetriesPerSeat,
    this.graceBackoff = openGraceBackoffDuration,
    this.peakMinSolveDuration = peakClick3MinSolveDuration,
    this.peakPostCheckDuration = peakClick3PostCheckDuration,
    this.peakRetryCooldownDuration = peakClick3RetryCooldownDuration,
    this.onLog,
    this.onCaptchaDiagnostic,
  });

  void _log(String msg) {
    final tag = '[$account]';
    final formatted = msg.contains(tag) ? msg : '$tag $msg';
    onLog?.call(account, formatted);
  }

  static String _formatSimilarityHint(List<List<double>> sim) {
    if (sim.isEmpty) {
      return '';
    }
    final topScores = <double>[];
    for (final row in sim) {
      if (row.isEmpty) {
        continue;
      }
      var best = row[0];
      for (var i = 1; i < row.length; i++) {
        if (row[i] > best) {
          best = row[i];
        }
      }
      topScores.add(best);
    }
    if (topScores.isEmpty) {
      return '';
    }
    final joined = topScores.map((s) => s.toStringAsFixed(2)).join('/');
    return ', sim=$joined';
  }

  bool _inOpenGraceWindow(DateTime? fireAt) {
    if (fireAt == null) {
      return false;
    }
    final now = client.clockSync.nowBeijing();
    final deltaS = now.difference(fireAt).inMicroseconds / 1000000.0;
    return deltaS >= -1.0 && deltaS <= openGraceWindowSeconds;
  }

  /// 处理服务端瞬态繁忙退避；若服务端提示「请稍后: 06」，足额等待 6.6s 以免重置 Redis 滑动窗口。
  Future<(bool, String)> _waitTransientBusy(
    String stageDesc,
    String message,
    int busyRetries,
    CancelTokenSource stopToken, {
    bool isRateLimit = true,
    double? retryAfterSeconds,
  }) async {
    final parsedCd = retryAfterSeconds ?? parseRetryAfterSeconds(message);
    final minDelayS =
        (parsedCd != null && peakRetryCooldownDuration > Duration.zero)
            ? (parsedCd + serverCooldownPadSeconds)
            : 0.0;
    final hint =
        minDelayS > 0 ? '（冷却 ${minDelayS.toStringAsFixed(1)}s）' : '';
    _log('⏳ $stageDesc遇服务端繁忙 ($busyRetries/$maxBusyRetries): $message，退避重试$hint...');
    try {
      final ok = await client.rateLimiter.waitBackoff(
        stopToken: stopToken,
        isRateLimit: isRateLimit,
        minDelaySeconds: minDelayS,
      );
      if (!ok) {
        return (false, '收到停止信号');
      }
      return (true, '');
    } on RateLimitCircuitOpenException catch (exc) {
      _log('🛑 ${exc.message}');
      return (false, exc.message);
    }
  }

  /// 对单个座位执行完整「取码 → 本地 ONNX 求解 → 校验 → freeBook」闭环。
  Future<BookResponse> attemptSeat(
    SeatCandidate seat, {
    required String startTime,
    required String endTime,
    required String dateStr,
    required CancelTokenSource stopToken,
    int priority = 0,
    DateTime? fireAt,
  }) async {
    var graceRetries = 0;
    var busyRetries = 0;
    var captchaAttempt = 0;
    var adaptivePostCheck = peakPostCheckDuration;

    while (captchaAttempt < maxCaptchaRetries) {
      if (stopToken.isCancelled) {
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: '收到停止信号',
          seatNo: seat.seatNo,
        );
      }

      final displayAttempt = captchaAttempt + 1;
      _log('🔁 座位 ${seat.seatNo} 第 $displayAttempt/$maxCaptchaRetries 次纯 API 验证码与提交尝试...');

      // 若上一轮已是 06:30 高峰三字码，跨次/跨座再次取码前确保距上次取码满 6.2s，防止触发「系统繁忙, 请稍后: 06」滑动锁
      if (_lastPeakCaptchaFetchElapsedMs != null &&
          peakRetryCooldownDuration > Duration.zero) {
        final sinceLastMs =
            _sessionClock.elapsedMilliseconds - _lastPeakCaptchaFetchElapsedMs!;
        final remainMs = peakRetryCooldownDuration.inMilliseconds - sinceLastMs;
        if (remainMs > 0) {
          _log(
            '⏳ 等待高峰取码 6s 冷却窗口结束 (剩余 ${(remainMs / 1000.0).toStringAsFixed(2)}s)...',
          );
          if (!await stopToken.sleepExact(Duration(milliseconds: remainMs))) {
            return BookResponse(
              status: ApiOutcomeStatus.stop,
              message: '收到停止信号',
              seatNo: seat.seatNo,
            );
          }
        }
      }

      ClickCaptchaChallenge challenge;
      try {
        challenge = await client.fetchClickCaptcha(stopToken: stopToken);
      } on StateError {
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: '收到停止信号',
          seatNo: seat.seatNo,
        );
      } on ProtocolDriftException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on TokenExpiredException {
        rethrow;
      } on TransientServerBusyException catch (exc) {
        if (_lastPeakCaptchaFetchElapsedMs != null) {
          _lastPeakCaptchaFetchElapsedMs = _sessionClock.elapsedMilliseconds;
        }
        busyRetries += 1;
        if (busyRetries > maxBusyRetries) {
          _log('💔 座位 ${seat.seatNo} 拉取验证码连续繁忙达 $maxBusyRetries 次，切换下一座位');
          return BookResponse(
            status: ApiOutcomeStatus.failed,
            message: exc.message,
            seatNo: seat.seatNo,
          );
        }
        final (cont, stopMsg) = await _waitTransientBusy(
          '拉取验证码',
          exc.message,
          busyRetries,
          stopToken,
          isRateLimit: exc.isRateLimit,
          retryAfterSeconds: exc.effectiveRetryAfterSeconds,
        );
        if (!cont) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: stopMsg,
            seatNo: seat.seatNo,
          );
        }
        continue;
      } on DioException catch (exc) {
        _log('⚠️ 拉取验证码网络异常: ${exc.message}');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      final fetchSw = Stopwatch()..start();
      final isPeakClick3 = challenge.wordCheckCount >= 3;
      if (isPeakClick3) {
        _lastPeakCaptchaFetchElapsedMs = _sessionClock.elapsedMilliseconds;
      }
      captchaAttempt += 1;

      final outcome = await captchaService.solve(
        challenge.targetBytes,
        challenge.bgBytes,
        hintCount: challenge.wordCheckCount,
        nowBeijing: client.clockSync.nowBeijing(),
      );

      void saveDiag() {
        if (recorder == null) {
          return;
        }
        recorder!.saveCaptchaDiagnostic(
          targetBytes: challenge.targetBytes,
          bgBytes: challenge.bgBytes,
          outcome: outcome.toDiagnosticMeta(),
          priority: priority,
          seat: seat.seatNo,
          retry: captchaAttempt,
        );
        if (recorder!.latestDiagnosticMeta != null) {
          onCaptchaDiagnostic?.call(account, recorder!.latestDiagnosticMeta!);
        }
      }

      if (outcome.decoder == 'package_image') {
        _log('⚠️ 图像解码回退到纯 Dart 解码器，JPEG 精度可能略有下降');
      }

      if (!outcome.ok || outcome.points.isEmpty) {
        saveDiag();
        _log(
          '⚠️ 本地 ${outcome.kind.wireName} 模型未命中 '
          '(${outcome.error.isNotEmpty ? outcome.error : "empty"}, '
          '${outcome.elapsedMs.round()}ms)，刷新重取...',
        );
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      final simHint = _formatSimilarityHint(outcome.similarity);
      _log(
        '🧠 本地 ${outcome.kind.wireName} 模型解出 ${outcome.points.length} 点 '
        '(${outcome.elapsedMs.round()}ms$simHint): ${outcome.points}',
      );

      // 06:30 高峰三字码防极速风控：补齐最小求解间隔，避免 500ms 内直交被后端拒判
      if (isPeakClick3 && peakMinSolveDuration > Duration.zero) {
        final pad = peakMinSolveDuration - fetchSw.elapsed;
        if (pad > Duration.zero && !await stopToken.sleepExact(pad)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
      }

      ClickCaptchaCheckResult checkRes;
      try {
        checkRes = await client.checkClickCaptcha(
          challenge,
          outcome.points,
          stopToken: stopToken,
        );
      } on StateError {
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: '收到停止信号',
          seatNo: seat.seatNo,
        );
      } on ProtocolDriftException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on TokenExpiredException {
        rethrow;
      } on TransientServerBusyException catch (exc) {
        saveDiag();
        if (captchaAttempt > 0) {
          captchaAttempt -= 1;
        }
        busyRetries += 1;
        if (busyRetries > maxBusyRetries) {
          return BookResponse(
            status: ApiOutcomeStatus.failed,
            message: exc.message,
            seatNo: seat.seatNo,
          );
        }
        final (cont, stopMsg) = await _waitTransientBusy(
          '校验验证码',
          exc.message,
          busyRetries,
          stopToken,
          isRateLimit: exc.isRateLimit,
        );
        if (!cont) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: stopMsg,
            seatNo: seat.seatNo,
          );
        }
        continue;
      } on DioException catch (exc) {
        saveDiag();
        _log('⚠️ 校验验证码网络异常: ${exc.message}');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      if (!checkRes.ok) {
        saveDiag();
        if (isTransientBusyText(checkRes.message)) {
          if (captchaAttempt > 0) {
            captchaAttempt -= 1;
          }
          busyRetries += 1;
          if (busyRetries > maxBusyRetries) {
            return BookResponse(
              status: ApiOutcomeStatus.failed,
              message: checkRes.message,
              seatNo: seat.seatNo,
            );
          }
          final (cont, stopMsg) = await _waitTransientBusy(
            '校验验证码',
            checkRes.message,
            busyRetries,
            stopToken,
            isRateLimit: true,
          );
          if (!cont) {
            return BookResponse(
              status: ApiOutcomeStatus.stop,
              message: stopMsg,
              seatNo: seat.seatNo,
            );
          }
          continue;
        }
        _log('⚠️ 验证码校验未通过 (${checkRes.message})，刷新重试');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      if (isPeakClick3 && adaptivePostCheck > Duration.zero) {
        _log(
          '✅ 验证码校验通过，遵循官网高峰防风控窗口等待 '
          '${(adaptivePostCheck.inMilliseconds / 1000.0).toStringAsFixed(2)}s 后提交 freeBook (座位 ${seat.seatNo})...',
        );
        if (!await stopToken.sleepExact(adaptivePostCheck)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
      } else {
        _log('✅ 验证码一次通过，立即提交 freeBook (座位 ${seat.seatNo})...');
      }

      final inGrace = _inOpenGraceWindow(fireAt);
      BookResponse bookRes;
      try {
        bookRes = await client.freeBook(
          seatId: seat.seatId,
          seatNo: seat.seatNo,
          startTime: startTime,
          endTime: endTime,
          dateStr: dateStr,
          authid: challenge.token,
          inOpenGraceWindow: inGrace,
          stopToken: stopToken,
        );
      } on StateError {
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: '收到停止信号',
          seatNo: seat.seatNo,
        );
      } on ProtocolDriftException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        _log('🛑 终止当前会话: ${exc.message}');
        return BookResponse(
          status: ApiOutcomeStatus.stop,
          message: exc.message,
          seatNo: seat.seatNo,
        );
      } on TokenExpiredException {
        rethrow;
      } on TransientServerBusyException catch (exc) {
        saveDiag();
        if (captchaAttempt > 0) {
          captchaAttempt -= 1;
        }
        busyRetries += 1;
        if (busyRetries > maxBusyRetries) {
          return BookResponse(
            status: ApiOutcomeStatus.failed,
            message: exc.message,
            seatNo: seat.seatNo,
          );
        }
        final (cont, stopMsg) = await _waitTransientBusy(
          '提交预约',
          exc.message,
          busyRetries,
          stopToken,
          isRateLimit: exc.isRateLimit,
        );
        if (!cont) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: stopMsg,
            seatNo: seat.seatNo,
          );
        }
        continue;
      } on DioException catch (exc) {
        saveDiag();
        _log('⚠️ freeBook 网络异常: ${exc.message}');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      saveDiag();

      if (bookRes.status == ApiOutcomeStatus.success) {
        return bookRes;
      }
      if (bookRes.status == ApiOutcomeStatus.blacklist ||
          bookRes.status == ApiOutcomeStatus.stop) {
        return bookRes;
      }

      if (bookRes.notOpenYet) {
        graceRetries += 1;
        if (graceRetries > maxOpenGraceRetries) {
          _log('🛑 放座宽限重试 $maxOpenGraceRetries 次后仍提示未开放: ${bookRes.message}');
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: bookRes.message,
            seatNo: seat.seatNo,
          );
        }
        _log(
          '⏳ 服务端尚在切换放座瞬态 ($graceRetries/$maxOpenGraceRetries): '
          '${bookRes.message}，${graceBackoff.inMilliseconds}ms 后重探...',
        );
        if (!await stopToken.sleepExact(graceBackoff)) {
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: '收到停止信号',
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      if (bookRes.status == ApiOutcomeStatus.retryCaptcha) {
        if (bookRes.rateLimited) {
          if (captchaAttempt > 0) {
            captchaAttempt -= 1;
          }
          busyRetries += 1;
          if (busyRetries > maxBusyRetries) {
            return BookResponse(
              status: ApiOutcomeStatus.failed,
              message: bookRes.message,
              seatNo: seat.seatNo,
            );
          }
          final (cont, stopMsg) = await _waitTransientBusy(
            '提交预约',
            bookRes.message,
            busyRetries,
            stopToken,
            isRateLimit: true,
          );
          if (!cont) {
            return BookResponse(
              status: ApiOutcomeStatus.stop,
              message: stopMsg,
              seatNo: seat.seatNo,
            );
          }
          continue;
        }

        if (isPeakClick3 &&
            bookRes.message.contains('验证码') &&
            adaptivePostCheck < peakPostCheckMaxDuration) {
          final nextMs =
              (adaptivePostCheck + peakPostCheckStepDuration).inMilliseconds;
          adaptivePostCheck = Duration(
            milliseconds: nextMs > peakPostCheckMaxDuration.inMilliseconds
                ? peakPostCheckMaxDuration.inMilliseconds
                : nextMs,
          );
          _log(
            '⚠️ 校验已通过但 freeBook 报【${bookRes.message}】，自动提升高峰校验后缓冲至 '
            '${(adaptivePostCheck.inMilliseconds / 1000.0).toStringAsFixed(2)}s 后重试',
          );
        } else {
          _log('⚠️ 收到可重试业务反馈【${bookRes.message}】，退避重试当前座位');
        }

        try {
          if (!await client.rateLimiter.waitBackoff(
            stopToken: stopToken,
            isRateLimit: false,
          )) {
            return BookResponse(
              status: ApiOutcomeStatus.stop,
              message: '收到停止信号',
              seatNo: seat.seatNo,
            );
          }
        } on RateLimitCircuitOpenException catch (exc) {
          _log('🛑 ${exc.message}');
          return BookResponse(
            status: ApiOutcomeStatus.stop,
            message: exc.message,
            seatNo: seat.seatNo,
          );
        }
        continue;
      }

      _log(
        '💔 座位 ${seat.seatNo} 提交未成功（${bookRes.status.wireName}）: ${bookRes.message}',
      );
      return bookRes;
    }

    _log('💔 座位 ${seat.seatNo} 连续 $maxCaptchaRetries 次尝试未通过，切换下一座位');
    return BookResponse(
      status: ApiOutcomeStatus.failed,
      message: 'max_captcha_retries_exceeded',
      seatNo: seat.seatNo,
    );
  }

  Future<BookResponse> _verifyAndEnrichSuccess(
    BookResponse res,
    CancelTokenSource stopToken,
  ) async {
    if (res.reservationId.isNotEmpty && res.receipt.isNotEmpty) {
      return res;
    }
    try {
      final records = await client.listActiveReservations(stopToken: stopToken);
      for (final rec in records) {
        if (rec.status.toUpperCase() == 'RESERVE' ||
            rec.reservationId.isNotEmpty) {
          return BookResponse(
            status: ApiOutcomeStatus.success,
            message: res.message,
            seatNo: res.seatNo,
            reservationId: res.reservationId.isNotEmpty
                ? res.reservationId
                : rec.reservationId,
            receipt: res.receipt.isNotEmpty ? res.receipt : rec.receipt,
            location: res.location.isNotEmpty ? res.location : rec.location,
          );
        }
      }
    } catch (_) {}
    return res;
  }

  Future<String> _hasBlockingReservation(CancelTokenSource stopToken) async {
    try {
      final records = await client.listActiveReservations(stopToken: stopToken);
      for (final rec in records) {
        final st = rec.status.toUpperCase();
        if (st == 'RESERVE' || st == 'CHECK_IN' || st == 'AWAY') {
          final loc = rec.location.isNotEmpty ? rec.location : '已有预约';
          return '$loc (${rec.begin}-${rec.end}, 状态=$st, 单号=${rec.reservationId})';
        }
      }
    } catch (_) {}
    return '';
  }

  Future<bool> _roomHasFreeSeats(
    RoomInfo room,
    String dateStr,
    CancelTokenSource stopToken,
  ) async {
    try {
      final stats = await client.listRoomStats(
        room.buildingId,
        dateStr,
        stopToken: stopToken,
      );
      for (final st in stats) {
        if (st.roomId == room.roomId) {
          _log(
            '📊 备选自习室 ${room.roomName} 实时概况: 空座 ${st.freeSeats} / 总座 ${st.totalSeats}',
          );
          return st.freeSeats > 0;
        }
      }
    } catch (_) {}
    return true;
  }

  /// 执行完整抢座主流程（支持首选直击 + 实时空座刷新 + FALLBACK_ROOMS 多自习室兜底）。
  Future<AttackOutcome> attackRooms({
    required List<RoomTarget> roomPlan,
    required List<String> preferSeats,
    required String startTime,
    required String endTime,
    required RushSchedule? schedule,
    required CancelTokenSource stopToken,
    required SeatClaimCoordinator coordinator,
    required WaitUntilFn waitUntilFn,
    int fireOffsetMs = 200,
  }) async {
    if (roomPlan.isEmpty) {
      _log('❌ 未配置任何目标自习室，无法抢座。');
      return const AttackOutcome(outcome: 'all_failed');
    }

    final existing = await _hasBlockingReservation(stopToken);
    if (existing.isNotEmpty) {
      _log('🛑 当前账号已有有效预约：$existing，停止本次抢座。');
      return const AttackOutcome(outcome: 'stopped');
    }

    final nowBj = client.clockSync.nowBeijing();
    String pad2(int n) => n.toString().padLeft(2, '0');
    final dateStr = schedule?.dateStr ??
        '${nowBj.year}-${pad2(nowBj.month)}-${pad2(nowBj.day)}';
    final fireAt = schedule?.fireAt;
    final keepaliveAt = schedule?.keepaliveAt;

    final primaryTarget = roomPlan[0];
    RoomInfo? primaryRoom;
    for (var prepTry = 1; prepTry <= 4; prepTry++) {
      try {
        primaryRoom = await client.resolveRoom(
          primaryTarget.campus,
          primaryTarget.room,
          dateStr,
          stopToken: stopToken,
        );
        break;
      } on ProtocolDriftException catch (exc) {
        _log('🛑 解析目标自习室失败，停止会话: ${exc.message}');
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryTarget.room,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        _log('🛑 解析目标自习室失败，停止会话: ${exc.message}');
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryTarget.room,
        );
      } on TransientServerBusyException catch (exc) {
        if (prepTry >= 4) {
          _log('🛑 解析目标自习室连续繁忙，停止会话: ${exc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryTarget.room,
          );
        }
        _log('⏳ 解析目标自习室遇繁忙 ($prepTry/4): ${exc.message}，退避重试...');
        try {
          if (!await client.rateLimiter.waitBackoff(
            stopToken: stopToken,
            isRateLimit: exc.isRateLimit,
          )) {
            return AttackOutcome(
              outcome: 'stopped',
              resolvedRoomName: primaryTarget.room,
            );
          }
        } on RateLimitCircuitOpenException catch (rlExc) {
          _log('🛑 ${rlExc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryTarget.room,
          );
        }
      } on DioException catch (exc) {
        if (prepTry >= 4) {
          _log('🛑 解析目标自习室网络异常，停止会话: ${exc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryTarget.room,
          );
        }
        _log('⚠️ 解析目标自习室网络异常 ($prepTry/4): ${exc.message}，退避重试...');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryTarget.room,
          );
        }
      }
    }

    if (primaryRoom == null) {
      _log('❌ 无法在系统中找到自习室: ${primaryTarget.campus} / ${primaryTarget.room}');
      return AttackOutcome(
        outcome: 'all_failed',
        resolvedRoomName: primaryTarget.room,
      );
    }

    var primarySeats = const <SeatCandidate>[];
    for (var layoutTry = 1; layoutTry <= 4; layoutTry++) {
      try {
        primarySeats = await client.listRoomSeats(
          primaryRoom.roomId,
          dateStr,
          stopToken: stopToken,
        );
        client.rateLimiter.markSeatsRefreshed();
        break;
      } on ProtocolDriftException catch (exc) {
        _log('🛑 拉取自习室座位布局失败，停止会话: ${exc.message}');
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryRoom.roomName,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        _log('🛑 拉取自习室座位布局失败，停止会话: ${exc.message}');
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryRoom.roomName,
        );
      } on TransientServerBusyException catch (exc) {
        if (layoutTry >= 4) {
          _log('🛑 拉取自习室座位布局连续繁忙，停止会话: ${exc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryRoom.roomName,
          );
        }
        _log('⏳ 拉取自习室布局遇繁忙 ($layoutTry/4): ${exc.message}，退避重试...');
        try {
          if (!await client.rateLimiter.waitBackoff(
            stopToken: stopToken,
            isRateLimit: exc.isRateLimit,
          )) {
            return AttackOutcome(
              outcome: 'stopped',
              resolvedRoomName: primaryRoom.roomName,
            );
          }
        } on RateLimitCircuitOpenException catch (rlExc) {
          _log('🛑 ${rlExc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryRoom.roomName,
          );
        }
      } on DioException catch (exc) {
        if (layoutTry >= 4) {
          _log('🛑 拉取自习室座位布局网络异常，停止会话: ${exc.message}');
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryRoom.roomName,
          );
        }
        _log('⚠️ 拉取自习室布局网络异常 ($layoutTry/4): ${exc.message}，退避重试...');
        if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryRoom.roomName,
          );
        }
      } catch (exc) {
        _log('🛑 拉取自习室座位布局失败，停止会话: $exc');
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryRoom.roomName,
        );
      }
    }

    final freeCnt =
        primarySeats.where((s) => s.status == SeatStatus.free).length;
    _log(
      '🏫 目标自习室就绪: ${primaryRoom.campusName} -> ${primaryRoom.roomName} '
      '(room_id=${primaryRoom.roomId}, 共 ${primarySeats.length} 座, 当前空闲 $freeCnt 座)',
    );

    final bjNowForPlan = client.clockSync.nowBeijing();
    final nowMinsForPlan = bjNowForPlan.hour * 60 + bjNowForPlan.minute;
    final startMinsForPlan = parseHhmmMinutes(startTime);
    final isFutureSlotToday =
        startMinsForPlan != null && startMinsForPlan > nowMinsForPlan;

    final initialQueues = planSeatCandidates(
      preferSeats,
      primarySeats,
      skipOccupiedPreferred: fireAt == null && !isFutureSlotToday,
      shuffleFallback: true,
    );

    recorder?.writeSeatPlan(
      campus: primaryRoom.campusName,
      room: primaryRoom.roomName,
      preferSeats: initialQueues.preferred.map((s) => s.seatNo).toList(),
      fallbackSeats: initialQueues.fallback.map((s) => s.seatNo).toList(),
      startTime: startTime,
      endTime: endTime,
      totalRoomSeats: primarySeats.length,
      freeRoomSeats: freeCnt,
    );

    if (fireAt != null) {
      if (keepaliveAt != null) {
        final ok = await waitUntilFn(
          keepaliveAt,
          account,
          stopToken,
          '等待会话保活与时钟复校',
          client.clockSync.nowBeijing,
        );
        if (!ok) {
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: primaryRoom.roomName,
          );
        }
        final alive = await client.keepalive(stopToken: stopToken);
        final offStr = client.clockSync.offsetSeconds.toStringAsFixed(3);
        _log('💓 保活完成 (ok=$alive, clock_offset=${offStr}s)');
      }

      final fireTarget = fireAt.add(
        Duration(milliseconds: fireOffsetMs < 0 ? 0 : fireOffsetMs),
      );
      final ok = await waitUntilFn(
        fireTarget,
        account,
        stopToken,
        '等待准点开抢',
        client.clockSync.nowBeijing,
      );
      if (!ok) {
        return AttackOutcome(
          outcome: 'stopped',
          resolvedRoomName: primaryRoom.roomName,
        );
      }
    }

    final swAttack = Stopwatch()..start();
    try {
      for (var roomIdx = 0; roomIdx < roomPlan.length; roomIdx++) {
        final target = roomPlan[roomIdx];
        if (stopToken.isCancelled) {
          return AttackOutcome(
            outcome: 'stopped',
            resolvedRoomName: target.room,
          );
        }

        RoomInfo room;
        List<SeatCandidate> prefQueue;
        List<SeatCandidate> fallbackQueue;

        if (roomIdx == 0) {
          room = primaryRoom;
          prefQueue = List<SeatCandidate>.from(initialQueues.preferred);
          fallbackQueue = List<SeatCandidate>.from(initialQueues.fallback);
        } else {
          _log('🔀 主自习室已耗尽，切换备选自习室: ${target.campus} -> ${target.room}');
          RoomInfo? resolved;
          try {
            resolved = await client.resolveRoom(
              target.campus,
              target.room,
              dateStr,
              stopToken: stopToken,
            );
          } on TransientServerBusyException catch (exc) {
            _log('⏳ 解析备选自习室 ${target.room} 遇繁忙，跳过: ${exc.message}');
            continue;
          } on DioException catch (exc) {
            _log('⚠️ 解析备选自习室 ${target.room} 网络异常，跳过: ${exc.message}');
            continue;
          }
          if (resolved == null) {
            _log('⚠️ 备选自习室未找到，跳过: ${target.campus} / ${target.room}');
            continue;
          }
          room = resolved;
          if (!await _roomHasFreeSeats(room, dateStr, stopToken)) {
            _log('⏭️ 备选自习室 ${room.roomName} 当前无空座，跳过');
            continue;
          }
          List<SeatCandidate>? liveSeats;
          for (var fbTry = 1; fbTry <= 3; fbTry++) {
            try {
              liveSeats = await client.listRoomSeats(
                room.roomId,
                dateStr,
                stopToken: stopToken,
              );
              client.rateLimiter.markSeatsRefreshed();
              break;
            } on TransientServerBusyException catch (exc) {
              if (fbTry >= 3) {
                _log('⚠️ 拉取备选房 ${room.roomName} 座位布局繁忙，跳过: ${exc.message}');
                break;
              }
              try {
                if (!await client.rateLimiter.waitBackoff(
                  stopToken: stopToken,
                  isRateLimit: exc.isRateLimit,
                )) {
                  return AttackOutcome(
                    outcome: 'stopped',
                    resolvedRoomName: room.roomName,
                  );
                }
              } on RateLimitCircuitOpenException catch (rlExc) {
                _log('🛑 ${rlExc.message}');
                return AttackOutcome(
                  outcome: 'stopped',
                  resolvedRoomName: room.roomName,
                );
              }
            } on DioException catch (exc) {
              if (fbTry >= 3) {
                _log('⚠️ 拉取备选房 ${room.roomName} 座位布局网络异常，跳过: ${exc.message}');
                break;
              }
              if (!await client.rateLimiter.waitBackoff(stopToken: stopToken)) {
                return AttackOutcome(
                  outcome: 'stopped',
                  resolvedRoomName: room.roomName,
                );
              }
            }
          }
          if (liveSeats == null || liveSeats.isEmpty) {
            continue;
          }
          final planned = planSeatCandidates(
            const <String>[],
            liveSeats,
            skipOccupiedPreferred: true,
            shuffleFallback: true,
          );
          prefQueue = planned.preferred;
          fallbackQueue = planned.fallback;
        }

        final triedSeatIds = <String>{};
        var priority = 0;
        var activeQueue = <(String, SeatCandidate)>[
          for (final s in prefQueue) ('首选', s),
          for (final s in fallbackQueue) ('兜底', s),
        ];
        var refreshedAfterPref = false;

        while (activeQueue.isNotEmpty) {
          if (stopToken.isCancelled) {
            return AttackOutcome(
              outcome: 'stopped',
              resolvedRoomName: room.roomName,
            );
          }

          var (tag, seat) = activeQueue.removeAt(0);
          if (triedSeatIds.contains(seat.seatId)) {
            continue;
          }

          // 定时模式首选耗尽进入兜底前才刷新一次实时空座；若未配首选（triedSeatIds 为空）则直接用 06:29:45 刚拉好的全空快照，避免 06:30:00 浪费 250ms
          if (tag == '兜底' &&
              fireAt != null &&
              triedSeatIds.isNotEmpty &&
              !refreshedAfterPref &&
              client.rateLimiter.canRefreshSeats()) {
            refreshedAfterPref = true;
            try {
              final freshSeats = await client.listRoomSeats(
                room.roomId,
                dateStr,
                stopToken: stopToken,
              );
              client.rateLimiter.markSeatsRefreshed();
              final freshPlan = planSeatCandidates(
                const <String>[],
                freshSeats,
                skipOccupiedPreferred: true,
                shuffleFallback: true,
              );
              activeQueue = <(String, SeatCandidate)>[
                for (final s in freshPlan.fallback)
                  if (!triedSeatIds.contains(s.seatId)) ('兜底', s),
              ];
              _log('🔄 已刷新 ${room.roomName} 实时空座快照：剩余 ${activeQueue.length} 个未试空座');
              if (activeQueue.isEmpty) {
                break;
              }
              (tag, seat) = activeQueue.removeAt(0);
            } catch (_) {}
          }

          if (!coordinator.tryClaim(
            account,
            room.roomId,
            seat.seatNo,
            startTime,
            endTime,
          )) {
            _log('⏭️ 座位 ${seat.seatNo} 正由其他同时间段账号尝试，错开换座');
            continue;
          }

          triedSeatIds.add(seat.seatId);
          priority += 1;
          _log('🎯 === [$tag] 抢 ${room.roomName} 座位 ${seat.seatNo} (id=${seat.seatId}) ===');

          BookResponse res;
          try {
            res = await attemptSeat(
              seat,
              startTime: startTime,
              endTime: endTime,
              dateStr: dateStr,
              stopToken: stopToken,
              priority: priority,
              fireAt: fireAt,
            );
          } finally {
            coordinator.release(account, room.roomId, seat.seatNo);
          }

          if (res.status == ApiOutcomeStatus.success) {
            final enriched = await _verifyAndEnrichSuccess(res, stopToken);
            swAttack.stop();
            final elapsedS =
                (swAttack.elapsedMilliseconds / 1000.0).toStringAsFixed(2);
            _log(
              '🎉🎉🎉 ${room.roomName} 座位 ${seat.seatNo} 抢座成功！'
              '(单号=${enriched.reservationId.isNotEmpty ? enriched.reservationId : "-"}, '
              '凭证=${enriched.receipt.isNotEmpty ? enriched.receipt : "-"}, 用时=${elapsedS}s)',
            );
            return AttackOutcome(
              outcome: 'success',
              bookResponse: enriched,
              resolvedRoomName: room.roomName,
            );
          }

          if (res.status == ApiOutcomeStatus.blacklist) {
            _log('🛑 账号已被加入黑名单，立刻停止抢座: ${res.message}');
            return AttackOutcome(
              outcome: 'stopped',
              bookResponse: res,
              resolvedRoomName: room.roomName,
            );
          }

          if (res.status == ApiOutcomeStatus.stop) {
            _log('🛑 收到终态停止信号，立即退出: ${res.message}');
            return AttackOutcome(
              outcome: 'stopped',
              bookResponse: res,
              resolvedRoomName: room.roomName,
            );
          }

          if (res.status == ApiOutcomeStatus.seatTaken &&
              client.rateLimiter.canRefreshSeats()) {
            try {
              final freshSeats = await client.listRoomSeats(
                room.roomId,
                dateStr,
                stopToken: stopToken,
              );
              client.rateLimiter.markSeatsRefreshed();
              final freeIds = <String>{
                for (final s in freshSeats)
                  if (s.status == SeatStatus.free) s.seatId,
              };
              final remainingPref = <(String, SeatCandidate)>[
                for (final item in activeQueue)
                  if (item.$1 == '首选' && !triedSeatIds.contains(item.$2.seatId))
                    item,
              ];
              final freshPlan = planSeatCandidates(
                const <String>[],
                freshSeats,
                skipOccupiedPreferred: true,
                shuffleFallback: true,
              );
              final prefIds = <String>{
                for (final item in remainingPref) item.$2.seatId,
              };
              final remainingFb = <(String, SeatCandidate)>[
                for (final s in freshPlan.fallback)
                  if (freeIds.contains(s.seatId) &&
                      !triedSeatIds.contains(s.seatId) &&
                      !prefIds.contains(s.seatId))
                    ('兜底', s),
              ];
              activeQueue = <(String, SeatCandidate)>[
                ...remainingPref,
                ...remainingFb,
              ];
            } catch (_) {}
          }
        }
      }

      _log('❌ 全部候选自习室与可用座位均已尝试完毕，本轮未抢到。');
      return AttackOutcome(
        outcome: 'all_failed',
        resolvedRoomName: roomPlan.last.room,
      );
    } finally {
      coordinator.releaseAll(account);
    }
  }
}
