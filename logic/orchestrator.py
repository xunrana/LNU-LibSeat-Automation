"""纯 API 多账号抢座调度与生命周期编排层（零浏览器 / 零 GUI 依赖）。

同时服务 CLI（``main.py``）、PySide6 桌面（``ui_qt/workers/booker_worker.py``）
以及未来 v6.1 移动端 Web 控制面板（PWA）。
"""
from __future__ import annotations

import os
import threading
from datetime import datetime, timedelta
from typing import Any, Callable

import core.utils as utils
from core.captcha_service import CaptchaService, get_captcha_service, preload_captcha_models
from core.clock_sync import ClockSync
from core.libseat_client import HttpLibSeatClient, LibSeatClient
from core.logger import get_logger, register_account_log_file
from core.notifications import notify_booking_success
from core.protocol import APP_VERSION, DEFAULT_BASE_URL, TokenExpiredError
from core.rate_limiter import RateLimiter
from core.session_recorder import SessionRecorder
from logic.booker import ApiSeatBooker
from logic.seat_strategy import SeatClaimCoordinator, build_room_plan

logger = get_logger(__name__)

# 纯 API 定时调度提前量（无浏览器冷启动，15s 预热 + 5s 保活足够宽裕）
PREP_LEAD_SECONDS = 15
KEEPALIVE_LEAD_SECONDS = 5
MAINTENANCE_RETRY_INTERVAL_SECONDS = 120
DEFAULT_FIRE_OFFSET_MS = 200
ACCOUNT_STAGGER_SECONDS = 2

_CAPTCHA_PRELOAD_THREAD: threading.Thread | None = None


def _cfg(attr: str, default: Any = None) -> Any:
    import config

    return getattr(config, attr, default)


def start_captcha_model_preload(reason: str = "startup") -> None:
    """后台异步预加载本地 Click1 + Click3 ONNX 模型，避免 06:30 首次冷启动。"""
    global _CAPTCHA_PRELOAD_THREAD
    if _CAPTCHA_PRELOAD_THREAD is not None and _CAPTCHA_PRELOAD_THREAD.is_alive():
        return

    def _worker() -> None:
        try:
            logger.info("🧠 本地 YOLOv8+Siamese 验证码模型开始预加载 (%s)...", reason)
            preload_captcha_models("preload")
        except Exception as exc:
            logger.warning("⚠️ 本地验证码模型预加载线程异常: %s", exc)

    _CAPTCHA_PRELOAD_THREAD = threading.Thread(
        target=_worker,
        name="captcha-onnx-preload",
        daemon=True,
    )
    _CAPTCHA_PRELOAD_THREAD.start()


def build_custom_schedule(
    target_hour: int,
    target_minute: int,
    now: datetime | None = None,
) -> dict[str, Any]:
    """计算定时模式日程：过点自动顺延到次日。"""
    current = now or utils.get_beijing_time()
    fire_at = current.replace(
        hour=target_hour,
        minute=target_minute,
        second=0,
        microsecond=0,
    )
    if current >= fire_at:
        fire_at = fire_at + timedelta(days=1)

    prep_at = fire_at - timedelta(seconds=PREP_LEAD_SECONDS)
    keepalive_at = fire_at - timedelta(seconds=KEEPALIVE_LEAD_SECONDS)

    return {
        "run_date": fire_at.date(),
        "prep_at": prep_at,
        "keepalive_at": keepalive_at,
        "fire_at": fire_at,
    }


