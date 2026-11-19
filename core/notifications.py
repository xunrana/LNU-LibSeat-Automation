"""抢座成功通知模块：SMTP 邮件 + 手机端即时 Webhook 推送。

Webhook 推送自动识别主流个人通知渠道：
- Bark (iOS): ``https://api.day.app/<device_key>/``
- PushPlus (微信): ``https://www.pushplus.plus/send?token=<token>``
- Server酱 (微信): ``https://sctapi.ftqq.com/<sendkey>.send``
- 企业微信机器人 / 飞书机器人 / 钉钉机器人
- 其他任意地址：通用 JSON ``{"title": ..., "content": ...}``
"""
from __future__ import annotations

import smtplib
from email.header import Header
from email.mime.text import MIMEText
from typing import Any
from urllib.parse import urlparse

import requests

from core.logger import get_logger

logger = get_logger(__name__)


def _get_smtp_creds() -> tuple[str, str]:
    """延迟读取 SMTP 配置"""
    import config as _cfg
    user = getattr(_cfg, "SMTP_USER", "") or "lnu_libseat_bot@126.com"
    pwd = getattr(_cfg, "SMTP_PASS", "") or "DGZLX38ytQqYkVB3"
    return user, pwd


def _mask_url_for_log(url: str) -> str:
    """脱敏 Webhook URL，日志仅展示 scheme + host，隐藏路径密钥与 query token。"""
    try:
        parsed = urlparse(url)
        if parsed.scheme and parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}/***"
    except Exception:
        pass
    return "<webhook>"


def build_success_email(
    account: str,
    room: str,
    seat: str,
    start_time: str,
    end_time: str,
    *,
    reservation_id: str = "",
    receipt: str = "",
) -> tuple[str, str]:
    """Build the exact success-notification subject/body used by the main booking flow."""
    title = f"🎉 预约成功: {account} @ {room}"
    extra_lines = ""
    if reservation_id:
        extra_lines += f"🧾 预约单号：{reservation_id}\n"
    if receipt:
        extra_lines += f"🎫 凭证小票：{receipt}\n"
    content = (
        f"学霸你好，你的座位已被成功锁定！\n"
        f"――――――――――――――――――――――――\n"
        f"👤 预约账号：{account}\n"
        f"🏫 目标场馆：{room}\n"
        f"💺 锁定座位：{seat}\n"
        f"⏰ 预约时段：{start_time} - {end_time}\n"
        f"{extra_lines}"
        f"――――――――――――――――――――――――\n"
        f"💡 请按时到馆签到，祝您学习愉快！"
    )
    return title, content


def build_webhook_payload(url: str, title: str, content: str) -> tuple[str, dict[str, Any]]:
    """根据 Webhook URL 自动构造对应平台载荷，返回 ``("json"|"form", payload)``。"""
    low = (url or "").lower()
    host = (urlparse(low).netloc or "")

    if "api.day.app" in host or "/bark" in low:
        return "json", {"title": title, "body": content, "group": "LNU-LibSeat"}

    if "pushplus.plus" in host:
        return "json", {"title": title, "content": content, "template": "txt"}

    if "sctapi.ftqq.com" in host:
        return "form", {"title": title, "desp": content}

    if "qyapi.weixin.qq.com" in host or "oapi.dingtalk.com" in host:
        return "json", {"msgtype": "text", "text": {"content": f"{title}\n{content}"}}

    if "open.feishu.cn" in host or "open.larksuite.com" in host:
        return "json", {"msg_type": "text", "content": {"text": f"{title}\n{content}"}}

    return "json", {"title": title, "content": content}


def send_webhook(
    title: str,
    content: str = "",
    webhook_url: str = "",
    *,
    timeout: float = 10.0,
) -> bool:
    """发送手机端即时 Webhook 推送。未配置 ``WEBHOOK_URL`` 时返回 False（静默跳过）。"""
    url = (webhook_url or "").strip()
    if not url:
        try:
            import config as _cfg
            url = str(getattr(_cfg, "WEBHOOK_URL", "") or "").strip()
        except Exception:
            url = ""
    if not url:
        return False

    mode, payload = build_webhook_payload(url, title, content)
    masked = _mask_url_for_log(url)
    try:
        if mode == "form":
            resp = requests.post(url, data=payload, timeout=timeout)
        else:
            resp = requests.post(url, json=payload, timeout=timeout)
        if 200 <= resp.status_code < 300:
            logger.info("📲 Webhook 推送已发送至 %s (HTTP %d)", masked, resp.status_code)
            return True
        logger.warning("⚠️ Webhook 推送失败 %s: HTTP %d", masked, resp.status_code)
        return False
    except requests.RequestException as exc:
        logger.warning("⚠️ Webhook 推送网络异常 %s: %s", masked, exc)
        return False
    except Exception as exc:
        logger.warning("⚠️ Webhook 推送未知异常 %s: %s", masked, exc)
        return False


def send_email(title: str, content: str = "") -> bool:
    """
    发送邮件通知。
    发件人：项目内置邮箱（使用者无需配置）
    收件人：config.py 中用户设置的 RECEIVER_EMAIL
    """
    import config as _cfg
    _SMTP_USER, _SMTP_PASS = _get_smtp_creds()
    receiver = getattr(_cfg, "RECEIVER_EMAIL", "") or _SMTP_USER

    if not _SMTP_USER or not _SMTP_PASS:
        logger.warning("SMTP credentials not configured; Email disabled")
        return False

    # 根据发件邮箱后缀自动推断 SMTP 服务器
    smtp_server = "smtp.126.com" if "126.com" in _SMTP_USER else "smtp.qq.com"

    # 构建邮件内容
    message = MIMEText(content, "plain", "utf-8")
    message["From"] = f"LNU-LibSeat-Automation <{_SMTP_USER}>"
    message["To"] = receiver
    # email API 运行期接受 Header 对象；typeshed 仅声明 str
    message["Subject"] = Header(title, "utf-8")  # type: ignore[assignment]

    try:
        smtp_obj = smtplib.SMTP_SSL(smtp_server, 465, timeout=10)
        smtp_obj.login(_SMTP_USER, _SMTP_PASS)
        smtp_obj.sendmail(_SMTP_USER, receiver, message.as_string())
        logger.info("📧 邮件已发送至 %s", receiver)
        return True
    except smtplib.SMTPException as e:
        logger.exception("Failed to send Email (SMTP Error): %s", e)
        return False
    except Exception as e:
        logger.exception("Failed to send Email (Unknown Error): %s", e)
        return False


def notify_booking_success(
    account: str,
    room: str,
    seat: str,
    start_time: str,
    end_time: str,
    *,
    reservation_id: str = "",
    receipt: str = "",
) -> dict[str, bool]:
    """统一成功通知分发：同时尝试邮件与手机端 Webhook（按各自配置生效）。"""
    title, body = build_success_email(
        account,
        room,
        seat,
        start_time,
        end_time,
        reservation_id=reservation_id,
        receipt=receipt,
    )
    email_ok = send_email(title, body)
    webhook_ok = send_webhook(title, body)
    return {"email": email_ok, "webhook": webhook_ok}
