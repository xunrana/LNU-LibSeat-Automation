"""
LNU-LibSeat-Automation Android 本地打包脚本（精简 FP16 独立端侧版）
===================================================================
在本地 Windows 或 macOS 上将 `mobile/` 打包为独立运行的 Android 64 位安装包 (`.apk`)。
不依赖 GitHub Actions，不依赖远程服务器，内置 5 个 FP16/INT8 本地 ONNX 验证码模型。

流程：
    1. 自动执行 `scripts/prepare_mobile_assets.py`（将 ONNX 权重转为 FP16，总计减重 ~73MB，
       并同步 `info/` 21 间自习室离线座号索引到 `mobile/assets/rooms/room_catalog.json`）
    2. 自动执行 `scripts/dump_test_vectors.py`（导出跨语言协议测试向量）
    3. 若首次拉取尚未生成 Gradle 包装器，自动执行 `flutter create` 初始化原生壳并保留自定义保活代码
    4. 执行 `flutter pub get` 与 `flutter test`（校验 AES/HMAC/策略单测）
    5. 执行 `flutter build apk --release --target-platform android-arm64 --split-per-abi`

用法：
    python build_android.py
    python build_android.py --prepare-only   # 仅准备 FP16 ONNX 资源与测试向量

产物：
    dist/辽宁大学图书馆座位预约.apk
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MOBILE_DIR = ROOT / "mobile"
DIST_DIR = ROOT / "dist"
APP_VERSION = "v6.1.0"
APK_OUT_NAME = "辽宁大学图书馆座位预约.apk"

CUSTOM_FILES_TO_PRESERVE = (
    "pubspec.yaml",
    "analysis_options.yaml",
    "lib/main.dart",
    "test/widget_test.dart",
    "android/settings.gradle.kts",
    "android/build.gradle.kts",
    "android/gradle.properties",
    "android/app/build.gradle.kts",
    "android/app/src/main/AndroidManifest.xml",
    "android/app/src/main/res/xml/network_security_config.xml",
    "android/app/src/main/kotlin/com/xunrana/lnulibseat/MainActivity.kt",
    "ios/Runner/Info.plist",
    "ios/Runner/AppDelegate.swift",
)


def _find_flutter() -> str | None:
    found = shutil.which("flutter") or shutil.which("flutter.bat")
    if found:
        return found
    home = Path.home()
    candidates = [
        home / "develop" / "flutter" / "bin" / "flutter.bat",
        home / "develop" / "flutter" / "bin" / "flutter",
        home / "flutter" / "bin" / "flutter.bat",
        home / "flutter" / "bin" / "flutter",
        Path("C:/src/flutter/bin/flutter.bat"),
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    return None


def _run(cmd: list[str], cwd: Path = ROOT) -> None:
    print(f"  $ {' '.join(cmd)}")
    subprocess.run(cmd, cwd=str(cwd), check=True)


def ensure_flutter_platform_scaffold(flutter_bin: str) -> None:
    """若 mobile/android/gradlew 尚未生成，调用 flutter create 补齐原生工程骨架并恢复自定义源码。"""
    gradle_check = MOBILE_DIR / "android" / "build.gradle"
    gradle_kts_check = MOBILE_DIR / "android" / "build.gradle.kts"
    if gradle_check.exists() or gradle_kts_check.exists():
        return

    print("=== [Bootstrap] 首次构建：正在通过 flutter create 生成 Android/iOS 原生 Gradle/Xcode 骨架 ===")
    backups: dict[str, bytes] = {}
    for rel in CUSTOM_FILES_TO_PRESERVE:
        p = MOBILE_DIR / rel
        if p.is_file():
            backups[rel] = p.read_bytes()

    _run(
        [
            flutter_bin,
            "create",
            "--platforms=android,ios",
            "--org",
            "com.xunrana.lnulibseat",
            "--project-name",
            "lnu_libseat_mobile",
            ".",
        ],
        cwd=MOBILE_DIR,
    )

    for rel, content in backups.items():
        p = MOBILE_DIR / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)

    dup_kt_dir = (
        MOBILE_DIR
        / "android"
        / "app"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "xunrana"
        / "lnulibseat"
        / "lnu_libseat_mobile"
    )
    if dup_kt_dir.exists():
        shutil.rmtree(dup_kt_dir, ignore_errors=True)
    print("  [OK] 原生工程骨架生成完毕，已还原自定义保活服务与明文 HTTP 配置")


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 LNU-LibSeat Android APK")
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="仅准备 FP16 ONNX 模型、自习室字典与跨语言测试向量，不调用 Flutter 编译",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="跳过 flutter test 离线单测",
    )
    args = parser.parse_args()

    from scripts.dump_test_vectors import main as dump_vectors_main
    from scripts.prepare_mobile_assets import prepare_mobile_assets

    print("=================================================================")
    print(f"  LNU-LibSeat 手机端 Android 构建流水线 ({APP_VERSION} · 原版无损 FP32 模型)")
    print("=================================================================")
    prepare_mobile_assets(enable_fp16=False)
    dump_vectors_main()

    if args.prepare_only:
        print("\n[DONE] --prepare-only 已完成所有移动端 FP16 模型与测试向量准备。")
        return

    flutter_bin = _find_flutter()
    if not flutter_bin:
        print(
            "\n[ERROR] 未在 PATH 中检测到 `flutter` 命令！\n"
            "请先安装 Flutter SDK (https://docs.flutter.dev/get-started/install) 并配置 Android SDK，\n"
            "然后再重新运行 `python build_android.py`。",
            file=sys.stderr,
        )
        sys.exit(1)

    ensure_flutter_platform_scaffold(flutter_bin)

    print("\n=== [Step 4] 拉取 Dart 依赖并执行跨语言契约单测 ===")
    _run([flutter_bin, "pub", "get"], cwd=MOBILE_DIR)
    if not args.skip_tests:
        _run([flutter_bin, "test"], cwd=MOBILE_DIR)

    print("\n=== [Step 5] 编译 Release Android APK (arm64-v8a) ===")
    _run(
        [
            flutter_bin,
            "build",
            "apk",
            "--release",
            "--target-platform",
            "android-arm64",
            "--split-per-abi",
        ],
        cwd=MOBILE_DIR,
    )

    apk_candidates = [
        MOBILE_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-arm64-v8a-release.apk",
        MOBILE_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk",
    ]
    built_apk = next((p for p in apk_candidates if p.is_file()), None)
    if built_apk is None:
        raise FileNotFoundError("未找到编译产出的 APK 文件，请检查 Flutter 构建输出")

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    out_apk = DIST_DIR / APK_OUT_NAME
    shutil.copy2(built_apk, out_apk)
    size_mb = out_apk.stat().st_size / (1024 * 1024)
    print("\n=================================================================")
    print("  🎉 Android 安装包构建成功！")
    print(f"  📦 路径: {out_apk}")
    print(f"  🪶 大小: {size_mb:.2f} MB")
    print("=================================================================")


if __name__ == "__main__":
    main()
