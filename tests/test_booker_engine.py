"""v6 纯 API 抢座引擎、编排器与配置兼容性单元测试（100% 离线，零浏览器依赖）。"""
from __future__ import annotations

import os
import threading
from datetime import datetime, timedelta, timezone
from unittest import mock

import main
from core.captcha_service import CaptchaService, CaptchaSolveOutcome
from core.clock_sync import BJ_TZ, ClockSync
from core.libseat_client import (
    BookResponse,
    ClickCaptchaChallenge,
    ClickCaptchaCheckResult,
    FiltersData,
    LoginResponse,
    ReservationRecord,
    RoomInfo,
    RoomStats,
    UserProfile,
)
from core.protocol import GlobalConfig, TokenExpiredError
from core.rate_limiter import RateLimiter, RateLimiterConfig
from logic.booker import ApiSeatBooker
from logic.orchestrator import run_api_session
from logic.seat_strategy import SeatCandidate, SeatClaimCoordinator
from ui_qt.services import config_io


class _FakeCaptchaService(CaptchaService):
    def __init__(self, outcomes: list[CaptchaSolveOutcome] | None = None):
        super().__init__()
        self._outcomes = list(outcomes or [])

    def solve(self, target_bytes, bg_bytes, *, kind=None, hint_count=None, now=None):
        if self._outcomes:
            return self._outcomes.pop(0)
        pts = ((10, 20), (30, 40), (50, 60)) if hint_count == 3 else ((120, 80),)
        return CaptchaSolveOutcome(ok=True, kind="click3" if hint_count == 3 else "click1", points=pts)


class _FakeLibSeatClient:
    def __init__(
        self,
        *,
        login_responses: list[LoginResponse] | None = None,
        active_reservations: list[ReservationRecord] | None = None,
        rooms: dict[tuple[str, str], RoomInfo] | None = None,
        seats_by_room: dict[str, list[SeatCandidate]] | None = None,
        stats_by_building: dict[str, list[RoomStats]] | None = None,
        book_results: list[BookResponse | Exception] | None = None,
        check_results: list[ClickCaptchaCheckResult] | None = None,
        word_check_count: int = 3,
        now_utc: datetime | None = None,
    ):
        self._clock = ClockSync(now_utc_fn=(lambda: now_utc) if now_utc else None)
        self._limiter = RateLimiter(
            RateLimiterConfig(min_interval_ms=0.0, jitter_ms=0.0, backoff_base_s=0.0, seat_refresh_cooldown_s=0.0),
            sleep_fn=lambda _: None,
        )
        self._login_responses = list(
            login_responses
            or [LoginResponse(ok=True, token="t" * 48, profile=UserProfile("38497", "20240001"))]
        )
        self._active_reservations = list(active_reservations or [])
        self._rooms = rooms or {
            ("崇山校区图书馆", "三楼智慧研修空间"): RoomInfo("崇山校区图书馆", "三楼智慧研修空间", "2", "30"),
            ("崇山校区图书馆", "四楼南自习室"): RoomInfo("崇山校区图书馆", "四楼南自习室", "2", "24"),
        }
        self._seats_by_room = seats_by_room or {
            "30": [
                SeatCandidate("8", "17293", "30", "free"),
                SeatCandidate("9", "17294", "30", "occupied"),
                SeatCandidate("10", "17295", "30", "free"),
            ],
            "24": [
                SeatCandidate("194", "20194", "24", "free"),
            ],
        }
        self._stats_by_building = stats_by_building or {
            "2": [
                RoomStats("30", "三楼智慧研修空间", total_seats=3, free_seats=2),
                RoomStats("24", "四楼南自习室", total_seats=1, free_seats=1),
            ]
        }
        self._book_results = list(book_results or [BookResponse(status="success", seat_no="8", reservation_id="4666692", receipt="7222-692-4")])
        self._check_results = list(check_results or [])
        self._word_check_count = word_check_count

        self.booked_seat_ids: list[str] = []
        self.login_calls = 0
        self.keepalive_calls = 0
        self.closed = False

    @property
    def clock_sync(self) -> ClockSync:
        return self._clock

    @property
    def rate_limiter(self) -> RateLimiter:
        return self._limiter

    def bootstrap_global(self, stop_event=None):
        return GlobalConfig()

    def login(self, account, password, *, stop_event=None, max_attempts=6):
        self.login_calls += 1
        return self._login_responses.pop(0) if len(self._login_responses) > 1 else self._login_responses[0]

    def keepalive(self, stop_event=None):
        self.keepalive_calls += 1
        return True

    def list_active_reservations(self, stop_event=None):
        return list(self._active_reservations)

    def fetch_filters(self, stop_event=None):
        return FiltersData()

    def list_room_stats(self, building_id, date_str, *, stop_event=None):
        return list(self._stats_by_building.get(building_id, []))

    def resolve_room(self, campus_name, room_name, date_str, *, stop_event=None):
        return self._rooms.get((campus_name, room_name))

    def list_room_seats(self, room_id, date_str, *, stop_event=None):
        return list(self._seats_by_room.get(room_id, []))

    def fetch_click_captcha(self, *, stop_event=None):
        return ClickCaptchaChallenge(
            token="c" * 32,
            word_check_count=self._word_check_count,
            target_bytes=b"target",
            bg_bytes=b"bg",
        )

    def check_click_captcha(self, challenge, points, *, stop_event=None):
        if self._check_results:
            return self._check_results.pop(0)
        return ClickCaptchaCheckResult(ok=True)

    def free_book(
        self,
        *,
        seat_id,
        seat_no,
        start_time,
        end_time,
        date_str,
        authid,
        in_open_grace_window=False,
        stop_event=None,
    ):
        self.booked_seat_ids.append(seat_id)
        item = self._book_results.pop(0) if len(self._book_results) > 1 else self._book_results[0]
        if isinstance(item, Exception):
            raise item
        return BookResponse(
            status=item.status,
            message=item.message,
            seat_no=seat_no,
            reservation_id=item.reservation_id,
            receipt=item.receipt,
            not_open_yet=item.not_open_yet,
            rate_limited=item.rate_limited,
        )

    def cancel_reservation(self, reservation_id, *, stop_event=None):
        return True

    def close(self):
        self.closed = True


