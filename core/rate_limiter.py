"""纯 API 客户端请求节流、退避与熔断护栏。

防止纯 HTTP 模式下因高频并发请求触发校园网出口限流、HTTP 429 或业务层
「操作过于频繁」风控，同时为单会话请求总数提供硬顶保护。
"""
from __future__ import annotations

import random
import threading
import time
from dataclasses import dataclass
from typing import Callable


class RateLimitCircuitOpenError(RuntimeError):
    """限流熔断器打开或单会话请求预算耗尽时抛出。"""


@dataclass(frozen=True)
class RateLimiterConfig:
    min_interval_ms: float = 120.0
    jitter_ms: float = 40.0
    seat_refresh_cooldown_s: float = 1.5
    backoff_base_s: float = 0.2
    backoff_max_s: float = 6.0
    throttle_backoff_base_s: float = 3.0
    max_consecutive_throttles: int = 5
    max_session_requests: int = 160


def _interruptible_sleep(
    seconds: float,
    stop_event: threading.Event | None,
    sleep_fn: Callable[[float], None],
) -> bool:
    """可响应 stop_event 的休眠；正常结束返回 True，被中断返回 False。"""
    if seconds <= 0:
        return not (stop_event is not None and stop_event.is_set())
    if stop_event is not None:
        return not stop_event.wait(timeout=seconds)
    sleep_fn(seconds)
    return True


class RateLimiter:
    """线程安全的单会话请求节流与退避控制器。"""

    def __init__(
        self,
        config: RateLimiterConfig | None = None,
        *,
        monotonic_fn: Callable[[], float] | None = None,
        sleep_fn: Callable[[float], None] | None = None,
        rng: random.Random | None = None,
    ) -> None:
        self.config = config or RateLimiterConfig()
        self._monotonic = monotonic_fn or time.monotonic
        self._sleep = sleep_fn or time.sleep
        self._rng = rng or random.Random()
        self._lock = threading.Lock()

        self._last_request_at: float | None = None
        self._last_seat_refresh_at: float | None = None
        self._total_requests: int = 0
        self._consecutive_retries: int = 0
        self._consecutive_throttles: int = 0

    @property
    def total_requests(self) -> int:
        with self._lock:
            return self._total_requests

    @property
    def consecutive_throttles(self) -> int:
        with self._lock:
            return self._consecutive_throttles

    def wait_slot(self, stop_event: threading.Event | None = None) -> bool:
        """等待下一个合法请求窗口；若预算耗尽抛 RateLimitCircuitOpenError，被中止返回 False。"""
        if stop_event is not None and stop_event.is_set():
            return False

        with self._lock:
            if self._total_requests >= self.config.max_session_requests:
                raise RateLimitCircuitOpenError(
                    f"单会话请求数已达安全上限 ({self.config.max_session_requests})，停止继续请求"
                )
            now = self._monotonic()
            wait_s = 0.0
            if self._last_request_at is not None:
                base_s = max(0.0, self.config.min_interval_ms) / 1000.0
                jitter_s = max(0.0, self.config.jitter_ms) / 1000.0
                delta = self._rng.uniform(-jitter_s, jitter_s) if jitter_s > 0 else 0.0
                target_interval = max(0.0, base_s + delta)
                elapsed = now - self._last_request_at
                if elapsed < target_interval:
                    wait_s = target_interval - elapsed

        if wait_s > 0 and not _interruptible_sleep(wait_s, stop_event, self._sleep):
            return False

        with self._lock:
            if self._total_requests >= self.config.max_session_requests:
                raise RateLimitCircuitOpenError(
                    f"单会话请求数已达安全上限 ({self.config.max_session_requests})，停止继续请求"
                )
            self._last_request_at = self._monotonic()
            self._total_requests += 1
        return True

    def can_refresh_seats(self) -> bool:
        """是否已过房间空座快照刷新冷却期。"""
        with self._lock:
            if self._last_seat_refresh_at is None:
                return True
            elapsed = self._monotonic() - self._last_seat_refresh_at
            return elapsed >= self.config.seat_refresh_cooldown_s

    def mark_seats_refreshed(self) -> None:
        with self._lock:
            self._last_seat_refresh_at = self._monotonic()

    def record_success(self) -> None:
        """成功响应后重置连续重试与限流计数。"""
        with self._lock:
            self._consecutive_retries = 0
            self._consecutive_throttles = 0

    def next_backoff(self, *, is_rate_limit: bool = False) -> float:
        """计算下一次退避秒数；若连续限流次数达到熔断阈值则抛出异常。"""
        with self._lock:
            if is_rate_limit:
                self._consecutive_throttles += 1
                if self._consecutive_throttles >= self.config.max_consecutive_throttles:
                    raise RateLimitCircuitOpenError(
                        f"连续触发限流/429 达 {self._consecutive_throttles} 次，熔断停止当前会话"
                    )
                exponent = self._consecutive_throttles - 1
                base = self.config.throttle_backoff_base_s * (2 ** exponent)
            else:
                self._consecutive_retries += 1
                exponent = self._consecutive_retries - 1
                base = self.config.backoff_base_s * (2 ** exponent)

            capped = min(base, self.config.backoff_max_s)
            jitter = self._rng.uniform(0.0, min(0.15, capped * 0.25))
            return min(capped + jitter, self.config.backoff_max_s)

    def wait_backoff(
        self,
        stop_event: threading.Event | None = None,
        *,
        is_rate_limit: bool = False,
    ) -> bool:
        """计算退避并执行可中断休眠；被 stop_event 中断返回 False。"""
        delay = self.next_backoff(is_rate_limit=is_rate_limit)
        return _interruptible_sleep(delay, stop_event, self._sleep)
