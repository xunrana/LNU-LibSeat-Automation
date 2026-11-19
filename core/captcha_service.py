"""点选验证码统一推理服务（Click1 + Click3）。

从 ``logic/booker.py`` 抽离模型预加载、线程锁与自适应路由逻辑，让纯 API
引擎、现有流程与未来 Web 服务共用同一套零浏览器依赖的验证码求解服务。
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from datetime import datetime, time as dt_time, timedelta, timezone
from io import BytesIO
from typing import Any, Callable, Literal

from PIL import Image

from core.logger import get_logger

logger = get_logger(__name__)

CaptchaKind = Literal["click1", "click3"]

BJ_TZ = timezone(timedelta(hours=8))
RUSH_WINDOW_START = dt_time(6, 30, 0)
RUSH_WINDOW_END = dt_time(6, 35, 0)

# 与训练/推理裁剪槽位保持一致：
# - Click3: 3 个字符位于 x=[5:25], [25:45], [45:65], y=[5:27]
# - Click1: 1 个字符居中位于 x=[25:45], y=[5:27]
_SLOT_Y1 = 5
_SLOT_Y2 = 27
_SLOT_XS = ((5, 25), (25, 45), (45, 65))
_INK_GRAY_THRESHOLD = 180
_SLOT_PRESENT_RATIO = 0.02
_SLOT_EMPTY_RATIO = 0.01


@dataclass(frozen=True)
class CaptchaSolveOutcome:
    """统一求解结果，同时承载坐标与诊断元数据（供 SessionRecorder 画叠加图）。"""

    ok: bool
    kind: CaptchaKind
    points: tuple[tuple[int, int], ...] = ()
    candidates: tuple[tuple[int, int], ...] = ()
    candidate_confidences: tuple[float, ...] = ()
    similarity: Any = None
    elapsed_ms: float = 0.0
    error: str = ""


def _in_rush_window(now: datetime | None = None) -> bool:
    current = now.astimezone(BJ_TZ) if now is not None else datetime.now(BJ_TZ)
    return RUSH_WINDOW_START <= current.time() <= RUSH_WINDOW_END


def _slot_ink_ratio(gray_img: Image.Image, x1: int, y1: int, x2: int, y2: int) -> float:
    crop = gray_img.crop((x1, y1, x2, y2))
    raw = crop.tobytes()
    if not raw:
        return 0.0
    dark = sum(1 for p in raw if p < _INK_GRAY_THRESHOLD)
    return dark / len(raw)


def detect_captcha_kind(
    target_bytes: bytes | None = None,
    *,
    hint_count: int | None = None,
    now: datetime | None = None,
) -> CaptchaKind:
    """自适应判定验证码为 click1（1 字）还是 click3（3 字）。

    判定优先级：
    1. 接口显式告知的点数 ``hint_count``（1 或 3）
    2. ``target_bytes`` 左右槽位笔迹占空比（Click3 三槽均有字，Click1 仅中槽有字）
    3. 兜底回退北京时间 ``06:30:00–06:35:00`` 窗口规则
    """
    if hint_count == 3:
        return "click3"
    if hint_count == 1:
        return "click1"

    if target_bytes:
        try:
            with Image.open(BytesIO(target_bytes)) as img:
                gray = img.convert("L")
                w, h = gray.size
                if w >= 65 and h >= _SLOT_Y2:
                    left_ratio = _slot_ink_ratio(gray, _SLOT_XS[0][0], _SLOT_Y1, _SLOT_XS[0][1], _SLOT_Y2)
                    mid_ratio = _slot_ink_ratio(gray, _SLOT_XS[1][0], _SLOT_Y1, _SLOT_XS[1][1], _SLOT_Y2)
                    right_ratio = _slot_ink_ratio(gray, _SLOT_XS[2][0], _SLOT_Y1, _SLOT_XS[2][1], _SLOT_Y2)
                    if left_ratio >= _SLOT_PRESENT_RATIO and right_ratio >= _SLOT_PRESENT_RATIO:
                        return "click3"
                    if (
                        mid_ratio >= _SLOT_PRESENT_RATIO
                        and left_ratio < _SLOT_EMPTY_RATIO
                        and right_ratio < _SLOT_EMPTY_RATIO
                    ):
                        return "click1"
        except Exception as exc:
            logger.debug("target 图自适应分类失败，回退时间窗口规则: %s", exc)

    return "click3" if _in_rush_window(now) else "click1"


def _default_click1_solver() -> Any:
    from core.captcha_click1_yolo4_siamese import get_click1_yolo4_siamese_solver

    return get_click1_yolo4_siamese_solver()


def _default_click3_solver() -> Any:
    from core.captcha_yolo4_siamese import get_yolo4_siamese_solver

    return get_yolo4_siamese_solver()


class CaptchaService:
    """线程安全的本地 ONNX 点选验证码求解服务。"""

    def __init__(
        self,
        *,
        click1_factory: Callable[[], Any] | None = None,
        click3_factory: Callable[[], Any] | None = None,
    ) -> None:
        self._click1_factory = click1_factory or _default_click1_solver
        self._click3_factory = click3_factory or _default_click3_solver
        self._lock = threading.Lock()
        self._preloaded = False

    @property
    def preloaded(self) -> bool:
        return self._preloaded

    def preload(self, account: str = "system") -> bool:
        """预热 Click3 + Click1 两个本地 ONNX 求解器，避免首次求解冷启动。"""
        if self._preloaded:
            return True

        started = time.monotonic()
        try:
            with self._lock:
                if self._preloaded:
                    return True
                self._click3_factory().warmup()
                self._click1_factory().warmup()
                self._preloaded = True
            logger.info(
                "✅ [%s] 验证码模型预加载完成 (click3+click1)，用时 %.2fs",
                account,
                time.monotonic() - started,
            )
            return True
        except Exception as exc:
            logger.warning("⚠️ [%s] 验证码模型预加载失败: %s", account, exc)
            return False

    def solve(
        self,
        target_bytes: bytes,
        bg_bytes: bytes,
        *,
        kind: CaptchaKind | None = None,
        hint_count: int | None = None,
        now: datetime | None = None,
    ) -> CaptchaSolveOutcome:
        """端到端求解点选验证码，返回带候选与置信度的结构化结果。"""
        resolved_kind: CaptchaKind = kind or detect_captcha_kind(
            target_bytes, hint_count=hint_count, now=now,
        )
        started = time.monotonic()
        try:
            with self._lock:
                if resolved_kind == "click3":
                    solver = self._click3_factory()
                    detail = solver.solve(target_bytes, bg_bytes, return_details=True)
                    elapsed_ms = (time.monotonic() - started) * 1000.0
                    if detail is None or len(detail.points) != 3:
                        return CaptchaSolveOutcome(
                            ok=False,
                            kind="click3",
                            elapsed_ms=elapsed_ms,
                            error="click3_no_solution",
                        )
                    return CaptchaSolveOutcome(
                        ok=True,
                        kind="click3",
                        points=tuple((int(x), int(y)) for x, y in detail.points),
                        candidates=tuple((int(x), int(y)) for x, y in detail.candidates),
                        candidate_confidences=tuple(float(c) for c in detail.candidate_confidences),
                        similarity=detail.similarity,
                        elapsed_ms=elapsed_ms,
                    )

                solver = self._click1_factory()
                detail = solver.solve(target_bytes, bg_bytes, return_details=True)
                elapsed_ms = (time.monotonic() - started) * 1000.0
                if detail is None:
                    return CaptchaSolveOutcome(
                        ok=False,
                        kind="click1",
                        elapsed_ms=elapsed_ms,
                        error="click1_no_solution",
                    )
                px, py = detail.point
                return CaptchaSolveOutcome(
                    ok=True,
                    kind="click1",
                    points=((int(px), int(py)),),
                    candidates=tuple((int(x), int(y)) for x, y in detail.candidates),
                    candidate_confidences=tuple(float(c) for c in detail.candidate_confidences),
                    similarity=detail.similarity,
                    elapsed_ms=elapsed_ms,
                )
        except Exception as exc:
            elapsed_ms = (time.monotonic() - started) * 1000.0
            logger.warning("⚠️ 验证码求解异常 (%s): %s", resolved_kind, exc)
            return CaptchaSolveOutcome(
                ok=False,
                kind=resolved_kind,
                elapsed_ms=elapsed_ms,
                error=f"{type(exc).__name__}: {exc}",
            )


_default_service: CaptchaService | None = None


def get_captcha_service() -> CaptchaService:
    global _default_service
    if _default_service is None:
        _default_service = CaptchaService()
    return _default_service


def preload_captcha_models(account: str = "system") -> bool:
    return get_captcha_service().preload(account=account)
