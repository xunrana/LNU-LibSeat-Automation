"""导出 Python 参考实现的跨语言黄金测试向量（供 Flutter / Dart 移动端单元测试 100% 对齐校验）。

导出路径：
    mobile/test/fixtures/protocol_test_vectors.json

用法：
    python scripts/dump_test_vectors.py
"""
from __future__ import annotations

import base64
import hashlib
import json
import sys
from io import BytesIO
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.api_crypto import (  # noqa: E402
    decrypt_aes_b64,
    decrypt_hmac_secret,
    encode_captcha_points,
    encrypt_aes_b64,
    encrypt_login_credential,
    sign_request_headers,
)
from core.protocol import (  # noqa: E402
    AES_IV,
    AES_KEY,
    DEFAULT_BASE_URL,
    DEFAULT_NUMCODE_ENCRYPTED,
    LOGIN_CRED_SUFFIX,
    parse_global_js,
)
from logic.result_classifier import classify_api_booking_result  # noqa: E402
from logic.seat_strategy import (  # noqa: E402
    build_room_plan,
    normalize_seat_no,
    parse_hhmm_minutes,
    time_ranges_overlap,
)

FIXTURE_OUT_PATH = ROOT / "mobile" / "test" / "fixtures" / "protocol_test_vectors.json"


