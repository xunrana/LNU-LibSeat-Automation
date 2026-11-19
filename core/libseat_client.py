"""LibSeat 纯 HTTP API 客户端（强类型契约 + 生产实现）。

特性：
- 单会话 ``requests.Session`` 连接池复用（Keep-Alive），全请求自动注入
  ``loginType`` / ``Authorization`` / ``X-hmac-request-key`` 签名头；
- 自动把每个响应的 HTTP ``Date`` 头与 RTT 喂给 ``ClockSync``；
- 自动接入 ``RateLimiter`` 节流、429/5xx 退避熔断与 ``SessionRecorder`` 脱敏审计；
- 强 Schema 校验：响应异常（非 JSON、缺核心字段）立即抛 ``ProtocolDriftError``；
  ``code == "12"`` 立即抛 ``TokenExpiredError``。
"""
from __future__ import annotations

import base64
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Literal, Protocol, Sequence

import requests
from requests.adapters import HTTPAdapter

from core.api_crypto import (
    decrypt_hmac_secret,
    encode_captcha_points,
    encrypt_login_credential,
    sign_request_headers,
)
from core.clock_sync import ClockSync
from core.logger import get_logger
from core.protocol import (
    DEFAULT_BASE_URL,
    DEFAULT_REFERER,
    DEFAULT_USER_AGENT,
    EP_AUTH,
    EP_AVAIL_SEATS,
    EP_CANCEL,
    EP_CHECK_CAPTCHA,
    EP_CLICK_CAPTCHA,
    EP_CREATE_LOGIN_CAPTCHA,
    EP_END_TIMES,
    EP_FREE_BOOK,
    EP_FREE_FILTERS,
    EP_ROOM_LAYOUT,
    EP_ROOM_STATS,
    EP_START_TIMES,
    EP_USER,
    EP_USER_RESERVATIONS,
    FREE_SEAT_STATUSES,
    GLOBAL_JS_PATHS,
    LOGIN_TYPE,
    MAINTENANCE_KEYWORDS,
    OCCUPIED_SEAT_STATUSES,
    TOKEN_EXPIRED_CODE,
    GlobalConfig,
    ProtocolDriftError,
    TokenExpiredError,
    parse_global_js,
)
from core.rate_limiter import RateLimitCircuitOpenError, RateLimiter
from core.session_recorder import SessionRecorder
from logic.result_classifier import ApiOutcomeStatus, classify_api_booking_result
from logic.seat_strategy import SeatCandidate, SeatStatus, normalize_seat_no, parse_hhmm_minutes

logger = get_logger(__name__)

LoginFailureReason = Literal[
    "ok",
    "maintenance",
    "bad_credentials",
    "captcha_failed",
    "protocol_drift",
    "rate_limited",
    "network_error",
    "stopped",
]


@dataclass(frozen=True)
class UserProfile:
    user_id: str
    username: str
    status: str = "NORMAL"
    violation_count: int = 0
    reservation_status: str | None = None


@dataclass(frozen=True)
class LoginResponse:
    ok: bool
    reason: LoginFailureReason = "ok"
    token: str = ""
    profile: UserProfile | None = None
    message: str = ""


@dataclass(frozen=True)
class RoomInfo:
    campus_name: str
    room_name: str
    building_id: str
    room_id: str


@dataclass(frozen=True)
class RoomStats:
    room_id: str
    room_name: str
    floor: int = 0
    total_seats: int = 0
    free_seats: int = 0
    reserved_seats: int = 0
    in_use_seats: int = 0
    away_seats: int = 0
    disabled_seats: int = 0


@dataclass(frozen=True)
class FiltersData:
    buildings: dict[str, str] = field(default_factory=dict)  # campus_name -> building_id
    rooms_by_name: dict[tuple[str, str], RoomInfo] = field(default_factory=dict)  # (campus, room) -> RoomInfo
    dates: tuple[str, ...] = ()


@dataclass(frozen=True)
class ClickCaptchaChallenge:
    token: str
    word_check_count: int
    target_bytes: bytes
    bg_bytes: bytes


@dataclass(frozen=True)
class ClickCaptchaCheckResult:
    ok: bool
    message: str = ""


