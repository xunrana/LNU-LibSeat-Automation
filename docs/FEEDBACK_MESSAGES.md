# 业务反馈与状态分类参考（v6 纯 API）

桌面端（`logic/result_classifier.py`）与移动端（`mobile/lib/logic/result_classifier.dart`）共用的结果决策树，已由跨语言单测锁定一致。v5 时代的浏览器 DOM / toast 检测逻辑已移除。

[← 返回首页](../README.md) · [纯 API 协议契约](API_PROTOCOL_CONTRACT.md) · [架构文档](ARCHITECTURE.md) · [数字参数](NUMERIC_PARAMETERS.md)

---

## 一、核心分类模型：`ApiBookingClassification`

`/rest/v2/freeBook` 返回 JSON 中的 `message` 文本经 `classify_api_booking_result(result_text, in_open_grace_window=...)` 映射为 6 种标准状态（`ApiOutcomeStatus`）与 2 个辅助标记：

| 字段 | 取值 | 含义 |
| :--- | :--- | :--- |
| `status` | `success` | 预约成功（后续调 `/rest/v2/user/reservations` 补全凭证并发送通知） |
| `status` | `stop` | 账号级终态停止（不再尝试其他座位或房间） |
| `status` | `blacklist` | 账号命中 7 天黑名单处罚，立即终止本账号会话 |
| `status` | `retry_captcha` | 当前座位可重试（验证码错、瞬态未开放或短时繁忙） |
| `status` | `seat_taken` | 当前座位已被占或无可用时段，冷却满足时刷新实时空座快照并切下一座 |
| `status` | `failed` | 其他单座失败原因，换下一个候选座位 |
| `not_open_yet` | `bool` | `True` 表示在 `06:30:00–06:30:05` 宽限窗内遇到「未到可预约时间」，短退避原地重探 |
| `rate_limited` | `bool` | `True` 表示命中「操作过于频繁 / 系统繁忙」等限流信号，触发指数退避与熔断计数 |

---

## 二、决策优先级树（严格按代码执行顺序）

```text
输入: result_text, in_open_grace_window
│
├─ 1. is_stop_booking_feedback(text)
│     └─ 含 "系统可预约时间" 且含 "06:30" 且含 "22:30"（兼容 ～/〜/-）
│        ├─ in_open_grace_window == True  → status="retry_captcha", not_open_yet=True（退避 250ms 重探，最多 5 次）
│        └─ in_open_grace_window == False → status="stop"（立即停止）
│
├─ 2. "预约成功" in text                   → status="success"
│
├─ 3. "有效预约" / "每日限制" / "部分读者" → status="stop"
│
├─ 4. is_blacklist_feedback(text)          → status="blacklist"
│     └─ 正则匹配：对不起，您已被加入黑名单，预约权限将在YYYY年M月D日恢复。原因：7天内迟到违约，超过3次，加入黑名单7天
│
├─ 5. is_rate_limited_feedback(text)       → status="retry_captcha", rate_limited=True
│     └─ 关键词："操作过于频繁" / "请求过于频繁" / "系统繁忙"
│
├─ 6. "验证码错误" / "请稍后" / "请重试"   → status="retry_captcha"
│
├─ 7. is_seat_taken_feedback(text)         → status="seat_taken"
│     └─ 关键词："已被他人预约" / "座位已被预约" / "该座位不可用" / "没有可用时间" / "没有可约时间" / "已被占用"
│
└─ 8. 其他未命中文案                       → status="failed"（换下一座）
```

---

## 三、常见服务端反馈与程序行为速查表

