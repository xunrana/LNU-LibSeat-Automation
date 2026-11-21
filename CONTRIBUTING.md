# 贡献指南

感谢你愿意为 **LNU-LibSeat-Automation** 出一份力！本文档说明桌面端（Python）与移动端（Flutter）的源码环境搭建、测试门禁与提交流程。

> 普通用户无需阅读本文档——直接到 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 下载开箱即用的安装包（主推 **Android `.apk`** 与 **Windows `.zip`**，同步提供 **iOS `.ipa`** 与 **macOS `.zip`**）即可。本文档面向开发者。

---

## 一、环境准备

### 1. 桌面端（Python）
- **Python 3.12**（CI 基准；3.10+ 可用）
- **零浏览器依赖**：v6 已彻底移除 Selenium / WebDriver / OpenCV，无需安装 Edge / Chrome 驱动。

```powershell
git clone https://github.com/XUNRANA/LNU-LibSeat-Automation
cd LNU-LibSeat-Automation
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python gui_qt.py            # PySide6 桌面 GUI
# 或 python main.py         # 纯 CLI 入口
```

`config.py` 由 GUI 首次运行自动生成（含学号/密码，已被 `.gitignore` 忽略，**切勿提交**）；也可手动从 `config.example.py` 复制。

### 2. 移动端（Flutter Android & iOS）
- **Flutter SDK 3.22+**（当前已在 Flutter `3.50.1` / Dart `3.14.0` 实测通过）
- 构建 Android 需配置 Android SDK；构建 iOS 需在 macOS 上安装 Xcode 与 CocoaPods。
- 首次准备 5 个无损 ONNX 模型与跨语言黄金向量：

```bash
python build_android.py --prepare-only
cd mobile
flutter pub get
```

---

## 二、测试与 Lint 门禁

CI（[`.github/workflows/ci.yml`](.github/workflows/ci.yml)）在每次 push / PR 上运行 Python 离线测试、全量 `ruff` 与 `mypy`。提交代码前请在本地逐项通过：

```powershell
# 1. 桌面端 Python 单元测试与静态检查（92 项纯离线，零浏览器）
pip install pytest ruff mypy
pytest tests/ -q
ruff check .                # 阻塞门槛：全量默认规则集，须 0 告警
mypy --platform linux .     # 非阻塞：改类型后建议对齐 CI (Linux) 视角检查

# 2. 若改动 mobile/ 或跨端协议/算子，必须同时通过移动端单测（19 项）
cd mobile
flutter test
flutter analyze
```

- 改动核心协议/抢座流程（`core/libseat_client.py`、`logic/booker.py`、`logic/orchestrator.py`、`mobile/lib/core/`）后，建议在**非整点时段**用自己的账号做一次真机端到端验证（测完记得及时取消预约释放座位）。
- 改动跨语言协议、加解密、结果分类或 Pillow 预处理算子时，必须**同步更新 Python 与 Dart 两端**，重新运行 `python scripts/dump_test_vectors.py` 并确认 `pytest` 与 `flutter test` 全部通过。

---

## 三、代码与隐私规范

- **严禁提交敏感数据**：绝对禁止把真实学号、校园卡密码、Token、个人邮箱或 `config.py` 提交到源码或测试文件中（测试统一使用虚拟占位账号如 `20250000001`）。
- **异常捕获按域收窄**：网络调用用 `requests.RequestException`，协议错误用 `ProtocolDriftError` / `TokenExpiredError`，文件/进程用 `OSError`，解析用 `ValueError`；仅在模型推理黑盒、日志/GUI 顶层兜底处保留宽 `except Exception` 并写明注释。
- **命名约定**：验证码模型对外是 **YOLOv8 + Siamese**；源码中保留的 `yolo4` 仅是早期实验代号，非检测器架构版本。
- **提交信息规范**：使用中文、`类型(范围): 摘要` 形式（如 `feat(mobile): ...`、`fix(android): ...`、`docs(readme): ...`）。

---

## 四、分支与提交策略

- 主分支为 `master`，请基于最新 `master` 开分支并通过 PR 合入。
- 本仓库坚持 **forward commit**：不 rebase / amend 已推送历史、不 force-push。

---

## 五、目录速览

各目录职责见对应 README：
[`mobile/`](mobile/README.md) · [`core/`](core/README.md) · [`logic/`](logic/README.md) · [`ui_qt/`](ui_qt/README.md) · [`model/`](model/README.md) · [`train/`](train/README.md) · [`tests/`](tests/README.md) · [`info/`](info/README.md)。

全仓架构见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，移动端构建说明见 [`docs/MOBILE_GUIDE.md`](docs/MOBILE_GUIDE.md)。
