"""登录图形验证码 OCR 求解器（纯 ONNX + Pillow + numpy，零 OpenCV 依赖）。

运行时优先直接加载随包精简的 ``ddddocr_lite/``（仅 ``common_old.onnx`` + ``charset_old.json``），
开发态若未生成精简目录则直接定位已安装 ``ddddocr`` 包内的 ``common_old.onnx`` 与 ``charsets.py``
（无需触发 ``ddddocr`` 顶层的 OpenCV 检查），兼容旧版 ``ddddocr`` 时再回退到 ``ddddocr.DdddOcr``。
"""
from __future__ import annotations

import base64
import importlib.util
import json
import threading
from io import BytesIO
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from PIL import Image

from core.logger import get_logger
from core.paths import resource_root

logger = get_logger(__name__)


def _load_charset_from_py(charsets_py: Path) -> list[str]:
    """从 ddddocr/charsets.py 加载 CHARSET_OLD，不触发 ddddocr 顶层 import。"""
    spec = importlib.util.spec_from_file_location("_ddddocr_charsets", charsets_py)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载字符集模块: {charsets_py}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    charset = getattr(mod, "CHARSET_OLD", None)
    if not isinstance(charset, list) or not charset:
        raise RuntimeError(f"{charsets_py} 中缺少有效的 CHARSET_OLD")
    return [str(c) for c in charset]


def _locate_lite_assets() -> tuple[Path, list[str]] | None:
    """定位 (common_old.onnx, CHARSET_OLD)；找不到时返回 None。"""
    # 1. 打包产物内的精简目录（仅 13MB common_old.onnx + ~30KB charset_old.json）
    lite_dir = resource_root() / "ddddocr_lite"
    lite_model = lite_dir / "common_old.onnx"
    lite_charset = lite_dir / "charset_old.json"
    if lite_model.is_file() and lite_charset.is_file():
        charset = json.loads(lite_charset.read_text(encoding="utf-8"))
        return lite_model, [str(c) for c in charset]

    # 2. 开发态：直接从已安装的 ddddocr 包读取模型与 charsets.py（绕过 cv2 检查）
    spec = importlib.util.find_spec("ddddocr")
    if spec and spec.origin:
        pkg_dir = Path(spec.origin).resolve().parent
        model_path = pkg_dir / "common_old.onnx"
        charsets_py = pkg_dir / "charsets.py"
        if model_path.is_file() and charsets_py.is_file():
            return model_path, _load_charset_from_py(charsets_py)

    return None


class _LiteOnnxOcr:
    """与 ddddocr 默认模式 (det=False, old=False, beta=False) 等价的轻量 OCR 引擎。"""

    def __init__(self, model_path: Path, charset: list[str]) -> None:
        ort.set_default_logger_severity(3)
        self._session = ort.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"]
        )
        self._input_name = self._session.get_inputs()[0].name
        self._charset = charset

    def classification(self, image: Image.Image) -> str:
        target_height = 64
        target_width = max(1, int(image.size[0] * (target_height / image.size[1])))
        gray = image.resize(
            (target_width, target_height), Image.Resampling.LANCZOS
        ).convert("L")
        arr = np.asarray(gray, dtype=np.float32) / 255.0
        blob = arr[np.newaxis, np.newaxis, :, :]

        output = self._session.run(None, {self._input_name: blob})[0]
        if output.ndim == 3:
            if output.shape[1] == 1:
                indices = np.argmax(output[:, 0, :], axis=1)
            else:
                indices = np.argmax(output[0, :, :], axis=1)
        else:
            indices = np.argmax(output, axis=-1).reshape(-1)

        chars: list[str] = []
        prev_idx: int | None = None
        charset_len = len(self._charset)
        for raw_idx in indices:
            idx = int(raw_idx)
            if idx != prev_idx and idx != 0 and 0 <= idx < charset_len:
                chars.append(self._charset[idx])
            prev_idx = idx
        return "".join(chars)


class CaptchaSolver:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._ocr: Any = None

    def _ensure_ocr(self) -> Any:
        if self._ocr is None:
            with self._lock:
                if self._ocr is None:
                    assets = _locate_lite_assets()
                    if assets is not None:
                        model_path, charset = assets
                        self._ocr = _LiteOnnxOcr(model_path, charset)
                    else:
                        import ddddocr

                        self._ocr = ddddocr.DdddOcr(
                            det=False, use_gpu=False, show_ad=False
                        )
        return self._ocr

    def solve_base64(self, base64_str: str) -> str:
        """解析 Base64 图片流"""
        try:
            image_bytes = base64.b64decode(base64_str)
            image = Image.open(BytesIO(image_bytes))
            return str(self._ensure_ocr().classification(image))
        except Exception as e:
            logger.error("❌ 验证码解析失败: %s", e)
            return ""


# 单例模式，全局用这就行
solver = CaptchaSolver()
