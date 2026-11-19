"""选座策略、多自习室兜底规划与多账号防撞座协调器（纯逻辑，零网络/UI 依赖）。

支撑 v6 纯 API 引擎的三大核心改进：
1. 实时空座优先：首选直击 + 仅对实时 ``free`` 座位随机扫描，告别全房盲扫；
2. 多自习室兜底（``FALLBACK_ROOMS``）：主自习室耗尽后按序切换备选房；
3. 多账号防撞座（``SeatClaimCoordinator``）：时段重叠的并发账号错开同一兜底座，
   时段不重叠的账号（如 09:00-15:00 + 15:00-21:00 无缝衔接）允许抢同一心仪座。
"""
from __future__ import annotations

import random
import threading
from dataclasses import dataclass
from typing import Literal, Sequence

SeatStatus = Literal["free", "occupied", "unavailable", "unknown"]


@dataclass(frozen=True)
class SeatCandidate:
    seat_no: str
    seat_id: str = ""
    room_id: str = ""
    status: SeatStatus = "unknown"


def normalize_seat_no(raw: str) -> str:
    """归一化座号：去除前导零（'001' -> '1'），混合编号（'A-06-1'）原样保留。"""
    s = str(raw).strip()
    return str(int(s)) if s.isdigit() else s


def parse_hhmm_minutes(time_str: str) -> int | None:
    """把 'HH:MM' / 'H:MM' 解析为自 00:00 起的分钟数；非法格式返回 None。"""
    parts = (time_str or "").strip().split(":")
    if len(parts) != 2:
        return None
    try:
        hour = int(parts[0])
        minute = int(parts[1])
    except ValueError:
        return None
    if not (0 <= hour <= 24 and 0 <= minute < 60):
        return None
    total = hour * 60 + minute
    return total if total <= 24 * 60 else None


def time_ranges_overlap(start_a: str, end_a: str, start_b: str, end_b: str) -> bool:
    """判断两个半开区间 ``[start, end)`` 是否重叠。

    边界相等（如 09:00-15:00 与 15:00-21:00）视为**不重叠**，允许无缝衔接占同一座。
    若任一时间无法解析，出于保守策略视为重叠。
    """
    sa = parse_hhmm_minutes(start_a)
    ea = parse_hhmm_minutes(end_a)
    sb = parse_hhmm_minutes(start_b)
    eb = parse_hhmm_minutes(end_b)
    if sa is None or ea is None or sb is None or eb is None:
        return True
    if ea <= sa or eb <= sb:
        return True
    return sa < eb and sb < ea


def build_room_plan(
    primary_campus: str,
    primary_room: str,
    fallback_rooms: Sequence[tuple[str, str]] | None = None,
) -> list[tuple[str, str]]:
    """构造去重且保序的 ``[(campus, room), ...]`` 目标自习室队列。"""
    plan: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def _add(campus: str, room: str) -> None:
        c = (campus or "").strip()
        r = (room or "").strip()
        if not r:
            return
        key = (c, r)
        if key not in seen:
            seen.add(key)
            plan.append(key)

    _add(primary_campus, primary_room)
    for item in fallback_rooms or ():
        if len(item) == 2:
            _add(item[0], item[1])
    return plan


def plan_seat_candidates(
    prefer_seats: Sequence[str],
    room_seats: Sequence[SeatCandidate],
    *,
    skip_occupied_preferred: bool = True,
    shuffle_fallback: bool = True,
    rng: random.Random | None = None,
) -> tuple[list[SeatCandidate], list[SeatCandidate]]:
    """根据用户首选列表与房间实时座位快照，生成 ``(首选队列, 兜底队列)``。

    规则：
    - ``prefer_seats`` 按用户填写顺序归一化匹配；若不在房间内则跳过。
    - ``skip_occupied_preferred=True`` 时跳过实时快照中已明确 ``occupied`` / ``unavailable``
      的首选座；06:30:00 首个直击场景可传 ``False`` 以避免错过放座瞬间。
    - 兜底队列严格过滤掉 ``occupied`` 与 ``unavailable``（仅保留 ``free`` / ``unknown``），
      并在 ``shuffle_fallback=True`` 时随机打乱。
    """
    by_norm: dict[str, SeatCandidate] = {}
    for seat in room_seats:
        norm = normalize_seat_no(seat.seat_no)
        if norm and norm not in by_norm:
            by_norm[norm] = SeatCandidate(
                seat_no=norm,
                seat_id=seat.seat_id,
                room_id=seat.room_id,
                status=seat.status,
            )

    preferred: list[SeatCandidate] = []
    picked_norms: set[str] = set()
    for raw in prefer_seats:
        norm = normalize_seat_no(raw)
        if not norm or norm in picked_norms:
            continue
        candidate = by_norm.get(norm)
        if candidate is None:
            continue
        if skip_occupied_preferred and candidate.status in ("occupied", "unavailable"):
            continue
        preferred.append(candidate)
        picked_norms.add(norm)

    fallback = [
        seat
        for norm, seat in by_norm.items()
        if norm not in picked_norms and seat.status in ("free", "unknown")
    ]
    if shuffle_fallback and len(fallback) > 1:
        (rng or random).shuffle(fallback)

    return preferred, fallback


@dataclass(frozen=True)
class _SeatClaim:
    account: str
    start_time: str
    end_time: str


class SeatClaimCoordinator:
    """进程内多账号选座防撞协调器（线程安全）。

    仅在同房间、同座号且时间区间重叠时阻止第二个账号同时争抢同一座位；
    同一账号重复声明幂等通过，不重叠时段（如上午+下午接力）放行。
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._claims: dict[tuple[str, str], list[_SeatClaim]] = {}

    def try_claim(
        self,
        account: str,
        room_id: str,
        seat_no: str,
        start_time: str,
        end_time: str,
    ) -> bool:
        key = (room_id, normalize_seat_no(seat_no))
        with self._lock:
            existing = self._claims.get(key, [])
            for claim in existing:
                if claim.account == account:
                    return True
                if time_ranges_overlap(claim.start_time, claim.end_time, start_time, end_time):
                    return False
            existing.append(_SeatClaim(account=account, start_time=start_time, end_time=end_time))
            self._claims[key] = existing
            return True

    def release(self, account: str, room_id: str, seat_no: str) -> None:
        key = (room_id, normalize_seat_no(seat_no))
        with self._lock:
            existing = self._claims.get(key)
            if not existing:
                return
            remaining = [c for c in existing if c.account != account]
            if remaining:
                self._claims[key] = remaining
            else:
                self._claims.pop(key, None)

    def release_all(self, account: str) -> None:
        with self._lock:
            empty_keys: list[tuple[str, str]] = []
            for key, existing in self._claims.items():
                remaining = [c for c in existing if c.account != account]
                if remaining:
                    self._claims[key] = remaining
                else:
                    empty_keys.append(key)
            for key in empty_keys:
                self._claims.pop(key, None)
