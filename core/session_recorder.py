"""纯 API 会话级可观测性与脱敏诊断产物记录器。

替代 v5 的浏览器截图与 MP4 录屏，在 ``logs/sessions/<ts>_<account>/`` 下产出：
1. ``http_trace.jsonl`` —— 强制白名单脱敏后的 HTTP 事务流水（绝不落盘密码/Token/Cookie）
2. ``<prio>_<seat>_<retry>_captcha_<ts>.png`` —— 拼合 target + bg + YOLO 候选框 + 预测点击红点
3. ``抢座顺序.txt`` —— 首选、实时空座统计与尝试队列清单
"""
from __future__ import annotations

import json
import re
import threading
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path
from typing import Any, Sequence

from PIL import Image, ImageDraw

from core.captcha_service import CaptchaSolveOutcome
from core.logger import get_logger

logger = get_logger(__name__)

BJ_TZ = timezone(timedelta(hours=8))

_SENSITIVE_KEY_RE = re.compile(
    r"(pass|passwd|pwd|secret|token|cookie|authorization|auth|credential|session|aes|sign|smtp_pass)",
    re.I,
)
_OPAQUE_LONG_RE = re.compile(r"^[A-Za-z0-9+/=_-]{65,}$")
_BASE64_DATA_URL_RE = re.compile(r"^data:image/[a-z0-9+.-]+;base64,", re.I)


def sanitize_for_trace(obj: Any, *, parent_key: str = "", depth: int = 0) -> Any:
    """递归脱敏任意结构化对象，确保密码/Token/Cookie/大段 base64 绝不落盘。"""
    if depth > 6:
        return "<TRUNCATED>"

    if isinstance(obj, dict):
        return {
            str(k): sanitize_for_trace(v, parent_key=str(k), depth=depth + 1)
            for k, v in obj.items()
        }

    if isinstance(obj, (list, tuple)):
        items = [sanitize_for_trace(x, parent_key=parent_key, depth=depth + 1) for x in obj[:20]]
        if len(obj) > 20:
            items.append(f"<... {len(obj) - 20} more>")
        return items

    if isinstance(obj, bytes):
        return f"<BYTES len={len(obj)}>"

    if _SENSITIVE_KEY_RE.search(parent_key):
        return "<REDACTED>"

    if isinstance(obj, str):
        if _BASE64_DATA_URL_RE.match(obj):
            return f"<BASE64_IMG len={len(obj)}>"
        if _OPAQUE_LONG_RE.match(obj):
            return f"<REDACTED_OPAQUE len={len(obj)}>"
        return obj

    return obj


