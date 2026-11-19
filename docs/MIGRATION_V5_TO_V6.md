<div align="center">

# 🚀 v5 → v6 升级指南

### 2 分钟平滑迁移到纯 API 引擎

[← 返回 README](../README.md) ·
[v6.0.0 发布说明](RELEASE_NOTES_V6.md) ·
[配置详解](CONFIGURATION.md) ·
[架构文档](ARCHITECTURE.md)

</div>

---

## 🎯 为什么要升 v6？

| 痛点（v5 Selenium） | 解决（v6 纯 API） |
|---|---|
| 启动 Edge/Chrome + 登录要 15–35 秒，还常遇驱动不匹配 | **彻底移除 Selenium / 浏览器**，登录 < 1 秒，零驱动维护 |
| 双账号开 2 个浏览器吃 ~1.5GB 内存；macOS Safari 仅单账号 | 每账号仅一个 HTTP Session（几十 KB），Win / macOS 体验完全一致 |
| 盲扫全自习室座位表，碰已占座浪费大量时间 | **180ms 实时拉取全房空座**，精准只抢空座，支持多自习室兜底 |
| 前端强制 1.5s + 2.0s 假延时，加上 `sleep(2)` 慢 5.5 秒 | 直连 API 零假延时，**实测开抢到下单核心仅 0.55 秒** |
| 本机时钟若偏快 1.5 秒容易提前撞到未放座提示 | **HTTP `Date` 自动校准服务端时钟** + `06:30:00~06:30:05` 瞬态宽限 |
| 仅支持邮件通知 | 新增 **手机端即时 Webhook 推送**（Bark / PushPlus / Server酱 / 企微 / 飞书） |

---

## 🟢 EXE / macOS App 用户升级（推荐，2 分钟）

1. **备份旧 `config.py`**（含你的学号密码和首选座）。
2. 前往 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 下载 `LNU-LibSeat-v6.0.0-Windows-x86_64.zip`（macOS 下载 `LNU-LibSeat-v6.0.0-macOS-arm64.zip`），解压到**新目录**。
3. 直接把旧 `config.py` 复制到新目录（与 `LNU-LibSeat.exe` / `.app` 同级）即可双击运行！
   - 旧配置里的 `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` 会被 **自动静默忽略**，不需要手动删除。
   - 下次点「开始抢座」时，GUI 会自动帮你重写为干净的 v6 格式 `config.py`。

---

## 🧑‍💻 源码用户升级

```powershell
# 1. 拉取最新代码
git pull

# 2. 卸载 v5 不再需要的浏览器依赖
pip uninstall selenium webdriver-manager mss -y

# 3. 安装 v6 依赖（新增 pycryptodome）
pip install -r requirements.txt

# 4. 跑一遍离线单测确认环境正常
pytest tests/ -q

# 5. 启动 GUI（或 python main.py 走纯 CLI）
python gui_qt.py
```

### 依赖变化 diff

```diff
- selenium>=4.20.0
- webdriver-manager>=4.0.2
- mss>=9.0.1
+ pycryptodome>=3.20.0
```

> [!NOTE]
> `ddddocr` 仍需保留——PC 端登录接口 `/rest/auth` 需要先识别 `/auth/createCaptcha` 的 4 位图形码。

---

## 📦 配置迁移对照表（`config.py`）

| 字段 | v5 | v6 | 说明 |
|---|---|---|---|
| `USERS` / `TARGET_CAMPUS` / `TARGET_ROOM` / `WAIT_FOR_0630` / `MAX_ACCOUNTS` | ✅ | ✅ | **完全不变** |
| `PREFER_SEATS` | 必填至少 1 座 | **可留空** | 留空 = 实时扫描当前空座；填了则优先直击首选座 |
| `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` | ✅ | ❌ **已移除** | 旧文件中保留会**静默忽略，不报错** |
| `FALLBACK_ROOMS` | — | 🆕 **新增** | 可选备选自习室列表，如 `[("崇山校区图书馆", "四楼南自习室")]` |
| `WEBHOOK_URL` | — | 🆕 **新增** | 可选手机端即时推送地址（GUI 账号卡中也可直接填写） |
| `API_BASE_URL` | — | 🆕 **新增** | 默认 `"http://libseat.lnu.edu.cn"`，通常保持默认 |
| `API_FIRE_OFFSET_MS` | — | 🆕 **新增** | 定时模式准点后顺延毫秒数，默认 `200` |
| `RECEIVER_EMAIL` / `SMTP_*` / `LOG_*` / `SCHEDULE_*` | ✅ | ✅ | **完全不变** |

---

## 🔄 行为与排障产物变化

| 项 | v5 | v6 |
|---|---|---|
| **定时预热提前量** | `06:29:30`（提前 30s 开浏览器） | `06:29:45`（提前 15s 登录查房）→ `06:29:55` 保活复校时钟 |
| **抢座可视化** | 弹出真实浏览器窗口 | **后台静默极速执行**，全部状态实时打印到 GUI 日志终端 |
| **会话追溯目录** | `session.log` + 4 阶段截图 + MP4 录屏 | `session.log` + `抢座顺序.txt` + **脱敏 `http_trace.jsonl`** + **轻量验证码叠加图 (`*_captcha_*.png`)** |
| **验证码路由** | 依赖本地时钟判断 `06:30–06:35` | 优先按接口返回 `wordCheckCount`（1 或 3）精准路由，零时钟误判 |
| **成功通知内容** | 账号 / 场馆 / 座位 / 时段 | 额外附带 **预约单号 + 小票凭证**，同步支持手机 Webhook |

---

## ✅ 升级验证清单

```
[ ] 双击 LNU-LibSeat.exe（或 python gui_qt.py），界面无「浏览器」下拉框，新增「手机推送」框
[ ] 旧 config.py 载入正常，账号/目标自习室完整保留
[ ] 立即模式实测一次非高峰预约：登录 < 2s、实时空座命中、下单 < 1s（测完记得手动取消！）
[ ] 检查 logs/sessions/<时间戳>_<学号>/ 已生成 session.log、抢座顺序.txt、http_trace.jsonl、*_captcha_*.png
[ ] 核验 http_trace.jsonl 中不含明文密码或 48 位 token
[ ] （可选）填入 Bark / PushPlus Webhook，确认手机秒收战报
```
