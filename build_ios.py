"""
LNU-LibSeat-Automation iOS 本地免付费打包脚本（Mac 专属 · 0 元免签名导出 .ipa）
===============================================================================
在你的 macOS 电脑上将 `mobile/` 编译为免付费签名的 iOS 发行包 (`.ipa`)。
无需购买 $99/年 Apple 开发者账号，无需 GitHub Actions。

工作原理：
    1. 自动执行 `scripts/prepare_mobile_assets.py`（将 ONNX 权重转为 FP16，节省 ~73MB）
       与 `scripts/dump_test_vectors.py`
    2. 执行 `flutter build ios --release --no-codesign` 生成 `Runner.app`
    3. 按照 Apple IPA 标准目录结构创建 `Payload/Runner.app`，并用 macOS 原生 `ditto --norsrc`
       打包为 `dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`

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
import urllib.request
import zipfile
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

IPA_OUT_NAME = "LNU-LibSeat-iOS-arm64-unsigned.ipa"
STAGE_IOS_DIR = ROOT / ".build_stage_ios"
ORT_IOS_VERSION = "1.15.1"
ORT_NUGET_URL = (
    f"https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/"
    f"{ORT_IOS_VERSION}/microsoft.ml.onnxruntime.{ORT_IOS_VERSION}.nupkg"
)
LOCAL_ORT_PODS_DIR = MOBILE_DIR / "ios" / ".generated" / "onnxruntime-pods"


def ensure_ios_onnxruntime_local_pods() -> None:
    """从微软官方 NuGet 提取 iOS onnxruntime.xcframework 1.15.1 生成本地 CocoaPods 源。

    Flutter `onnxruntime: ^1.4.1` 依赖的 CocoaPods 归档 URL
    (`onnxruntimepackages.z14.web.core.windows.net/pod-archive-onnxruntime-*-1.15.1.zip`)
    已返回 404；微软官方 NuGet 包 `Microsoft.ML.OnnxRuntime 1.15.1` 内置同一套
    官方 iOS `onnxruntime.xcframework`，本函数将其解包为本地 Pod 供 `Podfile` 引用，
    并强制保留 Dart FFI 所需的 C API 符号避免 Release 链接裁剪。
    """
    ort_c_dir = LOCAL_ORT_PODS_DIR / "onnxruntime-c"
    ort_objc_dir = LOCAL_ORT_PODS_DIR / "onnxruntime-objc"
    xcfw_dir = ort_c_dir / "onnxruntime.xcframework"
    arm64_bin = xcfw_dir / "ios-arm64" / "onnxruntime.framework" / "onnxruntime"
    c_podspec = ort_c_dir / "onnxruntime-c.podspec"
    objc_podspec = ort_objc_dir / "onnxruntime-objc.podspec"
    anchor_src = ort_objc_dir / "Sources" / "OrtFfiAnchor.c"

    if arm64_bin.is_file() and c_podspec.is_file() and objc_podspec.is_file() and anchor_src.is_file():
        print(f"  [OK] 已命中本地官方 ONNX Runtime iOS xcframework ({ORT_IOS_VERSION})")
        return

    print(
        f"=== [iOS ORT] 准备微软官方 NuGet Microsoft.ML.OnnxRuntime {ORT_IOS_VERSION} "
        "iOS xcframework ==="
    )
    LOCAL_ORT_PODS_DIR.mkdir(parents=True, exist_ok=True)
    nupkg_path = LOCAL_ORT_PODS_DIR / f"microsoft.ml.onnxruntime.{ORT_IOS_VERSION}.nupkg"

    # 若工作区临时目录已有缓存包则复用，避免重复下载 104MB
    cached_tmp = ROOT / ".tmp" / "ort_nuget" / f"ort-{ORT_IOS_VERSION}.nupkg"
    if not nupkg_path.is_file() and cached_tmp.is_file():
        shutil.copy2(cached_tmp, nupkg_path)

    if not nupkg_path.is_file():
        print(f"  -> 正在下载 {ORT_NUGET_URL}")
        tmp_dl = nupkg_path.with_suffix(".nupkg.part")
        urllib.request.urlretrieve(ORT_NUGET_URL, tmp_dl)
        tmp_dl.replace(nupkg_path)

    if xcfw_dir.exists():
        shutil.rmtree(xcfw_dir)
    ort_c_dir.mkdir(parents=True, exist_ok=True)
    (ort_objc_dir / "Sources").mkdir(parents=True, exist_ok=True)

    prefix = "runtimes/ios/native/onnxruntime.xcframework/"
    license_bytes = b"MIT License\n"
    with zipfile.ZipFile(nupkg_path, "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if info.filename == "LICENSE.txt":
                license_bytes = zf.read(info.filename)
                continue
            if info.filename.startswith(prefix):
                rel = info.filename[len(prefix) :]
                dst = xcfw_dir / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info, "r") as src_f, dst.open("wb") as dst_f:
                    shutil.copyfileobj(src_f, dst_f)

    if not arm64_bin.is_file():
        raise FileNotFoundError(f"NuGet 包中未找到 iOS arm64 onnxruntime.framework: {arm64_bin}")

    (ort_c_dir / "LICENSE").write_bytes(license_bytes)
    (ort_objc_dir / "LICENSE").write_bytes(license_bytes)

    c_podspec.write_text(
        f"""Pod::Spec.new do |s|
  s.name                  = 'onnxruntime-c'
  s.version               = '{ORT_IOS_VERSION}'
  s.summary               = 'ONNX Runtime C/C++ Pod (official NuGet Microsoft.ML.OnnxRuntime {ORT_IOS_VERSION})'
  s.description           = 'ONNX Runtime C/C++ iOS xcframework extracted from official Microsoft.ML.OnnxRuntime {ORT_IOS_VERSION} NuGet package.'
  s.homepage              = 'https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/{ORT_IOS_VERSION}'
  s.license               = {{ :type => 'MIT', :file => 'LICENSE' }}
  s.author                = {{ 'ONNX Runtime' => 'onnxruntime@microsoft.com' }}
  s.source                = {{ :path => '.' }}
  s.platform              = :ios, '15.0'
  s.vendored_frameworks   = 'onnxruntime.xcframework'
  s.static_framework      = true
  s.weak_frameworks       = 'CoreML'
  s.libraries             = 'c++'
  s.preserve_paths        = ['LICENSE']
  s.user_target_xcconfig  = {{
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_OrtGetApiBase -Wl,-u,_OrtSessionOptionsAppendExecutionProvider_CPU -Wl,-u,_OrtSessionOptionsAppendExecutionProvider_CoreML'
  }}
