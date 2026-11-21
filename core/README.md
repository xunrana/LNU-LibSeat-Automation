# core/ — 协议与基础设施层（v6 纯 API，零 Selenium / 零 OpenCV）

与具体抢座策略解耦的底层能力：HTTP 协议客户端、加解密与签名、服务端时钟校准、限流护栏、本地 ONNX 验证码识别、脱敏追溯、日志与多渠道通知。

| 文件 | 职责 |
|---|---|
| `protocol.py` | 全量 API 端点常量、`baseUrl.js` `Global` 动态引导、`ProtocolDriftError` / `TokenExpiredError` |
| `api_crypto.py` | AES-128-CBC + PKCS7 登录凭据加密、HMAC-SHA256 全局请求签名、验证码坐标 Base64 编码 |
| `libseat_client.py` | 强类型 `LibSeatClient` Protocol 与 `HttpLibSeatClient`（`requests.Session` 连接池实现） |
| `clock_sync.py` | 基于 HTTP `Date` 响应头 + `RTT/2` 补偿的服务端北京时间校准 |
| `rate_limiter.py` | 最小请求间隔 + Jitter、空座刷新冷却、指数退避、429 熔断与单会话请求上限 |
| `captcha_service.py` | Click1 + Click3 统一自适应推理服务（按 `wordCheckCount` / 槽位笔迹 / 时间窗三级路由 + 锁 + 预热） |
| `captcha.py` | 登录页 4 位图形验证码识别（优先加载 `ddddocr_lite/common_old.onnx`，纯 Pillow + ONNX 零 OpenCV） |
| `captcha_yolo4_siamese.py` | 点选验证码 **Click3** 求解器（YOLOv8 检测 + Siamese 相似度） |
| `captcha_click1_yolo4_siamese.py` | 点选验证码 **Click1** 求解器（`Click1Yolo4SiameseSolver.solve()`） |
| `yolo_onnx.py` | YOLOv8 ONNX 通用推理封装 |
| `checkpoints/` | 4 个点选验证码运行时 ONNX 权重（Click1/Click3 的 yolo + siamese） |
| `session_recorder.py` | API 级脱敏追溯（`http_trace.jsonl` + 轻量验证码候选/点击叠加诊断图） |
| `notifications.py` | 内置 SMTP 邮件通知 + 手机端即时 Webhook 推送（Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉） |
| `logger.py` | 日志系统（按账号路由、毫秒级时间、GUI 回调 handler、Windows UTF-8 防崩溃） |
| `paths.py` | 跨平台资源与用户数据路径解析（兼容 PyInstaller 冻结态） |
| `utils.py` | 北京时间工具函数 |

> 验证码对外是 **YOLOv8 + Siamese**；文件名里的 `yolo4` 是历史实验代号，非架构版本。
> 移动端同源 Dart 实现位于 [`mobile/lib/core/`](../mobile/README.md)；训练代码见 [`model/`](../model/README.md) 与 [`train/`](../train/README.md)；协议契约见 [`docs/API_PROTOCOL_CONTRACT.md`](../docs/API_PROTOCOL_CONTRACT.md)。
