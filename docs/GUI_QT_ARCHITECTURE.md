# 桌面端 GUI 架构（PySide6）

适用于 LNU-LibSeat v6.0.0 桌面端（Windows / macOS）。

[← 返回首页](../README.md) · [架构文档](ARCHITECTURE.md) · [配置详解](CONFIGURATION.md) · [数字参数](NUMERIC_PARAMETERS.md) · [v6.0.0 更新说明](RELEASE_NOTES_V6.md)

---

## 目录

- [整体目录结构](#-整体目录结构)
- [主题系统](#-主题系统)
- [Panel 拆分](#-panel-拆分)
- [Worker 线程模型](#-worker-线程模型)
- [Config I/O 服务](#-config-io-服务)
- [防休眠服务](#-防休眠服务)
- [精简打包策略（瘦身 400MB+）](#-精简打包策略瘦身-400mb)
- [扩展开发指南](#-扩展开发指南)

---

## 🗂️ 整体目录结构

桌面端入口 `gui_qt.py` 仅委托 `ui_qt.app:main()` 启动主窗口，`ui_qt/` 按职责拆分为 `panels / widgets / workers / services`：

```text
ui_qt/
├── __init__.py
├── app.py                       # 🏠 MainWindow 主窗口（无边框 + 防休眠联动 + 启停控制）
├── theme.py                     # 🎨 全局配色（辽大蓝 / 暖米纸底 / 琥珀金）与字体工厂
│
├── panels/                      # 📋 左右双面板
│   ├── config_panel.py          #   左：目标（校区/自习室/首选座）/ 账号 / 邮箱与 Webhook / 执行模式
│   └── dashboard_panel.py       #   右：校徽 / 自绘倒计时圆环 / 启停按钮 / 彩色 RUN LOG 终端
│
├── widgets/                     # 🧱 11 个可复用组件
│   ├── header_bar.py            #   顶部状态栏
│   ├── title_bar.py             #   无边框自定义窗口控制栏
│   ├── account_card.py          #   单账号卡片（学号 / 密码显隐 / 起止时段）
│   ├── section_card.py          #   通用分组卡片
│   ├── mode_toggle.py           #   立即 / 定时模式切换器
│   ├── seat_grid.py             #   最多 10 个优先座位号输入网格（v6 可全留空）
│   ├── status_pill.py           #   状态指示丸
│   ├── countdown_ring.py        #   QPainter 自绘 360×360 倒计时圆环（~30fps）
│   ├── log_terminal.py          #   终端风格实时彩色日志流
│   ├── buttons.py               #   PrimaryButton / GhostButton
│   └── seal_mark.py             #   校徽/封印装饰
│
├── workers/                     # 🧵 后台纯 API 抢座线程
│   └── booker_worker.py         #   QThread 驱动 main.main() → logic.orchestrator
│
└── services/                    # ⚙️ 本地配置与系统电源服务
    ├── config_io.py             #   GuiState / AccountState / ROOM_DATA + config.py 读写注入
    └── prevent_sleep.py         #   Windows ExecutionState+心跳 / macOS caffeinate -dimsu
```

---

## 🎨 主题系统

源码：`ui_qt/theme.py`（与移动端 `mobile/lib/ui/theme/app_theme.dart` 共享「辽大蓝 · 暖米纸底 · 崇山银杏金」视觉体系）

- **核心色板（`C` 类）**：纸感背景 `BG = "#f5f1e8"`、卡片 `CARD = "#fdfcf8"`、辽大海军蓝 `INK = "#003876"`、琥珀强调 `AMBER = "#d4a574"`、状态色 `OK / WARN / ERR`。
- **字体工厂**：`serif(size)`（衬线标题）、`sans(size)`（无衬线正文）、`mono(size)`（等宽时间与日志）。

---

## 📋 Panel 拆分

主窗口（`ui_qt/app.py:MainWindow`）默认尺寸 `1400×920`（最小 `1100×760`，启动默认最大化），采用左 `45%`（`420–600px`）+ 右 `55%` 左右分栏布局：

### 1. 左侧 `ConfigPanel`（`ui_qt/panels/config_panel.py`）

v6 **已彻底移除「浏览器选择」下拉框**，新增 **「手机推送 Webhook」** 输入框与纯 API 引擎状态提示，并允许首选座位留空：

| 分组卡片 | 控件 | 说明 |
| :--- | :--- | :--- |
| **🎯 目标设置** | `cb_campus` / `cb_room` / `SeatGrid` | 双校区 21 间自习室联动；优先座位可全留空（留空即实时扫当前空座） |
| **👤 账号设置** | `AccountCard` × `MAX_ACCOUNTS (2)` + `chk_use_acc2` | 支持主副双号分时段无缝接力 |
| **通知与推送** | `email_input` + `webhook_input` | 收件邮箱（免配 SMTP）+ 手机推送（自动识别 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉） |
| **⚡ 执行设置** | `ModeToggle` + `sched_hour` / `sched_min` | 默认定时 `06:30`（北京时间），切换立即模式自动隐藏时间框；底部展示「⚡ 纯 API 直连引擎 · 无需安装浏览器或 WebDriver」 |

### 2. 右侧 `DashboardPanel`（`ui_qt/panels/dashboard_panel.py`）
- 顶部校徽与 `CountdownRing`（`360×360` QPainter 自绘圆环，33ms 刷新 ~30fps）
- 主操作按钮（开始抢座）与次操作按钮（中止）
- 底部 `LogTerminal`（实时接收 `core.logger.attach_gui_handler` 推送的 INFO 及以上日志流，运行期不再弹出任何浏览器窗口）

---

## 🧵 Worker 线程模型

源码：`ui_qt/workers/booker_worker.py`

```text
点击「开始抢座」
  → 校验表单 & 写回 config.py（并注入内存 config 模块，含 SCHEDULE_HOUR/MINUTE）
  → 启动 prevent_sleep.enable() 防休眠
  → QThread 启动 BookerWorker.run()
      → 调用 main.main(stop_event=self._stop_event)
      → logic.orchestrator 异步预热 ONNX + 多账号纯 HTTP API 调度
      → logger 经信号 log_emitted 实时回推 UI（绝不阻塞主线程）
  → 抢座完成或点击「中止」（stop_event.set() 毫秒级唤醒等待并退出）
  → worker.finished 恢复按钮状态 & prevent_sleep.disable()
  → 延迟 1200ms (QTimer.singleShot) 刷新倒计时圆环状态
```

---

## ⚙️ Config I/O 服务

源码：`ui_qt/services/config_io.py`

- **数据模型**：`GuiState`（含 `campus / room / fallback_rooms / seats / accounts / email / webhook_url / api_base_url / api_fire_offset_ms / mode / sched_hour / sched_min`）与 `AccountState`。
- **双校区 21 间自习室（`ROOM_DATA`）**：
  - 蒲河校区（13 间）：三楼走廊、4楼阅览室、四楼走廊、5楼阅览室、五楼走廊、6楼阅览室、六楼走廊、704、706、707、708、七楼走廊、智慧空间；
  - 崇山校区（8 间）：二楼书库北、二楼书库南、二楼背诵长廊、三楼智慧研修空间、三楼理科书库、四楼北自习室、四楼南自习室、四楼自习室406。
- **向下兼容与无损透传**：
  - 读取旧 v5 `config.py` 时自动静默忽略废弃字段（`BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE`）；
  - 用户在 `config.py` 中手工配置的 `FALLBACK_ROOMS`、`API_BASE_URL`、`API_FIRE_OFFSET_MS` 会在 GUI 读写时完整保留不丢失；
  - `SCHEDULE_HOUR` / `SCHEDULE_MINUTE` 在启动时注入内存 `config` 模块，不覆盖写死。

---

## 🛡️ 防休眠服务

源码：`ui_qt/services/prevent_sleep.py`

| 平台 | 实现机制 | 关键参数 |
| :--- | :--- | :--- |
| **Windows（主力）** | `kernel32.SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED \| ES_DISPLAY_REQUIRED)` + `QTimer` 心跳 + 闲置微抖动 `SendInput(+1px, -1px)` 绕过 S0ix Modern Standby | 心跳间隔 `30s`；用户空闲 `>= 60s` 触发 `1px` 抵消抖动；退出调用 `SetThreadExecutionState(ES_CONTINUOUS)` 还原 |
| **macOS** | 启动系统自带子进程 `caffeinate -dimsu` 阻止显示器/系统/磁盘休眠 | 无需心跳与鼠标抖动；结束或关闭窗口时 `terminate()` 还原 |

---

## 📦 精简打包策略（瘦身 400MB+）

源码：`build.py`（Windows） / `build_mac.py`（macOS）

相比 v5（Windows `613 MB` / macOS `632 MB`），v6 在隔离虚拟环境中采用极限瘦身与架构保障策略，产出体积降至 **Windows `204.7 MB` / macOS `193.6 MB`**：

1. **仅安装 `PySide6-Essentials`**：显式排除 `QtWebEngine / QtPdf / QtQuick / Qt3D / QtMultimedia / QtCharts` 等 30+ 冗余 Qt 模块（立省 500MB+）；
2. **彻底零 Selenium / 零 OpenCV**：`BUILD_DEPS` 仅含 `pyinstaller / PySide6-Essentials / numpy / onnxruntime / Pillow / requests / pycryptodome`；
3. **精简 `ddddocr_lite/`**：仅从 `ddddocr` 提取 `common_old.onnx (13 MB)` + `charset_old.json`，丢弃未用到的 `common.onnx (52 MB)` 与 `common_det.onnx (19 MB)`；
4. **严格过滤模型权重**：仅打包 `core/checkpoints/*.onnx`，排除所有 `.pt / .pth` 训练权重及未在运行期使用的 `logo.png`；
5. **macOS 纯原生 `arm64` 校验（`build_mac.py`）**：强制 `--target-arch arm64`、`Info.plist` 声明 `LSArchitecturePriority: ["arm64"]` 与版本号，打包后扫描包内全部 Mach-O 二进制确保零 `x86_64` 残留（彻底告别 Rosetta 2 提醒）。

---

## 🛠️ 扩展开发指南

- **新增组件**：在 `ui_qt/widgets/` 新建 `QWidget` 子类，统一引用 `theme.C` / `theme.sans()` 等常量；
- **修改配色**：只需调整 `ui_qt/theme.py` 中 `C` 类常量即可全界面生效；
- **严禁耦合**：切勿在 `core/` 或 `logic/` 中导入 `PySide6`，以保证 `pytest tests/ -q` 无头纯离线测试始终畅通。
