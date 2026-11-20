"""
LNU-LibSeat-Automation Windows Build Script (Slim)
==================================================
Packages the project into a standalone folder that runs without Python.

Slimming strategy (kept in sync with build_mac.py):
    1. Install PySide6-Essentials only (drops QtWebEngine/QtPdf/QtQuick/Qt3D ~500MB+)
    2. Zero OpenCV (cv2); extract only ddddocr's common_old.onnx (13MB) + charset table
       (drops unused 52MB common.onnx & 19MB common_det.onnx)
    3. Replace broad --collect-all flags with targeted binary/hidden-import rules and
       explicit --exclude-module lists
    4. Drop unused 7.7MB logo.png and duplicate root logo copies; optimize logo1.png

Usage:
    python build.py

Output:
    dist/LNU-LibSeat-v6.0.0/
        LNU-LibSeat.exe   <- Double-click to run (GUI)
        logs/              <- Log output (auto-created)
"""
import os
import shutil
import subprocess
import sys
import time
import venv

ROOT = os.path.dirname(os.path.abspath(__file__))
APP_NAME = "LNU-LibSeat"
APP_VERSION = "v6.0.0"  # 每次发布新版本请修改此处
DIST_NAME = f"{APP_NAME}-{APP_VERSION}"
DIST_DIR = os.path.join(ROOT, "dist", DIST_NAME)
VENV_DIR = os.path.join(ROOT, ".build_venv")
STAGE_DIR = os.path.join(ROOT, ".build_stage")

# Only these packages (and their minimal dependencies) go into the exe (zero Selenium / OpenCV / QtAddons!)
BUILD_DEPS = [
    "pyinstaller",
    "PySide6-Essentials",
    "numpy",
    "onnxruntime",
    "Pillow",
    "requests",
    "pycryptodome",
]

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
    """Return the python executable path inside the build venv."""
    if sys.platform == "win32":
        return os.path.join(VENV_DIR, "Scripts", "python.exe")
    return os.path.join(VENV_DIR, "bin", "python")


def _subproc_env():
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return env


def _create_clean_venv():
    """Create a fresh venv with only the required packages."""
    if os.path.exists(VENV_DIR):
        print("[*] Removing old build venv...")
        shutil.rmtree(VENV_DIR)

    print("[*] Creating clean build venv...")
    venv.create(VENV_DIR, with_pip=True)

    py = _venv_python()
    if not os.path.isfile(py):
        sys.exit(f"[ERROR] venv python not found: {py}")

    env = _subproc_env()
    print("[*] Installing slim build dependencies (no OpenCV / QtWebEngine)...")
    subprocess.check_call(
        [py, "-m", "pip", "install", "--upgrade", "--no-compile", "pip"],
        stdout=subprocess.DEVNULL,
        env=env,
    )
    subprocess.check_call(
        [py, "-m", "pip", "install", "--no-compile"] + BUILD_DEPS,
        env=env,
    )
    # Install ddddocr with --no-deps solely to extract common_old.onnx + charset table (skip opencv-python-headless)
    subprocess.check_call(
        [py, "-m", "pip", "install", "--no-deps", "--no-compile", "ddddocr"],
        env=env,
    )
    # Workaround for Anaconda Python on Windows: Anaconda adds Library\bin to the DLL search path,
    # whose icuuc.dll has versioned symbols incompatible with Qt 6.12 (causing PyInstaller's
    # hook-PySide6.py QtLibraryInfo probe to fail and skip qwindows.dll). Preloading Windows'
    # System32\icuuc.dll via a build-venv-only .pth ensures hook-PySide6.py succeeds while keeping
    # Library\bin available for stdlib DLLs (ffi.dll, libexpat.dll, etc.).
    if sys.platform == "win32":
        pth_path = os.path.join(VENV_DIR, "Lib", "site-packages", "_preload_sys_icuuc.pth")
        with open(pth_path, "w", encoding="utf-8") as f:
            f.write(
                "import ctypes, os; "
                "_p = os.path.join(os.environ.get('SystemRoot', r'C:\\Windows'), 'System32', 'icuuc.dll'); "
                "os.path.isfile(_p) and ctypes.WinDLL(_p)\n"
            )
    print("[OK] Build venv ready.\n")


def _stage_ddddocr_lite(py: str, stage_dir: str) -> str:
    """Extract only common_old.onnx (13MB) and charset_old.json from ddddocr."""
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
print(f"[OK] ddddocr_lite staged: common_old.onnx ({model.stat().st_size // 1024 // 1024}MB) + {len(charset)} chars")
"""
    subprocess.check_call([py, "-c", extractor, out_dir])
    return out_dir


def _stage_slim_logo(py: str, stage_dir: str) -> str:
    """Create an optimized 720x720 copy of logo1.png without modifying the source image."""
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
print(f"[OK] logo1.png optimized: {os.path.getsize(src) // 1024}KB -> {os.path.getsize(dst) // 1024}KB")
"""
    subprocess.check_call([py, "-c", optimizer, src, dst])
    return dst


