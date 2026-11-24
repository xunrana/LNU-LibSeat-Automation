# 关键数字参数参考手册（v6）

桌面端（Python）与移动端（Flutter / Android / iOS）的超时、间隔、重试上限等常量清单，均逐条核对自当前 `master` 源码。

[← 返回首页](../README.md) · [架构文档](ARCHITECTURE.md) · [配置详解](CONFIGURATION.md) · [业务反馈分类](FEEDBACK_MESSAGES.md) · [验证码引擎](CAPTCHA_YOLO4_SIAMESE.md)

---

## 一、定时调度与多账号编排（桌面 & 移动一致）

> 源码：`logic/orchestrator.py`（Python） / `mobile/lib/logic/orchestrator.dart`（Dart）

| 参数 | 值 | 源码符号 | 说明 |
| :--- | :---: | :--- | :--- |
| 预热提前量 | `15` 秒 | `PREP_LEAD_SECONDS` / `prepLeadSeconds` | 开抢前 15s（`06:29:45`）登录并预拉自习室与全房座号索引 |
| 保活提前量 | `5` 秒 | `KEEPALIVE_LEAD_SECONDS` / `keepaliveLeadSeconds` | 开抢前 5s（`06:29:55`）发 `/rest/v2/user` 保活 TCP 并二次校准服务端时钟 |
| 准点顺延偏移 | `200` ms | `DEFAULT_FIRE_OFFSET_MS` / `API_FIRE_OFFSET_MS` | 定时准点后顺延 200ms 开枪（`06:30:00.200`），避免踩服务端切状态边界 |
| 多账号启动错开 | `2` 秒 | `ACCOUNT_STAGGER_SECONDS` / `accountStaggerSeconds` | 并发多账号预热错开间隔 |
| 最大并发账号数 | `2` | `MAX_ACCOUNTS` (`ui_qt/services/config_io.py`) | 默认最多并发 2 个账号 |
| 维护期重试间隔 | `120` 秒 | `MAINTENANCE_RETRY_INTERVAL_SECONDS` | 遇到「系统维护中」时等待 2 分钟后重连 |
| 长等待心跳间隔 | `1800` 秒 | `wait_until` (`heartbeat_interval`) | 长等待每 30 分钟输出一条心跳日志 |
| 精确等待分段 | `>0.5s` 休眠 ≤0.2s；`0.02–0.5s` 休眠 `0.01s`；`<0.02s` 短忙等 | `wait_until` | 兼顾零 CPU 占用与毫秒级触发精度 |

---

## 二、抢座重试、06:30 高峰反作弊窗口与瞬态宽限

> 源码：`logic/booker.py` / `mobile/lib/logic/booker.dart`