end
""",
        encoding="utf-8",
    )

    anchor_src.write_text(
        """#include <stdint.h>

extern const void *OrtGetApiBase(void);
extern void *OrtSessionOptionsAppendExecutionProvider_CPU(void *options, int use_arena);
extern void *OrtSessionOptionsAppendExecutionProvider_CoreML(void *options, uint32_t coreml_flags);

__attribute__((used, visibility("default")))
const void *lnu_ort_ffi_keep_symbols(int idx) {
  switch (idx) {
    case 0: return (const void *)&OrtGetApiBase;
    case 1: return (const void *)&OrtSessionOptionsAppendExecutionProvider_CPU;
    case 2: return (const void *)&OrtSessionOptionsAppendExecutionProvider_CoreML;
    default: return (const void *)0;
  }
}
""",
        encoding="utf-8",
    )

    objc_podspec.write_text(
        f"""Pod::Spec.new do |s|
  s.name                  = 'onnxruntime-objc'
  s.version               = '{ORT_IOS_VERSION}'
  s.summary               = 'ONNX Runtime Objective-C Pod shim for Flutter FFI'
  s.description           = 'Lightweight shim satisfying Flutter onnxruntime FFI pod dependency and anchoring exported C API symbols.'
  s.homepage              = 'https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/{ORT_IOS_VERSION}'
  s.license               = {{ :type => 'MIT', :file => 'LICENSE' }}
  s.author                = {{ 'ONNX Runtime' => 'onnxruntime@microsoft.com' }}
  s.source                = {{ :path => '.' }}
  s.platform              = :ios, '15.0'
  s.static_framework      = true
  s.preserve_paths        = ['LICENSE']
  s.source_files          = 'Sources/**/*.c'
  s.dependency 'onnxruntime-c', '{ORT_IOS_VERSION}'
end
""",
        encoding="utf-8",
    )
    print(f"  [OK] 本地官方 ONNX Runtime iOS Pod 就绪: {LOCAL_ORT_PODS_DIR}")


def package_unsigned_ipa(runner_app_dir: Path, out_ipa_path: Path) -> None:
    """将 Runner.app 封装进 Payload/ 并使用 ditto 压缩为标准 .ipa 安装包。"""
    if STAGE_IOS_DIR.exists():
        shutil.rmtree(STAGE_IOS_DIR)
    payload_dir = STAGE_IOS_DIR / "Payload"
    payload_dir.mkdir(parents=True, exist_ok=True)

    target_app = payload_dir / "Runner.app"
    if sys.platform == "darwin":
        _run(["ditto", "--norsrc", str(runner_app_dir), str(target_app)])
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
                "--norsrc",
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

    ensure_ios_onnxruntime_local_pods()

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
