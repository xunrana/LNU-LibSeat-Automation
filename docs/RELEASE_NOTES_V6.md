<div align="center">

# 📦 LNU-LibSeat v6.0.0 发布说明

### 纯 HTTP API 全平台引擎（主推 Android & Windows · 同步支持 iOS & macOS）· 实测 0.55 秒下单

[← 返回 README](../README.md) ·
[🤖 Android 直装与保活教程](ANDROID_INSTALL_GUIDE.md) ·
[📘 全平台快速上手](QUICKSTART.md) ·
[📱 手机独立版全览](../mobile/README.md) ·
[🍎 iOS 零元安装教程](IOS_INSTALL_GUIDE.md) ·
[v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)

</div>

---

> [!IMPORTANT]
> 本次发布是一次**里程碑式底层与全平台重构**（源自社区 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) & [Issue #6](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/6)）：**彻底移除 Selenium、WebDriver、OpenCV 与浏览器依赖**，全面转向实测 **0.55 秒下单** 的纯 HTTP API 引擎，并正式推出 **Android / iOS 手机独立离线版**（100% 脱离电脑），同时保持桌面端 v5 `config.py` 100% 向后兼容。

---

## 📦 下载选型（先看这里）

| 推荐档位 | 平台 | 安装包文件 | 体积 | 特点与安装方式 | 详细教程 |
| :--- | :--- | :--- | :---: | :--- | :--- |
| **🏆 首选主推** | **🤖 Android 手机** | `LNU-LibSeat-Android-arm64.apk` | `165.9 MB` | **0 元直装、永久免续签**；脱离电脑、全馆 21 室雷达、5 重隔夜保活 + Android 14 锁屏解冻、系统签到提醒 | [Android 直装与保活教程](ANDROID_INSTALL_GUIDE.md) |
| **🏆 首选主推** | **🪟 Windows 电脑** | `LNU-LibSeat-v6.0.0-Windows-x86_64.zip` | `204.6 MB` | **解压双击 `LNU-LibSeat.exe` 即用**；零浏览器/零 Python、内置防休眠，较 v5 瘦身 408MB+ | [全平台快速上手](QUICKSTART.md) |
| 🍎 苹果生态 | **📱 iPhone / iPad** | `LNU-LibSeat-iOS-arm64-unsigned.ipa` | `146.7 MB` | **0 元免越狱自签**（Sideloadly / 爱思 / SideStore / 巨魔）；内置锁屏静音保活 + 银杏夜守 | [iOS 零元安装教程](IOS_INSTALL_GUIDE.md) |
| 🍎 苹果生态 | **💻 macOS 电脑** | `LNU-LibSeat-v6.0.0-macOS-arm64.zip` | `193.6 MB` | **Apple Silicon 原生 `.app`**；右键 `.command` 首启，双账号原生并行，较 v5 瘦身 438MB+ | [全平台快速上手](QUICKSTART.md) |

> **v5 桌面老用户升级**：旧 `config.py` 直接复制到新目录即可运行，废弃的 `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` 会被自动静默忽略。详见 [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)。

---

## 🔥 核心亮点

### 1. 纯 HTTP API 直连底座，实测核心下单 0.55 秒
- 完整实现 `AES-128-CBC` 登录凭据加密、`HMAC-SHA256` 全局请求签名与 `baseUrl.js` 动态密钥引导（`core/protocol.py` + `core/api_crypto.py` + `core/libseat_client.py`；移动端 Dart 引擎 1:1 对齐）。
- 消除原 Vue 前端强制的 **1.5 秒隐藏确定按钮 + 2.0 秒假加载动画**，实机测试从锁定空座到 `freeBook` 返回预约单号仅需 **0.55 秒**（其中本地 ONNX 点选推理 ~62ms）。
- 彻底摆脱 Edge / Chrome / Safari 版本匹配、WebDriver 缓存失效与 1.5GB 浏览器内存占用。

### 2. 🤖 Android 手机独立版（主推 · 0 元永久直装，100% 脱离电脑）
- 端侧离线内置与桌面端同源的 **5 个原版无损 ONNX 模型**（总计 `159.52 MB`），采用原生纯 CPU `BitmapFactory` 解码并逐像素对齐 Python Pillow 22-bit 定点重采样，息屏无 GPU 依赖、识别率与桌面端一致。
- 完整提供 **「晨约 · 寻座 · 入馆 · 我的」** 四频道：双校区 21 间自习室实时余座雷达、单室可视化座位网格一键直订、宝藏座笔记、双号全天接力与违约信用守护、系统级签到防违约提醒（开始前 15 分钟 / 签到截止前 10 分钟）。
- **5 重 06:30 隔夜防杀 + Android 14 锁屏全屏解冻**：`AlarmClock` 主唤醒（提前 20 秒）+ `prepAt` 预热轻推双闹钟 + Android 14 `MODE_BACKGROUND_ACTIVITY_START_ALLOWED` / `CATEGORY_ALARM` 全屏唤醒解冻 + 动态 26 小时 `WakeLock` + `WifiLock` + 被杀冷启动续抢 / 夜间重启自恢复，配合 App 内 4 项实时权限体检与「银杏夜守」OLED 纯黑床头模式。

### 3. 🪟 Windows & 💻 macOS 桌面独立版（极致瘦身 400MB+）
- `build.py` / `build_mac.py` 彻底剔除 `selenium`、`webdriver-manager`、`mss` 与 `cv2 (OpenCV)`，改用 `PySide6-Essentials` 仅打包核心 Qt 模块，并从 `ddddocr` 精简提取 `common_old.onnx (13 MB) + charset_old.json` 且过滤排除 `.pt/.pth` 训练权重：
  - Windows 发行包从 **613 MB → 204.6 MB**；
  - macOS 发行包从 **632 MB → 193.6 MB**，且彻底告别 Safari 单账号限制，Win / Mac 双账号原生并行体验完全一致。
- 保留系统级防休眠（Windows `SetThreadExecutionState` + 30 秒心跳；macOS `caffeinate -dimsu`），适合电脑整晚无人值守挂机。

### 4. 🍎 iPhone / iPad 独立版（0 元免越狱自签）
- 与 Android 共享同一套 Flutter 界面、纯 API 引擎与 5 个原版无损 ONNX 模型，采用原生纯 CPU `ImageIO + CoreGraphics` 解码（锁屏不依赖 Metal GPU）。
- 内置 `UIBackgroundModes: audio` 全零静音锁屏后台保活（`.mixWithOthers` 不打断听歌、抢完自动释放）+ 「银杏夜守」OLED 纯黑床头模式 + `UNUserNotificationCenter` 时效签到提醒。

### 5. 服务端时钟自动校准 + 06:30 瞬态宽限 + 智能空座策略
- **时钟校准 (`core/clock_sync.py`)**：解析 HTTP `Date` 响应头并结合 `RTT/2` 校准服务端北京时间；`06:30:00–06:30:05` 区间若遇「系统可预约时间为 06:30 ~ 22:30」自动短退避原地重探（最多 5 次 × 250ms）。
- **实时空座 + 多房兜底 + 防撞座 (`logic/seat_strategy.py`)**：`PREFER_SEATS` 支持留空直接抢实时空座；支持 `FALLBACK_ROOMS` 多自习室顺延并通过 `room/stats2` 快查自动跳过满员房；`SeatClaimCoordinator` 在重叠时段自动错开、不重叠接力时段放行同抢心仪座。
- **自适应 Click1 / Click3 验证码服务 (`core/captcha_service.py`)**：按 `wordCheckCount` → 目标图槽位笔迹 → 时间窗三级路由，1:1 原生像素坐标直传。

### 6. 手机端即时 Webhook 推送 + 限流熔断 + 轻量脱敏追溯
- `core/notifications.py`（及手机端 `notification_service.dart`）支持内置 126 邮箱直发 + `WEBHOOK_URL` 自动识别 **Bark / PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉 / 通用 JSON**，战报附带**预约单号与小票凭证**。
- `core/rate_limiter.py` 内置 `120ms ± 40ms` 最小请求间隔、1.5 秒空座刷新冷却、连续 5 次限流/429 熔断与单会话 160 次请求硬顶；`core/session_recorder.py` 以脱敏 `http_trace.jsonl` + `< 50KB` 验证码叠加图取代笨重 MP4 录屏。

---

## 🧪 质量保证

- **桌面端**：**92 项纯离线 Python 单元测试**（`pytest tests/ -q`）全部通过，零浏览器依赖。
- **移动端**：**19 项 Flutter 跨语言契约与界面单测**（`flutter test`，含 AES/HMAC、Pillow 22-bit 定点重采样 SHA-256 逐字节校验、结果分类器与隔夜唤醒状态机）全部通过。
- **代码门禁**：`ruff check .` 0 告警通过。

---

## 🙏 致谢

特别感谢 **[@MorinGale](https://github.com/MorinGale)** 在 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 提出的纯 API 设想与可行性验证，以及所有在真机上协助反馈 Android 14 / iOS 实测细节的同学们！
