"""
LNU-LibSeat-Automation iOS 本地免付费打包脚本（Mac 专属 · 0 元免签名导出 .ipa）
===============================================================================
在你的 macOS 电脑上将 `mobile/` 编译为免付费签名的 iOS 发行包 (`.ipa`)。
无需购买 $99/年 Apple 开发者账号，无需 GitHub Actions。

工作原理：
    1. 自动执行 `scripts/prepare_mobile_assets.py`（将 ONNX 权重转为 FP16，节省 ~73MB）
       与 `scripts/dump_test_vectors.py`
    2. 执行 `flutter build ios --release --no-codesign` 生成 `Runner.app`
    3. 按照 Apple IPA 标准目录结构创建 `Payload/Runner.app`，并用 macOS 原生 `ditto`
       打包为 `dist/LNU-LibSeat-v6.1.0-iOS-arm64-unsigned.ipa`

安装与分发方式（0 元免付费）：
    - 你自己安装：在 Mac 上用 Xcode 打开 `mobile/ios/Runner.xcworkspace`，登录你自己的
      免费个人 Apple ID (Personal Team)，插上 iPhone 点击 Run 即可直装；
    - 分发给辽大同学：将产出的 `.ipa` 上传到 GitHub Releases，同学使用
      **爱思助手 / Sideloadly / AltStore / SideStore / TrollStore** 一键免费自签安装！

用法（在 Mac 上）：
    python3.12 build_ios.py
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from build_android import (
    APP_VERSION,
    DIST_DIR,
    MOBILE_DIR,
    ROOT,
    _find_flutter,
    _run,
    ensure_flutter_platform_scaffold,
)

IPA_OUT_NAME = f"LNU-LibSeat-{APP_VERSION}-iOS-arm64-unsigned.ipa"
STAGE_IOS_DIR = ROOT / ".build_stage_ios"


def package_unsigned_ipa(runner_app_dir: Path, out_ipa_path: Path) -> None:
    """将 Runner.app 封装进 Payload/ 并使用 ditto 压缩为标准 .ipa 安装包。"""
    if STAGE_IOS_DIR.exists():
        shutil.rmtree(STAGE_IOS_DIR)
    payload_dir = STAGE_IOS_DIR / "Payload"
    payload_dir.mkdir(parents=True, exist_ok=True)

    target_app = payload_dir / "Runner.app"
    if sys.platform == "darwin":
        _run(["ditto", str(runner_app_dir), str(target_app)])
    else:
        shutil.copytree(runner_app_dir, target_app)

    out_ipa_path.parent.mkdir(parents=True, exist_ok=True)
    if out_ipa_path.exists():
        out_ipa_path.unlink()

    if sys.platform == "darwin":
        _run(
            [
                "ditto",
                "-c",
                "-k",
                "--sequesterRsrc",
                "--keepParent",
                str(payload_dir),
                str(out_ipa_path),
            ]
        )
    else:
        archive_base = STAGE_IOS_DIR / "ipa_archive"
        zip_file = shutil.make_archive(
            str(archive_base),
            "zip",
            root_dir=str(STAGE_IOS_DIR),
            base_dir="Payload",
        )
        shutil.move(zip_file, out_ipa_path)

    shutil.rmtree(STAGE_IOS_DIR, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 LNU-LibSeat 免签名 iOS IPA (需在 macOS 运行)")
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="仅准备 FP16 ONNX 模型与测试向量，不调用 Xcode 编译",
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
    print(f"  LNU-LibSeat 手机端 iOS 免付费构建流水线 ({APP_VERSION} · 原版无损 FP32 模型)")
    print("=================================================================")
    prepare_mobile_assets(enable_fp16=False)
    dump_vectors_main()

    if args.prepare_only:
        print("\n[DONE] --prepare-only 已完成所有移动端 FP16 模型与测试向量准备。")
        return

    if sys.platform != "darwin":
        print(
            "\n[ERROR] iOS 编译依赖 Xcode 工具链，必须在你的 Mac 电脑上运行 `python3 build_ios.py`！\n"
            "（当前系统为非 macOS，已完成全部 FP16 模型与资源预处理）",
            file=sys.stderr,
        )
        sys.exit(1)

    flutter_bin = _find_flutter()
    if not flutter_bin:
        print(
            "\n[ERROR] 未在 Mac PATH 中检测到 `flutter` 命令！\n"
            "请在 Mac 上安装 Flutter SDK 与 Xcode 后重新运行 `python3 build_ios.py`。",
            file=sys.stderr,
        )
        sys.exit(1)

    ensure_flutter_platform_scaffold(flutter_bin)

    print("\n=== [Step 4] 拉取 Dart 依赖并执行跨语言契约单测 ===")
    _run([flutter_bin, "pub", "get"], cwd=MOBILE_DIR)
    if not args.skip_tests:
        _run([flutter_bin, "test"], cwd=MOBILE_DIR)

    print("\n=== [Step 5] 免签名编译 Release iOS Runner.app (--no-codesign) ===")
    _run(
        [
            flutter_bin,
            "build",
            "ios",
            "--release",
            "--no-codesign",
        ],
        cwd=MOBILE_DIR,
    )

    runner_app = MOBILE_DIR / "build" / "ios" / "iphoneos" / "Runner.app"
    if not runner_app.is_dir():
        raise FileNotFoundError(f"未找到编译产出的 Runner.app: {runner_app}")

    out_ipa = DIST_DIR / IPA_OUT_NAME
    print("\n=== [Step 6] 封装标准 Payload/Runner.app 并压制 .ipa ===")
    package_unsigned_ipa(runner_app, out_ipa)

    size_mb = out_ipa.stat().st_size / (1024 * 1024)
    print("\n=================================================================")
    print("  🍎 iOS 免签名安装包 (.ipa) 构建成功！")
    print(f"  📦 路径: {out_ipa}")
    print(f"  🪶 大小: {size_mb:.2f} MB")
    print("  💡 自用：Xcode 打开 mobile/ios/Runner.xcworkspace 登录免费 Apple ID 直装真机")
    print("  💡 分发：同学用 爱思助手 / Sideloadly / AltStore / SideStore / TrollStore 自签安装")
    print("=================================================================")


if __name__ == "__main__":
    main()
