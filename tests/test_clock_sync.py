"""core.clock_sync 服务端时钟校准单元测试。"""
from datetime import datetime, timedelta, timezone

import pytest

from core.clock_sync import BJ_TZ, ClockSync


def _utc(year, month, day, hour, minute, second, microsecond=0):
    return datetime(year, month, day, hour, minute, second, microsecond, tzinfo=timezone.utc)


def test_unsynced_returns_local_beijing_time():
    fixed = _utc(2026, 11, 19, 22, 29, 58)  # BJ 06:29:58 next day
    cs = ClockSync(now_utc_fn=lambda: fixed)
    assert cs.synced is False
    assert cs.offset_seconds == 0.0
    assert cs.now_beijing() == datetime(2026, 11, 20, 6, 29, 58, tzinfo=BJ_TZ)


def test_update_from_http_date_applies_rtt_midpoint():
    # 本地收到响应时刻为 22:29:58.500 UTC，RTT = 0.200s -> 本地请求中点为 22:29:58.400
    # 服务端 Date 为 22:30:00 UTC -> offset = +1.600s
    recv = _utc(2026, 11, 19, 22, 29, 58, 500_000)
    cs = ClockSync(now_utc_fn=lambda: recv)
    sample = cs.update_from_http_date(
        "Thu, 19 Nov 2026 22:30:00 GMT",
        rtt_seconds=0.2,
        local_received_utc=recv,
    )
    assert sample is not None
    assert cs.synced is True
    assert cs.offset_seconds == pytest.approx(1.6, abs=1e-3)
    # 校准后的北京时间 = 06:29:58.500 + 1.6s = 06:30:00.100
    assert cs.now_beijing() == datetime(2026, 11, 20, 6, 30, 0, 100_000, tzinfo=BJ_TZ)


def test_prefers_lower_rtt_sample_until_stale():
    t0 = _utc(2026, 11, 19, 22, 29, 0)
    cs = ClockSync(stale_after_seconds=60.0, now_utc_fn=lambda: t0)

    # 样本1: rtt=0.5s, offset=+1.25s
    cs.update_from_http_date("Thu, 19 Nov 2026 22:29:01 GMT", rtt_seconds=0.5, local_received_utc=t0)
    assert cs.offset_seconds == pytest.approx(1.25, abs=1e-3)

    # 样本2 (10s 后): rtt=0.8s 更差 -> 不覆盖
    t1 = t0 + timedelta(seconds=10)
    cs.update_from_http_date("Thu, 19 Nov 2026 22:29:15 GMT", rtt_seconds=0.8, local_received_utc=t1)
    assert cs.offset_seconds == pytest.approx(1.25, abs=1e-3)

    # 样本3 (12s 后): rtt=0.1s 更好 -> 覆盖
    t2 = t0 + timedelta(seconds=12)
    cs.update_from_http_date("Thu, 19 Nov 2026 22:29:13 GMT", rtt_seconds=0.1, local_received_utc=t2)
    assert cs.offset_seconds == pytest.approx(1.05, abs=1e-3)

    # 样本4 (75s 后已过期): 即使 rtt=0.9s 也刷新
    t3 = t2 + timedelta(seconds=75)
    cs.update_from_http_date("Thu, 19 Nov 2026 22:30:28 GMT", rtt_seconds=0.9, local_received_utc=t3)
    assert cs.offset_seconds == pytest.approx(1.45, abs=1e-3)


def test_rejects_invalid_and_extreme_http_date():
    now = _utc(2026, 11, 19, 22, 29, 0)
    cs = ClockSync(max_accept_offset_seconds=3600.0, now_utc_fn=lambda: now)

    assert cs.update_from_http_date("") is None
    assert cs.update_from_http_date("not-a-date") is None
    # 极端异常时间 (1970) 应被拒绝
    assert cs.update_from_http_date("Thu, 01 Jan 1970 00:00:00 GMT", local_received_utc=now) is None
    assert cs.synced is False


def test_reset_clears_offset():
    now = _utc(2026, 11, 19, 22, 29, 0)
    cs = ClockSync(now_utc_fn=lambda: now)
    cs.update_from_http_date("Thu, 19 Nov 2026 22:29:02 GMT", local_received_utc=now)
    assert cs.synced is True
    cs.reset()
    assert cs.synced is False
    assert cs.offset_seconds == 0.0
