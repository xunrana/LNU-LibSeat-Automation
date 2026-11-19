"""LibSeat 纯 API 加解密与请求签名工具（纯函数，无网络副作用）。

与前端模块 ``AOJh``（AES-128-CBC + PKCS7）及 ``6r5/``（HMAC-SHA256 请求头签名）
完全一致；同时兼容 ``pycryptodome``（优先）与 ``cryptography`` 两个常见加密库。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
import uuid
from typing import Sequence

from core.protocol import (
    AES_IV,
    AES_KEY,
    DEFAULT_NUMCODE_ENCRYPTED,
    LOGIN_CRED_SUFFIX,
)


def _aes_cbc_encrypt_raw(plaintext: bytes, key: bytes, iv: bytes) -> bytes:
    try:
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import pad

        cipher = AES.new(key, AES.MODE_CBC, iv)
        return bytes(cipher.encrypt(pad(plaintext, 16)))
    except ImportError:
        from cryptography.hazmat.primitives import padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        padder = padding.PKCS7(128).padder()
        padded = padder.update(plaintext) + padder.finalize()
        enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        return enc.update(padded) + enc.finalize()


def _aes_cbc_decrypt_raw(ciphertext: bytes, key: bytes, iv: bytes) -> bytes:
    try:
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import unpad

        cipher = AES.new(key, AES.MODE_CBC, iv)
        return bytes(unpad(cipher.decrypt(ciphertext), 16))
    except ImportError:
        from cryptography.hazmat.primitives import padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        padded = dec.update(ciphertext) + dec.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        return unpadder.update(padded) + unpadder.finalize()


def encrypt_aes_b64(text: str, *, key: str = AES_KEY, iv: str = AES_IV) -> str:
    """使用 AES-128-CBC + PKCS7 加密 UTF-8 文本，返回标准 Base64 字符串。"""
    raw = _aes_cbc_encrypt_raw(
        text.encode("utf-8"),
        key.encode("utf-8"),
        iv.encode("utf-8"),
    )
    return base64.b64encode(raw).decode("ascii")


def decrypt_aes_b64(b64_text: str, *, key: str = AES_KEY, iv: str = AES_IV) -> str:
    """解密标准 Base64 编码的 AES-128-CBC + PKCS7 密文，返回 UTF-8 明文。"""
    raw = _aes_cbc_decrypt_raw(
        base64.b64decode(b64_text),
        key.encode("utf-8"),
        iv.encode("utf-8"),
    )
    return raw.decode("utf-8")


def encrypt_login_credential(value: str, *, key: str = AES_KEY, iv: str = AES_IV) -> str:
    """加密登录凭据（学号或密码），附加前端约定的 ``_encrypt`` 后缀。"""
    if value.endswith(LOGIN_CRED_SUFFIX):
        return value
    return encrypt_aes_b64(value, key=key, iv=iv) + LOGIN_CRED_SUFFIX


def decrypt_hmac_secret(numcode_encrypted: str = DEFAULT_NUMCODE_ENCRYPTED) -> str:
    """解密 ``Global.NUMCODE`` 得到 HMAC-SHA256 签名密钥明文。"""
    return decrypt_aes_b64(numcode_encrypted)


def sign_request_headers(
    method: str,
    *,
    hmac_secret: str,
    request_id: str | None = None,
    timestamp_ms: int | None = None,
) -> dict[str, str]:
    """生成 ``X-request-id`` / ``X-request-date`` / ``X-hmac-request-key`` 签名头。

    原文格式与前端 ``g(e)`` 完全一致：
    ``"seat::" + uuid4 + "::" + timestamp_ms + "::" + method.upper()``
    """
    req_id = request_id or str(uuid.uuid4())
    ts_ms = int(timestamp_ms if timestamp_ms is not None else time.time() * 1000)
    payload = f"seat::{req_id}::{ts_ms}::{method.upper()}"
    signature = hmac.new(
        hmac_secret.encode("utf-8"),
        payload.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return {
        "X-request-id": req_id,
        "X-request-date": str(ts_ms),
        "X-hmac-request-key": signature,
    }


def encode_captcha_points(points: Sequence[tuple[int, int]]) -> str:
    """把点选坐标序列编码为 ``/cap/checkCaptcha`` 的 ``a`` 参数（紧凑 JSON + Base64）。"""
    payload = [{"x": int(x), "y": int(y)} for x, y in points]
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")