| 服务端常见 `message` | 分类输出 | 程序实际行为 |
| :--- | :--- | :--- |
| `预约成功！`（或 `freeBook` 返回 `status=="success"`） | `success` | 核验预约单号与小票凭证 → 发邮件/Webhook/手机通知 → 注册签到提醒 → 结束 |
| `系统可预约时间为 06:30 ~ 22:30`（**宽限窗内**） | `retry_captcha` + `not_open_yet=True` | 等待 `250ms` 原地重探（单座最多 `5` 次宽限重试），不消耗换座机会 |
| `系统可预约时间为 06:30 ~ 22:30`（**宽限窗外**） | `stop` | 判定当前不在开放时段，立即停止本账号 |
| `已有1个有效预约，请在使用结束后再次进行选择` | `stop` | 立即停止（开抢前亦会通过 `/rest/v2/user/reservations` 预检拦截） |
| `预约次数已达到每日限制` | `stop` | 立即停止 |
| `教室仅对部分读者开放` | `stop` | 立即停止 |
| `对不起，您已被加入黑名单，预约权限将在...恢复。原因：7天内迟到违约，超过3次，加入黑名单7天` | `blacklist` | 立即停止本账号，防止无意义请求 |
| `操作过于频繁` / `请求过于频繁` / `系统繁忙`（含 `系统繁忙, 请稍后: 06`） | `retry_captcha` + `rate_limited=True` | 不消耗正常验证码次数；若有明确冷却秒数（如 `06`）则足额等待 `冷却 + 0.60s`，否则按 `RateLimiter` 指数退避（`0.8s → 6.8s`），单座最多 `12` 次繁忙重试，连续 `12` 次限流/429 触发 `RateLimitCircuitOpenError` 熔断 |
| `验证码错误,请重试` / `请稍后` | `retry_captcha` | 重新拉取点选验证码重试当前座位（单座上限 `8` 次；若高峰 Click3 校验已通过但 `freeBook` 报验证码错，自动递增校验后缓冲 `+0.40s` 至最高 `2.80s`） |
| `座位已被他人预约` / `该座位不可用` / `没有可用时间` / `已被占用` | `seat_taken` | 若距离上次刷新 `>= 1.5s`，刷新 `/layoutByDate` 实时空座快照并切换下一空座；主房无空座时顺延 `FALLBACK_ROOMS` |
| 其他未知拒绝文本 | `failed` | 切换下一个候选座位 |

---

## 四、协议层与登录层异常状态

除下单业务反馈外，客户端与调度层还会处理以下结构化异常（桌面与移动一致）：

| 异常 / 状态 | 触发条件 | 程序行为 |
| :--- | :--- | :--- |
| **`TokenExpiredError` (`code == "12"`)** | 任意业务接口返回业务码 `"12"` | `orchestrator` 捕获后自动重新登录刷新 Token 并续跑当前任务 |
| **`TransientServerBusyError`** | 高峰接口返回「系统繁忙 / 请稍后: 06」、网关 5xx 或验证码池拥堵 | 视为可恢复瞬态拥堵而非协议漂移，解析冷却秒数并按 `RateLimiter` 退避重试（单座最多 `12` 次） |
| **`ProtocolDriftError`** | 响应非预期 JSON（非繁忙文本）或缺失核心协议字段 | 判定学校接口改版，**立即熔断停止**以防误操作或刷屏 |
| **`RateLimitCircuitOpenError`** | 连续触发 HTTP 429/限流达 `12` 次，或单会话总请求达 `200` 次上限 | **立即熔断停止**，保护校园网出口与个人账号 |
| **系统维护中 (`maintenance`)** | 登录或响应命中 `系统维护中 / 系统维护 / 维护中` | 调度层休眠 `120s`（`MAINTENANCE_RETRY_INTERVAL_SECONDS`）后自动重试 |
| **凭据错误 (`bad_credentials`)** | 学号或密码错误 | 立即停止本账号，不死循环撞密码 |

---

## 🔗 相关文档

- 🔌 [纯 API 协议契约](API_PROTOCOL_CONTRACT.md) — 接口完整字段定义
- 🔢 [数字参数参考手册](NUMERIC_PARAMETERS.md) — 宽限窗、限流与重试上限精确数值
- 🏗️ [全仓架构文档](ARCHITECTURE.md) — 完整 06:30 抢座时序图
