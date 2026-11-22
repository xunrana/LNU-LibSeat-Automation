/// 纯 API 客户端请求节流、退避与熔断护栏。
///
/// 与 Python 端 `core/rate_limiter.py` 完全对齐。
library;

import 'dart:async';
import 'dart:math';

/// 限流熔断器打开或单会话请求预算耗尽时抛出。
class RateLimitCircuitOpenException implements Exception {
  final String message;
  const RateLimitCircuitOpenException(this.message);

  @override
  String toString() => 'RateLimitCircuitOpenException: $message';
}

/// 可随时取消的停止信号令牌（对应 Python `threading.Event`）。
///
/// 支持 `nudge()` 唤醒正在 `sleepInterruptible()` 的等待循环（用于 Android 闹钟触发后
/// 立刻重查时钟而不必等完残余 Timer 步长），且不改变 `isCancelled` 状态。
class CancelTokenSource {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();
  Completer<void> _nudgeCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _completer.future;

  /// 唤醒当前所有挂起的 `sleepInterruptible` 调用（非取消，仅促使其立刻重查墙钟）。
  void nudge() {
    if (_cancelled) {
      return;
    }
    if (!_nudgeCompleter.isCompleted) {
      _nudgeCompleter.complete();
    }
    _nudgeCompleter = Completer<void>();
  }

  void cancel() {
    if (!_cancelled) {
      _cancelled = true;
      if (!_completer.isCompleted) {
        _completer.complete();
      }
      if (!_nudgeCompleter.isCompleted) {
        _nudgeCompleter.complete();
      }
    }
  }

  /// 可响应取消信号与外部闹钟唤醒的异步休眠：正常/唤醒结束返回 true，被取消返回 false。
  Future<bool> sleepInterruptible(Duration duration) async {
    if (_cancelled) {
      return false;
    }
    if (duration <= Duration.zero) {
      return !_cancelled;
    }
    final nudgeFuture = _nudgeCompleter.future;
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(duration),
      _completer.future,
      nudgeFuture,
    ]);
    return !_cancelled;
  }

  /// 精确时长可取消休眠：仅响应时长到期或 `cancel()`，不会被外部 `nudge()` 心跳提前截断。
  Future<bool> sleepExact(Duration duration) async {
    if (_cancelled) {
      return false;
    }
    if (duration <= Duration.zero) {
      return !_cancelled;
    }
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(duration),
      _completer.future,
    ]);
    return !_cancelled;
  }
}

class RateLimiterConfig {
  final double minIntervalMs;
  final double jitterMs;
  final double seatRefreshCooldownS;
  final double backoffBaseS;
  final double backoffMaxS;
  final double throttleBackoffBaseS;
  final int maxConsecutiveThrottles;
  final int maxSessionRequests;

  const RateLimiterConfig({
    this.minIntervalMs = 120.0,
    this.jitterMs = 40.0,
    this.seatRefreshCooldownS = 1.5,
    this.backoffBaseS = 0.2,
    this.backoffMaxS = 4.0,
    this.throttleBackoffBaseS = 0.8,
    this.maxConsecutiveThrottles = 12,
    this.maxSessionRequests = 200,
  });
}

class RateLimiter {
  final RateLimiterConfig config;
  final Random _rng;
  final Stopwatch _stopwatch = Stopwatch()..start();

  double? _lastRequestAt;
  double? _lastSeatRefreshAt;
  int _totalRequests = 0;
  int _consecutiveRetries = 0;
  int _consecutiveThrottles = 0;

  RateLimiter({
    this.config = const RateLimiterConfig(),
    Random? rng,
  }) : _rng = rng ?? Random();

  int get totalRequests => _totalRequests;
  int get consecutiveThrottles => _consecutiveThrottles;

  double _monotonicSeconds() => _stopwatch.elapsedMicroseconds / 1000000.0;

  /// 等待下一个合法请求窗口；若预算耗尽抛 RateLimitCircuitOpenException，被中止返回 false。
  Future<bool> waitSlot({CancelTokenSource? stopToken}) async {
    if (stopToken != null && stopToken.isCancelled) {
      return false;
    }

    if (_totalRequests >= config.maxSessionRequests) {
      throw RateLimitCircuitOpenException(
        '单会话请求数已达安全上限 (${config.maxSessionRequests})，停止继续请求',
      );
    }

    final now = _monotonicSeconds();
    var waitS = 0.0;
    if (_lastRequestAt != null) {
      final baseS = max(0.0, config.minIntervalMs) / 1000.0;
      final jitterS = max(0.0, config.jitterMs) / 1000.0;
      final delta = jitterS > 0 ? (_rng.nextDouble() * 2 - 1) * jitterS : 0.0;
      final targetInterval = max(0.0, baseS + delta);
      final elapsed = now - _lastRequestAt!;
      if (elapsed < targetInterval) {
        waitS = targetInterval - elapsed;
      }
    }

    if (waitS > 0) {
      final waitDur = Duration(microseconds: (waitS * 1000000.0).round());
      if (stopToken != null) {
        final ok = await stopToken.sleepExact(waitDur);
        if (!ok) {
          return false;
        }
      } else {
        await Future<void>.delayed(waitDur);
      }
    }

    if (_totalRequests >= config.maxSessionRequests) {
      throw RateLimitCircuitOpenException(
        '单会话请求数已达安全上限 (${config.maxSessionRequests})，停止继续请求',
      );
    }
    _lastRequestAt = _monotonicSeconds();
    _totalRequests += 1;
    return true;
  }

  /// 是否已过房间空座快照刷新冷却期。
  bool canRefreshSeats() {
    if (_lastSeatRefreshAt == null) {
      return true;
    }
    final elapsed = _monotonicSeconds() - _lastSeatRefreshAt!;
    return elapsed >= config.seatRefreshCooldownS;
  }

  void markSeatsRefreshed() {
    _lastSeatRefreshAt = _monotonicSeconds();
  }

  void recordSuccess() {
    _consecutiveRetries = 0;
    _consecutiveThrottles = 0;
  }

  /// 计算下一次退避秒数；若连续限流次数达到熔断阈值则抛出异常。
  double nextBackoff({bool isRateLimit = false}) {
    double base;
    if (isRateLimit) {
      _consecutiveThrottles += 1;
      if (_consecutiveThrottles >= config.maxConsecutiveThrottles) {
        throw RateLimitCircuitOpenException(
          '连续触发限流/429 达 $_consecutiveThrottles 次，熔断停止当前会话',
        );
      }
      final exponent = _consecutiveThrottles - 1;
      base = config.throttleBackoffBaseS * pow(2, exponent);
    } else {
      _consecutiveRetries += 1;
      final exponent = _consecutiveRetries - 1;
      base = config.backoffBaseS * pow(2, exponent);
    }

    final capped = min(base, config.backoffMaxS);
    final jitter = _rng.nextDouble() * min(0.15, capped * 0.25);
    return min(capped + jitter, config.backoffMaxS);
  }

  /// 计算退避并执行可中断休眠；被取消返回 false。
  Future<bool> waitBackoff({
    CancelTokenSource? stopToken,
    bool isRateLimit = false,
  }) async {
    final delayS = nextBackoff(isRateLimit: isRateLimit);
    final dur = Duration(microseconds: (delayS * 1000000.0).round());
    if (stopToken != null) {
      return stopToken.sleepExact(dur);
    }
    await Future<void>.delayed(dur);
    return true;
  }
}
