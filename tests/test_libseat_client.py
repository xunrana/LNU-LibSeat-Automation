"""core.libseat_client 纯 HTTP 客户端离线单元测试（全 Mock 传输层）。"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import json
from io import BytesIO
from typing import Any

import pytest
from PIL import Image

from core.clock_sync import ClockSync
from core.libseat_client import ClickCaptchaChallenge, HttpLibSeatClient
from core.protocol import GlobalConfig, ProtocolDriftError, TokenExpiredError
from core.rate_limiter import RateLimitCircuitOpenError, RateLimiter, RateLimiterConfig
from core.session_recorder import SessionRecorder


def _png_data_url(w: int = 330, h: int = 160) -> str:
    buf = BytesIO()
    Image.new("RGB", (w, h), (240, 240, 240)).save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


class _FakeResponse:
    def __init__(self, status_code: int = 200, body: Any = None, headers: dict[str, str] | None = None):
        self.status_code = status_code
        self._body = body
        self.headers = headers or {"Date": format_datetime(datetime.now(timezone.utc), usegmt=True)}
        self.text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)

    def json(self) -> Any:
        if isinstance(self._body, str):
            return json.loads(self._body)
        return self._body


class _MockSession:
    def __init__(self, routes: list[_FakeResponse]):
        self._routes = list(routes)
        self.calls: list[dict[str, Any]] = []

    def request(self, method, url, params=None, headers=None, json=None, files=None, timeout=None):
        self.calls.append({
            "method": method,
            "url": url,
            "params": params,
            "headers": headers or {},
            "json": json,
            "files": files,
        })
        assert self._routes, f"Unexpected HTTP call: {method} {url}"
        return self._routes.pop(0)

    def close(self):
        pass


def _make_client(responses: list[_FakeResponse], tmp_path=None, ocr_fn=None) -> tuple[HttpLibSeatClient, _MockSession]:
    sess = _MockSession(responses)
    limiter = RateLimiter(
        RateLimiterConfig(min_interval_ms=0.0, jitter_ms=0.0, backoff_base_s=0.0, throttle_backoff_base_s=0.0),
        sleep_fn=lambda _: None,
    )
    rec = SessionRecorder(tmp_path / "sess", "20240001") if tmp_path else None
    client = HttpLibSeatClient(
        session=sess,  # type: ignore[arg-type]
        clock_sync=ClockSync(),
        rate_limiter=limiter,
        recorder=rec,
        login_ocr_fn=ocr_fn or (lambda _b: "ab12"),
        global_config=GlobalConfig(),
    )
    return client, sess


def test_login_retries_wrong_captcha_and_fetches_profile(tmp_path):
    responses = [
        # 第1次：图形码错了
        _FakeResponse(200, {"captchaId": "cid1", "captchaImage": _png_data_url(160, 70)}),
        _FakeResponse(200, {"status": "fail", "message": "验证码错误"}),
        # 第2次：登录成功 + 拉 user profile
        _FakeResponse(200, {"captchaId": "cid2", "captchaImage": _png_data_url(160, 70)}),
        _FakeResponse(200, {"status": "success", "data": {"token": "t" * 48}, "code": "0", "message": ""}),
        _FakeResponse(200, {"status": "success", "data": {"id": 38497, "username": "20240001", "status": "NORMAL"}}),
    ]
    client, sess = _make_client(responses, tmp_path=tmp_path)
    res = client.login("20240001", "secret123")

    assert res.ok is True
    assert res.token == "t" * 48
    assert res.profile is not None and res.profile.user_id == "38497"
    assert client.clock_sync.synced is True

    # 验证 /rest/auth 请求携带加密头与 HMAC 签名头
    auth_call = sess.calls[1]
    assert auth_call["method"] == "GET"
    assert auth_call["headers"]["username"].endswith("_encrypt")
    assert auth_call["headers"]["password"].endswith("_encrypt")
    assert auth_call["headers"]["loginType"] == "PC"
    assert len(auth_call["headers"]["X-hmac-request-key"]) == 64

    # 验证审计日志中密码与 token 已脱敏
    trace = (tmp_path / "sess" / "http_trace.jsonl").read_text(encoding="utf-8")
    assert "secret123" not in trace
    assert "t" * 48 not in trace


def test_login_detects_maintenance_and_bad_credentials():
    c1, _ = _make_client([
        _FakeResponse(200, {"captchaId": "cid1", "captchaImage": _png_data_url(160, 70)}),
        _FakeResponse(200, {"status": "fail", "message": "系统维护中，请稍后再试"}),
    ])
    r1 = c1.login("20240001", "pwd")
    assert r1.ok is False and r1.reason == "maintenance"

    c2, _ = _make_client([
        _FakeResponse(200, {"captchaId": "cid1", "captchaImage": _png_data_url(160, 70)}),
        _FakeResponse(200, {"status": "fail", "message": "密码错误"}),
    ])
    r2 = c2.login("20240001", "wrong")
    assert r2.ok is False and r2.reason == "bad_credentials"


def test_resolve_room_and_layout_seat_status_mapping():
    responses = [
        _FakeResponse(
            200,
            {
                "status": "success",
                "data": {
                    "buildings": [[1, "蒲河校区图书馆", 0, ""], [2, "崇山校区图书馆", 0, ""]],
                    "rooms": [[30, "三楼智慧研修空间", 2, 3, None]],
                    "dates": ["2026-11-19"],
                },
            },
        ),
        _FakeResponse(
            200,
            {
                "status": "success",
                "data": {
                    "id": 30,
                    "name": "三楼智慧研修空间",
                    "layout": {
                        "0": {"type": "empty"},
                        "1": {"id": 17286, "name": "001", "type": "seat", "status": "FREE", "enabled": True},
                        "2": {"id": 17287, "name": "2", "type": "seat", "status": "IN_USE", "enabled": True},
                        "3": {"id": 17288, "name": "3", "type": "seat", "status": "FULL", "enabled": False},
                        "4": {"id": 17289, "name": "4", "type": "seat", "status": "YESSELECT", "enabled": True},
                    },
                },
            },
        ),
    ]
    client, _ = _make_client(responses)
    room = client.resolve_room("崇山校区图书馆", "三楼智慧研修空间", "2026-11-19")
    assert room is not None and room.room_id == "30" and room.building_id == "2"

    seats = client.list_room_seats("30", "2026-11-19")
    by_no = {s.seat_no: s for s in seats}
    assert set(by_no.keys()) == {"1", "2", "3", "4"}
    assert by_no["1"].status == "free" and by_no["1"].seat_id == "17286"
    assert by_no["2"].status == "occupied"
    assert by_no["3"].status == "unavailable"
    assert by_no["4"].status == "free"


def test_click_captcha_and_multipart_free_book_and_cancel():
    responses = [
        # fetch_click_captcha (wordCheckCount=3)
        _FakeResponse(
            200,
            {
                "status": "OK",
                "token": "a" * 32,
                "wordCheckCount": 3,
                "image": _png_data_url(330, 160),
                "wordImage": _png_data_url(70, 36),
            },
        ),
        # check_click_captcha
        _FakeResponse(200, {"status": "OK"}),
        # free_book success
        _FakeResponse(
            200,
            {
                "status": "success",
                "data": {
                    "id": 4666692,
                    "receipt": "7222-692-4",
                    "location": "崇山校区图书馆3层三楼智慧研修空间，座位号8",
                },
                "message": "",
                "code": "0",
            },
        ),
        # cancel
        _FakeResponse(200, {"status": "success", "data": {"totalCancelled": 1, "allowedCancel": 3}}),
    ]
    client, sess = _make_client(responses)
    client._token = "L" * 48
    client._account = "20240001"

    ch = client.fetch_click_captcha()
    assert isinstance(ch, ClickCaptchaChallenge)
    assert ch.word_check_count == 3 and ch.token == "a" * 32

    chk = client.check_click_captcha(ch, [(10, 20), (100, 50), (250, 90)])
    assert chk.ok is True

    book = client.free_book(
        seat_id="17293",
        seat_no="8",
        start_time="17:00",
        end_time="18:00",
        date_str="2026-11-19",
        authid=ch.token,
    )
    assert book.status == "success"
    assert book.reservation_id == "4666692"
    assert book.receipt == "7222-692-4"

    # 验证 freeBook multipart 字段与分钟整数转换 (17:00 -> 1020, 18:00 -> 1080)
    fb_fields = {k: v[1] for k, v in sess.calls[2]["files"]}
    assert fb_fields["startTime"] == "1020"
    assert fb_fields["endTime"] == "1080"
    assert fb_fields["seat"] == "17293"
    assert fb_fields["authid"] == "a" * 32

    assert client.cancel_reservation("4666692") is True


def test_protocol_drift_token_expired_and_rate_limit_errors():
    c_tok, _ = _make_client([_FakeResponse(200, {"status": "fail", "code": "12", "message": "token过期"})])
    with pytest.raises(TokenExpiredError):
        c_tok.list_active_reservations()

    c_html, _ = _make_client([_FakeResponse(200, "<html>unexpected page</html>")])
    with pytest.raises(ProtocolDriftError):
        c_html.list_active_reservations()

    c_404, _ = _make_client([_FakeResponse(404, {"message": "not found"})])
    with pytest.raises(ProtocolDriftError):
        c_404.list_active_reservations()

    c_429, _ = _make_client([_FakeResponse(429, {"message": "too many requests"})])
    with pytest.raises(RateLimitCircuitOpenError):
        c_429.list_active_reservations()
