# 桌面端配置详解 (`config.py`)

适用于 **LNU-LibSeat v6.0.0 桌面端（Windows / macOS）**。手机端（Android / iOS）全部在 App 内配置，不需要编辑本文件。

一般直接双击 `LNU-LibSeat.exe`（或 macOS `LNU-LibSeat.app`）填表就会自动生成 `config.py`；只有在手动配置 `FALLBACK_ROOMS` 或纯 CLI（`python main.py`）运行时才需要直接改它。老用户的 v5 `config.py` 可直接沿用，废弃的 `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` 字段会被自动忽略。

[← 返回首页](../README.md) · [快速上手](QUICKSTART.md) · [Android 安装教程](ANDROID_INSTALL_GUIDE.md) · [架构文档](ARCHITECTURE.md) · [v5 → v6 升级](MIGRATION_V5_TO_V6.md)

---

## 📋 全字段速查表

| 字段 | 类型 | 默认值 | GUI 写入？ | 说明 |
|---|---|---|---|---|
| `USERS` | dict | 空 | ✅ | 学号 → 密码 + 时段 |
| `TARGET_CAMPUS` | str | `"崇山校区图书馆"` | ✅ | 主校区名（与系统一致） |
| `TARGET_ROOM` | str | `"三楼智慧研修空间"` | ✅ | 主自习室名 |
| `FALLBACK_ROOMS` | list | `[]` | 保留读写 | **v6 新增**：备选自习室列表 `[("校区", "自习室"), ...]` |
| `PREFER_SEATS` | list | `[]` | ✅ | 优先座位号；**v6 可留空**（自动实时扫当前空座） |
| `WAIT_FOR_0630` | bool | `False` | ✅ | `True` = 定时模式 / `False` = 立即模式 |
| `MAX_ACCOUNTS` | int | `2` | ✅ | 多账号并发上限（超过自动截断） |
| `API_BASE_URL` | str | `"http://libseat.lnu.edu.cn"` | ✅ | **v6 新增**：LibSeat 服务端地址 |
| `API_FIRE_OFFSET_MS` | int | `200` | ✅ | **v6 新增**：定时准点后顺延毫秒数（配合服务端时钟校准） |
| `RECEIVER_EMAIL` | str | `""` | ✅ | 接收成功通知的邮箱 |
| `WEBHOOK_URL` | str | `""` | ✅ | **v6 新增**：手机端即时推送 Webhook 地址 |
| `SMTP_USER` / `SMTP_PASS` | str | `""` | ✅ | 可选自定义发件箱（留空走内置发件箱） |
| `LOG_LEVEL` | str | `"INFO"` | ✅ | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `LOG_DIR` | str | `"logs"` | ✅ | 日志根目录 |
| `SCHEDULE_HOUR` / `SCHEDULE_MINUTE` | int | `6` / `30` | ⚠️ 内存注入 | 定时模式准点时刻（手编 CLI 时可写入） |

---

## 一、账号设置 (`USERS`)

```python
USERS = {
    "你的学号": {
        "password": "你的密码",
        "time": {"start": "09:00", "end": "15:00"},
    },
    "第二个学号": {
        "password": "密码",
        "time": {"start": "15:00", "end": "21:00"},
    },
}
```

- 不重叠接力时段（如 `09:00-15:00` 与 `15:00-21:00`）允许双账号抢同一心仪座位；时段重叠时进程内协调器会自动错开兜底座，避免互相撞座。

---

## 二、目标场馆、多自习室兜底与首选座位

```python
TARGET_CAMPUS = "崇山校区图书馆"
TARGET_ROOM = "三楼智慧研修空间"
FALLBACK_ROOMS = [
    ("崇山校区图书馆", "四楼南自习室"),
    ("崇山校区图书馆", "四楼北自习室"),
]
PREFER_SEATS = ["185", "186"]  # 留空 [] 则直接抢当前实时空座
```

- **双校区 21 间自习室**：
  - **崇山（8 间）**：二楼书库北、二楼书库南、二楼背诵长廊、三楼智慧研修空间、三楼理科书库、四楼北自习室、四楼南自习室、四楼自习室406
  - **蒲河（13 间）**：三楼走廊、4楼阅览室、四楼走廊、5楼阅览室、五楼走廊、6楼阅览室、六楼走廊、704、706、707、708、七楼走廊、智慧空间
- **多房兜底行为**：当主自习室无可用空座时，按 `FALLBACK_ROOMS` 顺序先调用 76ms 空座快查接口，自动跳过已满房间。

---

## 三、定时调度与纯 API 引擎参数

```python
WAIT_FOR_0630 = True
SCHEDULE_HOUR = 6
SCHEDULE_MINUTE = 30
API_BASE_URL = "http://libseat.lnu.edu.cn"
API_FIRE_OFFSET_MS = 200
```

- **`WAIT_FOR_0630 = True`**：提前 15s（`06:29:45`）登录并预拉座位索引 → 提前 5s（`06:29:55`）保活并二次校准服务端时钟 → 服务端 `06:30:00.200` 准点直击。
- **`WAIT_FOR_0630 = False`**：立即登录、查实时空座并下单。

---

## 四、邮件与手机端 Webhook 推送

```python
RECEIVER_EMAIL = "you@example.com"
WEBHOOK_URL = "https://api.day.app/你的DeviceKey/"
SMTP_USER = ""
SMTP_PASS = ""
```

`WEBHOOK_URL` 会根据域名自动适配请求载荷：
- **Bark（iOS）**：`https://api.day.app/<key>/`
- **PushPlus（微信）**：`https://www.pushplus.plus/send?token=<token>`
- **Server酱（微信）**：`https://sctapi.ftqq.com/<sendkey>.send`
- **企业微信 / 飞书 / 钉钉群机器人**：直接填对应 Webhook 地址
- **其他地址**：自动发送通用 JSON `{"title": ..., "content": ...}`

---

## 五、日志与脱敏追溯目录

```
logs/
├── lnu_seat.log                  ← 全量主日志
├── lnu_seat_<学号>.log            ← 各账号独立日志
└── sessions/
    └── <时间戳>_<学号>/           ← 每次抢座专属目录
        ├── session.log           ← 仅本次会话日志
        ├── 抢座顺序.txt           ← 实时空座统计 + 首选/兜底列表
        ├── http_trace.jsonl      ← 脱敏 HTTP 流水（绝不含密码/Token/Cookie）
        └── *_captcha_*.png       ← 目标字 + 背景 + YOLO 绿圈 + 点击红点诊断图
```
