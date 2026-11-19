"""服务端时钟校准（基于 HTTP Date 响应头 + RTT/2 补偿）。

纯 API 模式下取代硬编码 ``time.sleep(2)``：在预热登录与 06:29:55 保活时
采集服务端 ``Date`` 响应头，估算 ``server_utc - local_utc``，消除本机时钟
偏快/偏慢造成的提前提交或晚点问题。
"""
from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from typing import Callable

from core.logger import get_logger

logger = get_logger(__name__)

BJ_TZ = timezone(timedelta(hours=8))


@dataclass(frozen=True)
class ClockSample:
    """单次服务端时钟采样结果。"""

    server_utc: datetime
    local_utc: datetime
    rtt_seconds: float
    offset_seconds: float


class ClockSync:
    """线程安全的服务端时钟偏移校准器。

    说明：
    - RFC 7231 HTTP ``Date`` 响应头精度为 1 秒（向下取整到整秒），因此采用
      ``server_utc - local_mid`` 属于**偏保守估计**（使客户端宁可略晚于
      服务端整点几十到几百毫秒，也不轻易抢跑撞到未开放边界）。
    - 多次采样时优先保留 RTT 更小的样本（更低的网络抖动误差）；若历史样本
      已超过 ``stale_after_seconds``，则允许被新样本刷新。
    """

    def __init__(
        self,
        *,
        warn_offset_seconds: float = 30.0,
        max_accept_offset_seconds: float = 3600.0,
        stale_after_seconds: float = 300.0,
        now_utc_fn: Callable[[], datetime] | None = None,
    ) -> None:
        self._warn_offset = float(warn_offset_seconds)
        self._max_accept_offset = float(max_accept_offset_seconds)
        self._stale_after = float(stale_after_seconds)
        self._now_utc = now_utc_fn or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()
        self._best_sample: ClockSample | None = None

    @property
    def synced(self) -> bool:
        with self._lock:
            return self._best_sample is not None

    @property
    def offset_seconds(self) -> float:
        with self._lock:
            return self._best_sample.offset_seconds if self._best_sample else 0.0

    @property
    def best_sample(self) -> ClockSample | None:
        with self._lock:
            return self._best_sample

    def reset(self) -> None:
        with self._lock:
            self._best_sample = None

    def update_from_http_date(
        self,
        date_header: str | None,
        *,
        rtt_seconds: float = 0.0,
        local_received_utc: datetime | None = None,
    ) -> ClockSample | None:
        """从 HTTP ``Date`` 响应头更新时钟偏移，返回本次采样或 None（解析/校验失败）。"""
        if not date_header or not date_header.strip():
            return None

        try:
            parsed = parsedate_to_datetime(date_header.strip())
        except (TypeError, ValueError):
            logger.debug("无法解析 HTTP Date 响应头: %r", date_header)
            return None

        if parsed.tzinfo is None:
            server_utc = parsed.replace(tzinfo=timezone.utc)
        else:
            server_utc = parsed.astimezone(timezone.utc)

        recv_utc = local_received_utc or self._now_utc()
        if recv_utc.tzinfo is None:
            recv_utc = recv_utc.replace(tzinfo=timezone.utc)
        else:
            recv_utc = recv_utc.astimezone(timezone.utc)

        safe_rtt = max(0.0, float(rtt_seconds))
        local_mid = recv_utc - timedelta(seconds=safe_rtt / 2.0)
        offset = (server_utc - local_mid).total_seconds()

        if abs(offset) > self._max_accept_offset:
            logger.warning(
                "⚠️ 忽略异常 HTTP Date 时钟偏移: offset=%.2fs (header=%r)",
                offset,
                date_header,
            )
            return None

        if abs(offset) > self._warn_offset:
            logger.warning(
                "⚠️ 检测到本机与服务端时钟偏差较大: offset=%+.2fs (rtt=%.0fms)",
                offset,
                safe_rtt * 1000.0,
            )

        sample = ClockSample(
            server_utc=server_utc,
            local_utc=local_mid,
            rtt_seconds=safe_rtt,
            offset_seconds=offset,
        )

        with self._lock:
            prev = self._best_sample
            should_replace = prev is None
            if prev is not None:
                age = (local_mid - prev.local_utc).total_seconds()
                if age >= self._stale_after or safe_rtt <= prev.rtt_seconds:
                    should_replace = True
            if should_replace:
                self._best_sample = sample
                logger.info(
                    "🕒 服务端时钟已校准: offset=%+.3fs (rtt=%.0fms)",
                    sample.offset_seconds,
                    sample.rtt_seconds * 1000.0,
                )

        return sample

    def now_utc(self) -> datetime:
        """返回经服务端偏移校准后的当前 UTC 时间。"""
        base = self._now_utc()
        if base.tzinfo is None:
            base = base.replace(tzinfo=timezone.utc)
        else:
            base = base.astimezone(timezone.utc)
        return base + timedelta(seconds=self.offset_seconds)

    def now_beijing(self) -> datetime:
        """返回经服务端偏移校准后的当前北京时间（UTC+8）。"""
        return self.now_utc().astimezone(BJ_TZ)
