# 更新日志

本文件记录项目的重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

各大版本的完整说明见 [`docs/RELEASE_NOTES_V6.md`](docs/RELEASE_NOTES_V6.md)（v6）、[`docs/RELEASE_NOTES_V5.md`](docs/RELEASE_NOTES_V5.md)（v5）与 [`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md)（v3）。

## [Unreleased]

## [6.0.1] - 2026-11-24

> **强烈推荐所有 v6.0.0 用户覆盖升级**（账号、密码、方案与笔记全部保留）。本版本根治了 `06:30` 三字验证码高峰期的「校验通过后下单报验证码错误」与「系统繁忙 6 秒滑动锁 12 次熔断」问题，补齐手机端偏好选座顺位提示与全量日志导出，并将四端统一对齐到 `v6.0.1`。

### Added
- **偏好选座顺位可视化（[Issue #9](https://github.com/xunrana/LNU-LibSeat-Automation/issues/9)）**：手机端「速改 → 首选座位」已选座号右上角显示琥珀色顺位角标（`1 / 2 / 3…`），网格上方新增可横向滚动顺位队列条（轻点移除自动递补）；首页目标摘要、夜守模式与「寻座」存入首选同步展示顺位。
- **移动端全量脱敏日志导出（`mobile/lib/services/log_exporter.dart`）**：支持一键导出最近一轮完整日志（含双账号）或打包全部历史日志（`.zip`），运行日志自动落盘 `run_log.txt`；iOS 开启「文件」App 直读与隔空投送。
- **四端统一版本与日志版本首行标识**：`core/protocol.py` / `mobile/lib/core/protocol.dart` 统一定义 `v6.0.1`（Android `versionCode` 递增至 `611` 保证覆盖安装不降级），桌面与手机端 `session.log` 首行及设置页底部均显示当前版本号，便于排查旧包问题。

### Fixed
- **彻底解决 `06:30` 高峰下单被拒与繁忙熔断（全四端生效）**：
  - 主动对齐官网 Vue 前端 `chunk0.js` 的 `1.5s + 2.0s` 反作弊延时（`1.55s` 求解间隔 + `2.05s` 校验后缓冲，自适应最高 `2.80s`），解决 `checkCaptcha=OK` 后 `freeBook` 仍报「验证码错误」的问题；
  - 将 `06:30` 高峰 `/cap/captcha` 返回「系统繁忙, 请稍后: 05/06」与网关 5xx 归类为 `TransientServerBusyError`（不再误判为协议漂移停机），新增 `parse_retry_after_seconds` 提取倒计时并按 `冷却 + 0.60s` 足额等待，跨次/跨座取码自动保持 `6.20s` 冷却，彻底告别 12 次连续繁忙熔断；
  - 未填首选座时直接复用 `06:29:45` 预热座位表，避免 `06:30:00` 重复刷图。
- **macOS 纯原生 `arm64` 校验（[Issue #8](https://github.com/xunrana/LNU-LibSeat-Automation/issues/8)）**：`build_mac.py` 强制 `--target-arch arm64`、`Info.plist` 声明原生架构并在打包后自动校验全部 180 个 Mach-O 二进制零 `x86_64` / 零 Rosetta 2 依赖。
- **构建产物与文档对齐**：`build.py` 直接产出 `dist/LNU-LibSeat-v6.0.1-Windows-x86_64.zip` 与 Release 命名一致；修正文档内菜单名称与接口方法细节，Release 页面新增 4 端直链下载表。

## [6.0.0] - 2026-11-20

> **核心升级**：彻底移除 Selenium、WebDriver 与 OpenCV 依赖，全面切换为**纯 HTTP API 引擎**（非高峰实测约 **0.55 秒**下单，06:30 高峰自动对齐官网反作弊时间窗与 6 秒冷却），并正式推出 **Android（主力推荐） & iOS 手机独立离线版**，桌面端发行包瘦身 **400MB+**（macOS 为纯原生 `arm64`）。详见 [`docs/RELEASE_NOTES_V6.md`](docs/RELEASE_NOTES_V6.md) 与 [`docs/MIGRATION_V5_TO_V6.md`](docs/MIGRATION_V5_TO_V6.md)。

### Added
- **手机独立离线版（`mobile/`，Android 主推 · 同步支持 iOS）**：
  - 100% 脱离电脑、零服务器成本的 Flutter 跨平台应用，内置与桌面端同源的 **5 个原版无损 ONNX 模型**（`159.52 MB`，自动确保 `IR <= 8` / `Opset <= 18`），通过 `pil_image_ops.dart` 逐字节复现 Python Pillow 22-bit 定点重采样，Android 走原生 CPU `BitmapFactory`、iOS 走原生 CPU `ImageIO`，息屏无 GPU 依赖。
  - 完整「晨约 · 寻座 · 入馆 · 我的」四频道：崇山/蒲河 21 间自习室实时余座雷达、单室可视化选座网格直订、宝藏座笔记、双号全天接力与违约守护、系统级签到防违约提醒（开始前 15m 温和提醒 & 开始后 20m 紧急催促，锁屏/划后台仍响）。
  - **偏好选座顺位提示（Issue #9）**：在「速改 → 首选座位」点选座号后，已选座位右上角显示琥珀色顺位角标（`1 / 2 / 3…`），网格上方新增横向可滚动顺位队列条（轻点移除自动递补）；首页目标摘要、夜守模式与「寻座」存入首选全面同步顺位。
  - **移动端全量脱敏日志导出（`log_exporter.dart`）**：支持导出最近一轮完整日志（含双账号）或打包全部历史日志（`.zip`），运行终端日志自动落盘 `run_log.txt`（2MB 滚动保留 1MB）；iOS 开启 `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`，支持系统「文件」App 直接查看与隔空投送。
  - **Android 06:30 隔夜防杀与解冻（`MainActivity.kt`）**：`RushForegroundService`（`mediaPlayback|specialUse`）+ 正式 `MediaSession`（`STATE_PLAYING`）+ `AudioTrack MODE_STREAM` 24kHz/-90dB 实时流不可闻防冻结音频（不占音频焦点）+ 通知栏每秒实时倒计时与原生 250ms 心跳驱动 + 动态 26h `WakeLock` / `WifiLock` + 四段式系统硬件闹钟（`-35s / -15s / -5s / -1s` + `goAsync()` 7.5s 广播租约）+ Android 14 锁屏全屏强解冻 + `RushBootReceiver` 重启恢复 + App 内 4 项实时保活体检。
  - **iOS 锁屏静音保活（`AppDelegate.swift`）**：`UIBackgroundModes: audio` 全零静音流（`.mixWithOthers` 不打断其他音频，抢完自动释放）+ `lnulibseat://` 快捷指令深链；双端均提供「银杏夜守」OLED 纯黑床头模式。
  - 一键本地构建脚本 `build_android.py`（产出 `dist/辽宁大学图书馆座位预约.apk`）、`build_ios.py`（产出免签名 `.ipa`）与资源/黄金向量脚本 `scripts/prepare_mobile_assets.py`、`scripts/dump_test_vectors.py`。
- **纯 API 协议与客户端层（桌面 & 移动同构）**：
  - `core/protocol.py`：全量端点单一来源、动态拉取 `baseUrl.js` 签名配置、`ProtocolDriftError`（协议漂移熔断）、`TransientServerBusyError`（高峰繁忙退避重试与 `parse_retry_after_seconds` 冷却秒数提取）及 `TokenExpiredError`（`code == "12"` 自动重登）。
  - `core/api_crypto.py`：实现 AES-128-CBC + PKCS7 登录凭据加密（`+ "_encrypt"`）、HMAC-SHA256 全局请求头签名（`X-request-id` / `X-request-date` / `X-hmac-request-key`）及点选坐标 Base64 编码。
  - `core/libseat_client.py`：强类型 `LibSeatClient` Protocol 与 `HttpLibSeatClient`（`requests.Session` 连接池复用、实时查校区/自习室/空座/布局、`multipart/form-data` `freeBook` 一步下单、预约查询与取消）。
- **时序、限流与防风控基础设施**：
  - `core/clock_sync.py`：基于 HTTP `Date` 响应头 + `RTT/2` 自动校准服务端北京时间，替代盲目 `time.sleep(2)`。
  - `core/rate_limiter.py`：请求最小间隔（`120ms ± 40ms`）、实时空座快照刷新冷却（`1.5s`）、指数退避（限流起点 `0.8s`，上限 `6.8s`，支持按服务端返回冷却秒数足额等待）、连续 12 次限流/429 熔断与单会话 200 次请求预算硬顶。
  - `core/captcha_service.py`：统一 Click1 / Click3 ONNX 模型预热与线程锁，支持按服务端 `wordCheckCount` → 槽位笔迹 → 时间窗三级全天候自适应路由。
  - `core/session_recorder.py`：API 级会话诊断产物——白名单递归脱敏 `http_trace.jsonl` 与轻量验证码候选/点击叠加图（`< 50KB`）。
- **选座增强与手机推送**：
  - `logic/seat_strategy.py`：实时空座优先筛选、**`FALLBACK_ROOMS` 多自习室兜底**（通过 `room/stats2` 快查跳过满员房）、进程内多账号 `SeatClaimCoordinator` 防撞座（重叠时段错开，不重叠无缝接力放行）。
  - `logic/orchestrator.py`：引擎无关的多账号调度、维护期延迟/重连（`120s`）、Token 过期自动重登与 `06:30:00~06:30:05` 放座瞬态宽限重试。
  - `core/notifications.py`：新增手机端即时 Webhook 推送（自动适配 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉 / 通用 JSON），成功战报附带预约单号与小票凭证。
  - `logic/result_classifier.py`：新增 `classify_api_booking_result`（细分 `seat_taken`、`not_open_yet` 宽限窗与 `rate_limited`），保持 v5 `classify_booking_result` 100% 向后兼容。
- **工程化、测试与文档**：
  - 全套 **94 项 Python 离线单元测试**（`tests/`）+ **23 项 Flutter 跨语言契约与界面单测**（`mobile/test/`）。
  - 全平台文档重构：主推 Android & Windows，同步覆盖 iOS & macOS（`docs/ANDROID_INSTALL_GUIDE.md`、`docs/IOS_INSTALL_GUIDE.md`、`mobile/README.md`、`docs/API_PROTOCOL_CONTRACT.md`、`docs/RELEASE_NOTES_V6.md`、`docs/MIGRATION_V5_TO_V6.md` 等）。

### Changed
- `logic/booker.py` 与 `mobile/lib/logic/booker.dart` 重写为纯 API `ApiSeatBooker`：非高峰单字码直连约 `0.55s` 下单；06:30 高峰三字码主动对齐官网 `chunk0.js` 反作弊延时（`1.55s` 求解间隔 + `2.05s` 校验后缓冲，自适应最高 `2.80s`）与 `6.20s` 取码冷却，并支持单座最多 `12` 次繁忙重试。
- `main.py` 瘦身为薄入口，委托 `logic/orchestrator.py` 调度（定时模式提前量优化为 `PREP_LEAD_SECONDS = 15`、`KEEPALIVE_LEAD_SECONDS = 5`、`DEFAULT_FIRE_OFFSET_MS = 200`）。
- `ui_qt/panels/config_panel.py` 与 `ui_qt/services/config_io.py`：移除浏览器下拉框与 WebDriver 配置（读取旧 v5 `config.py` 时自动静默忽略废弃字段），新增「手机推送 Webhook」输入框，并允许留空 `PREFER_SEATS` 直接抢实时空座。
- `build.py` / `build_mac.py` / `core/captcha.py`：采用 `PySide6-Essentials` + 精简提取 `ddddocr_lite/`（仅 `common_old.onnx` + `charset_old.json`）+ 零 OpenCV + 仅打 `*.onnx`，桌面发行包体积由 Win 613MB / Mac 632MB 降至 **Win 204.7MB / Mac 193.6MB**（直减 **400MB+**）；`build_mac.py` 新增强制 `--target-arch arm64`、`Info.plist` 原生架构声明与打包后全量 Mach-O 纯 `arm64` 校验（Issue #8）。
- 全仓类型标注收敛与 `ruff check .` 0 告警门禁。

### Removed
- **彻底移除 Selenium 与 OpenCV 运行时依赖**：删除 `core/driver.py`、`core/screen_recorder.py`、`core/captcha_api.py`、`logic/navigator.py`、`logic/auth.py` 及对应旧浏览器测试；从运行时与打包依赖移除 `selenium`、`webdriver-manager`、`mss`、`cv2`。
- 移除废弃配置字段 `BROWSER`、`DRIVER_PATH`、`WEBDRIVER_CACHE`（老配置兼容静默忽略）。

### Fixed
- 修复 06:30 高峰「系统繁忙, 请稍后: 06」/ 网关 5xx 被误判为 `ProtocolDriftError` 导致停机的问题，并避免未填首选座时在 `06:30:00` 重复拉取空座布局。
- 修复 Windows 源码运行时 console 打印 emoji 触发的 GBK `UnicodeEncodeError`（`core/logger.py`）。
- 修复 `logic/booker.py` 中 `_AccountLoggerAdapter` 误把 `[%s]` 占位符当成账号标签导致「抢座开始」日志漏打 `[account]` 前缀的问题。

## [5.0.0]
- 全新 PySide6 界面；自研 **YOLOv8 + Siamese** 本地验证码识别取代付费 API；模型预加载；全自习室扫描；会话级追溯（日志 + 截图 + 录屏）。
- 详见 [`docs/RELEASE_NOTES_V5.md`](docs/RELEASE_NOTES_V5.md) 与 [`docs/MIGRATION_V3_TO_V5.md`](docs/MIGRATION_V3_TO_V5.md)。

## [3.0.1]
- v3 维护修复。

## [3.0.0]
- 整间自习室兜底扫描、双引擎验证码（图鉴 API + ddddocr）、会话级追踪。详见 [`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md)。

## [2.3.0] – [2.8.0]
- 早期迭代：点选文字验证码识别、多账号并发、定时模式等逐步成型（见 git 标签）。

[Unreleased]: https://github.com/xunrana/LNU-LibSeat-Automation/compare/v6.0.1...HEAD
[6.0.1]: https://github.com/xunrana/LNU-LibSeat-Automation/compare/v6.0.0...v6.0.1
[6.0.0]: https://github.com/xunrana/LNU-LibSeat-Automation/compare/v5.0.0...v6.0.0
[5.0.0]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v5.0.0
[3.0.1]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v3.0.1
[3.0.0]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v3.0.0