def build_protocol_test_vectors() -> dict[str, Any]:
    hmac_secret = decrypt_hmac_secret(DEFAULT_NUMCODE_ENCRYPTED)

    credential_cases = [
        "20230001",
        "000000",
        "Lnu@Seat#2026!",
        "22104050123",
        "辽宁大学图书馆",
    ]
    aes_vectors = []
    for plain in credential_cases:
        b64 = encrypt_aes_b64(plain)
        cred = encrypt_login_credential(plain)
        assert decrypt_aes_b64(b64) == plain
        aes_vectors.append(
            {
                "plaintext": plain,
                "aes_b64": b64,
                "login_credential": cred,
            }
        )

    hmac_cases = [
        {
            "method": "GET",
            "request_id": "550e8400-e29b-41d4-a716-446655440000",
            "timestamp_ms": 1718404200123,
        },
        {
            "method": "post",
            "request_id": "123e4567-e89b-12d3-a456-426614174000",
            "timestamp_ms": 1718404205999,
        },
    ]
    hmac_vectors = []
    for case in hmac_cases:
        headers = sign_request_headers(
            case["method"],
            hmac_secret=hmac_secret,
            request_id=case["request_id"],
            timestamp_ms=case["timestamp_ms"],
        )
        hmac_vectors.append(
            {
                **case,
                "hmac_secret": hmac_secret,
                "expected_headers": headers,
            }
        )

    points_cases = [
        [(165, 82)],
        [(58, 112), (241, 49), (133, 95)],
        [(0, 0), (330, 160), (12, 34)],
    ]
    captcha_points_vectors = [
        {
            "points": [[x, y] for x, y in pts],
            "encoded_a": encode_captcha_points(pts),
        }
        for pts in points_cases
    ]

    js_sample = (
        'window.Global = { BASEURL: "http://libseat.lnu.edu.cn/", '
        'CODE: true, NUMCODE: "cDf+jadFUWncEn536MXItw==" };'
    )
    parsed_js = parse_global_js(js_sample)
    assert parsed_js is not None

    classifier_cases = [
        {"text": "预约成功", "grace": False},
        {"text": "该座位已被他人预约", "grace": False},
        {"text": "没有可用时间", "grace": False},
        {"text": "系统可预约时间为 06:30 ~ 22:30", "grace": False},
        {"text": "系统可预约时间为 06:30 ~ 22:30", "grace": True},
        {"text": "验证码错误，请重试", "grace": False},
        {"text": "操作过于频繁，请稍后再试", "grace": False},
        {"text": "您已有有效预约，请勿重复预约", "grace": False},
        {
            "text": "对不起，您已被加入黑名单，预约权限将在2026年11月27日恢复。原因：7天内迟到违约，超过3次，加入黑名单7天",
            "grace": False,
        },
    ]
    classifier_vectors = []
    for item in classifier_cases:
        res = classify_api_booking_result(
            item["text"],
            in_open_grace_window=item["grace"],
        )
        classifier_vectors.append(
            {
                "text": item["text"],
                "in_open_grace_window": item["grace"],
                "status": res.status,
                "not_open_yet": res.not_open_yet,
                "rate_limited": res.rate_limited,
            }
        )

    seat_norm_vectors = [
        {"raw": raw, "normalized": normalize_seat_no(raw)}
        for raw in ("001", "010", "194", "A-06-1", " 042 ")
    ]

    time_overlap_vectors = [
        {"a": ["08:00", "12:00"], "b": ["12:00", "16:00"], "overlap": time_ranges_overlap("08:00", "12:00", "12:00", "16:00")},
        {"a": ["08:00", "13:00"], "b": ["12:00", "16:00"], "overlap": time_ranges_overlap("08:00", "13:00", "12:00", "16:00")},
        {"a": ["09:00", "15:00"], "b": ["15:00", "21:00"], "overlap": time_ranges_overlap("09:00", "15:00", "15:00", "21:00")},
    ]

    room_plan_sample = build_room_plan(
        "崇山校区图书馆",
        "三楼智慧研修空间",
        [
            ("崇山校区图书馆", "三楼智慧研修空间"),
            ("崇山校区图书馆", "四楼南自习室"),
            ("蒲河校区图书馆", "智慧空间"),
        ],
    )

    # Pillow 图像算子逐字节对齐黄金测试向量（SHA256 校验每个输出像素 0 误差）
    rng = np.random.default_rng(20261120)
    src_small = rng.integers(0, 256, size=(22, 20, 3), dtype=np.uint8)
    src_wide = rng.integers(0, 256, size=(35, 80, 3), dtype=np.uint8)

    pil_small = Image.fromarray(src_small, "RGB")
    pil_wide = Image.fromarray(src_wide, "RGB")

    bicubic_out = np.asarray(pil_small.resize((101, 112), Image.Resampling.BICUBIC), dtype=np.uint8)
    bilinear_out = np.asarray(pil_wide.resize((128, 56), Image.Resampling.BILINEAR), dtype=np.uint8)
    lanczos_out = np.asarray(pil_wide.resize((73, 32), Image.Resampling.LANCZOS), dtype=np.uint8)
    luma_out = np.asarray(pil_wide.convert("L"), dtype=np.uint8)

    # Login OCR 完整预处理向量 (80x35 -> int(80 * 64 / 35) = 146x64 LANCZOS -> L)
    login_tw = max(1, int(80 * (64 / 35)))
    login_gray = np.asarray(
        pil_wide.resize((login_tw, 64), Image.Resampling.LANCZOS).convert("L"),
        dtype=np.uint8,
    )

    # detect_captcha_kind 槽位墨迹检测黄金样本（click1 中槽有字 vs click3 三槽均有字）
    def _make_target_png_b64(slots: tuple[int, ...]) -> str:
        im = Image.new("RGB", (70, 36), (255, 255, 255))
        draw = ImageDraw.Draw(im)
        boxes = ((8, 8, 22, 24), (28, 8, 42, 24), (48, 8, 62, 24))
        for slot in slots:
            draw.rectangle(boxes[slot], fill=(15, 15, 15))
        buf = BytesIO()
        im.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")

    pil_ops_vectors = {
        "small_rgb_b64": base64.b64encode(src_small.tobytes()).decode("ascii"),
        "small_w": 20,
        "small_h": 22,
        "bicubic_101x112_sha256": hashlib.sha256(bicubic_out.tobytes()).hexdigest(),
        "wide_rgb_b64": base64.b64encode(src_wide.tobytes()).decode("ascii"),
        "wide_w": 80,
        "wide_h": 35,
        "bilinear_128x56_sha256": hashlib.sha256(bilinear_out.tobytes()).hexdigest(),
        "lanczos_73x32_sha256": hashlib.sha256(lanczos_out.tobytes()).hexdigest(),
        "luma_sha256": hashlib.sha256(luma_out.tobytes()).hexdigest(),
        "login_target_width": login_tw,
        "login_gray_sha256": hashlib.sha256(login_gray.tobytes()).hexdigest(),
        "target_click1_png_b64": _make_target_png_b64((1,)),
        "target_click3_png_b64": _make_target_png_b64((0, 1, 2)),
        "py_round_cases": [
            {"x": x, "expected": int(round(x))}
            for x in (0.5, 1.5, 2.5, 3.5, 4.5, -0.5, -1.5, -2.5, 12.49, 12.51)
        ],
    }

    return {
        "constants": {
            "default_base_url": DEFAULT_BASE_URL,
            "aes_key": AES_KEY,
            "aes_iv": AES_IV,
            "login_cred_suffix": LOGIN_CRED_SUFFIX,
            "default_numcode_encrypted": DEFAULT_NUMCODE_ENCRYPTED,
            "decrypted_hmac_secret": hmac_secret,
        },
        "aes_vectors": aes_vectors,
        "hmac_vectors": hmac_vectors,
        "captcha_points_vectors": captcha_points_vectors,
        "global_js_vector": {
            "js_text": js_sample,
            "base_url": parsed_js.base_url,
            "code_enabled": parsed_js.code_enabled,
            "numcode_encrypted": parsed_js.numcode_encrypted,
        },
        "classifier_vectors": classifier_vectors,
        "seat_norm_vectors": seat_norm_vectors,
        "time_minutes_vectors": [
            {"hhmm": t, "minutes": parse_hhmm_minutes(t)}
            for t in ("06:30", "08:00", "09:00", "17:00", "22:30")
        ],
        "time_overlap_vectors": time_overlap_vectors,
        "room_plan_vector": [[c, r] for c, r in room_plan_sample],
        "pil_ops_vectors": pil_ops_vectors,
    }


def main() -> None:
    FIXTURE_OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    vectors = build_protocol_test_vectors()
    FIXTURE_OUT_PATH.write_text(
        json.dumps(vectors, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"[OK] 已生成跨语言黄金测试向量: {FIXTURE_OUT_PATH}")


if __name__ == "__main__":
    main()
