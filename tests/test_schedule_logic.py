"""定时日程与 wait_until 精度/中断逻辑单元测试（v6 纯 API 提前量）。"""
import threading
from datetime import datetime, timedelta, timezone

import main

BJ = timezone(timedelta(hours=8))


def bj_time(year, month, day, hour, minute, second=0):
    return datetime(year, month, day, hour, minute, second, tzinfo=BJ)


def test_build_custom_schedule_before_target_runs_today():
    schedule = main.build_custom_schedule(6, 30, bj_time(2026, 3, 26, 5, 0, 0))

    assert schedule["run_date"].isoformat() == "2026-03-26"
    assert schedule["fire_at"] == bj_time(2026, 3, 26, 6, 30, 0)
    assert schedule["prep_at"] == bj_time(2026, 3, 26, 6, 29, 45)      # fire - 15s
    assert schedule["keepalive_at"] == bj_time(2026, 3, 26, 6, 29, 55) # fire - 5s


def test_build_custom_schedule_at_or_after_target_rolls_to_tomorrow():
    schedule = main.build_custom_schedule(6, 30, bj_time(2026, 3, 26, 6, 30, 0))

    assert schedule["run_date"].isoformat() == "2026-03-27"
    assert schedule["fire_at"] == bj_time(2026, 3, 27, 6, 30, 0)
    assert schedule["prep_at"] == bj_time(2026, 3, 27, 6, 29, 45)
    assert schedule["keepalive_at"] == bj_time(2026, 3, 27, 6, 29, 55)


def test_build_custom_schedule_uses_lead_constants():
    schedule = main.build_custom_schedule(11, 25, bj_time(2026, 3, 26, 11, 0, 0))

    fire_at = schedule["fire_at"]
    assert fire_at == bj_time(2026, 3, 26, 11, 25, 0)
    assert schedule["prep_at"] == fire_at - timedelta(seconds=main.PREP_LEAD_SECONDS)
    assert schedule["keepalive_at"] == fire_at - timedelta(seconds=main.KEEPALIVE_LEAD_SECONDS)


def test_wait_until_returns_immediately_when_target_has_passed(monkeypatch):
    now = bj_time(2026, 3, 26, 6, 30, 1)
    target = bj_time(2026, 3, 26, 6, 30, 0)
    monkeypatch.setattr(main.utils, "get_beijing_time", lambda: now)

    assert main.wait_until(target, "test_account", threading.Event(), "确认提交") is True


def test_wait_until_supports_custom_clock_sync_now_fn():
    server_now = bj_time(2026, 3, 26, 6, 30, 0)
    target = bj_time(2026, 3, 26, 6, 30, 0)
    assert main.wait_until(target, "acc", threading.Event(), "服务端开抢", now_fn=lambda: server_now) is True


def test_wait_until_returns_false_when_stop_event_already_set(monkeypatch):
    now = bj_time(2026, 3, 26, 5, 0, 0)
    target = bj_time(2026, 3, 26, 6, 30, 0)
    monkeypatch.setattr(main.utils, "get_beijing_time", lambda: now)

    ev = threading.Event()
    ev.set()
    assert main.wait_until(target, "test_account", ev, "确认提交") is False


class _SignalDuringWait:
    def is_set(self):
        return False

    def wait(self, timeout=None):
        return True


def test_wait_until_aborts_when_signal_arrives_during_long_sleep(monkeypatch):
    now = bj_time(2026, 3, 26, 5, 0, 0)
    target = bj_time(2026, 3, 26, 6, 30, 0)
    monkeypatch.setattr(main.utils, "get_beijing_time", lambda: now)

    assert main.wait_until(target, "test_account", _SignalDuringWait(), "确认提交") is False


def test_build_custom_schedule_rolls_across_year_boundary():
    schedule = main.build_custom_schedule(6, 30, bj_time(2026, 12, 31, 23, 0, 0))

    assert schedule["run_date"].isoformat() == "2027-01-01"
    assert schedule["fire_at"] == bj_time(2027, 1, 1, 6, 30, 0)
    assert schedule["keepalive_at"] == bj_time(2027, 1, 1, 6, 29, 55)
