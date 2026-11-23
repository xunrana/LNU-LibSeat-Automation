"""纯 API 抢座引擎（零 Selenium / 零浏览器依赖）。

职责：
1. 预热期动态解析校区/自习室 ``room_id`` 与全房 ``seat_no -> seat_id`` 映射；
2. 开抢前预检已有有效预约，避免无效请求；
3. 06:30 定时模式下结合 ``ClockSync`` 精准保活与卡点触发（消除原前端 3.5s 假延时）；
4. 首选直击 + 实时空座刷新兜底 + ``FALLBACK_ROOMS`` 多自习室联动 + 多账号防撞座；
5. 自动适配 Click1 / Click3 点选验证码闭环、06:30:00~06:30:05 瞬态未放座短宽限、
   以及下单后预约记录核验。
"""
from __future__ import annotations

import logging
import threading
import time
from datetime import datetime, timedelta
from typing import Any, Callable, Sequence

import requests

from core.captcha_service import CaptchaService, get_captcha_service
from core.libseat_client import (
    BookResponse,
    LibSeatClient,
    RoomInfo,
)
from core.logger import get_logger
from core.protocol import (
    ProtocolDriftError,
    TokenExpiredError,
    TransientServerBusyError,
    is_transient_busy_text,
    parse_retry_after_seconds,
)
from core.rate_limiter import RateLimitCircuitOpenError
from core.session_recorder import SessionRecorder
from logic.seat_strategy import (
    SeatCandidate,
    SeatClaimCoordinator,
    plan_seat_candidates,
)

_logger = get_logger(__name__)

MAX_CAPTCHA_RETRIES_PER_SEAT = 8
MAX_BUSY_RETRIES_PER_SEAT = 12
OPEN_GRACE_WINDOW_SECONDS = 5.0
MAX_OPEN_GRACE_RETRIES = 5
OPEN_GRACE_BACKOFF_SECONDS = 0.25
# 对齐官网 Vue 前端 chunk0.js 硬编码延时：
# 1) loadCaptchaImg -> setTimeout(showConfirm=true, 1500)
# 2) orderSeatFun   -> setTimeout(freeBook, 2000)
# 3) /cap/captcha   -> 服务端 6 秒滑动窗口频控（系统繁忙, 请稍后: 06）
PEAK_CLICK3_MIN_SOLVE_SECONDS = 1.55
PEAK_CLICK3_POST_CHECK_SECONDS = 2.05
PEAK_POST_CHECK_STEP_SECONDS = 0.40
PEAK_POST_CHECK_MAX_SECONDS = 2.80
PEAK_CLICK3_RETRY_COOLDOWN_SECONDS = 6.20
SERVER_COOLDOWN_PAD_SECONDS = 0.60


class _AccountLoggerAdapter(logging.LoggerAdapter):
    """自动给日志加上 [account] 前缀，供按账号分流日志文件与 GUI 路由使用。"""

    def process(self, msg: Any, kwargs: Any) -> tuple[Any, Any]:
        tag = f"[{self.extra.get('account', 'unknown')}]" if self.extra else "[unknown]"
        s = str(msg)
        if tag in s:
            return msg, kwargs
        return f"{tag} {msg}", kwargs


WaitUntilFn = Callable[[datetime, str, threading.Event, str, Callable[[], datetime]], bool]


