<div align="center">

# 📦 LNU-LibSeat v6.0.0 发布说明

### 彻底告别浏览器 · 纯 HTTP API 引擎 · 实测 0.55 秒下单

[← 返回 README](../README.md) ·
[v5 → v6 升级指南](MIGRATION_V5_TO_V6.md) ·
[架构文档](ARCHITECTURE.md) ·
[纯 API 协议契约](API_PROTOCOL_CONTRACT.md)

</div>

---

> [!IMPORTANT]
> 本次发布是一次**里程碑式底层重构**（源自社区 [Issue #4](https://github.com/xunrana/LNU-LibSeat-Automation/issues/4)）：**彻底移除 Selenium、WebDriver 与 Chromium 浏览器依赖**，全面转向纯 HTTP API 引擎，同时保持 v5 配置文件 100% 向后兼容。

---

## 🔥 核心亮点

### 1. 纯 HTTP API 直连，核心下单 0.55 秒
- 完整复现登录 `AES-128-CBC` 凭据加密、全局 `HMAC-SHA256` 请求签名与 `baseUrl.js` 动态配置引导（`core/protocol.py` + `core/api_crypto.py` + `core/libseat_client.py`）。
- 消除原前端 Vue 强制的 **1.5s 隐藏确定按钮 + 2.0s 假加载动画**，实机测试从锁定空座到 `freeBook` 返回预约单号仅需 **0.55 秒**（其中本地 ONNX 推理 62ms）。
- 彻底摆脱 Edge / Chrome / Safari 版本匹配、WebDriver 缓存失效、Edge 锁文件冲突与 1.5GB 浏览器内存占用，**Windows 与 macOS 双账号原生并行、体验完全一致**。

### 2. 服务端时钟自动校准 + 06:30 瞬态宽限
- 新增 `core/clock_sync.py`：在登录与 `06:29:55` 保活时解析 HTTP `Date` 响应头并结合 `RTT/2` 计算时钟偏移（实测可精准吸收本机偏快 1.4s+ 的误差）。
- 定时模式下 `06:30:00–06:30:05` 区间内若遇到服务端切换瞬态返回「系统可预约时间为 06:30 ~ 22:30」，自动短退避原地重探而非误判终止。

### 3. 实时空座精准筛查 + 多自习室兜底 + 多账号防撞座
- 动态解析 `room_id` 与全房座位 `seat_id` 实时占用状态，告别全房盲扫；`PREFER_SEATS` 支持留空直接抢实时空座。
- 新增 `FALLBACK_ROOMS` 多自习室兜底规划，切换备选房前通过 76ms 的 `room/stats2` 快查自动跳过满员房。
- 新增进程内 `SeatClaimCoordinator`：重叠时段并发账号自动错开兜底座，不重叠接力时段（如 `09:00-15:00` + `15:00-21:00`）放行同抢心仪座。

### 4. 自适应 Click1 / Click3 验证码服务
- 新增 `core/captcha_service.py`：直接按服务端 `/cap/captcha` 返回的 `wordCheckCount`（`1` 或 `3`）精准路由本地 Click1 / Click3 ONNX 模型，辅以目标图槽位笔迹兜底判断，1:1 原生像素坐标直传。

### 5. 手机端即时 Webhook 推送 + 轻量脱敏追溯
- `core/notifications.py` 新增 `WEBHOOK_URL`（GUI 账号卡新增「手机推送」输入框），自动识别 **Bark（iOS）/ PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉 / 通用 JSON**，战报附带**预约单号与小票凭证**。
- `core/session_recorder.py` 取代笨重 MP4 录屏：自动输出严格脱敏的 `http_trace.jsonl`（抹除密码/Token/Cookie）与轻量验证码候选/点击叠加图（`< 50KB`）。

### 6. 防风控护栏与打包瘦身
- 新增 `core/rate_limiter.py`：内置最小请求间隔 + 随机 Jitter + 1.5s 空座刷新冷却 + 429 熔断 + 单会话请求硬顶；检测到黑名单或 `ProtocolDriftError` 立即停机保号。
- `build.py` / `build_mac.py` 剔除 `selenium` / `webdriver-manager` / `mss` 并过滤仅打包 `*.onnx`（排除本地 `.pt/.pth` 权重），发行包大幅瘦身 **100MB+**。

---

## 📦 下载与升级

- **Windows**：下载 `LNU-LibSeat-v6.0.0-Windows-x86_64.zip` → 解压双击 `LNU-LibSeat.exe`
- **macOS**：下载 `LNU-LibSeat-v6.0.0-macOS-arm64.zip` → 右键运行 `首次运行请先双击我.command`
- **Android（安卓手机，0 元直接安装）**：下载 `LNU-LibSeat-Android-arm64.apk`（内置 5 个原版无损 ONNX 模型 + 5 重隔夜防杀保活 + Android 14 锁屏全屏解冻 + 银杏夜守），详细安装与国产 ROM 防冻结步骤见 [Android 直装与保活教程](ANDROID_INSTALL_GUIDE.md) · [手机独立版说明](../mobile/README.md)
- **iOS（iPhone / iPad，0 元免费自签）**：下载 `LNU-LibSeat-iOS-arm64-unsigned.ipa`（内置 5 个原版无损 ONNX 模型 + 锁屏后台静音保活 + 银杏夜守），详细图文安装步骤见 [iOS 零元安装教程](IOS_INSTALL_GUIDE.md) · [手机独立版说明](../mobile/README.md)
- **v5 老用户**：旧 `config.py` 直接复制过来即可运行，废弃的 `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` 会被自动静默忽略。详见 [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)。

---

## 🧪 质量保证

- 新增并重整全套 **87 个纯离线单元测试**（零浏览器依赖，1.1s 跑完），覆盖加解密、HMAC 签名、客户端契约、时钟校准、限流熔断、自适应验证码路由、选座策略、状态机与脱敏断言。
- `ruff check .` 0 告警通过。

---

## 🙏 致谢

特别感谢 **[@MorinGale](https://github.com/MorinGale)** 在 [Issue #4](https://github.com/xunrana/LNU-LibSeat-Automation/issues/4) 提出的纯 API 设想与可行性验证！
