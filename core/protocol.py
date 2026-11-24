"""LibSeat 纯 API 协议单一来源（端点、常量、Global 动态引导与异常定义）。

彻底移除 Selenium 后，所有服务端 URL 路径、AES 密钥常量、字段约束全部集中在本模块；
若站点协议微调，只需修改本文件与 ``core/libseat_client.py`` 即可快速热修。
"""
from __future__ import annotations

import re
from dataclasses import dataclass

APP_VERSION = "v6.0.1"
DEFAULT_BASE_URL = "http://libseat.lnu.edu.cn"
DEFAULT_REFERER = "http://libseat.lnu.edu.cn/libseat/"
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"
)

# 与前端模块 AOJh / baseUrl.js 保持一致
LOGIN_TYPE = "PC"
AES_KEY = "server_date_time"
AES_IV = "client_date_time"
LOGIN_CRED_SUFFIX = "_encrypt"
DEFAULT_CODE_ENABLED = True
DEFAULT_NUMCODE_ENCRYPTED = "cDf+jadFUWncEn536MXItw=="

# 响应业务码
TOKEN_EXPIRED_CODE = "12"

# 动态拉取 Global 配置的候选路径（与前端 /libseat/ 静态目录一致）
GLOBAL_JS_PATHS: tuple[str, ...] = (
    "/libseat/static/baseUrl.js",
    "/libseat/baseUrl.js",
)

# 全量 API 路径常量（对应前端模块 Apws）
EP_ANNOUNCE = "/rest/v2/announce"
EP_AVAIL_SEATS = "/rest/v2/availSeats"
EP_SETTINGS = "/rest/v2/settings"
EP_CREATE_LOGIN_CAPTCHA = "/auth/createCaptcha"
EP_AUTH = "/rest/auth"
EP_USER = "/rest/v2/user"
EP_USER_RESERVATIONS = "/rest/v2/user/reservations"
EP_FREE_FILTERS = "/rest/v2/free/filters"
EP_ROOM_FLOORS = "/rest/v2/room/floors/{building_id}"
EP_ROOM_STATS = "/rest/v2/room/stats2/{building_id}/{date}"
EP_ROOM_LAYOUT = "/rest/v2/room/layoutByDate/{room_id}/{date}"
EP_START_TIMES = "/rest/v2/startTimesForSeat/{seat_id}/{date}"
EP_END_TIMES = "/rest/v2/endTimesForSeat/{seat_id}/{date}/{start}"
EP_CLICK_CAPTCHA = "/cap/captcha/{token}"
EP_CHECK_CAPTCHA = "/cap/checkCaptcha"
EP_FREE_BOOK = "/rest/v2/freeBook"
EP_HISTORY = "/rest/v2/history/{page}/{page_size}"
EP_CANCEL = "/rest/v2/cancel/{reservation_id}"

# 座位状态分类集合（对应前端 dh3M.switchSeatImg）
FREE_SEAT_STATUSES = frozenset({"FREE", "YESSELECT"})
OCCUPIED_SEAT_STATUSES = frozenset({"IN_USE", "BOOKED", "FULL", "AWAY"})
UNAVAILABLE_SEAT_STATUSES = frozenset({"NOSELECT"})

# 维护提示关键词
MAINTENANCE_KEYWORDS = ("系统维护中", "系统维护", "维护中")

# 高峰期瞬态繁忙/限流关键词（应退避重试，绝不能误判为协议漂移停机）
TRANSIENT_BUSY_KEYWORDS = (
    "系统繁忙",
    "服务器繁忙",
    "繁忙",
    "操作过于频繁",
    "请求过于频繁",
    "请稍后",
    "请稍候",
    "请重试",
    "too busy",
    "try again",
)

_RE_BASEURL = re.compile(r'BASEURL\s*:\s*["\']([^"\']+)["\']')
_RE_CODE = re.compile(r"CODE\s*:\s*(true|false)", re.I)
_RE_NUMCODE = re.compile(r'NUMCODE\s*:\s*["\']([^"\']+)["\']')
_RE_RETRY_AFTER = re.compile(r"(?:请稍[后候]|繁忙)[^0-9]{0,8}(\d{1,2})\b")


def is_transient_busy_text(text: str | None) -> bool:
    """判断服务端反馈是否属于高峰瞬态繁忙/频控（排除维护提示）。"""
    cleaned = (text or "").strip()
    if not cleaned:
        return False
    if any(kw in cleaned for kw in MAINTENANCE_KEYWORDS):
        return False
    lowered = cleaned.lower()
    return any(kw in lowered for kw in TRANSIENT_BUSY_KEYWORDS)


def parse_retry_after_seconds(text: str | None) -> float | None:
    """从「系统繁忙, 请稍后: 06」等反馈中提取服务端滑动窗口冷却秒数（如 6.0）。"""
    cleaned = (text or "").strip()
    if not cleaned:
        return None
    if any(kw in cleaned for kw in MAINTENANCE_KEYWORDS):
        return None
    m = _RE_RETRY_AFTER.search(cleaned)
    if not m:
        return None
    val = int(m.group(1))
    return float(val) if 1 <= val <= 60 else None


class ProtocolDriftError(RuntimeError):
    """服务端响应结构/鉴权协议与已知契约不匹配时抛出，触发立即熔断停止。"""


class TransientServerBusyError(RuntimeError):
    """服务端瞬态繁忙/网关 5xx/验证码池拥堵等可恢复异常，应退避重试而非熔断停机。"""

    def __init__(
        self,
        message: str,
        *,
        is_rate_limit: bool = True,
        retry_after_seconds: float | None = None,
    ) -> None:
        super().__init__(message)
        self.is_rate_limit = is_rate_limit
        self.retry_after_seconds = (
            retry_after_seconds if retry_after_seconds is not None else parse_retry_after_seconds(message)
        )


class TokenExpiredError(RuntimeError):
    """服务端返回 code=='12'（token 已过期）时抛出，供上层按需重登。"""


@dataclass(frozen=True)
class GlobalConfig:
    """前端 baseUrl.js 暴露的全局签名配置。"""

    base_url: str = DEFAULT_BASE_URL
    code_enabled: bool = DEFAULT_CODE_ENABLED
    numcode_encrypted: str = DEFAULT_NUMCODE_ENCRYPTED


def parse_global_js(js_text: str, *, fallback_base_url: str = DEFAULT_BASE_URL) -> GlobalConfig | None:
    """从前端 ``baseUrl.js`` 文本解析 ``Global.BASEURL / CODE / NUMCODE``。"""
    if not js_text or "Global" not in js_text:
        return None

    m_num = _RE_NUMCODE.search(js_text)
    m_code = _RE_CODE.search(js_text)
    if not m_num and not m_code:
        return None

    m_base = _RE_BASEURL.search(js_text)
    base_url = m_base.group(1).rstrip("/") if m_base else fallback_base_url.rstrip("/")
    code_enabled = (m_code.group(1).lower() == "true") if m_code else DEFAULT_CODE_ENABLED
    numcode = m_num.group(1) if m_num else DEFAULT_NUMCODE_ENCRYPTED
    return GlobalConfig(
        base_url=base_url,
        code_enabled=code_enabled,
        numcode_encrypted=numcode,
    )