| 参数 | 值 | 源码符号 | 说明 |
| :--- | :---: | :--- | :--- |
| 单座最大验证码重试 | `8` 次 | `MAX_CAPTCHA_RETRIES_PER_SEAT` / `maxCaptchaRetriesPerSeat` | 单个候选座位的「取码→求解→校验→提交」最大闭环次数 |
| 单座最大繁忙重试 | `12` 次 | `MAX_BUSY_RETRIES_PER_SEAT` / `maxBusyRetriesPerSeat` | 遇高峰系统繁忙/5xx 时的独立重试上限（不消耗正常验证码次数） |
| 放座瞬态宽限窗口 | `5.0` 秒 | `OPEN_GRACE_WINDOW_SECONDS` / `openGraceWindowSeconds` | 相对 `fire_at` 的 `[-1.0s, +5.0s]` 区间内收到未开放提示视为瞬态 |
| 瞬态宽限最大重探 | `5` 次 | `MAX_OPEN_GRACE_RETRIES` / `maxOpenGraceRetries` | 宽限窗内原地重探上限 |
| 瞬态宽限退避间隔 | `0.25` 秒 | `OPEN_GRACE_BACKOFF_SECONDS` / `openGraceBackoffDuration` | 每次宽限重探前休眠 250ms |
| 高峰三字码最小求解间隔 | `1.55` 秒 | `PEAK_CLICK3_MIN_SOLVE_SECONDS` / `peakClick3MinSolveDuration` | 对齐官网前端 1.5s 确认按钮解锁延时，防 500ms 内提交被后端拒判 |
| 高峰校验后提交缓冲 | `2.05` 秒 | `PEAK_CLICK3_POST_CHECK_SECONDS` / `peakClick3PostCheckDuration` | 对齐官网前端 2.0s `orderSeatFun` 缓冲后再发 `freeBook` |
| 高峰缓冲自适应步长 / 上限 | `+0.40s` / `2.80s` | `PEAK_POST_CHECK_STEP_SECONDS` / `PEAK_POST_CHECK_MAX_SECONDS` | 校验通过但 `freeBook` 仍报验证码错误时自动加长缓冲 |
| 高峰再次取码最小冷却 | `6.20` 秒 | `PEAK_CLICK3_RETRY_COOLDOWN_SECONDS` / `peakClick3RetryCooldownDuration` | 跨次/跨座再次拉取高峰三字码前确保间隔 ≥ 6.2s，防触发 6 秒滑动锁 |
| 服务端冷却额外余量 | `0.60` 秒 | `SERVER_COOLDOWN_PAD_SECONDS` / `serverCooldownPadSeconds` | 解析「请稍后: 06」等倒计时后追加 0.6s 余量（如 `6.6s`），避免提前撞锁重置窗口 |

---

## 三、HTTP 客户端、时钟校准与限流护栏

### 1. HTTP 客户端（`core/libseat_client.py`）

| 参数 | 值 | 说明 |
| :--- | :---: | :--- |
| 连接 / 读取超时 | `(3.0, 8.0)` 秒 | `HttpLibSeatClient(timeout=...)` |
| 连接池大小 | `pool_connections=4, pool_maxsize=4` | 单会话 `requests.Session` Keep-Alive 复用 |
| 登录最大尝试次数 | `6` 次 | `login(..., max_attempts=6)`（含图形验证码自动重试） |

### 2. 服务端时钟校准（`core/clock_sync.py`）

| 参数 | 值 | 源码符号 | 说明 |
| :--- | :---: | :--- | :--- |
| 大偏差告警阈值 | `30.0` 秒 | `warn_offset_seconds` | `abs(offset) > 30s` 输出警告日志 |
| 极端异常拒收上限 | `3600.0` 秒 | `max_accept_offset_seconds` | 偏差超过 1 小时直接丢弃该样本 |
| 样本过期刷新时间 | `300.0` 秒 | `stale_after_seconds` | 超过 5 分钟允许用新样本刷新，否则优先保留 RTT 更低样本 |

### 3. 限流、退避与熔断护栏（`core/rate_limiter.py` / `mobile/lib/core/rate_limiter.dart`）

| 参数 | 值 | 源码符号 | 说明 |
| :--- | :---: | :--- | :--- |
| 最小请求间隔 | `120.0` ms | `min_interval_ms` | 单会话相邻请求最小基准间隔 |
| 随机抖动幅度 | `±40.0` ms | `jitter_ms` | 实际间隔落在 `[80ms, 160ms]` |
| 空座快照刷新冷却 | `1.5` 秒 | `seat_refresh_cooldown_s` | 触发 `seat_taken` 时刷新 `/layoutByDate` 的最小间隔 |
| 普通重试退避基数 | `0.2` 秒 | `backoff_base_s` | 指数退避起点（`0.2 → 0.4 → 0.8 ...`） |
| 限流/429 退避基数 | `0.8` 秒 | `throttle_backoff_base_s` | 触发限流或 HTTP 429 时的指数退避起点（支持服务端 `min_delay_s` 下限覆盖） |
| 单次退避上限 | `6.8` 秒 | `backoff_max_s` | 退避封顶（附加小幅随机抖动且不超过上限） |
| 连续限流熔断阈值 | `12` 次 | `max_consecutive_throttles` | 连续 12 次限流/429 抛 `RateLimitCircuitOpenError` 停机 |
| 单会话请求预算硬顶 | `200` 次 | `max_session_requests` | 达到硬顶强制熔断，防止异常死循环 |

