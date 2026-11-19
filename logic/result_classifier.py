"""预约结果文本分类（纯函数，无浏览器依赖）。

同时服务 v5 既有链路（``classify_booking_result`` 保持向后兼容）与 v6 纯 API
引擎（``classify_api_booking_result`` 细分 ``seat_taken``、06:30 瞬态宽限
``not_open_yet`` 与限流信号 ``rate_limited``）。
"""
from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Literal

# 黑名单提示固定文案（需整段长文本匹配，故用正则）
BLACKLIST_FEEDBACK_RE = re.compile(
    r"对不起[，,]?您已被加入黑名单[，,]?"
    r"预约权限将在\d{4}年\d{1,2}月\d{1,2}日恢复[。.!！]?"
    r"原因[:：]7天内迟到违约[，,]超过3次[，,]加入黑名单7天"
)

ApiOutcomeStatus = Literal[
    "success",
    "stop",
    "blacklist",
    "retry_captcha",
    "seat_taken",
    "failed",
]

_SEAT_TAKEN_KEYWORDS = (
    "已被他人预约",
    "座位已被预约",
    "该座位不可用",
    "没有可用时间",
    "没有可约时间",
    "已被占用",
)

_RATE_LIMIT_KEYWORDS = (
    "操作过于频繁",
    "请求过于频繁",
    "系统繁忙",
)


@dataclass(frozen=True)
class ApiBookingClassification:
    """v6 纯 API 引擎使用的结构化业务结果分类。"""

    status: ApiOutcomeStatus
    not_open_yet: bool = False
    rate_limited: bool = False


def is_blacklist_feedback(result_text: str | None) -> bool:
    text = re.sub(r"\s+", "", result_text or "")
    if not text:
        return False
    return bool(BLACKLIST_FEEDBACK_RE.search(text))


def is_stop_booking_feedback(result_text: str | None) -> bool:
    text = re.sub(r"\s+", "", result_text or "")
    if not text:
        return False
    text = text.replace("～", "~").replace("〜", "~").replace("-", "~")
    return (
        "系统可预约时间" in text
        and "06:30" in text
        and "22:30" in text
    )


def is_seat_taken_feedback(result_text: str | None) -> bool:
    text = result_text or ""
    return any(kw in text for kw in _SEAT_TAKEN_KEYWORDS)


def is_rate_limited_feedback(result_text: str | None) -> bool:
    text = result_text or ""
    return any(kw in text for kw in _RATE_LIMIT_KEYWORDS)


def classify_booking_result(result_text: str) -> str:
    """v5 兼容分类器：返回 success / stop / blacklist / retry_captcha / failed。"""
    if is_stop_booking_feedback(result_text):
        return "stop"

    if "预约成功" in result_text:
        return "success"
    if "有效预约" in result_text:
        return "stop"
    if "每日限制" in result_text:
        return "stop"
    if "部分读者" in result_text:
        return "stop"

    if is_blacklist_feedback(result_text):
        return "blacklist"

    if (
        "验证码错误" in result_text
        or "系统繁忙" in result_text
        or "请稍后" in result_text
        or "请重试" in result_text
        or "操作过于频繁" in result_text
    ):
        return "retry_captcha"

    if "已被他人预约" in result_text:
        return "failed"
    if "已有预约" in result_text or "预约失败" in result_text:
        return "failed"

    return "failed"


def classify_api_booking_result(
    result_text: str | None,
    *,
    in_open_grace_window: bool = False,
) -> ApiBookingClassification:
    """v6 纯 API 结果分类器。

    相比 ``classify_booking_result`` 增加三项关键能力：
    1. 定时放座瞬态（``in_open_grace_window=True``）收到「系统可预约时间 06:30~22:30」
       时返回 ``not_open_yet=True``，供调度层短退避重探而不误判为终态 ``stop``；
    2. 将「已被他人预约 / 没有可用时间」细分为 ``seat_taken``，触发刷新实时空座快照；
    3. 识别「操作过于频繁 / 系统繁忙」打标 ``rate_limited=True``，驱动退避与熔断器。
    """
    text = result_text or ""

    if is_stop_booking_feedback(text):
        if in_open_grace_window:
            return ApiBookingClassification(status="retry_captcha", not_open_yet=True)
        return ApiBookingClassification(status="stop")

    if "预约成功" in text:
        return ApiBookingClassification(status="success")
    if "有效预约" in text or "每日限制" in text or "部分读者" in text:
        return ApiBookingClassification(status="stop")

    if is_blacklist_feedback(text):
        return ApiBookingClassification(status="blacklist")

    if is_rate_limited_feedback(text):
        return ApiBookingClassification(status="retry_captcha", rate_limited=True)

    if "验证码错误" in text or "请稍后" in text or "请重试" in text:
        return ApiBookingClassification(status="retry_captcha")

    if is_seat_taken_feedback(text):
        return ApiBookingClassification(status="seat_taken")

    return ApiBookingClassification(status="failed")