def _instant_wait(_target, _account, stop_event, _stage, _now_fn=None):
    return not stop_event.is_set()


# ───────────────── ApiSeatBooker 核心状态机测试 ─────────────────

def test_booker_grace_retries_on_0630_not_open_yet_then_succeeds():
    fire_utc = datetime(2026, 11, 18, 22, 30, 0, tzinfo=timezone.utc)  # BJ 06:30:00
    fire_bj = fire_utc.astimezone(BJ_TZ)
    client = _FakeLibSeatClient(
        now_utc=fire_utc,
        book_results=[
            BookResponse(status="retry_captcha", message="系统可预约时间为 06:30 ~ 22:30", not_open_yet=True),
            BookResponse(status="success", reservation_id="4666692", receipt="7222-692-4"),
        ],
    )
    booker = ApiSeatBooker(
        client,
        account="20240001",
        captcha_service=_FakeCaptchaService(),
        grace_backoff_seconds=0.0,
    )
    res = booker.attempt_seat(
        SeatCandidate("8", "17293", "30", "free"),
        start_time="09:00",
        end_time="15:00",
        date_str="2026-11-19",
        stop_event=threading.Event(),
        fire_at=fire_bj,
    )
    assert res.status == "success"
    assert len(client.booked_seat_ids) == 2


def test_booker_rolls_over_to_fallback_room_when_primary_seats_taken():
    client = _FakeLibSeatClient(
        seats_by_room={
            "30": [SeatCandidate("8", "17293", "30", "free")],
            "24": [SeatCandidate("194", "20194", "24", "free")],
        },
        book_results=[
            BookResponse(status="seat_taken", message="该座位已被他人预约"),
            BookResponse(status="success", reservation_id="9001", receipt="R-9001"),
        ],
    )
    booker = ApiSeatBooker(client, account="20240001", captcha_service=_FakeCaptchaService())
    outcome, res, room_name = booker.attack_rooms(
        room_plan=[("崇山校区图书馆", "三楼智慧研修空间"), ("崇山校区图书馆", "四楼南自习室")],
        prefer_seats=["8"],
        start_time="09:00",
        end_time="15:00",
        schedule=None,
        stop_event=threading.Event(),
        coordinator=SeatClaimCoordinator(),
        wait_until_fn=_instant_wait,
    )
    assert outcome == "success"
    assert res is not None and res.seat_no == "194" and res.reservation_id == "9001"
    assert room_name == "四楼南自习室"
    assert client.booked_seat_ids == ["17293", "20194"]


def test_booker_stops_immediately_on_blacklist_and_existing_reservation():
    # 1) 已有有效预约直接停止，不发起下单
    c_existing = _FakeLibSeatClient(
        active_reservations=[ReservationRecord(reservation_id="123", status="RESERVE", location="四楼南194")],
    )
    b1 = ApiSeatBooker(c_existing, account="20240001", captcha_service=_FakeCaptchaService())
    outcome1, _, _ = b1.attack_rooms(
        room_plan=[("崇山校区图书馆", "三楼智慧研修空间")],
        prefer_seats=["8"],
        start_time="09:00",
        end_time="15:00",
        schedule=None,
        stop_event=threading.Event(),
        coordinator=SeatClaimCoordinator(),
        wait_until_fn=_instant_wait,
    )
    assert outcome1 == "stopped"
    assert c_existing.booked_seat_ids == []

    # 2) 黑名单立即停止，不尝试第二个座位
    c_bl = _FakeLibSeatClient(
        book_results=[BookResponse(status="blacklist", message="对不起，您已被加入黑名单")],
    )
    b2 = ApiSeatBooker(c_bl, account="20240001", captcha_service=_FakeCaptchaService())
    outcome2, res2, _ = b2.attack_rooms(
        room_plan=[("崇山校区图书馆", "三楼智慧研修空间")],
        prefer_seats=["8", "10"],
        start_time="09:00",
        end_time="15:00",
        schedule=None,
        stop_event=threading.Event(),
        coordinator=SeatClaimCoordinator(),
        wait_until_fn=_instant_wait,
    )
    assert outcome2 == "stopped" and res2 is not None and res2.status == "blacklist"
    assert c_bl.booked_seat_ids == ["17293"]