class ApiSeatBooker:
    """单账号纯 API 抢座执行器。"""

    def __init__(
        self,
        client: LibSeatClient,
        *,
        account: str,
        captcha_service: CaptchaService | None = None,
        recorder: SessionRecorder | None = None,
        max_captcha_retries: int = MAX_CAPTCHA_RETRIES_PER_SEAT,
        max_busy_retries: int = MAX_BUSY_RETRIES_PER_SEAT,
        grace_backoff_seconds: float = OPEN_GRACE_BACKOFF_SECONDS,
        peak_min_solve_seconds: float = PEAK_CLICK3_MIN_SOLVE_SECONDS,
        peak_post_check_seconds: float = PEAK_CLICK3_POST_CHECK_SECONDS,
        peak_retry_cooldown_seconds: float = PEAK_CLICK3_RETRY_COOLDOWN_SECONDS,
    ) -> None:
        self.client = client
        self.account = account or "unknown"
        self.captcha_service = captcha_service or get_captcha_service()
        self.recorder = recorder
        self.max_captcha_retries = max(1, int(max_captcha_retries))
        self.max_busy_retries = max(1, int(max_busy_retries))
        self.grace_backoff_seconds = max(0.0, float(grace_backoff_seconds))
        self.peak_min_solve_seconds = max(0.0, float(peak_min_solve_seconds))
        self.peak_post_check_seconds = max(0.0, float(peak_post_check_seconds))
        self.peak_retry_cooldown_seconds = max(0.0, float(peak_retry_cooldown_seconds))
        self._last_peak_captcha_fetch_at: float | None = None
        self.log = _AccountLoggerAdapter(_logger, {"account": self.account})

    def _in_open_grace_window(self, fire_at: datetime | None) -> bool:
        if fire_at is None:
            return False
        now = self.client.clock_sync.now_beijing()
        delta = (now - fire_at).total_seconds()
        return -1.0 <= delta <= OPEN_GRACE_WINDOW_SECONDS

    def _sleep_interruptible(self, seconds: float, stop_event: threading.Event) -> bool:
        if seconds <= 0:
            return not stop_event.is_set()
        return not stop_event.wait(timeout=seconds)

    def _wait_transient_busy(
        self,
        stage_desc: str,
        message: str,
        busy_retries: int,
        stop_event: threading.Event,
        *,
        is_rate_limit: bool = True,
        retry_after_seconds: float | None = None,
    ) -> tuple[bool, str]:
        """处理服务端瞬态繁忙退避；若服务端提示「请稍后: 06」，足额等待 6.6s 以免重置 Redis 滑动窗口。"""
        parsed_cd = retry_after_seconds if retry_after_seconds is not None else parse_retry_after_seconds(message)
        min_delay = (parsed_cd + SERVER_COOLDOWN_PAD_SECONDS) if (parsed_cd and self.peak_retry_cooldown_seconds > 0) else 0.0
        hint = f"（冷却 {min_delay:.1f}s）" if min_delay > 0 else ""
        self.log.warning(
            "⏳ %s遇服务端繁忙 (%d/%d): %s，退避重试%s...",
            stage_desc,
            busy_retries,
            self.max_busy_retries,
            message,
            hint,
        )
        try:
            ok = self.client.rate_limiter.wait_backoff(
                stop_event=stop_event,
                is_rate_limit=is_rate_limit,
                min_delay_s=min_delay,
            )
        except RateLimitCircuitOpenError as exc:
            self.log.error("🛑 %s", exc)
            return False, str(exc)
        if not ok:
            return False, "收到停止信号"
        return True, ""

    def attempt_seat(
        self,
        seat: SeatCandidate,
        *,
        start_time: str,
        end_time: str,
        date_str: str,
        stop_event: threading.Event,
        priority: int = 0,
        fire_at: datetime | None = None,
    ) -> BookResponse:
        """对单个座位执行完整「取码 → 求解 → 校验 → freeBook」闭环。"""
        grace_retries = 0
        busy_retries = 0
        captcha_attempt = 0
        adaptive_post_check_s = self.peak_post_check_seconds

        while captcha_attempt < self.max_captcha_retries:
            if stop_event.is_set():
                return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)

            display_attempt = captcha_attempt + 1
            self.log.info(
                "🔁 座位 %s 第 %d/%d 次纯 API 验证码与提交尝试...",
                seat.seat_no,
                display_attempt,
                self.max_captcha_retries,
            )

            # 若上一轮已是 06:30 高峰三字码，跨次/跨座再次取码前确保距上次取码满 6.2s，防止触发「系统繁忙, 请稍后: 06」滑动锁
            if self._last_peak_captcha_fetch_at is not None and self.peak_retry_cooldown_seconds > 0:
                since_last_fetch = time.monotonic() - self._last_peak_captcha_fetch_at
                cd_remain = self.peak_retry_cooldown_seconds - since_last_fetch
                if cd_remain > 0:
                    self.log.info("⏳ 等待高峰取码 6s 冷却窗口结束 (剩余 %.2fs)...", cd_remain)
                    if not self._sleep_interruptible(cd_remain, stop_event):
                        return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)

            try:
                challenge = self.client.fetch_click_captcha(stop_event=stop_event)
            except InterruptedError:
                return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
            except (ProtocolDriftError, RateLimitCircuitOpenError) as exc:
                self.log.error("🛑 终止当前会话: %s", exc)
                return BookResponse(status="stop", message=str(exc), seat_no=seat.seat_no)
            except TokenExpiredError:
                raise
            except TransientServerBusyError as exc:
                if self._last_peak_captcha_fetch_at is not None:
                    self._last_peak_captcha_fetch_at = time.monotonic()
                busy_retries += 1
                if busy_retries > self.max_busy_retries:
                    self.log.warning(
                        "💔 座位 %s 拉取验证码连续繁忙达 %d 次，切换下一座位",
                        seat.seat_no,
                        self.max_busy_retries,
                    )
                    return BookResponse(status="failed", message=str(exc), seat_no=seat.seat_no)
                cont, stop_msg = self._wait_transient_busy(
                    "拉取验证码",
                    str(exc),
                    busy_retries,
                    stop_event,
                    is_rate_limit=exc.is_rate_limit,
                    retry_after_seconds=exc.retry_after_seconds,
                )
                if not cont:
                    return BookResponse(status="stop", message=stop_msg, seat_no=seat.seat_no)
                continue
            except requests.RequestException as exc:
                self.log.warning("⚠️ 拉取验证码网络异常: %s", exc)
                if not self.client.rate_limiter.wait_backoff(stop_event=stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            fetch_done_at = time.monotonic()
            is_peak_click3 = challenge.word_check_count >= 3
            if is_peak_click3:
                self._last_peak_captcha_fetch_at = fetch_done_at
            captcha_attempt += 1

            outcome = self.captcha_service.solve(
                challenge.target_bytes,
                challenge.bg_bytes,
                hint_count=challenge.word_check_count,
                now=self.client.clock_sync.now_beijing(),
            )
            if self.recorder is not None:
                self.recorder.save_captcha_diagnostic(
                    target_bytes=challenge.target_bytes,
                    bg_bytes=challenge.bg_bytes,
                    outcome=outcome,
                    priority=priority,
                    seat=seat.seat_no,
                    retry=captcha_attempt,
                )

            if not outcome.ok or not outcome.points:
                self.log.warning(
                    "⚠️ 本地 %s 模型未命中 (%s, %.0fms)，刷新重取...",
                    outcome.kind,
                    outcome.error or "empty",
                    outcome.elapsed_ms,
                )
                if not self.client.rate_limiter.wait_backoff(stop_event=stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            self.log.info(
                "🧠 本地 %s 模型解出 %d 点 (%.0fms): %s",
                outcome.kind,
                len(outcome.points),
                outcome.elapsed_ms,
                list(outcome.points),
            )

            # 06:30 高峰三字码防极速风控：补齐最小求解间隔，避免 500ms 内直交被后端拒判
            if is_peak_click3 and self.peak_min_solve_seconds > 0:
                elapsed_since_fetch = time.monotonic() - fetch_done_at
                pad_s = self.peak_min_solve_seconds - elapsed_since_fetch
                if pad_s > 0 and not self._sleep_interruptible(pad_s, stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)

            try:
                check_res = self.client.check_click_captcha(
                    challenge,
                    outcome.points,
                    stop_event=stop_event,
                )
            except InterruptedError:
                return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
            except (ProtocolDriftError, RateLimitCircuitOpenError) as exc:
                self.log.error("🛑 终止当前会话: %s", exc)
                return BookResponse(status="stop", message=str(exc), seat_no=seat.seat_no)
            except TokenExpiredError:
                raise
            except TransientServerBusyError as exc:
                captcha_attempt = max(0, captcha_attempt - 1)
                busy_retries += 1
                if busy_retries > self.max_busy_retries:
                    return BookResponse(status="failed", message=str(exc), seat_no=seat.seat_no)
                cont, stop_msg = self._wait_transient_busy(
                    "校验验证码",
                    str(exc),
                    busy_retries,
                    stop_event,
                    is_rate_limit=exc.is_rate_limit,
                )
                if not cont:
                    return BookResponse(status="stop", message=stop_msg, seat_no=seat.seat_no)
                continue
            except requests.RequestException as exc:
                self.log.warning("⚠️ 校验验证码网络异常: %s", exc)
                if not self.client.rate_limiter.wait_backoff(stop_event=stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            if not check_res.ok:
                if is_transient_busy_text(check_res.message):
                    captcha_attempt = max(0, captcha_attempt - 1)
                    busy_retries += 1
                    if busy_retries > self.max_busy_retries:
                        return BookResponse(status="failed", message=check_res.message, seat_no=seat.seat_no)
                    cont, stop_msg = self._wait_transient_busy(
                        "校验验证码",
                        check_res.message,
                        busy_retries,
                        stop_event,
                        is_rate_limit=True,
                    )
                    if not cont:
                        return BookResponse(status="stop", message=stop_msg, seat_no=seat.seat_no)
                    continue
                self.log.warning("⚠️ 验证码校验未通过 (%s)，刷新重试", check_res.message)
                if not self.client.rate_limiter.wait_backoff(stop_event=stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            if is_peak_click3 and adaptive_post_check_s > 0:
                self.log.info(
                    "✅ 验证码校验通过，遵循官网高峰防风控窗口等待 %.2fs 后提交 freeBook (座位 %s)...",
                    adaptive_post_check_s,
                    seat.seat_no,
                )
                if not self._sleep_interruptible(adaptive_post_check_s, stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
            else:
                self.log.info("✅ 验证码一次通过，立即提交 freeBook (座位 %s)...", seat.seat_no)

            in_grace = self._in_open_grace_window(fire_at)
            try:
                book_res = self.client.free_book(
                    seat_id=seat.seat_id,
                    seat_no=seat.seat_no,
                    start_time=start_time,
                    end_time=end_time,
                    date_str=date_str,
                    authid=challenge.token,
                    in_open_grace_window=in_grace,
                    stop_event=stop_event,
                )
            except InterruptedError:
                return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
            except (ProtocolDriftError, RateLimitCircuitOpenError) as exc:
                self.log.error("🛑 终止当前会话: %s", exc)
                return BookResponse(status="stop", message=str(exc), seat_no=seat.seat_no)
            except TokenExpiredError:
                raise
            except TransientServerBusyError as exc:
                captcha_attempt = max(0, captcha_attempt - 1)
                busy_retries += 1
                if busy_retries > self.max_busy_retries:
                    return BookResponse(status="failed", message=str(exc), seat_no=seat.seat_no)
                cont, stop_msg = self._wait_transient_busy(
                    "提交预约",
                    str(exc),
                    busy_retries,
                    stop_event,
                    is_rate_limit=exc.is_rate_limit,
                )
                if not cont:
                    return BookResponse(status="stop", message=stop_msg, seat_no=seat.seat_no)
                continue
            except requests.RequestException as exc:
                self.log.warning("⚠️ freeBook 网络异常: %s", exc)
                if not self.client.rate_limiter.wait_backoff(stop_event=stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            if book_res.status == "success":
                return book_res

            if book_res.status in ("blacklist", "stop"):
                return book_res

            if book_res.not_open_yet:
                grace_retries += 1
                if grace_retries > MAX_OPEN_GRACE_RETRIES:
                    self.log.error("🛑 放座宽限重试 %d 次后仍提示未开放: %s", MAX_OPEN_GRACE_RETRIES, book_res.message)
                    return BookResponse(status="stop", message=book_res.message, seat_no=seat.seat_no)
                self.log.info(
                    "⏳ 服务端尚在切换放座瞬态 (%d/%d): %s，%.0fms 后重探...",
                    grace_retries,
                    MAX_OPEN_GRACE_RETRIES,
                    book_res.message,
                    self.grace_backoff_seconds * 1000.0,
                )
                if not self._sleep_interruptible(self.grace_backoff_seconds, stop_event):
                    return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                continue

            if book_res.status == "retry_captcha":
                if book_res.rate_limited:
                    captcha_attempt = max(0, captcha_attempt - 1)
                    busy_retries += 1
                    if busy_retries > self.max_busy_retries:
                        return BookResponse(status="failed", message=book_res.message, seat_no=seat.seat_no)
                    cont, stop_msg = self._wait_transient_busy(
                        "提交预约",
                        book_res.message,
                        busy_retries,
                        stop_event,
                        is_rate_limit=True,
                    )
                    if not cont:
                        return BookResponse(status="stop", message=stop_msg, seat_no=seat.seat_no)
                    continue

                if is_peak_click3 and "验证码" in book_res.message and adaptive_post_check_s < PEAK_POST_CHECK_MAX_SECONDS:
                    adaptive_post_check_s = min(
                        adaptive_post_check_s + PEAK_POST_CHECK_STEP_SECONDS,
                        PEAK_POST_CHECK_MAX_SECONDS,
                    )
                    self.log.warning(
                        "⚠️ 校验已通过但 freeBook 报【%s】，自动提升高峰校验后缓冲至 %.2fs 后重试",
                        book_res.message,
                        adaptive_post_check_s,
                    )
                else:
                    self.log.warning("⚠️ 收到可重试业务反馈【%s】，退避重试当前座位", book_res.message)

                try:
                    if not self.client.rate_limiter.wait_backoff(
                        stop_event=stop_event,
                        is_rate_limit=False,
                    ):
                        return BookResponse(status="stop", message="收到停止信号", seat_no=seat.seat_no)
                except RateLimitCircuitOpenError as exc:
                    self.log.error("🛑 %s", exc)
                    return BookResponse(status="stop", message=str(exc), seat_no=seat.seat_no)
                continue

            # seat_taken / failed：立即结束当前座位尝试，由外层换下一空座
            self.log.warning("💔 座位 %s 提交未成功（%s）: %s", seat.seat_no, book_res.status, book_res.message)
            return book_res

        self.log.warning("💔 座位 %s 连续 %d 次尝试未通过，切换下一座位", seat.seat_no, self.max_captcha_retries)
        return BookResponse(status="failed", message="max_captcha_retries_exceeded", seat_no=seat.seat_no)

    def _verify_and_enrich_success(
        self,
        res: BookResponse,
        stop_event: threading.Event,
    ) -> BookResponse:
        """下单成功后可选核验 /rest/v2/user/reservations，补齐凭证与位置文案。"""
        if res.reservation_id and res.receipt:
            return res
        try:
            records = self.client.list_active_reservations(stop_event=stop_event)
            for rec in records:
                if rec.status.upper() == "RESERVE" or rec.reservation_id:
                    return BookResponse(
                        status="success",
                        message=res.message,
                        seat_no=res.seat_no,
                        reservation_id=res.reservation_id or rec.reservation_id,
                        receipt=res.receipt or rec.receipt,
                        location=res.location or rec.location,
                    )
        except Exception as exc:
            self.log.debug("预约成功后的二次核验失败（不影响已成功结果）: %s", exc)
        return res

    def _has_blocking_reservation(self, stop_event: threading.Event) -> str:
        """预检是否已有生效中的预约，有则返回描述文本，无则返回空串。"""
        try:
            records = self.client.list_active_reservations(stop_event=stop_event)
        except Exception as exc:
            self.log.debug("预检已有预约异常（继续抢座）: %s", exc)
            return ""
        for rec in records:
            st = rec.status.upper()
            if st in ("RESERVE", "CHECK_IN", "AWAY"):
                return f"{rec.location or '已有预约'} ({rec.begin}-{rec.end}, 状态={st}, 单号={rec.reservation_id})"
        return ""

    def _room_has_free_seats(self, room: RoomInfo, date_str: str, stop_event: threading.Event) -> bool:
        """通过 76ms 的 stats2 快查备选房是否尚有空座；查询异常时保守返回 True。"""
        try:
            stats = self.client.list_room_stats(room.building_id, date_str, stop_event=stop_event)
            for st in stats:
                if st.room_id == room.room_id:
                    self.log.info(
                        "📊 备选自习室 %s 实时概况: 空座 %d / 总座 %d",
                        room.room_name,
                        st.free_seats,
                        st.total_seats,
                    )
                    return st.free_seats > 0
        except Exception as exc:
            self.log.debug("查询备选房 stats2 失败（回退查 layout）: %s", exc)
        return True

    def attack_rooms(
        self,
        *,
        room_plan: Sequence[tuple[str, str]],
        prefer_seats: Sequence[str],
        start_time: str,
        end_time: str,
        schedule: dict[str, Any] | None,
        stop_event: threading.Event,
        coordinator: SeatClaimCoordinator,
        wait_until_fn: WaitUntilFn,
        fire_offset_ms: int = 200,
    ) -> tuple[str, BookResponse | None, str]:
        """执行完整抢座主流程（支持多自习室兜底）。

        返回 ``(outcome, book_response, resolved_room_name)``：
        - ``outcome`` 为 ``"success" | "stopped" | "all_failed"``
        """
        if not room_plan:
            self.log.error("❌ 未配置任何目标自习室，无法抢座。")
            return "all_failed", None, ""

        # 1) 预检是否已有有效预约
        existing = self._has_blocking_reservation(stop_event)
        if existing:
            self.log.warning("🛑 当前账号已有有效预约：%s，停止本次抢座。", existing)
            return "stopped", None, ""

        now_bj = self.client.clock_sync.now_beijing()
        date_str = schedule["run_date"].isoformat() if schedule else now_bj.date().isoformat()
        fire_at: datetime | None = schedule["fire_at"] if schedule else None
        keepalive_at: datetime | None = schedule.get("keepalive_at") if schedule else None

        # 2) 预热期动态解析首个自习室并拉取座位映射（遇瞬态繁忙自动退避重试）
        primary_campus, primary_room_name = room_plan[0]
        primary_room: RoomInfo | None = None
        for prep_try in range(1, 5):
            try:
                primary_room = self.client.resolve_room(
                    primary_campus, primary_room_name, date_str, stop_event=stop_event,
                )
                break
            except (ProtocolDriftError, RateLimitCircuitOpenError) as exc:
                self.log.error("🛑 解析目标自习室失败，停止会话: %s", exc)
                return "stopped", None, primary_room_name
            except (TransientServerBusyError, requests.RequestException) as exc:
                if prep_try >= 4:
                    self.log.error("🛑 解析目标自习室连续繁忙/异常，停止会话: %s", exc)
                    return "stopped", None, primary_room_name
                is_rl = isinstance(exc, TransientServerBusyError) and exc.is_rate_limit
                self.log.warning("⏳ 解析目标自习室遇繁忙 (%d/4): %s，退避重试...", prep_try, exc)
                try:
                    if not self.client.rate_limiter.wait_backoff(stop_event=stop_event, is_rate_limit=is_rl):
                        return "stopped", None, primary_room_name
                except RateLimitCircuitOpenError as rl_exc:
                    self.log.error("🛑 %s", rl_exc)
                    return "stopped", None, primary_room_name

        if primary_room is None:
            self.log.error("❌ 无法在系统中找到自习室: %s / %s", primary_campus, primary_room_name)
            return "all_failed", None, primary_room_name

        primary_seats: list[SeatCandidate] = []
        for layout_try in range(1, 5):
            try:
                primary_seats = self.client.list_room_seats(
                    primary_room.room_id, date_str, stop_event=stop_event,
                )
                self.client.rate_limiter.mark_seats_refreshed()
                break
            except (ProtocolDriftError, RateLimitCircuitOpenError) as exc:
                self.log.error("🛑 拉取自习室座位布局失败，停止会话: %s", exc)
                return "stopped", None, primary_room.room_name
            except (TransientServerBusyError, requests.RequestException) as exc:
                if layout_try >= 4:
                    self.log.error("🛑 拉取自习室座位布局连续繁忙/异常，停止会话: %s", exc)
                    return "stopped", None, primary_room.room_name
                is_rl = isinstance(exc, TransientServerBusyError) and exc.is_rate_limit
                self.log.warning("⏳ 拉取自习室布局遇繁忙 (%d/4): %s，退避重试...", layout_try, exc)
                try:
                    if not self.client.rate_limiter.wait_backoff(stop_event=stop_event, is_rate_limit=is_rl):
                        return "stopped", None, primary_room.room_name
                except RateLimitCircuitOpenError as rl_exc:
                    self.log.error("🛑 %s", rl_exc)
                    return "stopped", None, primary_room.room_name

        free_cnt = sum(1 for s in primary_seats if s.status == "free")
        self.log.info(
            "🏫 目标自习室就绪: %s -> %s (room_id=%s, 共 %d 座, 当前空闲 %d 座)",
            primary_room.campus_name,
            primary_room.room_name,
            primary_room.room_id,
            len(primary_seats),
            free_cnt,
        )

        # 定时模式在 06:30:00 瞬间保留首选直击（不因放座前的状态过滤首选）；立即模式跳过已占首选
        initial_pref, initial_fb = plan_seat_candidates(
            prefer_seats,
            primary_seats,
            skip_occupied_preferred=(fire_at is None),
            shuffle_fallback=True,
        )
        if self.recorder is not None:
            self.recorder.write_seat_plan(
                campus=primary_room.campus_name,
                room=primary_room.room_name,
                prefer_seats=[s.seat_no for s in initial_pref],
                fallback_seats=[s.seat_no for s in initial_fb],
                start_time=start_time,
                end_time=end_time,
                total_room_seats=len(primary_seats),
                free_room_seats=free_cnt,
            )

        # 3) 定时模式：06:29:55 保活 + 06:30:00(+offset) 按服务端校准时钟触发
        if fire_at is not None:
            if keepalive_at is not None:
                ok = wait_until_fn(
                    keepalive_at,
                    self.account,
                    stop_event,
                    f"等待 {keepalive_at.strftime('%H:%M:%S')} 会话保活与时钟复校",
                    self.client.clock_sync.now_beijing,
                )
                if not ok:
                    return "stopped", None, primary_room.room_name
                alive = self.client.keepalive(stop_event=stop_event)
                self.log.info(
                    "💓 保活完成 (ok=%s, clock_offset=%+.3fs)",
                    alive,
                    self.client.clock_sync.offset_seconds,
                )

            fire_target = fire_at + timedelta(milliseconds=max(0, int(fire_offset_ms)))
            ok = wait_until_fn(
                fire_target,
                self.account,
                stop_event,
                f"等待 {fire_target.strftime('%H:%M:%S.%f')[:-3]} 准点开抢",
                self.client.clock_sync.now_beijing,
            )
            if not ok:
                return "stopped", None, primary_room.room_name

        # 4) 按自习室顺序逐房开抢（主房 + FALLBACK_ROOMS）
        started_attack = time.monotonic()
        try:
            for room_idx, (campus, room_name) in enumerate(room_plan):
                if stop_event.is_set():
                    return "stopped", None, room_name

                if room_idx == 0:
                    room = primary_room
                    pref_queue = list(initial_pref)
                    fallback_queue = list(initial_fb)
                else:
                    self.log.info("🔀 主自习室已耗尽，切换备选自习室: %s -> %s", campus, room_name)
                    try:
                        room = self.client.resolve_room(campus, room_name, date_str, stop_event=stop_event)
                    except (TransientServerBusyError, requests.RequestException) as exc:
                        self.log.warning("⏳ 解析备选自习室 %s 遇繁忙，跳过: %s", room_name, exc)
                        continue
                    if room is None:
                        self.log.warning("⚠️ 备选自习室未找到，跳过: %s / %s", campus, room_name)
                        continue
                    if not self._room_has_free_seats(room, date_str, stop_event):
                        self.log.info("⏭️ 备选自习室 %s 当前无空座，跳过", room.room_name)
                        continue
                    live_seats: list[SeatCandidate] | None = None
                    for fb_try in range(1, 4):
                        try:
                            live_seats = self.client.list_room_seats(room.room_id, date_str, stop_event=stop_event)
                            self.client.rate_limiter.mark_seats_refreshed()
                            break
                        except (TransientServerBusyError, requests.RequestException) as exc:
                            if fb_try >= 3:
                                self.log.warning("⚠️ 拉取备选房 %s 座位布局失败，跳过: %s", room.room_name, exc)
                                break
                            is_rl = isinstance(exc, TransientServerBusyError) and exc.is_rate_limit
                            try:
                                if not self.client.rate_limiter.wait_backoff(
                                    stop_event=stop_event,
                                    is_rate_limit=is_rl,
                                ):
                                    return "stopped", None, room.room_name
                            except RateLimitCircuitOpenError as rl_exc:
                                self.log.error("🛑 %s", rl_exc)
                                return "stopped", None, room.room_name
                    if not live_seats:
                        continue
                    pref_queue, fallback_queue = plan_seat_candidates(
                        [],
                        live_seats,
                        skip_occupied_preferred=True,
                        shuffle_fallback=True,
                    )

                tried_seat_ids: set[str] = set()
                priority = 0

                # 4a) 首选队列直击 + 兜底空座循环（遇 seat_taken 按冷却自动刷新实时空座）
                active_queue: list[tuple[str, SeatCandidate]] = (
                    [("首选", s) for s in pref_queue] + [("兜底", s) for s in fallback_queue]
                )
                refreshed_after_pref = False

                while active_queue:
                    if stop_event.is_set():
                        return "stopped", None, room.room_name

                    tag, seat = active_queue.pop(0)
                    if seat.seat_id in tried_seat_ids:
                        continue

                    # 定时模式首选耗尽进入兜底前，先拉一次实时空座快照（精准跳过 06:30 已被抢走的座）；
                    # 若未配置首选座（tried_seat_ids 为空），直接使用 06:29:45 刚拉好的全空快照，避免 06:30:00 浪费 250ms
                    if (
                        tag == "兜底"
                        and fire_at is not None
                        and bool(tried_seat_ids)
                        and not refreshed_after_pref
                        and self.client.rate_limiter.can_refresh_seats()
                    ):
                        refreshed_after_pref = True
                        try:
                            fresh_seats = self.client.list_room_seats(
                                room.room_id, date_str, stop_event=stop_event,
                            )
                            self.client.rate_limiter.mark_seats_refreshed()
                            _, fresh_fb = plan_seat_candidates(
                                [],
                                fresh_seats,
                                skip_occupied_preferred=True,
                                shuffle_fallback=True,
                            )
                            active_queue = [
                                ("兜底", s) for s in fresh_fb if s.seat_id not in tried_seat_ids
                            ]
                            self.log.info(
                                "🔄 已刷新 %s 实时空座快照：剩余 %d 个未试空座",
                                room.room_name,
                                len(active_queue),
                            )
                            if not active_queue:
                                break
                            tag, seat = active_queue.pop(0)
                        except (requests.RequestException, ProtocolDriftError, TransientServerBusyError) as exc:
                            self.log.debug("刷新实时空座失败，沿用已有列表: %s", exc)

                    if not coordinator.try_claim(
                        self.account, room.room_id, seat.seat_no, start_time, end_time,
                    ):
                        self.log.debug("⏭️ 座位 %s 正由其他同时间段账号尝试，错开换座", seat.seat_no)
                        continue

                    tried_seat_ids.add(seat.seat_id)
                    priority += 1
                    self.log.info("🎯 === [%s] 抢 %s 座位 %s (id=%s) ===", tag, room.room_name, seat.seat_no, seat.seat_id)

                    try:
                        res = self.attempt_seat(
                            seat,
                            start_time=start_time,
                            end_time=end_time,
                            date_str=date_str,
                            stop_event=stop_event,
                            priority=priority,
                            fire_at=fire_at,
                        )
                    finally:
                        coordinator.release(self.account, room.room_id, seat.seat_no)

                    if res.status == "success":
                        enriched = self._verify_and_enrich_success(res, stop_event)
                        elapsed = time.monotonic() - started_attack
                        self.log.info(
                            "🎉🎉🎉 %s 座位 %s 抢座成功！(单号=%s, 凭证=%s, 用时=%.2fs)",
                            room.room_name,
                            seat.seat_no,
                            enriched.reservation_id or "-",
                            enriched.receipt or "-",
                            elapsed,
                        )
                        return "success", enriched, room.room_name

                    if res.status == "blacklist":
                        self.log.error("🛑 账号已被加入黑名单，立刻停止抢座: %s", res.message)
                        return "stopped", res, room.room_name

                    if res.status == "stop":
                        self.log.error("🛑 收到终态停止信号，立即退出: %s", res.message)
                        return "stopped", res, room.room_name

                    # 座位被他人抢走且已过冷却 → 刷新一次实时空座快照，过滤已占座位
                    if res.status == "seat_taken" and self.client.rate_limiter.can_refresh_seats():
                        try:
                            fresh_seats = self.client.list_room_seats(
                                room.room_id, date_str, stop_event=stop_event,
                            )
                            self.client.rate_limiter.mark_seats_refreshed()
                            free_ids = {s.seat_id for s in fresh_seats if s.status == "free"}
                            remaining_pref = [
                                (t, s) for t, s in active_queue if t == "首选" and s.seat_id not in tried_seat_ids
                            ]
                            _, fresh_fb = plan_seat_candidates(
                                [],
                                fresh_seats,
                                skip_occupied_preferred=True,
                                shuffle_fallback=True,
                            )
                            pref_ids = {s.seat_id for _, s in remaining_pref}
                            remaining_fb = [
                                ("兜底", s)
                                for s in fresh_fb
                                if s.seat_id in free_ids
                                and s.seat_id not in tried_seat_ids
                                and s.seat_id not in pref_ids
                            ]
                            active_queue = remaining_pref + remaining_fb
                        except Exception as exc:
                            self.log.debug("换座刷新空座快照失败（继续沿用队列）: %s", exc)

            self.log.error("❌ 全部候选自习室与可用座位均已尝试完毕，本轮未抢到。")
            return "all_failed", None, room_plan[-1][1]
        finally:
            coordinator.release_all(self.account)


# 兼容旧符号引用
SeatBooker = ApiSeatBooker
