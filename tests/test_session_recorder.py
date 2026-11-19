"""core.session_recorder 脱敏 HTTP 追踪与验证码诊断图单元测试。"""
import json
from io import BytesIO

from PIL import Image

from core.captcha_service import CaptchaSolveOutcome
from core.session_recorder import SessionRecorder, sanitize_for_trace


def _png_bytes(w: int, h: int, color=(240, 240, 240)) -> bytes:
    buf = BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def test_sanitize_redacts_secrets_and_large_blobs():
    raw = {
        "password": "MySecretPassword123",
        "token": "eyJhbGciOiJIUzI1NiJ9.supersecret",
        "Authorization": "Bearer abcdef",
        "Cookie": "JSESSIONID=123456",
        "aesHeader": "plaintext-secret",
        "nested": {"pwd": "000000", "safe_seat": "194"},
        "opaque": "A" * 80,
        "img": "data:image/png;base64," + "B" * 200,
    }
    clean = sanitize_for_trace(raw)
    dumped = json.dumps(clean, ensure_ascii=False)

    assert "MySecretPassword123" not in dumped
    assert "supersecret" not in dumped
    assert "Bearer abcdef" not in dumped
    assert "JSESSIONID=123456" not in dumped
    assert "plaintext-secret" not in dumped
    assert "000000" not in dumped
    assert "A" * 80 not in dumped
    assert "B" * 200 not in dumped
    assert clean["nested"]["safe_seat"] == "194"


def test_record_http_writes_valid_sanitized_jsonl(tmp_path):
    rec = SessionRecorder(tmp_path / "sess1", "20240001")
    rec.record_http(
        stage="login",
        method="post",
        path="/rest/auth",
        status_code=200,
        rtt_ms=42.567,
        req_summary={"username": "20240001", "password": "secret-password", "headers": {"Cookie": "sid=xyz"}},
        resp_summary={"status": "success", "token": "tok_secret_value"},
        biz_msg="ok",
    )

    trace_file = tmp_path / "sess1" / "http_trace.jsonl"
    content = trace_file.read_text(encoding="utf-8")
    assert "secret-password" not in content
    assert "sid=xyz" not in content
    assert "tok_secret_value" not in content

    row = json.loads(content.strip())
    assert row["stage"] == "login"
    assert row["method"] == "POST"
    assert row["status"] == 200
    assert row["rtt_ms"] == 42.57
    assert row["req"]["password"] == "<REDACTED>"
    assert row["resp"]["token"] == "<REDACTED>"


def test_save_captcha_diagnostic_creates_valid_png(tmp_path):
    rec = SessionRecorder(tmp_path / "sess2", "20240001")
    outcome = CaptchaSolveOutcome(
        ok=True,
        kind="click3",
        points=((40, 50), (120, 60), (200, 70)),
        candidates=((40, 50), (120, 60), (200, 70), (250, 80)),
        candidate_confidences=(0.95, 0.91, 0.88, 0.72),
        elapsed_ms=135.4,
    )
    out = rec.save_captcha_diagnostic(
        target_bytes=_png_bytes(70, 32),
        bg_bytes=_png_bytes(300, 120, (200, 220, 240)),
        outcome=outcome,
        priority=1,
        seat="194",
        retry=1,
    )
    assert out is not None and out.is_file()
    with Image.open(out) as im:
        assert im.width >= 300
        assert im.height > 120


def test_write_seat_plan_includes_live_stats(tmp_path):
    rec = SessionRecorder(tmp_path / "sess3", "20240001")
    p = rec.write_seat_plan(
        campus="崇山校区图书馆",
        room="四楼南自习室",
        prefer_seats=["194", "195"],
        fallback_seats=["10", "20"],
        start_time="09:00",
        end_time="15:00",
        total_room_seats=336,
        free_room_seats=203,
    )
    assert p is not None and p.is_file()
    text = p.read_text(encoding="utf-8")
    assert "实时空座: 203 / 336" in text
    assert "1. [首选] 座位 194" in text
    assert "3. [兜底] 座位 10" in text