class SessionRecorder:
    """单个抢座会话的脱敏追溯与诊断图记录器（所有 I/O 失败均降级吞掉，不打断主流程）。"""

    def __init__(self, session_dir: str | Path | None, account: str) -> None:
        self.session_dir: Path | None = Path(session_dir) if session_dir else None
        self.account = account
        self._lock = threading.Lock()
        if self.session_dir is not None:
            try:
                self.session_dir.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                logger.debug("[%s] 创建会话目录失败: %s", account, exc)
                self.session_dir = None

    def record_http(
        self,
        *,
        stage: str,
        method: str,
        path: str,
        status_code: int | None,
        rtt_ms: float,
        req_summary: dict[str, Any] | None = None,
        resp_summary: dict[str, Any] | None = None,
        biz_msg: str = "",
        error: str = "",
    ) -> None:
        """追加一条脱敏后的 HTTP 事务记录到 ``http_trace.jsonl``。"""
        if self.session_dir is None:
            return

        record: dict[str, Any] = {
            "ts": datetime.now(BJ_TZ).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
            "stage": stage,
            "method": method.upper(),
            "path": path,
            "status": status_code,
            "rtt_ms": round(float(rtt_ms), 2),
        }
        if biz_msg:
            record["biz_msg"] = biz_msg
        if error:
            record["error"] = error
        if req_summary is not None:
            record["req"] = sanitize_for_trace(req_summary)
        if resp_summary is not None:
            record["resp"] = sanitize_for_trace(resp_summary)

        trace_path = self.session_dir / "http_trace.jsonl"
        try:
            line = json.dumps(record, ensure_ascii=False) + "\n"
            with self._lock:
                with trace_path.open("a", encoding="utf-8") as fh:
                    fh.write(line)
        except OSError as exc:
            logger.debug("[%s] 写入 http_trace.jsonl 失败: %s", self.account, exc)

    def save_captcha_diagnostic(
        self,
        *,
        target_bytes: bytes,
        bg_bytes: bytes,
        outcome: CaptchaSolveOutcome,
        priority: int = 0,
        seat: str = "unknown",
        retry: int = 0,
    ) -> Path | None:
        """生成 target + bg + YOLO 候选点 + 预测点击红点的单张轻量诊断图。"""
        if self.session_dir is None:
            return None

        try:
            with Image.open(BytesIO(target_bytes)) as t_im:
                target_rgb = t_im.convert("RGB")
            with Image.open(BytesIO(bg_bytes)) as b_im:
                bg_rgb = b_im.convert("RGB")

            header_h = max(36, target_rgb.height + 8)
            footer_h = 22
            canvas_w = max(bg_rgb.width, target_rgb.width + 16, 280)
            canvas_h = header_h + bg_rgb.height + footer_h

            canvas = Image.new("RGB", (canvas_w, canvas_h), (245, 245, 245))
            canvas.paste(target_rgb, (8, (header_h - target_rgb.height) // 2))
            bg_y0 = header_h
            canvas.paste(bg_rgb, (0, bg_y0))

            draw = ImageDraw.Draw(canvas)

            # 绿色圆圈标出 YOLO 候选中心
            for idx, (cx, cy) in enumerate(outcome.candidates, start=1):
                py = bg_y0 + cy
                r = 12
                draw.ellipse((cx - r, py - r, cx + r, py + r), outline=(34, 197, 94), width=2)
                draw.text((cx + 10, py - 14), f"C{idx}", fill=(22, 163, 74))

            # 红色十字 + 序号标出最终点击顺序
            for order, (px, py_raw) in enumerate(outcome.points, start=1):
                py = bg_y0 + py_raw
                arm = 8
                draw.line((px - arm, py, px + arm, py), fill=(220, 38, 38), width=2)
                draw.line((px, py - arm, px, py + arm), fill=(220, 38, 38), width=2)
                draw.ellipse((px - 5, py - 5, px + 5, py + 5), outline=(220, 38, 38), width=2)
                draw.text((px + 7, py + 4), str(order), fill=(220, 38, 38))

            status_txt = (
                f"{outcome.kind} | ok={outcome.ok} | {outcome.elapsed_ms:.0f}ms"
                + (f" | {outcome.error}" if outcome.error else "")
            )
            draw.text((8, header_h + bg_rgb.height + 4), status_txt, fill=(40, 40, 40))

            ts = datetime.now(BJ_TZ).strftime("%Y%m%d_%H%M%S")
            out_path = self.session_dir / f"{priority}_{seat}_{retry}_captcha_{ts}.png"
            canvas.save(out_path, format="PNG", optimize=True)
            return out_path
        except Exception as exc:
            logger.debug("[%s] 生成验证码诊断图失败: %s", self.account, exc)
            return None

    def write_seat_plan(
        self,
        *,
        campus: str,
        room: str,
        prefer_seats: Sequence[str],
        fallback_seats: Sequence[str],
        start_time: str,
        end_time: str,
        total_room_seats: int | None = None,
        free_room_seats: int | None = None,
    ) -> Path | None:
        """写出本次会话的 ``抢座顺序.txt``（兼容 v5 格式并附加实时空座统计）。"""
        if self.session_dir is None:
            return None
        plan_path = self.session_dir / "抢座顺序.txt"
        try:
            lines = [
                f"账号: {self.account}",
                f"校区: {campus}",
                f"自习室: {room}",
                f"时间: {datetime.now(BJ_TZ).strftime('%Y-%m-%d %H:%M:%S')}",
                f"开始: {start_time}  结束: {end_time}",
            ]
            if total_room_seats is not None and free_room_seats is not None:
                lines.append(f"实时空座: {free_room_seats} / {total_room_seats}")
            lines.append("")
            lines.append("=== 抢座顺序 ===")
            seq = 1
            for s in prefer_seats:
                lines.append(f"{seq}. [首选] 座位 {s}")
                seq += 1
            for s in fallback_seats:
                lines.append(f"{seq}. [兜底] 座位 {s}")
                seq += 1
            lines.append("")
            lines.append(f"共 {len(prefer_seats) + len(fallback_seats)} 个座位待尝试")
            plan_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return plan_path
        except OSError as exc:
            logger.debug("[%s] 写入抢座顺序失败: %s", self.account, exc)
            return None
