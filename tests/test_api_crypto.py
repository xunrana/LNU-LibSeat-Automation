"""core.api_crypto 与 core.protocol 单元测试。"""
import base64
import hashlib
import hmac
import json

from core.api_crypto import (
    decrypt_aes_b64,
    decrypt_hmac_secret,
    encode_captcha_points,
    encrypt_aes_b64,
    encrypt_login_credential,
    sign_request_headers,
)
from core.protocol import DEFAULT_NUMCODE_ENCRYPTED, parse_global_js


def test_aes_roundtrip_and_login_credential_suffix():
    plain = "20240123456"
    enc = encrypt_aes_b64(plain)
    assert len(enc) == 24
    assert decrypt_aes_b64(enc) == plain

    cred = encrypt_login_credential(plain)
    assert cred == enc + "_encrypt"
    assert len(cred) == 32
    # 幂等：已有 _encrypt 后缀不重复加密
    assert encrypt_login_credential(cred) == cred


def test_hmac_request_signing_matches_frontend_algorithm():
    secret = decrypt_hmac_secret(DEFAULT_NUMCODE_ENCRYPTED)
    assert len(secret) > 0

    req_id = "11111111-2222-4333-8444-555555555555"
    ts_ms = 1795078561033
    hdrs = sign_request_headers("post", hmac_secret=secret, request_id=req_id, timestamp_ms=ts_ms)

    expected_msg = f"seat::{req_id}::{ts_ms}::POST"
    expected_sig = hmac.new(secret.encode("utf-8"), expected_msg.encode("utf-8"), hashlib.sha256).hexdigest()

    assert hdrs["X-request-id"] == req_id
    assert hdrs["X-request-date"] == str(ts_ms)
    assert hdrs["X-hmac-request-key"] == expected_sig
    assert len(hdrs["X-hmac-request-key"]) == 64


def test_encode_captcha_points_matches_click1_and_click3_wire_format():
    # 单点格式与真实抓包一致：[{"x":232,"y":65}] -> W3sieCI6MjMyLCJ5Ijo2NX1d
    encoded_1 = encode_captcha_points([(232, 65)])
    assert encoded_1 == "W3sieCI6MjMyLCJ5Ijo2NX1d"
    assert json.loads(base64.b64decode(encoded_1)) == [{"x": 232, "y": 65}]

    # 3 点连击格式保持顺序且无空格
    encoded_3 = encode_captcha_points([(10, 20), (150, 80), (290, 120)])
    assert json.loads(base64.b64decode(encoded_3)) == [
        {"x": 10, "y": 20},
        {"x": 150, "y": 80},
        {"x": 290, "y": 120},
    ]


def test_parse_global_js_extracts_fields_and_handles_invalid():
    js = '''
    var Global = {
      BASEURL: "http://libseat.lnu.edu.cn/",
      CODE: true,
      NUMCODE: "cDf+jadFUWncEn536MXItw=="
    };
    '''
    cfg = parse_global_js(js)
    assert cfg is not None
    assert cfg.base_url == "http://libseat.lnu.edu.cn"
    assert cfg.code_enabled is True
    assert cfg.numcode_encrypted == DEFAULT_NUMCODE_ENCRYPTED

    assert parse_global_js("<html>not global</html>") is None