def build():
    if sys.version_info < (3, 10):
        sys.exit(
            f"[ERROR] Python >= 3.10 (3.12 recommended) is required; got {sys.version.split()[0]}."
        )

    shutil.rmtree(STAGE_DIR, ignore_errors=True)
    os.makedirs(STAGE_DIR, exist_ok=True)

    try:
        # --- Step 1: Prepare venv ---
        _create_clean_venv()
        py = _venv_python()

        # --- Step 2: Stage slim assets ---
        ddddocr_lite_dir = _stage_ddddocr_lite(py, STAGE_DIR)
        slim_logo1 = _stage_slim_logo(py, STAGE_DIR)

        # --- Step 3: Run PyInstaller in clean venv ---
        sep = os.pathsep  # Windows = ";"
        cmd = [
            py, "-m", "PyInstaller",
            "--noconfirm",
            "--onedir",
            "--name", APP_NAME,  # 保持 exe 名称为 LNU-LibSeat.exe，但文件夹会有版本号
            "--distpath", os.path.join(ROOT, "dist"),
            "--windowed",  # GUI 模式，无黑框

            # Add the custom icon for the taskbar and executable (skip unused 7.7MB logo.png)
            "--icon", os.path.join(ROOT, "logo.ico"),
            "--add-data", f"{os.path.join(ROOT, 'logo.ico')}{sep}.",
            "--add-data", f"{slim_logo1}{sep}.",
            "--add-data", f"{ddddocr_lite_dir}{sep}ddddocr_lite",

            # Runtime hook: set cwd and sys.path to exe dir before any imports
            "--runtime-hook", os.path.join(ROOT, "_runtime_hook.py"),

            # Targeted native binaries & lazy crypto imports (avoid --collect-all bloat)
            "--collect-binaries", "onnxruntime",
            "--collect-binaries", "Crypto.Cipher",
            "--hidden-import", "Crypto.Cipher.AES",
            "--hidden-import", "Crypto.Util.Padding",
            "--hidden-import", "onnxruntime.capi._pybind_state",

            # Exclude unused heavy deps, test suites, and unneeded Qt modules
            *[
                arg
                for mod in EXCLUDE_MODULES
                for arg in ("--exclude-module", mod)
            ],

            # Entry point: GUI
            os.path.join(ROOT, "gui_qt.py"),
        ]

        print("=" * 55)
        print("  Building LNU-LibSeat-Automation (Windows, slim) ...")
        print("=" * 55)
        subprocess.check_call(cmd, env=_subproc_env())
    finally:
        # --- Step 4: Clean up build venv & staging dir ---
        print("[*] Cleaning up build venv and staging dir...")
        shutil.rmtree(VENV_DIR, ignore_errors=True)
        shutil.rmtree(STAGE_DIR, ignore_errors=True)

    # --- Step 5: Rename output folder ---
    original_dist_folder = os.path.join(ROOT, "dist", APP_NAME)
    if os.path.exists(original_dist_folder) and APP_NAME != DIST_NAME:
        if os.path.exists(DIST_DIR):
            shutil.rmtree(DIST_DIR)
        renamed = False
        for attempt in range(1, 6):
            try:
                os.rename(original_dist_folder, DIST_DIR)
                renamed = True
                break
            except PermissionError:
                time.sleep(1.5)
        if not renamed:
            shutil.copytree(original_dist_folder, DIST_DIR)
            shutil.rmtree(original_dist_folder, ignore_errors=True)

    # Sanity check: ensure PySide6 Windows platform plugin was collected by hook-PySide6.py
    qwindows_dll = os.path.join(
        DIST_DIR, "_internal", "PySide6", "plugins", "platforms", "qwindows.dll"
    )
    if not os.path.isfile(qwindows_dll):
        sys.exit(
            f"[ERROR] Missing Qt platform plugin: {qwindows_dll}\n"
            "        PyInstaller's hook-PySide6.py likely failed to probe QtCore."
        )

    # --- Step 6: Post-build — set up distribution folder ---

    # Copy info/ directory (seat index for all rooms)
    src_info = os.path.join(ROOT, "info")
    dst_info = os.path.join(DIST_DIR, "info")
    if os.path.exists(src_info):
        if os.path.exists(dst_info):
            shutil.rmtree(dst_info)
        shutil.copytree(src_info, dst_info)
        print("[OK] info/ directory copied to distribution folder")

    # Copy core/checkpoints/ (ONLY *.onnx runtime models; skip local *.pt/*.pth training weights!)
    src_ckpts = os.path.join(ROOT, "core", "checkpoints")
    dst_ckpts = os.path.join(DIST_DIR, "_internal", "core", "checkpoints")
    if os.path.exists(src_ckpts):
        if os.path.exists(dst_ckpts):
            shutil.rmtree(dst_ckpts)
        shutil.copytree(
            src_ckpts,
            dst_ckpts,
            ignore=shutil.ignore_patterns("*.pt", "*.pth", ".claude", "__pycache__"),
        )
        print("[OK] core/checkpoints/*.onnx copied to distribution folder")

    # Create logs directory
    os.makedirs(os.path.join(DIST_DIR, "logs"), exist_ok=True)
    print("[OK] logs/ directory created")

    # Write a clean config template (NEVER ship personal data)
    clean_config = '''\
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
    config_path = os.path.join(DIST_DIR, "config.py")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(clean_config)
    print("[OK] Clean config.py template written (no personal data)")

    # --- Step 7: Create Zip ---
    print(f"[*] Packaging {DIST_NAME}.zip ...")
    shutil.make_archive(
        base_name=os.path.join(ROOT, "dist", DIST_NAME),
        format="zip",
        root_dir=os.path.join(ROOT, "dist"),
        base_dir=DIST_NAME,
    )
    zip_path = os.path.join(ROOT, "dist", f"{DIST_NAME}.zip")
    size_mb = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"[OK] {DIST_NAME}.zip created successfully ({size_mb:.1f} MB)")

    print()
    print("=" * 55)
    print("  Build complete!")
    print(f"  Output Folder: dist/{DIST_NAME}/")
    print(f"  Output Zip: dist/{DIST_NAME}.zip ({size_mb:.1f} MB)")
    print()
    print("  How to use:")
    print(f"  1. Double-click  dist/{DIST_NAME}/{APP_NAME}.exe")
    print("  2. Fill in the form and click Start")
    print("=" * 55)


if __name__ == "__main__":
    build()