def wait_until(
    target_time: datetime,
    account: str,
    stop_event: threading.Event,
    stage_name: str,
    now_fn: Callable[[], datetime] | None = None,
) -> bool:
    """绝对时间精确等待（支持服务端校准时钟、30 分钟心跳与即时响应 stop_event）。"""
    get_now = now_fn or utils.get_beijing_time
    now = get_now()
    if now >= target_time:
        logger.debug(
            "⏩ [%s] %s目标时间已过 (%s)，立即继续。",
            account,
            stage_name,
            target_time.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        )
        return True

    wait_seconds = (target_time - now).total_seconds()
    logger.info(
        "⏳ [%s] 当前: %s -> %s: %s",
        account,
        now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        stage_name,
        target_time.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
    )

    if wait_seconds > 0:
        logger.info("💤 [%s] %s前准备休眠 %.3f 秒...", account, stage_name, wait_seconds)
        if wait_seconds > 5:
            to_sleep = wait_seconds - 3
            heartbeat_interval = 1800  # 30 分钟
            while to_sleep > 0 and not stop_event.is_set():
                chunk = min(heartbeat_interval, to_sleep)
                if stop_event.wait(timeout=chunk):
                    logger.info("🛑 [%s] 等待期间收到停止信号，退出等待", account)
                    return False
                to_sleep -= chunk
                if to_sleep > 0:
                    now_hb = get_now()
                    logger.info(
                        "💓 [%s] 心跳: %s | %s还剩 %.0f 分钟",
                        account,
                        now_hb.strftime("%H:%M:%S"),
                        stage_name,
                        to_sleep / 60,
                    )

        while not stop_event.is_set():
            now = get_now()
            remaining = (target_time - now).total_seconds()
            if remaining <= 0:
                break
            if remaining > 0.5:
                step = min(0.2, remaining - 0.4 if remaining - 0.4 > 0 else 0.05)
                if stop_event.wait(timeout=step):
                    logger.info("🛑 [%s] 等待期间收到停止信号，退出等待", account)
                    return False
            elif remaining > 0.02:
                if stop_event.wait(timeout=0.01):
                    logger.info("🛑 [%s] 等待期间收到停止信号，退出等待", account)
                    return False
            else:
                # 最后 20ms 以内短忙等以保证毫秒精度
                pass

    if stop_event.is_set():
        logger.info("🛑 [%s] 等待被取消", account)
        return False

    logger.info("🔥 [%s] %s时间到！目标时刻 %s 已触发。", account, stage_name, target_time.strftime("%H:%M:%S"))
    return True


def setup_session_dir(account: str, log_dir: str | None = None) -> tuple[str | None, int]:
    """创建本次会话专属目录并记录账号日志起始字节偏移。"""
    base_dir = log_dir or str(_cfg("LOG_DIR", "logs") or "logs")
    session_ts = utils.get_beijing_time().strftime("%Y%m%d_%H%M%S")
    session_dir = os.path.join(base_dir, "sessions", f"{session_ts}_{account}")
    log_start = 0
    try:
        os.makedirs(session_dir, exist_ok=True)
        log_path = os.path.join(base_dir, f"lnu_seat_{account}.log")
        if os.path.exists(log_path):
            log_start = os.path.getsize(log_path)
    except OSError:
        return None, 0
    return session_dir, log_start


def export_session_log(
    session_dir: str | None,
    log_start: int,
    account: str,
    log_dir: str | None = None,
) -> None:
    """将本次会话新增日志切片导出到 ``session.log``。"""
    if not session_dir or log_start < 0:
        return
    base_dir = log_dir or str(_cfg("LOG_DIR", "logs") or "logs")
    try:
        log_src = os.path.join(base_dir, f"lnu_seat_{account}.log")
        if os.path.exists(log_src):
            with open(log_src, "r", encoding="utf-8", errors="replace") as lf:
                lf.seek(log_start)
                new_lines = lf.read()
            if new_lines:
                with open(os.path.join(session_dir, "session.log"), "w", encoding="utf-8") as sf:
                    sf.write(new_lines)
    except OSError:
        pass


ClientFactory = Callable[[SessionRecorder], LibSeatClient]


def _default_client_factory(recorder: SessionRecorder) -> LibSeatClient:
    base_url = str(_cfg("API_BASE_URL", DEFAULT_BASE_URL) or DEFAULT_BASE_URL)
    return HttpLibSeatClient(
        base_url=base_url,
        clock_sync=ClockSync(),
        rate_limiter=RateLimiter(),
        recorder=recorder,
    )