@dataclass(frozen=True)
class ReservationRecord:
    reservation_id: str
    receipt: str = ""
    on_date: str = ""
    seat_id: str = ""
    status: str = ""
    location: str = ""
    begin: str = ""
    end: str = ""
    message: str = ""


@dataclass(frozen=True)
class BookResponse:
    status: ApiOutcomeStatus
    message: str = ""
    seat_no: str = ""
    reservation_id: str = ""
    receipt: str = ""
    location: str = ""
    not_open_yet: bool = False
    rate_limited: bool = False


class LibSeatClient(Protocol):
    """纯 API 客户端协议契约（生产使用 HttpLibSeatClient，单测注入 Fake）。"""

    @property
    def clock_sync(self) -> ClockSync: ...

    @property
    def rate_limiter(self) -> RateLimiter: ...

    def bootstrap_global(self, stop_event: threading.Event | None = None) -> GlobalConfig: ...

    def login(
        self,
        account: str,
        password: str,
        *,
        stop_event: threading.Event | None = None,
        max_attempts: int = 6,
    ) -> LoginResponse: ...

    def keepalive(self, stop_event: threading.Event | None = None) -> bool: ...

    def list_active_reservations(
        self,
        stop_event: threading.Event | None = None,
    ) -> list[ReservationRecord]: ...

    def fetch_filters(self, stop_event: threading.Event | None = None) -> FiltersData: ...

    def list_room_stats(
        self,
        building_id: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[RoomStats]: ...

    def resolve_room(
        self,
        campus_name: str,
        room_name: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> RoomInfo | None: ...

    def list_room_seats(
        self,
        room_id: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[SeatCandidate]: ...

    def fetch_click_captcha(
        self,
        *,
        stop_event: threading.Event | None = None,
    ) -> ClickCaptchaChallenge: ...

    def check_click_captcha(
        self,
        challenge: ClickCaptchaChallenge,
        points: Sequence[tuple[int, int]],
        *,
        stop_event: threading.Event | None = None,
    ) -> ClickCaptchaCheckResult: ...

    def free_book(
        self,
        *,
        seat_id: str,
        seat_no: str,
        start_time: str,
        end_time: str,
        date_str: str,
        authid: str,
        in_open_grace_window: bool = False,
        stop_event: threading.Event | None = None,
    ) -> BookResponse: ...

    def cancel_reservation(
        self,
        reservation_id: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> bool: ...

    def close(self) -> None: ...


def _decode_data_url(raw: str) -> bytes:
    if not raw:
        return b""
    payload = raw.split(",", 1)[1] if "," in raw else raw
    return base64.b64decode(payload)


def _is_maintenance_text(text: str) -> bool:
    s = (text or "").strip()
    return any(kw in s for kw in MAINTENANCE_KEYWORDS)


def _to_api_time_param(time_str: str) -> str:
    """把 'HH:MM' 或 'now' 转换为 freeBook / startTimes 接口所需的分钟数字符串。"""
    s = (time_str or "").strip().lower()
    if s in ("now", "-1", "现在"):
        return "-1"
    if s.isdigit():
        return s
    mins = parse_hhmm_minutes(time_str)
    if mins is None:
        raise ValueError(f"无法解析时间参数: {time_str!r}")
    return str(mins)


def _map_seat_status(enabled: bool, raw_status: str) -> SeatStatus:
    if not enabled:
        return "unavailable"
    st = (raw_status or "").upper()
    if st in FREE_SEAT_STATUSES:
        return "free"
    if st in OCCUPIED_SEAT_STATUSES:
        return "occupied"
    return "unavailable"


def _default_login_ocr(image_bytes: bytes) -> str:
    from core.captcha import solver

    b64 = base64.b64encode(image_bytes).decode("ascii")
    return str(solver.solve_base64(b64) or "").strip()


class HttpLibSeatClient:
    """基于 ``requests.Session`` 的 LibSeat 纯 API 生产客户端。"""

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_BASE_URL,
        timeout: tuple[float, float] = (3.0, 8.0),
        session: requests.Session | None = None,
        clock_sync: ClockSync | None = None,
        rate_limiter: RateLimiter | None = None,
        recorder: SessionRecorder | None = None,
        login_ocr_fn: Callable[[bytes], str] | None = None,
        global_config: GlobalConfig | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._owns_session = session is None
        self._session = session or self._build_session()
        self._clock_sync = clock_sync or ClockSync()
        self._rate_limiter = rate_limiter or RateLimiter()
        self._recorder = recorder
        self._login_ocr = login_ocr_fn or _default_login_ocr

        self._global_cfg = global_config or GlobalConfig(base_url=self.base_url)
        self._hmac_secret = decrypt_hmac_secret(self._global_cfg.numcode_encrypted)
        self._global_bootstrapped = global_config is not None

        self._token: str = ""
        self._account: str = ""
        self._profile: UserProfile | None = None
        self._filters_cache: FiltersData | None = None

    @staticmethod
    def _build_session() -> requests.Session:
        sess = requests.Session()
        adapter = HTTPAdapter(pool_connections=4, pool_maxsize=4)
        sess.mount("http://", adapter)
        sess.mount("https://", adapter)
        return sess

    @property
    def clock_sync(self) -> ClockSync:
        return self._clock_sync

    @property
    def rate_limiter(self) -> RateLimiter:
        return self._rate_limiter

    @property
    def token(self) -> str:
        return self._token

    @property
    def profile(self) -> UserProfile | None:
        return self._profile

    def close(self) -> None:
        if self._owns_session:
            try:
                self._session.close()
            except Exception:
                pass

    def _build_headers(self, method: str, extra: dict[str, str] | None = None) -> dict[str, str]:
        headers: dict[str, str] = {
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": DEFAULT_REFERER,
            "User-Agent": DEFAULT_USER_AGENT,
            "loginType": LOGIN_TYPE,
        }
        if self._token:
            headers["Authorization"] = self._token
        if method.upper() == "POST":
            headers["Origin"] = self.base_url
        if self._global_cfg.code_enabled:
            headers.update(sign_request_headers(method, hmac_secret=self._hmac_secret))
        if extra:
            headers.update(extra)
        return headers

    def _request_raw(
        self,
        stage: str,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        extra_headers: dict[str, str] | None = None,
        json_body: dict[str, Any] | None = None,
        files: list[tuple[str, tuple[None, str]]] | None = None,
        stop_event: threading.Event | None = None,
        bypass_rate_limit: bool = False,
    ) -> requests.Response:
        if not bypass_rate_limit:
            if not self._rate_limiter.wait_slot(stop_event=stop_event):
                raise InterruptedError("收到停止信号，取消 HTTP 请求")

        url = f"{self.base_url}{path}"
        headers = self._build_headers(method, extra=extra_headers)
        t0 = time.monotonic()
        status_code: int | None = None
        try:
            resp = self._session.request(
                method=method.upper(),
                url=url,
                params=params,
                headers=headers,
                json=json_body,
                files=files,
                timeout=self.timeout,
            )
            rtt = time.monotonic() - t0
            status_code = resp.status_code

            date_hdr = resp.headers.get("Date") or resp.headers.get("date")
            if date_hdr:
                self._clock_sync.update_from_http_date(
                    date_hdr,
                    rtt_seconds=rtt,
                    local_received_utc=datetime.now(timezone.utc),
                )

            if resp.status_code == 429 or resp.status_code >= 500:
                if self._recorder:
                    self._recorder.record_http(
                        stage=stage,
                        method=method,
                        path=path,
                        status_code=status_code,
                        rtt_ms=rtt * 1000.0,
                        req_summary=params,
                        error=f"HTTP {resp.status_code}",
                    )
                self._rate_limiter.wait_backoff(stop_event=stop_event, is_rate_limit=(resp.status_code == 429))
            return resp
        except requests.RequestException as exc:
            rtt = time.monotonic() - t0
            if self._recorder:
                self._recorder.record_http(
                    stage=stage,
                    method=method,
                    path=path,
                    status_code=status_code,
                    rtt_ms=rtt * 1000.0,
                    req_summary=params,
                    error=f"{type(exc).__name__}: {exc}",
                )
            raise

    def _request_json(
        self,
        stage: str,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        extra_headers: dict[str, str] | None = None,
        json_body: dict[str, Any] | None = None,
        files: list[tuple[str, tuple[None, str]]] | None = None,
        stop_event: threading.Event | None = None,
    ) -> dict[str, Any]:
        t0 = time.monotonic()
        resp = self._request_raw(
            stage,
            method,
            path,
            params=params,
            extra_headers=extra_headers,
            json_body=json_body,
            files=files,
            stop_event=stop_event,
        )
        rtt_ms = (time.monotonic() - t0) * 1000.0

        if resp.status_code in (404, 405):
            raise ProtocolDriftError(f"端点 {method.upper()} {path} 返回 HTTP {resp.status_code}，协议可能已变更")

        if resp.status_code == 429:
            raise RateLimitCircuitOpenError(f"端点 {path} 返回 HTTP 429 限流")

        try:
            data = resp.json()
        except ValueError as exc:
            snippet = (resp.text or "")[:160]
            if _is_maintenance_text(snippet):
                return {"status": "fail", "message": "系统维护中", "code": "maintenance"}
            if self._recorder:
                self._recorder.record_http(
                    stage=stage,
                    method=method,
                    path=path,
                    status_code=resp.status_code,
                    rtt_ms=rtt_ms,
                    req_summary=params,
                    error=f"non_json: {snippet}",
                )
            raise ProtocolDriftError(f"端点 {path} 返回非 JSON 响应 (HTTP {resp.status_code}): {snippet!r}") from exc

        if not isinstance(data, dict):
            raise ProtocolDriftError(f"端点 {path} 响应体不是 JSON 对象: {type(data).__name__}")

        biz_msg = str(data.get("message") or "")
        if self._recorder:
            self._recorder.record_http(
                stage=stage,
                method=method,
                path=path,
                status_code=resp.status_code,
                rtt_ms=rtt_ms,
                req_summary=params,
                resp_summary={k: v for k, v in data.items() if k != "data" or not isinstance(v, dict) or len(v) <= 12},
                biz_msg=biz_msg,
            )

        if str(data.get("code") or "") == TOKEN_EXPIRED_CODE:
            raise TokenExpiredError(biz_msg or "token 已过期，请重新登录")

        if 200 <= resp.status_code < 300:
            self._rate_limiter.record_success()

        return data

    def bootstrap_global(self, stop_event: threading.Event | None = None) -> GlobalConfig:
        """尝试从公开 ``baseUrl.js`` 动态同步 ``CODE / NUMCODE``，失败静默回退默认值。"""
        if self._global_bootstrapped:
            return self._global_cfg

        for rel_path in GLOBAL_JS_PATHS:
            try:
                resp = self._request_raw(
                    "bootstrap_global",
                    "GET",
                    rel_path,
                    stop_event=stop_event,
                    bypass_rate_limit=True,
                )
                if resp.status_code == 200 and resp.text:
                    parsed = parse_global_js(resp.text, fallback_base_url=self.base_url)
                    if parsed is not None:
                        self._global_cfg = parsed
                        self._hmac_secret = decrypt_hmac_secret(parsed.numcode_encrypted)
                        self._global_bootstrapped = True
                        logger.debug("已从 %s 动态加载 Global 签名配置 (CODE=%s)", rel_path, parsed.code_enabled)
                        return self._global_cfg
            except Exception as exc:
                logger.debug("尝试读取 %s 失败（将使用内置默认签名配置）: %s", rel_path, exc)

        self._global_bootstrapped = True
        return self._global_cfg

    def _fetch_login_captcha(self, stop_event: threading.Event | None = None) -> tuple[str, bytes]:
        data = self._request_json("login_captcha", "GET", EP_CREATE_LOGIN_CAPTCHA, stop_event=stop_event)
        captcha_id = str(data.get("captchaId") or "").strip()
        captcha_image = str(data.get("captchaImage") or "").strip()
        if not captcha_id or not captcha_image:
            if _is_maintenance_text(str(data.get("message") or "")):
                return "", b""
            raise ProtocolDriftError(f"/auth/createCaptcha 缺少 captchaId/captchaImage 字段: keys={list(data.keys())}")
        return captcha_id, _decode_data_url(captcha_image)

    def _fetch_user_profile(self, stop_event: threading.Event | None = None) -> UserProfile:
        data = self._request_json(
            "user_profile",
            "GET",
            EP_USER,
            params={"token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success" or not isinstance(data.get("data"), dict):
            raise ProtocolDriftError(f"/rest/v2/user 响应异常: {data.get('message') or data.get('status')}")
        u = data["data"]
        uid = u.get("id")
        if uid is None:
            raise ProtocolDriftError("/rest/v2/user 响应缺少 data.id")
        return UserProfile(
            user_id=str(uid),
            username=str(u.get("username") or self._account),
            status=str(u.get("status") or "NORMAL"),
            violation_count=int(u.get("violationCount") or 0),
            reservation_status=u.get("reservationStatus"),
        )

    def login(
        self,
        account: str,
        password: str,
        *,
        stop_event: threading.Event | None = None,
        max_attempts: int = 6,
    ) -> LoginResponse:
        self._account = account
        self._token = ""
        self._profile = None
        self._filters_cache = None

        try:
            self.bootstrap_global(stop_event=stop_event)
        except InterruptedError:
            return LoginResponse(ok=False, reason="stopped", message="已取消")

        enc_user = encrypt_login_credential(account)
        enc_pass = encrypt_login_credential(password)

        for attempt in range(1, max_attempts + 1):
            if stop_event is not None and stop_event.is_set():
                return LoginResponse(ok=False, reason="stopped", message="收到停止信号")

            try:
                captcha_id, img_bytes = self._fetch_login_captcha(stop_event=stop_event)
                if not captcha_id:
                    return LoginResponse(ok=False, reason="maintenance", message="系统维护中")

                code = self._login_ocr(img_bytes)
                if len(code) != 4:
                    logger.debug("[%s] 第 %d/%d 次登录图形码识别长度异常 (%r)，重取", account, attempt, max_attempts, code)
                    continue

                auth_data = self._request_json(
                    "login_auth",
                    "GET",
                    EP_AUTH,
                    params={"answer": code, "captchaId": captcha_id},
                    extra_headers={"username": enc_user, "password": enc_pass},
                    stop_event=stop_event,
                )
            except InterruptedError:
                return LoginResponse(ok=False, reason="stopped", message="收到停止信号")
            except ProtocolDriftError as exc:
                return LoginResponse(ok=False, reason="protocol_drift", message=str(exc))
            except RateLimitCircuitOpenError as exc:
                return LoginResponse(ok=False, reason="rate_limited", message=str(exc))
            except requests.RequestException as exc:
                logger.warning("⚠️ [%s] 第 %d/%d 次登录网络异常: %s", account, attempt, max_attempts, exc)
                if not self._rate_limiter.wait_backoff(stop_event=stop_event):
                    return LoginResponse(ok=False, reason="stopped", message="收到停止信号")
                continue

            msg = str(auth_data.get("message") or "")
            if _is_maintenance_text(msg):
                return LoginResponse(ok=False, reason="maintenance", message=msg or "系统维护中")

            if auth_data.get("status") == "success":
                payload = auth_data.get("data")
                if not isinstance(payload, dict) or not payload.get("token"):
                    return LoginResponse(
                        ok=False,
                        reason="protocol_drift",
                        message="/rest/auth 成功响应缺少 data.token",
                    )
                self._token = str(payload["token"])
                try:
                    self._profile = self._fetch_user_profile(stop_event=stop_event)
                except ProtocolDriftError as exc:
                    return LoginResponse(ok=False, reason="protocol_drift", message=str(exc))
                except (requests.RequestException, TokenExpiredError) as exc:
                    return LoginResponse(ok=False, reason="network_error", message=str(exc))

                return LoginResponse(
                    ok=True,
                    reason="ok",
                    token=self._token,
                    profile=self._profile,
                    message="登录成功",
                )

            # 区分图形码错误 vs 账号密码错误
            if "验证码" in msg:
                logger.info("🔄 [%s] 第 %d/%d 次登录图形码未匹配 (%s)，重试...", account, attempt, max_attempts, msg)
                continue
            if any(kw in msg for kw in ("密码", "用户名", "账号", "不存在", "锁定")):
                return LoginResponse(ok=False, reason="bad_credentials", message=msg)

            logger.warning("⚠️ [%s] 第 %d/%d 次登录返回失败: %s", account, attempt, max_attempts, msg or auth_data)
            if not self._rate_limiter.wait_backoff(stop_event=stop_event):
                return LoginResponse(ok=False, reason="stopped", message="收到停止信号")

        return LoginResponse(ok=False, reason="captcha_failed", message=f"登录连续 {max_attempts} 次未通过")

    def keepalive(self, stop_event: threading.Event | None = None) -> bool:
        """06:29:55 保活心跳：维持 TCP 连接热态并二次校准服务端时钟。"""
        try:
            path = EP_USER if self._token else EP_AVAIL_SEATS
            params = {"token": self._token} if self._token else None
            data = self._request_json("keepalive", "GET", path, params=params, stop_event=stop_event)
            return data.get("status") == "success"
        except (requests.RequestException, InterruptedError, TokenExpiredError, ProtocolDriftError):
            return False

    def list_active_reservations(
        self,
        stop_event: threading.Event | None = None,
    ) -> list[ReservationRecord]:
        data = self._request_json(
            "active_reservations",
            "GET",
            EP_USER_RESERVATIONS,
            params={"token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success":
            return []
        raw_list = data.get("data")
        if not raw_list:
            return []
        if isinstance(raw_list, dict):
            raw_list = [raw_list]
        records: list[ReservationRecord] = []
        for item in raw_list:
            if not isinstance(item, dict):
                continue
            records.append(
                ReservationRecord(
                    reservation_id=str(item.get("id") or ""),
                    receipt=str(item.get("receipt") or ""),
                    on_date=str(item.get("onDate") or ""),
                    seat_id=str(item.get("seatId") or ""),
                    status=str(item.get("status") or ""),
                    location=str(item.get("location") or ""),
                    begin=str(item.get("begin") or ""),
                    end=str(item.get("end") or ""),
                    message=str(item.get("message") or ""),
                )
            )
        return records

    def fetch_filters(self, stop_event: threading.Event | None = None) -> FiltersData:
        if self._filters_cache is not None:
            return self._filters_cache

        data = self._request_json(
            "free_filters",
            "GET",
            EP_FREE_FILTERS,
            params={"token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success" or not isinstance(data.get("data"), dict):
            raise ProtocolDriftError(f"/rest/v2/free/filters 响应异常: {data.get('message')}")
        payload = data["data"]

        buildings: dict[str, str] = {}
        id_to_campus: dict[str, str] = {}
        for row in payload.get("buildings") or []:
            if isinstance(row, list) and len(row) >= 2:
                bid = str(row[0])
                cname = str(row[1]).strip()
                buildings[cname] = bid
                id_to_campus[bid] = cname

        rooms_by_name: dict[tuple[str, str], RoomInfo] = {}
        for row in payload.get("rooms") or []:
            if isinstance(row, list) and len(row) >= 3:
                rid = str(row[0])
                rname = str(row[1]).strip()
                bid = str(row[2])
                cname = id_to_campus.get(bid, "")
                info = RoomInfo(campus_name=cname, room_name=rname, building_id=bid, room_id=rid)
                rooms_by_name[(cname, rname)] = info

        dates = tuple(str(d) for d in (payload.get("dates") or []) if d)
        self._filters_cache = FiltersData(
            buildings=buildings,
            rooms_by_name=rooms_by_name,
            dates=dates,
        )
        return self._filters_cache

    def list_room_stats(
        self,
        building_id: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[RoomStats]:
        path = EP_ROOM_STATS.format(building_id=building_id, date=date_str)
        data = self._request_json(
            "room_stats",
            "GET",
            path,
            params={"buildingId": building_id, "date": date_str, "token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success" or not isinstance(data.get("data"), list):
            raise ProtocolDriftError(f"{path} 响应异常: {data.get('message')}")

        stats: list[RoomStats] = []
        for item in data["data"]:
            if not isinstance(item, dict):
                continue
            stats.append(
                RoomStats(
                    room_id=str(item.get("roomId") or ""),
                    room_name=str(item.get("room") or "").strip(),
                    floor=int(item.get("floor") or 0),
                    total_seats=int(item.get("totalSeats") or 0),
                    free_seats=int(item.get("free") or 0),
                    reserved_seats=int(item.get("reserved") or 0),
                    in_use_seats=int(item.get("inUse") or 0),
                    away_seats=int(item.get("away") or 0),
                    disabled_seats=int(item.get("disableSeat") or 0),
                )
            )
        return stats

    def resolve_room(
        self,
        campus_name: str,
        room_name: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> RoomInfo | None:
        filters = self.fetch_filters(stop_event=stop_event)
        target_c = (campus_name or "").strip()
        target_r = (room_name or "").strip()

        # 1) 精确命中 filters 缓存
        exact = filters.rooms_by_name.get((target_c, target_r))
        if exact is not None:
            return exact

        # 2) 按 buildingId 查实时 stats2（覆盖 filters 未列出的房间或名称微调）
        bid = filters.buildings.get(target_c)
        if not bid:
            for cname, cid in filters.buildings.items():
                if target_c and (target_c in cname or cname in target_c):
                    bid = cid
                    target_c = cname
                    break

        candidate_bids = [bid] if bid else list(filters.buildings.values())
        for b_id in candidate_bids:
            stats = self.list_room_stats(b_id, date_str, stop_event=stop_event)
            for st in stats:
                if st.room_name == target_r or (target_r and target_r in st.room_name):
                    resolved_campus = next(
                        (cn for cn, cid in filters.buildings.items() if cid == b_id),
                        target_c,
                    )
                    return RoomInfo(
                        campus_name=resolved_campus,
                        room_name=st.room_name,
                        building_id=b_id,
                        room_id=st.room_id,
                    )

        # 3) 兜底按房名在 filters 中模糊匹配
        for (_cn, rn), info in filters.rooms_by_name.items():
            if target_r and (rn == target_r or target_r in rn):
                return info
        return None

    def list_room_seats(
        self,
        room_id: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[SeatCandidate]:
        path = EP_ROOM_LAYOUT.format(room_id=room_id, date=date_str)
        data = self._request_json(
            "room_layout",
            "GET",
            path,
            params={"id": room_id, "date": date_str, "token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success" or not isinstance(data.get("data"), dict):
            raise ProtocolDriftError(f"{path} 响应异常: {data.get('message')}")
        layout = data["data"].get("layout")
        if not isinstance(layout, dict):
            raise ProtocolDriftError(f"{path} 响应缺少 data.layout 字典")

        seats: list[SeatCandidate] = []
        for node in layout.values():
            if not isinstance(node, dict) or node.get("type") != "seat":
                continue
            sid = node.get("id")
            raw_name = str(node.get("name") or "").strip()
            if sid is None or not raw_name:
                continue
            enabled = bool(node.get("enabled", True))
            status = _map_seat_status(enabled, str(node.get("status") or ""))
            seats.append(
                SeatCandidate(
                    seat_no=normalize_seat_no(raw_name),
                    seat_id=str(sid),
                    room_id=str(room_id),
                    status=status,
                )
            )
        return seats

    def list_seat_start_times(
        self,
        seat_id: str,
        date_str: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[dict[str, str]]:
        path = EP_START_TIMES.format(seat_id=seat_id, date=date_str)
        data = self._request_json(
            "seat_start_times",
            "GET",
            path,
            params={"seatId": seat_id, "date": date_str, "token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success":
            return []
        raw = (data.get("data") or {}).get("startTimes") or []
        return [
            {"id": str(x.get("id", "")), "value": str(x.get("value", ""))}
            for x in raw
            if isinstance(x, dict)
        ]

    def list_seat_end_times(
        self,
        seat_id: str,
        date_str: str,
        start_id: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> list[dict[str, str]]:
        path = EP_END_TIMES.format(seat_id=seat_id, date=date_str, start=start_id)
        data = self._request_json(
            "seat_end_times",
            "GET",
            path,
            params={"id": seat_id, "date": date_str, "start": start_id, "token": self._token},
            stop_event=stop_event,
        )
        if data.get("status") != "success":
            return []
        raw = (data.get("data") or {}).get("endTimes") or []
        return [
            {"id": str(x.get("id", "")), "value": str(x.get("value", ""))}
            for x in raw
            if isinstance(x, dict)
        ]

    def fetch_click_captcha(
        self,
        *,
        stop_event: threading.Event | None = None,
    ) -> ClickCaptchaChallenge:
        username = self._profile.username if self._profile else self._account
        path = EP_CLICK_CAPTCHA.format(token=self._token)
        data = self._request_json(
            "click_captcha_fetch",
            "POST",
            path,
            params={"username": username},
            stop_event=stop_event,
        )
        if str(data.get("status") or "").upper() != "OK":
            msg = str(data.get("message") or data.get("status") or "")
            raise ProtocolDriftError(f"/cap/captcha 返回非 OK: {msg}")
        cap_token = str(data.get("token") or "").strip()
        bg_raw = str(data.get("image") or "")
        target_raw = str(data.get("wordImage") or "")
        if not cap_token or not bg_raw or not target_raw:
            raise ProtocolDriftError(f"/cap/captcha 缺少必需字段: keys={list(data.keys())}")
        word_count = int(data.get("wordCheckCount") or 1)
        return ClickCaptchaChallenge(
            token=cap_token,
            word_check_count=word_count,
            target_bytes=_decode_data_url(target_raw),
            bg_bytes=_decode_data_url(bg_raw),
        )

    def check_click_captcha(
        self,
        challenge: ClickCaptchaChallenge,
        points: Sequence[tuple[int, int]],
        *,
        stop_event: threading.Event | None = None,
    ) -> ClickCaptchaCheckResult:
        username = self._profile.username if self._profile else self._account
        user_id = self._profile.user_id if self._profile else ""
        encoded = encode_captcha_points(points)
        params: dict[str, Any] = {
            "a": encoded,
            "token": challenge.token,
            "username": username,
        }
        if user_id:
            params["userId"] = user_id

        data = self._request_json(
            "click_captcha_check",
            "GET",
            EP_CHECK_CAPTCHA,
            params=params,
            stop_event=stop_event,
        )
        ok = str(data.get("status") or "").upper() == "OK"
        return ClickCaptchaCheckResult(ok=ok, message=str(data.get("message") or data.get("status") or ""))

    def free_book(
        self,
        *,
        seat_id: str,
        seat_no: str,
        start_time: str,
        end_time: str,
        date_str: str,
        authid: str,
        in_open_grace_window: bool = False,
        stop_event: threading.Event | None = None,
    ) -> BookResponse:
        username = self._profile.username if self._profile else self._account
        user_id = self._profile.user_id if self._profile else ""
        start_param = _to_api_time_param(start_time)
        end_param = _to_api_time_param(end_time)

        # 使用 requests 的 files=[(k, (None, v))] 精确构造 multipart/form-data，与前端 FormData 一致
        multipart_fields: list[tuple[str, tuple[None, str]]] = [
            ("startTime", (None, start_param)),
            ("endTime", (None, end_param)),
            ("seat", (None, str(seat_id))),
            ("date", (None, date_str)),
            ("userId", (None, user_id)),
            ("username", (None, username)),
            ("authid", (None, authid)),
        ]
        data = self._request_json(
            "free_book",
            "POST",
            EP_FREE_BOOK,
            params={"token": self._token},
            files=multipart_fields,
            stop_event=stop_event,
        )

        if data.get("status") == "success":
            payload = data.get("data") if isinstance(data.get("data"), dict) else {}
            return BookResponse(
                status="success",
                message=str(data.get("message") or "预约成功"),
                seat_no=seat_no,
                reservation_id=str(payload.get("id") or ""),
                receipt=str(payload.get("receipt") or ""),
                location=str(payload.get("location") or ""),
            )

        msg = str(data.get("message") or "")
        classified = classify_api_booking_result(msg, in_open_grace_window=in_open_grace_window)
        return BookResponse(
            status=classified.status,
            message=msg or str(data.get("status") or "预约失败"),
            seat_no=seat_no,
            not_open_yet=classified.not_open_yet,
            rate_limited=classified.rate_limited,
        )

    def cancel_reservation(
        self,
        reservation_id: str,
        *,
        stop_event: threading.Event | None = None,
    ) -> bool:
        path = EP_CANCEL.format(reservation_id=reservation_id)
        data = self._request_json(
            "cancel_reservation",
            "GET",
            path,
            params={"id": reservation_id, "token": self._token},
            stop_event=stop_event,
        )
        return data.get("status") == "success"