# ───────────────── Orchestrator 会话编排测试 ─────────────────

def test_orchestrator_relogins_on_token_expired_and_notifies(tmp_path, monkeypatch):
    import config

    monkeypatch.setattr(config, "LOG_DIR", str(tmp_path), raising=False)
    monkeypatch.setattr(config, "TARGET_CAMPUS", "崇山校区图书馆", raising=False)
    monkeypatch.setattr(config, "TARGET_ROOM", "三楼智慧研修空间", raising=False)
    monkeypatch.setattr(config, "FALLBACK_ROOMS", [], raising=False)
    monkeypatch.setattr(config, "PREFER_SEATS", ["8"], raising=False)

    fake_client = _FakeLibSeatClient(
        book_results=[
            TokenExpiredError("token过期"),
            BookResponse(status="success", reservation_id="4666692", receipt="7222-692-4"),
        ]
    )
    with mock.patch("logic.orchestrator.notify_booking_success") as mock_notify:
        status = run_api_session(
            "20240001",
            "pwd",
            "09:00",
            "15:00",
            threading.Event(),
            client_factory=lambda _rec: fake_client,
            captcha_service=_FakeCaptchaService(),
            wait_until_fn=_instant_wait,
        )

    assert status == "success"
    assert fake_client.login_calls == 2
    assert fake_client.closed is True
    mock_notify.assert_called_once()


def test_orchestrator_maintenance_defer_until_fire(tmp_path, monkeypatch):
    import config

    monkeypatch.setattr(config, "LOG_DIR", str(tmp_path), raising=False)
    future_fire = datetime.now(BJ_TZ) + timedelta(minutes=10)
    schedule = {
        "run_date": future_fire.date(),
        "prep_at": future_fire - timedelta(seconds=15),
        "keepalive_at": future_fire - timedelta(seconds=5),
        "fire_at": future_fire,
    }
    fake_client = _FakeLibSeatClient(
        login_responses=[LoginResponse(ok=False, reason="maintenance", message="系统维护中")]
    )
    status = run_api_session(
        "20240001",
        "pwd",
        "09:00",
        "15:00",
        threading.Event(),
        schedule=schedule,
        wait_for_fire=True,
        client_factory=lambda _rec: fake_client,
        captcha_service=_FakeCaptchaService(),
        wait_until_fn=_instant_wait,
    )
    assert status == "maintenance_retry_at_fire"


# ───────────────── 会话日志切片与 v5 配置向后兼容测试 ─────────────────

def test_setup_session_dir_and_export_slice(tmp_path, monkeypatch):
    import config

    monkeypatch.setattr(config, "LOG_DIR", str(tmp_path), raising=False)
    logf = tmp_path / "lnu_seat_accC.log"
    logf.write_bytes(b"OLD\nNEW LINE\n")
    session_dir, log_start = main._setup_session_dir("accC")
    assert session_dir is not None and os.path.isdir(session_dir)
    assert log_start == len(b"OLD\nNEW LINE\n")

    main._export_session_log(session_dir, len(b"OLD\n"), "accC")
    assert (tmp_path / "sessions").is_dir()
    assert open(os.path.join(session_dir, "session.log"), encoding="utf-8").read() == "NEW LINE\n"


def test_config_io_ignores_legacy_v5_browser_fields_and_roundtrips_v6(tmp_path):
    legacy_cfg = tmp_path / "config.py"
    legacy_cfg.write_text(
        'USERS = {"20240001": {"password": "pwd", "time": {"start": "09:00", "end": "15:00"}}}\n'
        'TARGET_CAMPUS = "崇山校区图书馆"\n'
        'TARGET_ROOM = "四楼南自习室"\n'
        'PREFER_SEATS = ["194"]\n'
        'BROWSER = "edge"\n'
        'DRIVER_PATH = "C:/old/msedgedriver.exe"\n'
        'WEBDRIVER_CACHE = "C:/old/cache"\n'
        'WAIT_FOR_0630 = True\n',
        encoding="utf-8",
    )
    state = config_io.load_state(str(legacy_cfg))
    assert state.room == "四楼南自习室"
    assert state.seats == ["194"]
    assert state.accounts[0].account == "20240001"

    state.webhook_url = "https://api.day.app/demo/"
    state.fallback_rooms = [("崇山校区图书馆", "四楼北自习室")]
    out_cfg = tmp_path / "config_v6.py"
    config_io.save_state_to_file(state, str(out_cfg))
    text = out_cfg.read_text(encoding="utf-8")
    assert "BROWSER" not in text and "DRIVER_PATH" not in text
    assert "FALLBACK_ROOMS" in text and "WEBHOOK_URL" in text

    reloaded = config_io.load_state(str(out_cfg))
    assert reloaded.webhook_url == "https://api.day.app/demo/"
    assert reloaded.fallback_rooms == [("崇山校区图书馆", "四楼北自习室")]