def run_api_session(
    account: str,
    password: str,
    start_time: str,
    end_time: str,
    stop_event: threading.Event,
    *,
    schedule: dict[str, Any] | None = None,
    wait_for_fire: bool = False,
    maintenance_mode: str | None = None,
    coordinator: SeatClaimCoordinator | None = None,
    client_factory: ClientFactory | None = None,
    captcha_service: CaptchaService | None = None,
    wait_until_fn: Any = None,
) -> str:
    """执行单次纯 API 抢座会话。

    返回状态码：``"success" | "stopped" | "maintenance_retry_at_fire" | "maintenance_retry_later"``。
    """
    session_dir, log_start = setup_session_dir(account)
    recorder = SessionRecorder(session_dir, account)
    client = (client_factory or _default_client_factory)(recorder)
    shared_coord = coordinator or SeatClaimCoordinator()
    waiter = wait_until_fn or wait_until

    try:
        logger.info("⚡ [%s] 纯 API 会话启动（LNU-LibSeat %s · 无浏览器模式）。", account, APP_VERSION)

        effective_maint = maintenance_mode
        if effective_maint is None:
            effective_maint = "stop"
            if wait_for_fire and schedule and utils.get_beijing_time() < schedule["fire_at"]:
                effective_maint = "defer_until_fire"

        login_res = client.login(account, password, stop_event=stop_event)
        if not login_res.ok:
            if login_res.reason == "maintenance":
                if effective_maint == "defer_until_fire":
                    logger.warning("⏸️ [%s] 收到维护提示，等待预约时刻重试登录: %s", account, login_res.message)
                    return "maintenance_retry_at_fire"
                if effective_maint == "retry_later":
                    logger.warning("⏳ [%s] 系统维护中，稍后按间隔重试: %s", account, login_res.message)
                    return "maintenance_retry_later"
                logger.error("🛑 [%s] 系统维护中，停止任务: %s", account, login_res.message)
                return "stopped"
            if login_res.reason == "protocol_drift":
                logger.error(
                    "🛑 [%s] 检测到站点接口协议可能已变更: %s（请将 %s 下的 http_trace.jsonl 上报 Issue）",
                    account,
                    login_res.message,
                    session_dir or "logs/sessions",
                )
                return "stopped"
            if login_res.reason == "stopped" or stop_event.is_set():
                return "stopped"
            logger.error("❌ [%s] 纯 API 登录失败 (%s): %s", account, login_res.reason, login_res.message)
            return "stopped"

        uid = login_res.profile.user_id if login_res.profile else "-"
        logger.info(
            "✅ [%s] 纯 API 登录成功！(userId=%s, clock_offset=%+.3fs)",
            account,
            uid,
            client.clock_sync.offset_seconds,
        )

        target_campus = str(_cfg("TARGET_CAMPUS", "") or "")
        target_room = str(_cfg("TARGET_ROOM", "") or "")
        fallback_rooms = list(_cfg("FALLBACK_ROOMS", []) or [])
        prefer_seats = list(_cfg("PREFER_SEATS", []) or [])
        fire_offset_ms = int(_cfg("API_FIRE_OFFSET_MS", DEFAULT_FIRE_OFFSET_MS) or 0)

        room_plan = build_room_plan(target_campus, target_room, fallback_rooms)
        booker = ApiSeatBooker(
            client,
            account=account,
            captcha_service=captcha_service or get_captcha_service(),
            recorder=recorder,
        )

        # 若长等待后出现 token 过期 (code == "12")，自动重登一次并继续抢座
        for auth_round in range(2):
            try:
                outcome, book_res, resolved_room = booker.attack_rooms(
                    room_plan=room_plan,
                    prefer_seats=prefer_seats,
                    start_time=start_time,
                    end_time=end_time,
                    schedule=schedule if (wait_for_fire and auth_round == 0) else None,
                    stop_event=stop_event,
                    coordinator=shared_coord,
                    wait_until_fn=waiter,
                    fire_offset_ms=fire_offset_ms,
                )
                break
            except TokenExpiredError as exc:
                if auth_round >= 1 or stop_event.is_set():
                    logger.error("🛑 [%s] Token 连续过期，终止会话: %s", account, exc)
                    return "stopped"
                logger.warning("🔄 [%s] 检测到 Token 过期 (%s)，正在自动重新登录...", account, exc)
                relogin = client.login(account, password, stop_event=stop_event)
                if not relogin.ok:
                    logger.error("❌ [%s] 自动重新登录失败: %s", account, relogin.message)
                    return "stopped"
        else:
            return "stopped"

        if outcome == "success" and book_res is not None:
            notify_booking_success(
                account,
                resolved_room or target_room,
                book_res.seat_no,
                start_time,
                end_time,
                reservation_id=book_res.reservation_id,
                receipt=book_res.receipt,
            )
            return "success"

        return "stopped"

    except Exception as exc:
        logger.exception("❌ [%s] 纯 API 会话异常崩溃: %s", account, exc)
        return "stopped"
    finally:
        export_session_log(session_dir, log_start, account)
        client.close()


