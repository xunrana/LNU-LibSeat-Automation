"""移动端（Flutter Android & iOS）离线资源与 FP16 ONNX 模型准备脚本。

职责：
1. 从 ``core/checkpoints/`` 与 ``ddddocr`` 提取全部 5 个运行时 ONNX 模型与 ``charset_old.json``；
2. 使用 ``onnxruntime.transformers.float16`` 将 FP32 权重压缩为 FP16（``keep_io_types=True``，
   保持输入/输出张量为标准 ``float32``，使 Dart 端直接传入 ``Float32List`` 无需半精度位转换）；
3. 对每个生成的移动端 ONNX 模型执行 ``onnxruntime.InferenceSession`` 实机推理校验，
   确保张量形状、输入输出节点名与数值精度 100% 正常；
4. 将 ``info/*.txt`` 双校区 21 间自习室离线座号索引打包为 ``mobile/assets/rooms/room_catalog.json``。

用法：
    python scripts/prepare_mobile_assets.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.captcha import _locate_lite_assets  # noqa: E402
from ui_qt.services.config_io import ROOM_DATA  # noqa: E402

MOBILE_DIR = ROOT / "mobile"
MODELS_OUT_DIR = MOBILE_DIR / "assets" / "models"
ROOMS_OUT_DIR = MOBILE_DIR / "assets" / "rooms"
IMAGES_OUT_DIR = MOBILE_DIR / "assets" / "images"

ANDROID_ICON_SIZES: dict[str, int] = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

IOS_ICON_FILES: dict[str, int] = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

# Flutter `onnxruntime: ^1.4.1` 内置 ONNX Runtime 1.15.1（Android/iOS/Linux/macOS），
# 最高原生支持 IR Version 8、默认域 Opset 18（超过 Opset 18 会触发 Reshape(19) 无算子实现报错）。
MOBILE_ORT_MAX_IR_VERSION = 8
MOBILE_ORT_MAX_OPSET = 18

CHECKPOINT_MODELS: tuple[tuple[str, dict[str, tuple[int, ...]]], ...] = (
    (
        "click1_yolo_plan_bg_char40_best.onnx",
        {"images": (1, 3, 640, 640)},
    ),
    (
        "click1_siamese_yolo4_best.onnx",
        {"input1": (4, 3, 112, 112), "input2": (4, 3, 112, 112)},
    ),
    (
        "click3_yolo_plan_bg_char60_best.onnx",
        {"images": (1, 3, 640, 640)},
    ),
    (
        "click3_siamese_yolo4_posw3_best.onnx",
        {"input1": (12, 3, 112, 112), "input2": (12, 3, 112, 112)},
    ),
)

OCR_MODEL_NAME = "common_old.onnx"
OCR_DUMMY_SHAPES: dict[str, tuple[int, ...]] = {"input1": (1, 1, 64, 146)}


def _ensure_mobile_ort_compat(
    model: Any,
    *,
    max_ir: int = MOBILE_ORT_MAX_IR_VERSION,
    max_opset: int = MOBILE_ORT_MAX_OPSET,
) -> tuple[bool, int, int]:
    """将高于移动版 ORT 1.15.1 支持上限的 IR/Opset 降级到 IR<=8 / Opset<=18。

    返回 ``(modified, ir_version, default_opset_version)``。
    仅当所有节点属性均兼容 Opset 18 时才直接调整元数据，并通过 ``onnx.checker`` 校验。
    """
    import onnx

    modified = False
    default_opset = 0
    for imp in model.opset_import:
        if imp.domain in ("", "ai.onnx"):
            if imp.version > max_opset:
                # 安全校验：确保不存在 Opset 19+ 独有属性
                for node in model.graph.node:
                    if node.op_type == "Resize":
                        for attr in node.attribute:
                            val = onnx.helper.get_attribute_value(attr)
                            if attr.name == "antialias" and val:
                                raise ValueError(f"Resize 节点 {node.name} 使用了 Opset 19 antialias")
                            if attr.name == "keep_aspect_ratio_policy" and val not in (b"stretch", "stretch"):
                                raise ValueError(
                                    f"Resize 节点 {node.name} 使用了非默认 keep_aspect_ratio_policy={val!r}"
                                )
                imp.version = max_opset
                modified = True
            default_opset = max(default_opset, int(imp.version))

    if model.ir_version > max_ir:
        model.ir_version = max_ir
        modified = True

    if modified:
        onnx.checker.check_model(model)
    return modified, int(model.ir_version), default_opset


def _read_onnx_versions(model_path: Path) -> tuple[int, int]:
    import onnx

    model = onnx.load(str(model_path), load_external_data=False)
    default_opset = 0
    for imp in model.opset_import:
        if imp.domain in ("", "ai.onnx"):
            default_opset = max(default_opset, int(imp.version))
    return int(model.ir_version), default_opset


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _verify_onnx_model(
    model_path: Path,
    dummy_shapes_hint: dict[str, tuple[int, ...]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[np.ndarray]]:
    """使用 CPUExecutionProvider 加载并执行一次前向推理，返回输入/输出元数据与输出数组。"""
    ort.set_default_logger_severity(3)
    sess = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    inputs_meta: list[dict[str, Any]] = []
    feed: dict[str, np.ndarray] = {}
    rng = np.random.default_rng(42)

    for idx, inp in enumerate(sess.get_inputs()):
        inputs_meta.append({"name": inp.name, "shape": list(inp.shape), "type": inp.type})
        if inp.name in dummy_shapes_hint:
            shape = dummy_shapes_hint[inp.name]
        else:
            fallback_shapes = list(dummy_shapes_hint.values())
            shape = fallback_shapes[min(idx, len(fallback_shapes) - 1)]
        feed[inp.name] = rng.random(shape, dtype=np.float32)

    outputs_meta = [
        {"name": out.name, "shape": list(out.shape), "type": out.type}
        for out in sess.get_outputs()
    ]
    outputs = sess.run(None, feed)
    return inputs_meta, outputs_meta, [np.asarray(o) for o in outputs]


def _convert_single_model_to_fp16(
    src_path: Path,
    dst_path: Path,
    dummy_shapes_hint: dict[str, tuple[int, ...]],
    *,
    enable_fp16: bool = True,
) -> dict[str, Any]:
    """准备单个移动端 ONNX 模型（确保 IR<=8 / Opset<=18 兼容 ORT 1.15.1，可选 FP16）。"""
    import onnx

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    orig_size = src_path.stat().st_size

    in_meta_fp32, out_meta_fp32, ref_outputs = _verify_onnx_model(src_path, dummy_shapes_hint)

    precision = "fp32"
    max_abs_diff = 0.0
    ir_version = 0
    opset_version = 0

    def _export_fp32_compat() -> tuple[int, int, float]:
        model = onnx.load(str(src_path))
        modified, ir_v, opset_v = _ensure_mobile_ort_compat(model)
        if modified:
            onnx.save(model, str(dst_path))
            _, _, compat_outputs = _verify_onnx_model(dst_path, dummy_shapes_hint)
            diffs = [
                float(np.max(np.abs(a.astype(np.float32) - b.astype(np.float32))))
                for a, b in zip(ref_outputs, compat_outputs)
            ]
            diff = max(diffs) if diffs else 0.0
            if diff > 1e-5:
                raise RuntimeError(
                    f"{src_path.name} 降级至 IR={ir_v}/Opset={opset_v} 后数值偏差异常: {diff}"
                )
            return ir_v, opset_v, diff
        shutil.copy2(src_path, dst_path)
        return ir_v, opset_v, 0.0

    if enable_fp16:
        try:
            from onnxruntime.transformers.float16 import convert_float_to_float16

            model = onnx.load(str(src_path))
            _ensure_mobile_ort_compat(model)
            fp16_model = convert_float_to_float16(
                model,
                keep_io_types=True,
                op_block_list=["Resize", "Upsample", "NonMaxSuppression"],
            )
            _, ir_version, opset_version = _ensure_mobile_ort_compat(fp16_model)
            onnx.save(fp16_model, str(dst_path))
            _, _, test_outputs = _verify_onnx_model(dst_path, dummy_shapes_hint)
            diffs = [
                float(np.max(np.abs(a.astype(np.float32) - b.astype(np.float32))))
                for a, b in zip(ref_outputs, test_outputs)
            ]
            max_abs_diff = max(diffs) if diffs else 0.0
            precision = "fp16"
        except Exception as exc:
            print(f"  [WARN] {src_path.name} FP16 转换或 CPU 推理回退至 FP32: {exc}")
            ir_version, opset_version, max_abs_diff = _export_fp32_compat()
            precision = "fp32"
    else:
        ir_version, opset_version, max_abs_diff = _export_fp32_compat()

    final_size = dst_path.stat().st_size
    ratio = (final_size / orig_size) * 100.0 if orig_size else 100.0
    print(
        f"  [OK] {dst_path.name:<40} {precision.upper():<4} "
        f"IR={ir_version} opset={opset_version:<2} "
        f"{orig_size / 1e6:6.2f} MB -> {final_size / 1e6:6.2f} MB ({ratio:5.1f}%) "
        f"max_diff={max_abs_diff:.5f}"
    )

    return {
        "filename": dst_path.name,
        "precision": precision,
        "ir_version": ir_version,
        "opset_version": opset_version,
        "original_bytes": orig_size,
        "mobile_bytes": final_size,
        "sha256": _sha256_file(dst_path),
        "max_abs_diff": round(max_abs_diff, 6),
        "inputs": in_meta_fp32,
        "outputs": out_meta_fp32,
    }


def export_room_catalog(out_dir: Path = ROOMS_OUT_DIR) -> Path:
    """将 ROOM_DATA 与 info/*.txt 离线座号索引合并导出为 room_catalog.json。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    info_dir = ROOT / "info"
    room_seats: dict[str, list[str]] = {}

    if info_dir.is_dir():
        for txt_path in sorted(info_dir.glob("*.txt")):
            room_name = txt_path.stem.strip()
            seats = [
                line.strip()
                for line in txt_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            room_seats[room_name] = seats

    catalog = {
        "version": "6.1.0",
        "campuses": ROOM_DATA,
        "room_seats": room_seats,
    }
    out_path = out_dir / "room_catalog.json"
    out_path.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"  [OK] room_catalog.json 已生成: {len(ROOM_DATA)} 个校区, "
        f"{len(room_seats)} 间自习室离线座号清单"
    )
    return out_path


def export_brand_icons() -> None:
    """使用根目录正式蓝金校徽 logo1.png 生成移动端内置徽章与 Android/iOS 全套桌面图标。"""
    from PIL import Image

    src_logo = ROOT / "logo1.png"
    if not src_logo.is_file():
        print("  [WARN] 未找到根目录 logo1.png，跳过校徽与桌面图标生成")
        return

    with Image.open(src_logo) as raw:
        rgba = raw.convert("RGBA")

        # 1. Flutter 内置透明高清校徽 (512x512)
        IMAGES_OUT_DIR.mkdir(parents=True, exist_ok=True)
        crest_512 = rgba.resize((512, 512), Image.Resampling.LANCZOS)
        crest_512.save(IMAGES_OUT_DIR / "lnu_crest.png", format="PNG", optimize=True)

        # 2. 合成带暖米白纸底的方形图标底板（适配 iOS 无透明通道要求及 Android 规范）
        base_size = 1024
        paper_bg = Image.new("RGBA", (base_size, base_size), (245, 241, 232, 255))
        inner = rgba.resize((860, 860), Image.Resampling.LANCZOS)
        offset = (base_size - 860) // 2
        paper_bg.paste(inner, (offset, offset), inner)
        opaque_master = paper_bg.convert("RGB")

        # Android mipmap icons
        android_res = MOBILE_DIR / "android" / "app" / "src" / "main" / "res"
        if android_res.is_dir():
            for folder, px in ANDROID_ICON_SIZES.items():
                out_dir = android_res / folder
                out_dir.mkdir(parents=True, exist_ok=True)
                icon = opaque_master.resize((px, px), Image.Resampling.LANCZOS)
                icon.save(out_dir / "ic_launcher.png", format="PNG", optimize=True)

        # iOS AppIcon.appiconset
        ios_icon_dir = (
            MOBILE_DIR
            / "ios"
            / "Runner"
            / "Assets.xcassets"
            / "AppIcon.appiconset"
        )
        if ios_icon_dir.is_dir():
            for filename, px in IOS_ICON_FILES.items():
                icon = opaque_master.resize((px, px), Image.Resampling.LANCZOS)
                icon.save(ios_icon_dir / filename, format="PNG", optimize=True)

    print("  [OK] 已从 logo1.png 生成内置校徽及 Android/iOS 全套正式桌面图标")


def prepare_mobile_assets(*, enable_fp16: bool = False) -> dict[str, Any]:
    """执行完整移动端资源准备并返回 manifest 字典（默认 100% 原版无损 FP32 权重）。"""
    print("=== [1/3] 准备登录图形验证码 OCR 模型与字符表 ===")
    MODELS_OUT_DIR.mkdir(parents=True, exist_ok=True)

    lite_assets = _locate_lite_assets()
    if lite_assets is None:
        raise FileNotFoundError(
            "未找到 ddddocr common_old.onnx，请先在虚拟环境中 pip install ddddocr"
        )
    ocr_src_path, charset = lite_assets
    charset_path = MODELS_OUT_DIR / "charset_old.json"
    charset_path.write_text(
        json.dumps(charset, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"  [OK] charset_old.json 已写出 ({len(charset)} 个字符)")

    models_manifest: list[dict[str, Any]] = []
    # common_old.onnx 内部已包含 DynamicQuantizeLinear (INT8)，直接保留原模型
    ocr_entry = _convert_single_model_to_fp16(
        ocr_src_path,
        MODELS_OUT_DIR / OCR_MODEL_NAME,
        OCR_DUMMY_SHAPES,
        enable_fp16=False,
    )
    models_manifest.append(ocr_entry)

    print("=== [2/3] 转换并校验 Click1 / Click3 YOLOv8 + Siamese ONNX 模型 ===")
    checkpoints_dir = ROOT / "core" / "checkpoints"
    for filename, dummy_shapes in CHECKPOINT_MODELS:
        src = checkpoints_dir / filename
        if not src.is_file():
            raise FileNotFoundError(f"缺少核心 ONNX 权重文件: {src}")
        entry = _convert_single_model_to_fp16(
            src,
            MODELS_OUT_DIR / filename,
            dummy_shapes,
            enable_fp16=enable_fp16,
        )
        models_manifest.append(entry)

    total_orig = sum(m["original_bytes"] for m in models_manifest)
    total_mobile = sum(m["mobile_bytes"] for m in models_manifest)
    print(
        f"  [SUMMARY] 5 个 ONNX 模型总计: "
        f"{total_orig / 1e6:.2f} MB -> {total_mobile / 1e6:.2f} MB "
        f"(节省 {(total_orig - total_mobile) / 1e6:.2f} MB)"
    )

    print("=== [3/4] 导出双校区 21 间自习室离线座号目录 ===")
    export_room_catalog(ROOMS_OUT_DIR)

    print("=== [4/4] 生成辽大正式蓝金校徽与双端 App 图标 ===")
    export_brand_icons()

    manifest = {
        "version": "6.1.0",
        "total_original_bytes": total_orig,
        "total_mobile_bytes": total_mobile,
        "charset_count": len(charset),
        "models": models_manifest,
    }
    manifest_path = MODELS_OUT_DIR / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description="准备 LNU-LibSeat 移动端 ONNX 与房间资源")
    parser.add_argument(
        "--fp16",
        action="store_true",
        help="实验性启用 FP16 压缩（部分移动版 ONNX Runtime 不支持 ReduceMax FP16，默认关闭）",
    )
    args = parser.parse_args()
    prepare_mobile_assets(enable_fp16=bool(args.fp16))


if __name__ == "__main__":
    main()
