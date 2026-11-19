"""core.rate_limiter 节流、冷却与熔断器单元测试。"""
import random
import threading

import pytest

from core.rate_limiter import RateLimitCircuitOpenError, RateLimiter, RateLimiterConfig


class _FakeClock:
    def __init__(self, start: float = 100.0) -> None:
        self.now = start
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


def test_wait_slot_enforces_min_interval_with_jitter():
    clock = _FakeClock()
    cfg = RateLimiterConfig(min_interval_ms=200.0, jitter_ms=0.0, max_session_requests=10)
    limiter = RateLimiter(cfg, monotonic_fn=clock.monotonic, sleep_fn=clock.sleep, rng=random.Random(1))

    assert limiter.wait_slot() is True
    assert clock.sleeps == []
    assert limiter.total_requests == 1

    # 立刻发第二次：应精确休眠 0.2s
    assert limiter.wait_slot() is True
    assert len(clock.sleeps) == 1
    assert clock.sleeps[0] == pytest.approx(0.2, abs=1e-6)
    assert limiter.total_requests == 2


def test_wait_slot_aborts_immediately_on_stop_event():
    clock = _FakeClock()
    limiter = RateLimiter(monotonic_fn=clock.monotonic, sleep_fn=clock.sleep)
    ev = threading.Event()
    ev.set()
    assert limiter.wait_slot(stop_event=ev) is False
    assert limiter.total_requests == 0


def test_session_budget_trips_circuit_error():
    clock = _FakeClock()
    cfg = RateLimiterConfig(min_interval_ms=0.0, jitter_ms=0.0, max_session_requests=2)
    limiter = RateLimiter(cfg, monotonic_fn=clock.monotonic, sleep_fn=clock.sleep)

    assert limiter.wait_slot() is True
    assert limiter.wait_slot() is True
    with pytest.raises(RateLimitCircuitOpenError):
        limiter.wait_slot()


def test_seat_refresh_cooldown():
    clock = _FakeClock()
    cfg = RateLimiterConfig(seat_refresh_cooldown_s=1.5)
    limiter = RateLimiter(cfg, monotonic_fn=clock.monotonic, sleep_fn=clock.sleep)

    assert limiter.can_refresh_seats() is True
    limiter.mark_seats_refreshed()
    assert limiter.can_refresh_seats() is False

    clock.now += 1.0
    assert limiter.can_refresh_seats() is False

    clock.now += 0.5
    assert limiter.can_refresh_seats() is True


def test_backoff_and_throttle_circuit_breaker():
    clock = _FakeClock()
    cfg = RateLimiterConfig(
        backoff_base_s=0.2,
        backoff_max_s=5.0,
        throttle_backoff_base_s=2.0,
        max_consecutive_throttles=3,
    )
    limiter = RateLimiter(cfg, monotonic_fn=clock.monotonic, sleep_fn=clock.sleep, rng=random.Random(42))

    # 普通重试退避递增且封顶
    d1 = limiter.next_backoff(is_rate_limit=False)
    d2 = limiter.next_backoff(is_rate_limit=False)
    assert 0.2 <= d1 < d2 <= 5.0

    # 连续限流到第 3 次触发熔断
    t1 = limiter.next_backoff(is_rate_limit=True)
    t2 = limiter.next_backoff(is_rate_limit=True)
    assert 2.0 <= t1 <= 5.0
    assert 4.0 <= t2 <= 5.0
    with pytest.raises(RateLimitCircuitOpenError):
        limiter.next_backoff(is_rate_limit=True)

    # 成功后归零
    limiter.record_success()
    assert limiter.consecutive_throttles == 0
    assert limiter.next_backoff(is_rate_limit=True) >= 2.0