def thread_task(
    account: str,
    password: str,
    time_config: dict[str, str],
    stop_event: threading.Event,
    *,
    scheduled: bool = True,
    slot_index: int = 0,
    coordinator: SeatClaimCoordinator | None = None,
    client_factory: ClientFactory | None = None,
) -> None:
    """单账号完整执行线程（定时模式 / 立即模式 / 维护期自动重试）。"""
    start_time = time_config["start"]
    end_time = time_config["end"]
    shared_coord = coordinator or SeatClaimCoordinator()

    schedule = None
    if scheduled:
        schedule = build_custom_schedule(
            int(_cfg("SCHEDULE_HOUR", 6)),
            int(_cfg("SCHEDULE_MINUTE", 30)),
        )
        logger.info(
            "🗓️ [%s] 日程: %s | 预热登录 %s → 保活 %s → 准点开抢 %s",
            account,
            schedule["run_date"].isoformat(),
            schedule["prep_at"].strftime("%H:%M:%S"),
            schedule["keepalive_at"].strftime("%H:%M:%S"),
            schedule["fire_at"].strftime("%H:%M:%S"),
        )

    try:
        if scheduled and schedule:
            prep_at = schedule["prep_at"] + timedelta(seconds=slot_index * ACCOUNT_STAGGER_SECONDS)
            if not wait_until(prep_at, account, stop_event, "准备启动纯 API 会话"):
                return

            result = run_api_session(
                account,
                password,
                start_time,
                end_time,
                stop_event,
                schedule=schedule,
                wait_for_fire=True,
                coordinator=shared_coord,
                client_factory=client_factory,
            )

            if result == "maintenance_retry_at_fire" and not stop_event.is_set():
                if not wait_until(schedule["fire_at"], account, stop_event, "等待放座时刻重连"):
                    return
                logger.info("🔄 [%s] 到达预约时刻，重新登录并立即开抢。", account)
                result = run_api_session(
                    account,
                    password,
                    start_time,
                    end_time,
                    stop_event,
                    schedule=None,
                    wait_for_fire=False,
                    maintenance_mode="retry_later",
                    coordinator=shared_coord,
                    client_factory=client_factory,
                )

            while result == "maintenance_retry_later" and not stop_event.is_set():
                next_retry_at = utils.get_beijing_time() + timedelta(
                    seconds=MAINTENANCE_RETRY_INTERVAL_SECONDS,
                )
                if not wait_until(next_retry_at, account, stop_event, "系统维护间隔重试"):
                    return
                logger.info("🔁 [%s] 按 %ds 间隔重试登录...", account, MAINTENANCE_RETRY_INTERVAL_SECONDS)
                result = run_api_session(
                    account,
                    password,
                    start_time,
                    end_time,
                    stop_event,
                    schedule=None,
                    wait_for_fire=False,
                    maintenance_mode="retry_later",
                    coordinator=shared_coord,
                    client_factory=client_factory,
                )

            logger.info("🛑 [%s] 抢座任务结束（结果: %s）。", account, result)
            return

        logger.info("🚀 [%s] 立即模式：纯 API 直连开抢（实时空座优先）。", account)
        if stop_event.is_set():
            return
        result = run_api_session(
            account,
            password,
            start_time,
            end_time,
            stop_event,
            schedule=None,
            wait_for_fire=False,
            coordinator=shared_coord,
            client_factory=client_factory,
        )
        logger.info("🛑 [%s] 抢座任务结束（结果: %s）。", account, result)
    except Exception as exc:
        logger.exception("❌ [%s] 账号线程异常崩溃: %s", account, exc)


def run_all_accounts(stop_event: threading.Event | None = None) -> None:
    """多账号并发总控入口。"""
    users: dict[str, dict[str, Any]] = dict(_cfg("USERS", {}) or {})
    max_accounts = int(_cfg("MAX_ACCOUNTS", 2) or 2)
    if len(users) > max_accounts:
        logger.warning(
            "⚠️ 当前配置了 %d 个账号，最多支持 %d 个；本次只启动前 %d 个。",
            len(users),
            max_accounts,
            max_accounts,
        )
        users = dict(list(users.items())[:max_accounts])

    target_room = _cfg("TARGET_ROOM", "")
    fallback_rooms = list(_cfg("FALLBACK_ROOMS", []) or [])
    scheduled = bool(_cfg("WAIT_FOR_0630", True))

    logger.info("🚀 LNU-LibSeat v6（纯 API 引擎）启动...")
    logger.info("🎯 主目标: %s | 备选自习室: %d 间", target_room, len(fallback_rooms))
    start_captcha_model_preload("scheduled startup" if scheduled else "immediate startup")

    if stop_event is None:
        stop_event = threading.Event()

    coordinator = SeatClaimCoordinator()
    threads: list[threading.Thread] = []

    try:
        for account in users:
            register_account_log_file(account)

        for slot_index, (account, info) in enumerate(users.items()):
            t = threading.Thread(
                target=thread_task,
                args=(account, info["password"], info["time"], stop_event),
                kwargs={
                    "scheduled": scheduled,
                    "slot_index": slot_index,
                    "coordinator": coordinator,
                },
                name=f"libseat-api-{account}",
                daemon=True,
            )
            t.start()
            threads.append(t)

        while any(t.is_alive() for t in threads):
            if stop_event.is_set():
                break
            for t in threads:
                t.join(timeout=0.3)
    except KeyboardInterrupt:
        logger.info("🛑 收到 KeyboardInterrupt，正在停止所有纯 API 抢座线程...")
        stop_event.set()
    finally:
        for t in threads:
            t.join(timeout=3.0)
        logger.info("🏁 所有账号任务已结束。")
