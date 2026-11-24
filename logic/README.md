# logic/ — 纯 API 业务编排层

抢座核心调度与业务逻辑，零 Selenium / 零 GUI 依赖，驱动桌面 CLI 与 PySide6 GUI，并与移动端 `mobile/lib/logic/` 保持协议和策略语义 1:1 对齐。

| 文件 | 职责 |
|---|---|
| `orchestrator.py` | 多账号并发总控、定时日程计算与精确 `wait_until`、维护期延迟/重连、Token 过期自动重登与成功通知分发 |
| `booker.py` | `ApiSeatBooker`：已有预约预检、动态查房与实时空座刷新、首选直击、多房兜底、验证码闭环、06:30 高峰防风控延时对齐与 6s 滑动冷却、瞬态繁忙重试及 5s 宽限 |
| `seat_strategy.py` | 座号归一化、`FALLBACK_ROOMS` 多自习室规划、实时空座候选排序、多账号 `SeatClaimCoordinator` 防撞座 |
| `result_classifier.py` | 纯函数预约结果分类（`classify_booking_result` + v6 `classify_api_booking_result`），无副作用、可单测 |

> CLI 入口见仓库根 [`main.py`](../main.py)；系统反馈映射见 [`docs/FEEDBACK_MESSAGES.md`](../docs/FEEDBACK_MESSAGES.md)。
