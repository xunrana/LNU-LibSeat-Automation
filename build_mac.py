"""
LNU-LibSeat-Automation macOS 构建脚本（精简瘦身版）
===================================================
把项目打包成可双击的 macOS ``.app``，并装入一个发行夹后用 ``ditto`` 压成 zip。

⚠️ PyInstaller 不能跨平台编译：本脚本**必须在 macOS 上运行**（本地 Apple
   Silicon Mac，或 GitHub Actions 的 macos-14 runner），且需 **Python >= 3.10**
   （推荐 3.12，不要用 macOS 自带的 Python 3.9）。

瘦身策略（同步应用于 build.py / build_mac.py）：
    1. 仅安装 PySide6-Essentials（剔除 QtWebEngine/QtPdf/QtQuick/Qt3D 等 ~580MB 冗余）
    2. 彻底移除 OpenCV（cv2）依赖；ddddocr 仅提取 common_old.onnx (13MB) + 字符表，
       剔除未用到的 common.onnx (52MB) 与 common_det.onnx (19MB)
    3. 去掉宽泛的 --collect-all，按实际 import 精准打包并排除 sympy/测试集/无用 Qt 模块
    4. 不打包未在运行时使用的 logo.png (7.7MB)，logo1.png 按 2x Retina 尺寸无损优化

用法（在 Mac 上）：
    python3.12 build_mac.py

产物：
    dist/LNU-LibSeat-v6.0.0-macOS-arm64/        <- 发行夹
    dist/LNU-LibSeat-v6.0.0-macOS-arm64.zip      <- 分发给用户的压缩包
"""
import os
import platform
import shutil
import subprocess
import sys
import venv

ROOT = os.path.dirname(os.path.abspath(__file__))
APP_NAME = "LNU-LibSeat"
APP_VERSION = "v6.0.0"  # 每次发布新版本请修改此处
ARCH = platform.machine() or "arm64"  # arm64 (Apple Silicon)
DIST_NAME = f"{APP_NAME}-{APP_VERSION}-macOS-{ARCH}"
DIST_DIR = os.path.join(ROOT, "dist", DIST_NAME)
VENV_DIR = os.path.join(ROOT, ".build_venv_mac")
STAGE_DIR = os.path.join(ROOT, ".build_stage_mac")
BUNDLE_ID = "com.xunrana.lnulibseat"

# 精简构建依赖：仅 PySide6-Essentials，不含 OpenCV / Selenium / PySide6-Addons
BUILD_DEPS = [
    "pyinstaller",
    "PySide6-Essentials",
    "numpy",
    "onnxruntime",
    "Pillow",
    "requests",
    "pycryptodome",
]

# 显式排除运行时完全不会用到的重型依赖 / 测试套件 / Qt 附加模块
EXCLUDE_MODULES = [
    "config",
    "cv2",
    "ddddocr",
    "torch",
    "torchvision",
    "timm",
    "scipy",
    "matplotlib",
    "pandas",
    "ultralytics",
    "tensorboard",
    "tensorflow",
    "sympy",
    "mpmath",
    "tkinter",
    "_tkinter",
    "unittest",
    "pydoc",
    "doctest",
    "Crypto.SelfTest",
    "numpy.f2py",
    "numpy.testing",
    "numpy.tests",
    "onnxruntime.tools",
    "onnxruntime.quantization",
    "onnxruntime.transformers",
    "onnxruntime.datasets",
    "onnxruntime.backend",
    "PySide6.QtWebEngineCore",
    "PySide6.QtWebEngineWidgets",
    "PySide6.QtWebEngineQuick",
    "PySide6.QtQml",
    "PySide6.QtQuick",
    "PySide6.QtQuickWidgets",
    "PySide6.Qt3DCore",
    "PySide6.Qt3DRender",
    "PySide6.QtPdf",
    "PySide6.QtMultimedia",
    "PySide6.QtMultimediaWidgets",
    "PySide6.QtCharts",
    "PySide6.QtGraphs",
    "PySide6.QtSql",
    "PySide6.QtNetwork",
    "PySide6.QtOpenGL",
    "PySide6.QtOpenGLWidgets",
    "PySide6.QtDesigner",
    "PySide6.QtHelp",
    "PySide6.QtTest",
    "PySide6.QtSvg",
    "PySide6.QtPrintSupport",
    "PySide6.QtXml",
    "PySide6.QtBluetooth",
    "PySide6.QtNfc",
    "PySide6.QtPositioning",
    "PySide6.QtLocation",
    "PySide6.QtSensors",
    "PySide6.QtSerialPort",
    "PySide6.QtWebSockets",
    "PySide6.QtWebChannel",
    "PySide6.QtSpatialAudio",
    "PySide6.QtTextToSpeech",
    "PySide6.QtRemoteObjects",
    "PySide6.QtScxml",
    "PySide6.QtStateMachine",
    "PySide6.QtHttpServer",
    "PySide6.QtDBus",
]


