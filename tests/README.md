# tests/ — 全套纯离线单元测试（零浏览器依赖）

```powershell
pip install pytest
pytest tests/ -q
```

| 文件 | 覆盖 |
|---|---|
| `test_api_crypto.py` | AES-128-CBC 登录加密、HMAC-SHA256 签名头、验证码坐标编码、`baseUrl.js` 解析 |
| `test_libseat_client.py` | Mock HTTP 全链路（登录/图形码重试、维护期、查房查座状态映射、Click3 验证码、multipart `freeBook`、取消、Token 过期、高峰繁忙冷却解析、协议漂移与 429 熔断） |
| `test_booker_engine.py` | `ApiSeatBooker` 06:30 瞬态宽限与系统繁忙重试、`FALLBACK_ROOMS` 多房顺延、黑名单/已有预约熔断、`orchestrator` Token 自动重登、会话日志切片与 v5 旧配置兼容 |
| `test_mobile_assets.py` | 跨语言协议测试向量生成、21 间自习室离线目录导出、免签名 `.ipa` 封装与移动端 5 模型 ORT 1.15.1 兼容性校验 |
| `test_clock_sync.py` | HTTP `Date` 头 + `RTT/2` 服务端时钟偏移校准、低 RTT 择优与极端异常时间拒收 |
| `test_rate_limiter.py` | 最小请求间隔、空座冷却、指数退避、429 熔断与单会话请求预算硬顶 |
| `test_captcha_service.py` | Click1 / Click3 显式提示 + 目标图槽位笔迹自适应路由、预热幂等与异常降级 |
| `test_session_recorder.py` | 密码/Token/Cookie/AES 头递归脱敏断言、`http_trace.jsonl` 写入与验证码叠加诊断图 |
| `test_seat_strategy.py` | 座号归一化、实时空座过滤、`FALLBACK_ROOMS` 去重与多账号防撞座协调器 |
| `test_result_classifier.py` | v5/v6 业务反馈分类（含 `seat_taken`、`not_open_yet` 宽限与 `rate_limited`） |
| `test_notifications.py` | 邮件模板（含单号/小票）与 7 类手机端 Webhook 渠道载荷构建及发送 |
| `test_schedule_logic.py` | `build_custom_schedule` 提前量/跨天/跨年、`wait_until` 中断与服务端校准时钟注入 |
| `test_utils.py` | 北京时间时区感知校验 |
| `test_email_manual.py` | 邮件排版手动发送测试脚本 |

> 工具配置集中在仓库根 [`pyproject.toml`](../pyproject.toml)，CI 配置见 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)。
> 移动端（Android & iOS）23 项跨语言契约、Pillow 重采样 SHA-256 与界面单测位于 `mobile/test/`（运行 `cd mobile && flutter test`）。