---

## 四、本地 ONNX 验证码识别引擎

> 源码：`core/captcha_service.py`、`core/yolo_onnx.py`、`core/captcha_click1_yolo4_siamese.py`、`core/captcha_yolo4_siamese.py`、`core/captcha.py`

| 参数 | Click1 | Click3 | 登录 OCR | 说明 |
| :--- | :---: | :---: | :---: | :--- |
| 输入分辨率 | YOLO `640×640` / Siamese `112×112` | 同左 | 高度固定 `64 px` 等比缩放 | YOLO 用 `BILINEAR`、Siamese 用 `BICUBIC`、OCR 用 `LANCZOS` |
| 填充灰度值 | YOLO `114` / Siamese `128` | 同左 | — | letterbox 居中填充 |
| YOLO 置信度阈值 | `0.05` | `0.05` | — | `yolo_conf` |
| YOLO NMS IoU | `0.7` | `0.45` | — | `yolo_iou` |
| 最大检测 / 候选硬门槛 | `max_det=300` / 必须 `== 4` | 同左（且匹配 `== 3`） | — | 非 4 个检测直接刷新重取 |
| 字符裁剪边长 | `60 px` | `60 px` | — | `char_crop_size` |
| 目标图槽位坐标 | `x=[25:45], y=[5:27]` | `x=[5:25],[25:45],[45:65], y=[5:27]` | — | 槽位笔迹灰度 `< 180`；有字 `>= 2%`，空槽 `< 1%` |
| 兜底时间窗口 | 非高峰 | `06:30:00–06:35:00` | 全天 | 仅在无 `wordCheckCount` 且图像分类不确定时启用 |
| 移动端 ORT 兼容上限 | `IR <= 8`, `Opset <= 18` | 同左 | 同左 | `scripts/prepare_mobile_assets.py` |

---

## 五、通知、Webhook 与日志轮转

> 源码：`core/notifications.py`、`core/logger.py`、`mobile/lib/services/notification_service.dart`

| 参数 | 值 | 位置 | 说明 |
| :--- | :---: | :--- | :--- |
| SMTP SSL 端口 | `465` | `core/notifications.py:161` | 126 / QQ SMTP over SSL |
| SMTP 连接超时 | `10` 秒 | `core/notifications.py:161` | 邮件发送超时 |
| Webhook 超时 | `10.0` 秒（桌面）/ `6s+8s`（移动 Dio） | `notifications.py:103` / `notification_service.dart:73` | 手机推送 HTTP 超时 |
| 日志单文件上限 | `10 MB`（桌面）/ `2 MB`（移动 `run_log.txt`） | `core/logger.py:106` / `log_exporter.dart:35` | 桌面轮转保留 5 份；移动端超 2MB 自动滚动保留最新 1MB |
| 日志备份文件数 | `5` 个 | `core/logger.py:106` | 最多保留 5 个历史轮转日志 |

---

## 六、移动端原生保活与签到防违约提醒

> 源码：`mobile/android/.../MainActivity.kt`、`mobile/ios/Runner/AppDelegate.swift`、`mobile/lib/services/notification_service.dart`