def _venv_python():
    return os.path.join(VENV_DIR, "bin", "python")


def _subproc_env():
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return env


def _clean_pyside_templates():
    """清理 PySide6 内置的非合法 Python 模板文件（*.tmpl.py），防止 compileall / PyInstaller 报错。"""
    for root_dir, _, files in os.walk(VENV_DIR):
        for fn in files:
            if fn.endswith(".tmpl.py"):
                try:
                    os.remove(os.path.join(root_dir, fn))
                except OSError:
                    pass


def _create_clean_venv():
    if os.path.exists(VENV_DIR):
        print("[*] 移除旧的 build venv...")
        shutil.rmtree(VENV_DIR)

    print("[*] 创建干净的 build venv...")
    venv.create(VENV_DIR, with_pip=True)

    py = _venv_python()
    if not os.path.isfile(py):
        sys.exit(f"[ERROR] venv python 未找到: {py}")

    env = _subproc_env()
    print("[*] 安装精简构建依赖（arm64 wheel，不含 OpenCV / QtWebEngine）...")
    subprocess.check_call(
        [py, "-m", "pip", "install", "--upgrade", "--no-compile", "pip"],
        stdout=subprocess.DEVNULL,
        env=env,
    )
    # --no-compile: 跳过 wheel 解包后的 compileall，避免旧版 Python 编译 PySide6 模板报错
    subprocess.check_call(
        [py, "-m", "pip", "install", "--no-compile"] + BUILD_DEPS,
        env=env,
    )
    # 仅以 --no-deps 安装 ddddocr 以提取 common_old.onnx + 字符表，绝不拉入 opencv-python-headless
    subprocess.check_call(
        [py, "-m", "pip", "install", "--no-deps", "--no-compile", "ddddocr"],
        env=env,
    )
    _clean_pyside_templates()
    print("[OK] build venv 就绪。\n")


def _stage_ddddocr_lite(py: str, stage_dir: str) -> str:
    """从 venv 的 ddddocr 中仅提取 common_old.onnx (13MB) 与 charset_old.json。"""
    out_dir = os.path.join(stage_dir, "ddddocr_lite")
    os.makedirs(out_dir, exist_ok=True)
    extractor = r"""
import importlib.util, json, pathlib, shutil, sys

out_dir = pathlib.Path(sys.argv[1])
spec = importlib.util.find_spec("ddddocr")
if not spec or not spec.origin:
    raise SystemExit("ddddocr not found in build venv")
pkg_dir = pathlib.Path(spec.origin).resolve().parent
model = pkg_dir / "common_old.onnx"
if not model.is_file():
    raise SystemExit(f"common_old.onnx not found in {pkg_dir}")
shutil.copy2(model, out_dir / "common_old.onnx")

charsets_py = pkg_dir / "charsets.py"
if charsets_py.is_file():
    cs_spec = importlib.util.spec_from_file_location("_cs", charsets_py)
    cs_mod = importlib.util.module_from_spec(cs_spec)
    cs_spec.loader.exec_module(cs_mod)
    charset = list(cs_mod.CHARSET_OLD)
else:
    raise SystemExit(f"charsets.py not found in {pkg_dir}; please upgrade ddddocr >= 1.6")

(out_dir / "charset_old.json").write_text(
    json.dumps(charset, ensure_ascii=False), encoding="utf-8"
)
print(f"[OK] ddddocr_lite 提取完成: common_old.onnx ({model.stat().st_size // 1024 // 1024}MB) + {len(charset)} chars")
"""
    subprocess.check_call([py, "-c", extractor, out_dir])
    return out_dir


