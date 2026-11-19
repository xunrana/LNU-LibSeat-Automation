"""logic.result_classifier 纯函数的分支覆盖（v5 兼容 + v6 API 结构化分类）。"""
import pytest

from logic.result_classifier import (
    classify_api_booking_result,
    classify_booking_result,
    is_blacklist_feedback,
    is_rate_limited_feedback,
    is_seat_taken_feedback,
    is_stop_booking_feedback,
)


def test_success_branch():
    assert classify_booking_result("预约成功！座位已锁定") == "success"


@pytest.mark.parametrize("text", [
    "系统可预约时间 06:30～22:30，请在此时段操作",   # 全角波浪号
    "系统可预约时间 06:30〜22:30",                    # 另一种波浪号
    "系统可预约时间 06:30-22:30",                     # 连字符
])
def test_stop_branch_via_booking_window(text):
    # is_stop_booking_feedback 命中：非可预约时段提示 → stop
    assert is_stop_booking_feedback(text) is True
    assert classify_booking_result(text) == "stop"


@pytest.mark.parametrize("text", [
    "您今日已有有效预约",
    "已达每日限制",
    "部分读者暂不可预约",
])
def test_stop_branch_via_keywords(text):
    assert classify_booking_result(text) == "stop"


@pytest.mark.parametrize("text", [
    "验证码错误，请重新输入",
    "系统繁忙，请稍后",
    "请稍后再试",
    "请重试",
    "操作过于频繁",
])
def test_retry_captcha_branch(text):
    assert classify_booking_result(text) == "retry_captcha"


@pytest.mark.parametrize("text", [
    "该座位已被他人预约",
    "您已有预约",
    "预约失败，请重新选择",
    "未知的奇怪提示",   # 兜底分支
    "",                  # 空串：无关键字 → failed
])
def test_failed_branch_and_fallback(text):
    assert classify_booking_result(text) == "failed"


def test_is_stop_booking_feedback_requires_all_markers():
    # 只有时段词、缺 06:30/22:30 → 不算停止
    assert is_stop_booking_feedback("系统可预约时间另行通知") is False


@pytest.mark.parametrize("value", ["", None])
def test_helpers_handle_empty_input(value):
    assert is_stop_booking_feedback(value) is False
    assert is_blacklist_feedback(value) is False
    assert is_seat_taken_feedback(value) is False
    assert is_rate_limited_feedback(value) is False


# ───────────────── v6 API 结构化分类覆盖 ─────────────────

def test_api_classifier_open_grace_window_marks_not_open_yet():
    msg = "系统可预约时间为 06:30 ~ 22:30"
    # 06:30:00~06:30:05 瞬态宽限期内：不判 stop，走短退避重探
    c_grace = classify_api_booking_result(msg, in_open_grace_window=True)
    assert c_grace.status == "retry_captcha"
    assert c_grace.not_open_yet is True

    # 窗口外：仍判终态 stop
    c_normal = classify_api_booking_result(msg, in_open_grace_window=False)
    assert c_normal.status == "stop"
    assert c_normal.not_open_yet is False


@pytest.mark.parametrize("text", [
    "该座位已被他人预约",
    "当前座位没有可用时间",
    "该座位不可用，请选择其他座位",
])
def test_api_classifier_separates_seat_taken(text):
    res = classify_api_booking_result(text)
    assert res.status == "seat_taken"
    assert res.rate_limited is False


@pytest.mark.parametrize("text", ["操作过于频繁", "系统繁忙，请稍后:01"])
def test_api_classifier_flags_rate_limited(text):
    res = classify_api_booking_result(text)
    assert res.status == "retry_captcha"
    assert res.rate_limited is True


def test_api_classifier_blacklist_and_success():
    bl = (
        "对不起，您已被加入黑名单，预约权限将在2026年05月11日恢复。"
        "原因：7天内迟到违约，超过3次，加入黑名单7天"
    )
    assert classify_api_booking_result(bl).status == "blacklist"
    assert classify_api_booking_result("预约成功！").status == "success"
