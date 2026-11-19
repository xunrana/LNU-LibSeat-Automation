"""core.captcha_service 自适应路由与统一推理封装单元测试。"""
from dataclasses import dataclass
from datetime import datetime
from io import BytesIO

from PIL import Image, ImageDraw

from core.captcha_service import BJ_TZ, CaptchaService, detect_captcha_kind


def _make_target_png(slots: tuple[int, ...]) -> bytes:
    """生成 70x32 白底目标图，在指定槽位 (0=左, 1=中, 2=右) 绘制黑色字块。"""
    img = Image.new("RGB", (70, 32), (255, 255, 255))
    draw = ImageDraw.Draw(img)
    boxes = ((8, 8, 22, 24), (28, 8, 42, 24), (48, 8, 62, 24))
    for slot in slots:
        draw.rectangle(boxes[slot], fill=(15, 15, 15))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def test_detect_captcha_kind_prefers_explicit_hint():
    click1_img = _make_target_png((1,))
    click3_img = _make_target_png((0, 1, 2))
    assert detect_captcha_kind(click1_img, hint_count=3) == "click3"
    assert detect_captcha_kind(click3_img, hint_count=1) == "click1"


def test_detect_captcha_kind_infers_from_target_slots_regardless_of_clock():
    non_rush = datetime(2026, 11, 19, 14, 0, 0, tzinfo=BJ_TZ)
    rush = datetime(2026, 11, 19, 6, 31, 0, tzinfo=BJ_TZ)

    assert detect_captcha_kind(_make_target_png((0, 1, 2)), now=non_rush) == "click3"
    assert detect_captcha_kind(_make_target_png((1,)), now=rush) == "click1"


def test_detect_captcha_kind_falls_back_to_rush_window():
    rush = datetime(2026, 11, 19, 6, 30, 30, tzinfo=BJ_TZ)
    non_rush = datetime(2026, 11, 19, 10, 0, 0, tzinfo=BJ_TZ)

    assert detect_captcha_kind(b"invalid-bytes", now=rush) == "click3"
    assert detect_captcha_kind(b"invalid-bytes", now=non_rush) == "click1"


@dataclass
class _FakeClick1Detail:
    point: tuple[int, int]
    candidates: list[tuple[int, int]]
    candidate_confidences: list[float]
    similarity: list[float]


@dataclass
class _FakeClick3Detail:
    points: list[tuple[int, int]]
    candidates: list[tuple[int, int]]
    candidate_confidences: list[float]
    similarity: list[list[float]]


class _FakeSolver:
    def __init__(self, result):
        self._result = result
        self.warmups = 0
        self.calls = 0

    def warmup(self):
        self.warmups += 1

    def solve(self, target_bytes, bg_bytes, return_details=False):
        self.calls += 1
        return self._result


def test_captcha_service_preload_is_idempotent_and_routes_solvers():
    s1 = _FakeSolver(_FakeClick1Detail((50, 60), [(10, 20), (50, 60)], [0.9, 0.95], [0.1, 0.9]))
    s3 = _FakeSolver(
        _FakeClick3Detail(
            [(10, 20), (30, 40), (50, 60)],
            [(10, 20), (30, 40), (50, 60), (70, 80)],
            [0.9, 0.8, 0.85, 0.7],
            [[0.9, 0.1, 0.1, 0.1]],
        )
    )
    svc = CaptchaService(click1_factory=lambda: s1, click3_factory=lambda: s3)

    assert svc.preload("acc1") is True
    assert svc.preload("acc2") is True
    assert s1.warmups == 1 and s3.warmups == 1

    out1 = svc.solve(_make_target_png((1,)), b"bg")
    assert out1.ok is True
    assert out1.kind == "click1"
    assert out1.points == ((50, 60),)

    out3 = svc.solve(_make_target_png((0, 1, 2)), b"bg")
    assert out3.ok is True
    assert out3.kind == "click3"
    assert out3.points == ((10, 20), (30, 40), (50, 60))


def test_captcha_service_handles_none_and_exception():
    class _BrokenSolver:
        def warmup(self):
            pass

        def solve(self, *_a, **_kw):
            raise RuntimeError("ort exploded")

    svc = CaptchaService(click1_factory=lambda: _FakeSolver(None), click3_factory=_BrokenSolver)
    r1 = svc.solve(b"t", b"b", kind="click1")
    assert r1.ok is False and r1.error == "click1_no_solution"

    r3 = svc.solve(b"t", b"b", kind="click3")
    assert r3.ok is False and "RuntimeError" in r3.error