def _stage_slim_logo(py: str, stage_dir: str) -> str:
    """生成 720x720 (2x Retina for 360px hero) 优化版 logo1.png，不改动仓库原图。"""
    src = os.path.join(ROOT, "logo1.png")
    dst = os.path.join(stage_dir, "logo1.png")
    optimizer = r"""
import os, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
with Image.open(src) as im:
    im = im.convert("RGBA")
    if max(im.size) > 720:
        im.thumbnail((720, 720), Image.Resampling.LANCZOS)
    im.save(dst, format="PNG", optimize=True)
print(f"[OK] logo1.png 优化完成: {os.path.getsize(src) // 1024}KB -> {os.path.getsize(dst) // 1024}KB")
"""
    subprocess.check_call([py, "-c", optimizer, src, dst])
    return dst


def _make_icns(stage_dir: str):
    """用 macOS 自带 sips + iconutil 从 logo.png 生成 logo.icns（放在临时目录）。"""
    png = os.path.join(ROOT, "logo.png")
    if not os.path.exists(png):
        print("[WARN] 未找到 logo.png，将不带自定义图标。")
        return None

    iconset = os.path.join(stage_dir, "logo.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    icns = os.path.join(stage_dir, "logo.icns")
    try:
        for s in (16, 32, 64, 128, 256, 512):
            subprocess.check_call(
                ["sips", "-z", str(s), str(s), png,
                 "--out", os.path.join(iconset, f"icon_{s}x{s}.png")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.check_call(
                ["sips", "-z", str(s * 2), str(s * 2), png,
                 "--out", os.path.join(iconset, f"icon_{s}x{s}@2x.png")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", icns])
        print("[OK] logo.icns 生成成功。")
        return icns
    except Exception as e:
        print(f"[WARN] icns 生成失败，将不带自定义图标: {e}")
        return None
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


# 干净的配置模板（绝不打包个人数据；v6 纯 API 模式无需配置浏览器）
CLEAN_CONFIG = '''\
# ===================================================================
# LNU-LibSeat-Automation v6 配置文件 (由 GUI 自动保存，纯 API 模式)
# ===================================================================

USERS = {
    "": {
        "password": "",
        "time": {"start": "", "end": ""}
    },
}

TARGET_CAMPUS = "崇山校区图书馆"
TARGET_ROOM = "三楼智慧研修空间"
FALLBACK_ROOMS = []
PREFER_SEATS = []

WAIT_FOR_0630 = False
MAX_ACCOUNTS = 2

API_BASE_URL = "http://libseat.lnu.edu.cn"
API_FIRE_OFFSET_MS = 200

RECEIVER_EMAIL = ""
WEBHOOK_URL = ""
SMTP_USER = ""
SMTP_PASS = ""

LOG_LEVEL = "INFO"
LOG_DIR = "logs"
'''

# 一键解除 Gatekeeper 限制脚本（未签名 .app 首次需要）
UNLOCK_COMMAND = '''\
#!/bin/bash
# 解除 macOS 对未签名应用的隔离限制，然后启动应用。
cd "$(dirname "$0")"
echo "正在解除安全限制（可能需要几秒）..."
xattr -cr "LNU-LibSeat.app" 2>/dev/null
chmod +x "LNU-LibSeat.app/Contents/MacOS/LNU-LibSeat" 2>/dev/null
echo "完成！正在启动 LNU-LibSeat..."
open "LNU-LibSeat.app"
'''

USAGE_TXT = '''\
LNU-LibSeat 图书馆智能抢座系统 v6 · macOS 使用说明
==================================================

【首次运行】
1. 把本文件夹整个解压到任意位置（例如「下载」或「桌面」）。
2. 右键点击「首次运行请先双击我.command」→ 选择「打开」→ 再点一次「打开」。
   （因为应用未做苹果付费签名，必须用右键打开一次以解除安全限制；
     之后即可直接双击 LNU-LibSeat.app 启动。）
3. 如果第 2 步提示「无法打开」，请到 系统设置 ▸ 隐私与安全性 ▸ 底部「仍要打开」。
4. macOS 15+ / 26 首次联网时若弹出「允许查找并连接到本地网络上的设备」，请点击「允许」
   （建议先测试运行一次点掉该授权，再用于夜间无人值守定时抢座）。

【v6 纯 API 引擎】
- 无需安装 Chrome / Edge 或配置 Safari 远程自动化，双账号原生并行！

【数据位置】
- config.py（你的配置）、logs/（运行日志与脱敏追溯）都在本文件夹内，与 .app 同级，可直接查看/编辑。

【注意】
- 抢座等待期间请保持电脑开机；应用会自动防止系统休眠。
'''


def build():
    if sys.platform != "darwin":
        sys.exit("[ERROR] build_mac.py 只能在 macOS 上运行。Windows 请用 build.py，"
                 "或通过 GitHub Actions 的 macos runner 构建。")
    if sys.version_info < (3, 10):
        sys.exit(
            f"[ERROR] 需要 Python >= 3.10（推荐 3.12），当前为 {sys.version.split()[0]}。\n"
            "请勿使用 macOS 自带 Python 3.9，运行: brew install python@3.12 && python3.12 build_mac.py"
        )

    shutil.rmtree(STAGE_DIR, ignore_errors=True)
    os.makedirs(STAGE_DIR, exist_ok=True)

    try:
        # --- Step 1: venv ---
        _create_clean_venv()
        py = _venv_python()

        # --- Step 2: 准备精简资源 ---
        ddddocr_lite_dir = _stage_ddddocr_lite(py, STAGE_DIR)
        slim_logo1 = _stage_slim_logo(py, STAGE_DIR)
        icns = _make_icns(STAGE_DIR)

        # --- Step 3: PyInstaller ---
        sep = os.pathsep  # macOS = ":"
        cmd = [
            py, "-m", "PyInstaller",
            "--noconfirm",
            "--onedir",
            "--windowed",                       # 生成 .app（GUI，无终端窗口）
            "--name", APP_NAME,
            "--distpath", os.path.join(ROOT, "dist"),
            "--osx-bundle-identifier", BUNDLE_ID,

            # 运行时 hook：在任何 import 前把 cwd / sys.path 指向 .app 同级目录
            "--runtime-hook", os.path.join(ROOT, "_runtime_hook.py"),

            # 随包资源（仅运行时实际用到的精简资源，不打包 7.7MB 原图 logo.png）
            "--add-data", f"{slim_logo1}{sep}.",
            "--add-data", f"{os.path.join(ROOT, 'logo.ico')}{sep}.",
            "--add-data", f"{ddddocr_lite_dir}{sep}ddddocr_lite",
            # 仅打包 core/checkpoints/*.onnx（排除本地 *.pt/*.pth 训练权重）
            *[
                arg
                for fn in sorted(os.listdir(os.path.join(ROOT, "core", "checkpoints")))
                if fn.endswith(".onnx")
                for arg in (
                    "--add-data",
                    f"{os.path.join(ROOT, 'core', 'checkpoints', fn)}{sep}core/checkpoints",
                )
            ],

            # 仅精准收集原生动态库与懒加载加密子模块（绝不用 --collect-all）
            "--collect-binaries", "onnxruntime",
            "--collect-binaries", "Crypto.Cipher",
            "--hidden-import", "Crypto.Cipher.AES",
            "--hidden-import", "Crypto.Util.Padding",
            "--hidden-import", "onnxruntime.capi._pybind_state",

            # 显式排除无关重型依赖、测试集与未用 Qt 模块
            *[
                arg
                for mod in EXCLUDE_MODULES
                for arg in ("--exclude-module", mod)
            ],
        ]
        if icns:
            cmd += ["--icon", icns]
        cmd.append(os.path.join(ROOT, "gui_qt.py"))  # 入口

        print("=" * 55)
        print("  Building LNU-LibSeat (macOS .app, slim) ...")
        print("=" * 55)
        subprocess.check_call(cmd, env=_subproc_env())
    finally:
        # --- Step 4: 清理临时目录 ---
        print("[*] 清理 build venv 与临时暂存目录...")
        shutil.rmtree(VENV_DIR, ignore_errors=True)
        shutil.rmtree(STAGE_DIR, ignore_errors=True)

    app_src = os.path.join(ROOT, "dist", f"{APP_NAME}.app")
    if not os.path.isdir(app_src):
        sys.exit(f"[ERROR] 未生成 .app: {app_src}")

    # --- Step 5: 组装发行夹 ---
    if os.path.exists(DIST_DIR):
        shutil.rmtree(DIST_DIR)
    os.makedirs(DIST_DIR)

    # .app 移入发行夹
    shutil.move(app_src, os.path.join(DIST_DIR, f"{APP_NAME}.app"))
    print(f"[OK] {APP_NAME}.app 已放入发行夹")
    # PyInstaller 同时产出的 onedir 文件夹（非 .app）删掉，避免混淆
    shutil.rmtree(os.path.join(ROOT, "dist", APP_NAME), ignore_errors=True)

    # 外置可编辑 config.py（与 .app 同级 -> 对应 core.paths.app_data_dir）
    with open(os.path.join(DIST_DIR, "config.py"), "w", encoding="utf-8") as f:
        f.write(CLEAN_CONFIG)
    print("[OK] 干净 config.py 模板已写入（无个人数据）")

    # info/（座位索引）
    src_info = os.path.join(ROOT, "info")
    if os.path.exists(src_info):
        shutil.copytree(src_info, os.path.join(DIST_DIR, "info"))
        print("[OK] info/ 已复制")

    # logs/
    os.makedirs(os.path.join(DIST_DIR, "logs"), exist_ok=True)
    print("[OK] logs/ 已创建")

    # 解除限制脚本
    cmd_path = os.path.join(DIST_DIR, "首次运行请先双击我.command")
    with open(cmd_path, "w", encoding="utf-8") as f:
        f.write(UNLOCK_COMMAND)
    os.chmod(cmd_path, 0o755)
    print("[OK] 解除限制脚本已写入")

    # 使用说明
    with open(os.path.join(DIST_DIR, "使用说明.txt"), "w", encoding="utf-8") as f:
        f.write(USAGE_TXT)
    print("[OK] 使用说明.txt 已写入")

    # --- Step 6: ditto 压 zip（保留 .app 符号链接 / 权限 / ad-hoc 签名）---
    zip_path = os.path.join(ROOT, "dist", f"{DIST_NAME}.zip")
    if os.path.exists(zip_path):
        os.remove(zip_path)
    print(f"[*] 用 ditto 打包 {DIST_NAME}.zip ...")
    subprocess.check_call([
        "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
        DIST_DIR, zip_path,
    ])
    size_mb = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"[OK] {DIST_NAME}.zip 创建成功 ({size_mb:.1f} MB)")

    print()
    print("=" * 55)
    print("  构建完成！")
    print(f"  发行夹: dist/{DIST_NAME}/")
    print(f"  压缩包: dist/{DIST_NAME}.zip ({size_mb:.1f} MB)")
    print()
    print("  分发给用户：发送 zip；用户解压后右键运行")
    print("  「首次运行请先双击我.command」即可。")
    print("=" * 55)


if __name__ == "__main__":
    build()
