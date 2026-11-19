"""core.notifications 邮件模板与手机端 Webhook 推送单元测试。"""
from unittest import mock

import pytest

from core import notifications


def test_build_success_email_backward_compatible_and_supports_receipt():
    t1, c1 = notifications.build_success_email("20240001", "四楼南自习室", "194", "09:00", "15:00")
    assert "20240001" in t1 and "四楼南自习室" in t1
    assert "194" in c1 and "09:00 - 15:00" in c1
    assert "预约单号" not in c1

    t2, c2 = notifications.build_success_email(
        "20240001",
        "四楼南自习室",
        "194",
        "09:00",
        "15:00",
        reservation_id="4338311",
        receipt="0218-311-3",
    )
    assert t2 == t1
    assert "4338311" in c2 and "0218-311-3" in c2


@pytest.mark.parametrize(
    ("url", "expected_mode", "expected_key"),
    [
        ("https://api.day.app/MyDeviceKey/", "json", "body"),
        ("https://www.pushplus.plus/send?token=abc", "json", "template"),
        ("https://sctapi.ftqq.com/SCT12345.send", "form", "desp"),
        ("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k1", "json", "msgtype"),
        ("https://open.feishu.cn/open-apis/bot/v2/hook/h1", "json", "msg_type"),
        ("https://oapi.dingtalk.com/robot/send?access_token=t1", "json", "msgtype"),
        ("https://example.com/custom-hook", "json", "content"),
    ],
)
def test_build_webhook_payload_detects_channels(url, expected_mode, expected_key):
    mode, payload = notifications.build_webhook_payload(url, "Title", "Body")
    assert mode == expected_mode
    assert expected_key in payload


def test_send_webhook_skips_when_unconfigured(monkeypatch):
    import config

    monkeypatch.setattr(config, "WEBHOOK_URL", "", raising=False)
    with mock.patch("core.notifications.requests.post") as mock_post:
        assert notifications.send_webhook("T", "C") is False
        mock_post.assert_not_called()


def test_send_webhook_posts_json_and_handles_http_status():
    fake_ok = mock.Mock(status_code=200)
    with mock.patch("core.notifications.requests.post", return_value=fake_ok) as mock_post:
        assert notifications.send_webhook("成功", "座位194", "https://api.day.app/secretkey/") is True
        _, kwargs = mock_post.call_args
        assert kwargs["json"]["title"] == "成功"
        assert kwargs["json"]["body"] == "座位194"

    fake_err = mock.Mock(status_code=500)
    with mock.patch("core.notifications.requests.post", return_value=fake_err):
        assert notifications.send_webhook("成功", "座位194", "https://api.day.app/secretkey/") is False


def test_notify_booking_success_dispatches_both_channels():
    with (
        mock.patch("core.notifications.send_email", return_value=True) as mock_email,
        mock.patch("core.notifications.send_webhook", return_value=True) as mock_wh,
    ):
        res = notifications.notify_booking_success(
            "20240001", "四楼南自习室", "194", "09:00", "15:00", reservation_id="99",
        )
        assert res == {"email": True, "webhook": True}
        mock_email.assert_called_once()
        mock_wh.assert_called_once()
