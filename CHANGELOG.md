# 更新日志

本文件记录项目的重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

各大版本的完整说明见 [`docs/RELEASE_NOTES_V6.md`](docs/RELEASE_NOTES_V6.md)（v6）、[`docs/RELEASE_NOTES_V5.md`](docs/RELEASE_NOTES_V5.md)（v5）与 [`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md)（v3）。

## [Unreleased]

## [6.0.0] - 2026-11-19

> **核心升级**：彻底移除 Selenium 与浏览器自动化链，全面切换为**纯 HTTP API 引擎**，实测核心下单仅需 **0.55 秒**。详见 [`docs/RELEASE_NOTES_V6.md`](docs/RELEASE_NOTES_V6.md) 与 [`docs/MIGRATION_V5_TO_V6.md`](docs/MIGRATION_V5_TO_V6.md)。

### Added
- **纯 API 协议与客户端层**：
  - `core/protocol.py`：全量端点单一来源、动态拉取 `baseUrl.js` 签名配置、`ProtocolDriftError`（协议漂移熔断）与 `TokenExpiredError`（`code == "12"` 自动重登）。
  - `core/api_crypto.py`：实现 AES-128-CBC + PKCS7 登录凭据加密（`+ "_encrypt"`）、HMAC-SHA256 全局请求头签名（`X-request-id` / `X-request-date` / `X-hmac-request-key`）及点选坐标 Base64 编码。
  - `core/libseat_client.py`：强类型 `LibSeatClient` Protocol 与 `HttpLibSeatClient`（`requests.Session` 连接池复用、实时查校区/自习室/空座/布局、`multipart/form-data` `freeBook` 一步下单、预约查询与取消）。
- **时序、限流与防风控基础设施**：
  - `core/clock_sync.py`：基于 HTTP `Date` 响应头 + `RTT/2` 自动校准服务端北京时间，替代盲目 `time.sleep(2)`。
  - `core/rate_limiter.py`：请求最小间隔 + 随机 Jitter、实时空座快照刷新冷却（1.5s）、指数退避、连续 429 熔断与单会话请求预算硬顶。
  - `core/captcha_service.py`：统一 Click1 / Click3 ONNX 模型预热与线程锁，支持按服务端 `wordCheckCount` 与图像槽位笔迹自适应路由。
  - `core/session_recorder.py`：API 级会话诊断产物——白名单递归脱敏 `http_trace.jsonl` 与轻量验证码候选/点击叠加图（`< 50KB`）。
- **选座增强与手机推送**：
  - `logic/seat_strategy.py`：实时空座优先筛选、**`FALLBACK_ROOMS` 多自习室兜底**（通过 `room/stats2` 76ms 快查跳过满员房）、进程内多账号 `SeatClaimCoordinator` 防撞座（重叠时段错开，不重叠无缝接力放行）。
  - `logic/orchestrator.py`：引擎无关的多账号调度、维护期延迟/重连、Token 过期自动重登与 `06:30:00~06:30:05` 放座瞬态宽限重试。
  - `core/notifications.py`：新增手机端即时 Webhook 推送（自动适配 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉 / 通用 JSON），成功战报附带预约单号与小票凭证。
  - `logic/result_classifier.py`：新增 `classify_api_booking_result`（细分 `seat_taken`、`not_open_yet` 宽限窗与 `rate_limited`），保持 v5 `classify_booking_result` 100% 向后兼容。
- **工程化与文档**：
  - 完整离线协议契约 [`docs/API_PROTOCOL_CONTRACT.md`](docs/API_PROTOCOL_CONTRACT.md)、[`docs/RELEASE_NOTES_V6.md`](docs/RELEASE_NOTES_V6.md)、[`docs/MIGRATION_V5_TO_V6.md`](docs/MIGRATION_V5_TO_V6.md)。
  - CI 工作流（`.github/workflows/ci.yml` + Windows / macOS 打包工作流）、`pyproject.toml` 单一工具配置、公开 `train/` 训练管线及全套 87 个纯离线单元测试（`tests/`）。

### Changed
- `logic/booker.py` 重写为纯 API `ApiSeatBooker`，消除原前端 Vue 1.5s 按钮隐藏 + 2.0s 假加载动画共 3.5s 人为延时。
- `main.py` 瘦身为 39 行薄入口，委托 `logic/orchestrator.py` 调度（定时模式提前量优化为 `PREP_LEAD_SECONDS = 15`、`KEEPALIVE_LEAD_SECONDS = 5`）。
- `ui_qt/panels/config_panel.py` 与 `ui_qt/services/config_io.py`：移除浏览器下拉框与 WebDriver 配置（读取旧 v5 `config.py` 时自动静默忽略废弃字段），新增「手机推送 Webhook」输入框，并允许留空 `PREFER_SEATS` 直接抢实时空座。
- `build.py` / `build_mac.py` / `requirements.txt`：版本号升至 `v6.0.0`，新增 `pycryptodome` 依赖，并修复 `core/checkpoints/` 拷贝逻辑仅打包 `*.onnx`（排除本地 `.pt`/`.pth` 立减 ~73MB）。
- 全仓类型标注收敛与 ruff 0 告警门禁。

### Removed
- **彻底移除 Selenium 生态**：删除 `core/driver.py`、`core/screen_recorder.py`、`core/captcha_api.py`、`logic/navigator.py`、`logic/auth.py` 及对应旧浏览器测试；从运行时与打包依赖移除 `selenium`、`webdriver-manager`、`mss`。
- 移除废弃配置字段 `BROWSER`、`DRIVER_PATH`、`WEBDRIVER_CACHE`（老配置兼容静默忽略）。

### Fixed
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

[Unreleased]: https://github.com/XUNRANA/LNU-LibSeat-Automation/compare/v6.0.0...HEAD
[6.0.0]: https://github.com/XUNRANA/LNU-LibSeat-Automation/compare/v5.0.0...v6.0.0
[5.0.0]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v5.0.0
[3.0.1]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v3.0.1
[3.0.0]: https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/tag/v3.0.0