| 参数 | 值 | 平台 | 说明 |
| :--- | :---: | :---: | :--- |
| 四段式硬件闹钟链 | `wake` (`-35s`, 630) / `prep` (`-15s`, 631) / `keepalive` (`-5s`, 632) / `fire` (`-1s`, 633) | Android | `wake/prep/fire` 走 `setAlarmClock`，`keepalive` 走 `setExactAndAllowWhileIdle` |
| 实时流防冻结 `AudioTrack` | 原生采样率（回退 48000/44100/16000 Hz），16-bit Mono `MODE_STREAM` 每 500ms 写入 `±4` LSB × `0.25f`（24kHz / -90 dB）+ `MediaSession STATE_PLAYING` | Android | 物理不可闻且 `RMS > 0`，不占 AudioFocus，规避国产 ROM 静音假播放检测与 cgroup 冻结 |
| 原生心跳与广播租约 | 通知栏 `1s` 刷新；临近 60s 内每 `250ms` 推 `onNativeTick`；闹钟 `goAsync()` 持有 `7.5s` 租约 | Android | 绕开 Flutter 后台 `Timer` 休眠并防止 `onReceive` 返回后立刻被重冻结 |
| 动态 CPU `WakeLock` | `(fireAt - now) + 20m`，限幅 `[10m, 26h]` | Android | 覆盖前一天晚上开启至次日 06:50，未传有效时间时默认 `30m` |
| 闹钟亮屏唤醒锁 | `15` 秒 (`SCREEN_DIM_WAKE_LOCK \| ACQUIRE_CAUSES_WAKEUP`) | Android | 息屏态闹钟触发时点亮屏幕拉起 `MainActivity` |
| 冷启动状态过期窗口 | `fireAt + 10m` | Android | `RushAlarmStore.consumePendingState` 自动清理过期武装态 |
| 静音保活音频规格 | `8000 Hz`, 16-bit Mono PCM, `1s` 循环, `volume=0.01` | iOS | 纯内存 16KB 全零 WAV（`.mixWithOthers` 不打断音乐） |
| 签到防违约提醒节点 1 | 预约开始前 `15` 分钟 | Android & iOS | 温和提前提醒（如 `14:00` → `13:45`） |
| 签到防违约提醒节点 2 | 预约开始后 `20` 分钟（距 30 分钟违约截止剩 `10` 分钟） | Android & iOS | 紧急催促（iOS 启用 `.timeSensitive`，Android 走独立广播闹钟） |

---

## 七、桌面端 PySide6 界面与防休眠

> 源码：`ui_qt/app.py`、`ui_qt/services/prevent_sleep.py`、`ui_qt/widgets/countdown_ring.py`

| 参数 | 值 | 位置 | 说明 |
| :--- | :---: | :--- | :--- |
| 默认窗口 / 最小窗口 | `1400×920` / `1100×760` | `ui_qt/app.py:65-66` | 启动后默认 `showMaximized()` |
| 配置面板宽度范围 | `420–600` px（45% 弹性占比） | `ui_qt/app.py:96-98` | 左右分栏比例 |
| 完成后圆环刷新延迟 | `1200` ms | `ui_qt/app.py:231` | 结束态保留 1.2s 后切回待命显示 |
| 倒计时圆环尺寸 / 帧率 | `360×360` px / `33` ms (~30fps) | `ui_qt/widgets/countdown_ring.py` | QPainter 自绘动画 |
| Windows 防休眠心跳 | `30` 秒 | `prevent_sleep.py:26` | 周期性重申 `SetThreadExecutionState` |
| Windows 空闲抖动阈值 | `60.0` 秒 / `±1` px | `prevent_sleep.py:27,116-122` | 仅空闲 ≥ 60s 触发 1px 抵消移动，不打断操作 |
| 默认预约时刻 | `06:30`（北京时间） | `config_io.py:67-68` | 可在 GUI 自由修改 |

---

## 八、离线训练超参（不影响运行时）

> 源码：`model/siamese_model.py`、`model/siamese_dataloader.py`、`train/README.md`

| 参数 | 值 | 说明 |
| :--- | :---: | :--- |
| Siamese 骨干 / 特征维 | MobileNetV4-Conv-Medium / `1280` | 投影头 `1280→256→128`（v8+）/ 旧融合头 `5120→512→128→1` |
| 训练输入分辨率 / 划分 | `112×112` / `0.8` (seed `42`) | 80% 训练，20% 验证 |
| 数据增强 | 旋转 `±15°`；HSV `H ±18`、`S 0.3~1.7`、`V 0.7~1.3` | 提升复杂背景泛化能力 |
