<div align="center">

<table border="0" cellpadding="0" cellspacing="0">
<tr>
<!-- Logo -->
<td width="250" align="center" valign="middle">
<img src="logo.png" width="220" alt="LNU-LibSeat Logo">
</td>
<!-- 标题 + 标语 + 徽章 -->
<td colspan="3" valign="middle" padding-left="10">

<h1 align="left">LNU-LibSeat</h1>

<h3 align="left">🎯 辽宁大学图书馆 · 智能抢座神器（Win / Mac / iOS / Android）</h3>

<p align="left"><strong>纯 API 毫秒级直连 · 彻底告别浏览器 · 端侧自研 ONNX 识别 · 桌面端 & 手机独立版全平台覆盖</strong></p>

<p align="left">
<a href="mobile/README.md"><img src="https://img.shields.io/badge/Mobile%20App-iOS%20%26%20Android-000000?logo=apple&logoColor=white" alt="Mobile App"></a>
<a href="https://python.org"><img src="https://img.shields.io/badge/Python-3.10+-blue?logo=python&logoColor=white" alt="Python"></a>
<a href="https://doc.qt.io/qtforpython-6/"><img src="https://img.shields.io/badge/PySide6-6.7+-41CD22?logo=qt&logoColor=white" alt="PySide6"></a>
<a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-Mobile-02569B?logo=flutter&logoColor=white" alt="Flutter"></a>
<a href="https://onnxruntime.ai/"><img src="https://img.shields.io/badge/ONNX-Runtime-005CED?logo=onnx&logoColor=white" alt="ONNX Runtime"></a>
<a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/actions/workflows/ci.yml"><img src="https://github.com/XUNRANA/LNU-LibSeat-Automation/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest"><img src="https://img.shields.io/github/v/release/XUNRANA/LNU-LibSeat-Automation?label=Release&color=indigo" alt="Release"></a>
<a href="#-免责声明"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License"></a>
<a href="https://github.com/XUNRANA/LNU-LibSeat-Automation"><img src="https://img.shields.io/github/stars/XUNRANA/LNU-LibSeat-Automation?style=social" alt="Stars"></a>
</p>

</td>
</tr>
<!-- 统计数据行 -->
<tr>
<td align="center" width="250" height="160"><h1>⚡</h1><b>0.55s</b> 实测抢座核心<br>纯 API 零浏览器依赖</td>
<td align="center" width="250" height="160"><h1>🧠</h1>自研 YOLOv8+Siamese<br>Click1/Click3 自适应识别</td>
<td align="center" width="250" height="160"><h1>📱</h1><b>iOS & Android 独立版</b><br>脱离电脑 · 锁屏保活准点抢</td>
<td align="center" width="250" height="160"><h1>0 元</h1>本地离线零成本<br>邮件 + 推送 + 签到防违约</td>
</tr>
</table>

</div>

---

> [!IMPORTANT]
> ✨ **纯 HTTP API 直连引擎 + 手机独立版（iOS & Android）现已上线！**
> - 💻 **电脑桌面端（Windows / macOS）**：彻底移除 Selenium / 浏览器依赖，实测核心下单 **0.55 秒**。详见 [v6.0.0 发布说明](docs/RELEASE_NOTES_V6.md) · [v5 → v6 升级指南](docs/MIGRATION_V5_TO_V6.md)。
> - 📱 **手机独立版（iOS & Android）**：100% 脱离电脑、内置 5 个原版无损 ONNX 模型、支持全馆实时余座雷达与双端锁屏保活！详见 **[📱 手机独立版 README](mobile/README.md)** · **[🤖 Android 直装与保活教程](docs/ANDROID_INSTALL_GUIDE.md)** · **[🍎 iOS 零元免费安装教程](docs/IOS_INSTALL_GUIDE.md)**。

> [!WARNING]
> 🛡️ **准时到馆签到！** 连续或 7 天内累计 **3 次违约 = 黑名单 7 天**，期间无法预约。

> [!TIP]
> 第一次用？跳到 [§ 三步开始](#-三步开始30-秒上手) 30 秒搞定。

---

## 🎯 这是什么

一个**双击即用、无需安装浏览器驱动**的桌面工具，帮你在辽大图书馆每天 **06:30 放座**的瞬间以纯 HTTP API 完成：

动态校准服务端时钟 → 极速登录 → 实时拉取空座 → 本地 AI 解点选验证码 → 一步提交 `freeBook` → 邮件 & 手机推送战报。**不用装 Python，不用装 Edge/Chrome 驱动，不用懂代码。**

### 适合谁用？

<table width="1000">
<tr>
<td align="center" width="333">
<h2>🎓 普通学生</h2>
不想 6:30 起床抢座<br>
想要每天稳定占到心仪的位置
</td>
<td align="center" width="333">
<h2>📚 考研党 / 自习党</h2>
全天候图书馆挂机<br>
双账号分时段无缝衔接 9:00-21:00
</td>
<td align="center" width="333">
<h2>🌙 错峰 / 捡漏玩家</h2>
实时筛查当前空座<br>
0.55 秒秒锁，不再盲扫全房
</td>
</tr>
</table>

---

## ⚖️ 手动 vs v5 浏览器 vs v6 纯 API

<table width="1000">
<tr><th align="left" width="210">抢座环节</th><th align="left" width="230">😩 手动操作</th><th align="left" width="260">🐢 v5（Selenium 浏览器）</th><th align="left" width="300">⚡ v6（纯 API 引擎）</th></tr>
<tr><td><b>浏览器与驱动</b></td><td>手动打开网页</td><td>依赖 Edge/Chrome/Safari + 驱动匹配</td><td>✅ <b>完全无需浏览器与 WebDriver</b></td></tr>
<tr><td><b>登录与准备耗时</b></td><td>手动输码 10s+</td><td>提前 30s 启动浏览器</td><td>⚡ <b>< 1s</b>，提前 15s 预热 + 5s 保活</td></tr>
<tr><td><b>内存占用（双账号）</b></td><td>—</td><td>~1.5GB（2 个浏览器进程）</td><td>🪶 仅共享一份 ONNX 上下文，每账号几十 KB</td></tr>
<tr><td><b>空座查找策略</b></td><td>肉眼翻座位图</td><td>盲扫全房座号，每座试错 1–3s</td><td>🎯 <b>180ms 拉取全房实时空座</b>，零盲扫</td></tr>
<tr><td><b>前端人为延时</b></td><td>硬等 1.5s+2s 动画</td><td>被迫等待 3.5s 假动画 + sleep(2)</td><td>🚀 <b>直击接口</b>，实测下单核心 <b>0.55s</b></td></tr>
<tr><td><b>时钟偏差校准</b></td><td>看表容易偏 1–2s</td><td>依赖本机时钟</td><td>🕒 <b>HTTP Date 自动校准服务端时间</b> + 5s 瞬态宽限</td></tr>
<tr><td><b>不填首选座位</b></td><td>必须手挑</td><td>v5 要求至少填 1 个首选</td><td>✅ <b>可留空</b>，直接抢实时空座；支持多自习室兜底</td></tr>
<tr><td><b>成功战报通知</b></td><td>手动刷新查看</td><td>仅邮件通知</td><td>📲 <b>邮件 + 手机端 Webhook 秒推</b>（Bark/PushPlus/企微等）</td></tr>
<tr><td><b>出问题排查</b></td><td>全靠回忆</td><td>截图 + 笨重 MP4 录屏</td><td>📁 <b>脱敏 http_trace.jsonl + 轻量验证码叠加图</b></td></tr>
</table>

---

## 🚀 三步开始（30 秒上手）

<table width="1000">
<tr>
<td align="center" width="333">
<h3>① 下载</h3>
<a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest">
<img src="docs/screenshots/00_github_release.png" width="280" alt="去 Releases 下 zip">
</a>
<p>去 <a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest">Releases</a> 下载<br><code>LNU-LibSeat-v6.0.0-Windows-x86_64.zip</code></p>
</td>
<td align="center" width="333">
<h3>② 解压 → 双击</h3>
<img src="docs/screenshots/01_folder_structure.png" width="280" alt="解压后双击 exe">
<p>解压到任意位置<br>双击 <code>LNU-LibSeat.exe</code></p>
</td>
<td align="center" width="333">
<h3>③ 填表 → 开始</h3>
<img src="docs/screenshots/02_gui_main.png" width="280" alt="填表点开始">
<p>填学号密码 + 时段<br>点「🚀 开始抢座」</p>
</td>
</tr>
</table>

> [!NOTE]
> ❌ **不需要** Python、命令行、Edge/Chrome 浏览器、WebDriver 驱动——所有依赖都已打包进发行包。
>
> ✅ 唯一前提：Windows 10/11 或 macOS，能访问 `libseat.lnu.edu.cn` 即可。

---

## 🍎 macOS 用户（Apple Silicon & Intel）

Mac 双击不了 `.exe`，请下载 macOS 专版 `.app`：

1. 去 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 下载 `LNU-LibSeat-v6.0.0-macOS-arm64.zip`。
2. 解压后，**右键**点击 `首次运行请先双击我.command` → 「打开」→ 再点一次「打开」。
   - 应用未做苹果付费签名，首次必须右键打开一次解除安全限制；之后可直接双击 `LNU-LibSeat.app`。
   - 若提示「无法打开」，到 **系统设置 ▸ 隐私与安全性 ▸ 仍要打开**。
3. 填表 → 「开始抢座」。

> [!NOTE]
> - **v6 彻底移除浏览器限制**：macOS 不再需要安装 Chrome 或折腾 Safari 远程自动化，**双账号原生并发**，体验与 Windows 100% 一致！
> - **数据位置**：`config.py`、`logs/` 与 `.app` 同级，可直接查看 / 编辑。

---

## 📱 手机独立版（iOS & Android · 脱离电脑）

不想开电脑挂机？现已推出基于 Flutter 打造的 **手机独立版（iOS & Android）**——100% 脱离电脑、零服务器成本，端侧内置与桌面端同源的 **5 个原版无损 ONNX 验证码模型**，识别成功率与电脑桌面端一致！

<div align="center">
<table>
<tr>
<td align="center" width="33%">
<img src="docs/IOS/01_home_rush.png" width="230" alt="手机版晨约主界面"><br>
<b>晨约 · 抢座总控台</b><br>
<sub>立即 / 06:30 定时 · 快捷方案 · 终端日志</sub>
</td>
<td align="center" width="33%">
<img src="docs/IOS/03_seat_radar.png" width="230" alt="手机版全馆实时余座雷达"><br>
<b>寻座 · 双校区实时雷达</b><br>
<sub>崇山 / 蒲河 21 间自习室空座率 · 单室网格直订</sub>
</td>
<td align="center" width="33%">
<img src="docs/IOS/05_my_ticket_pass.png" width="230" alt="手机版入馆座签与自习伴侣"><br>
<b>入馆 · 座签与违约守护</b><br>
<sub>双号违约监控 · 暂离防丢座 · 签到防违约提醒</sub>
</td>
</tr>
</table>
</div>

- **🤖 Android 安卓直装（0 元永久生效）**：前往 [GitHub Releases](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest) 下载 **`LNU-LibSeat-Android-arm64.apk`** 直接安装即用；国产 ROM（vivo / 小米 / 华为 / OPPO）防锁屏冻结设置见 👉 **[🤖 Android 直装与隔夜保活教程](docs/ANDROID_INSTALL_GUIDE.md)**。
- **🍎 iPhone / iPad 安装（0 元免越狱）**：前往 [GitHub Releases](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest) 下载 **`LNU-LibSeat-iOS-arm64-unsigned.ipa`**，使用 Sideloadly / 爱思助手 / SideStore 免费自签安装，详细图文步骤见 👉 **[🍎 iOS 零元免费安装教程](docs/IOS_INSTALL_GUIDE.md)**。
- **⏰ 睡前 06:30 过夜保活**：
  - Android 内置 **5 重隔夜防杀**（`AlarmClock` + 预热轻推双闹钟 + Android 14 锁屏全屏强解冻 + 动态 26h `WakeLock` + `WifiLock` + 被杀/重启自动续抢），配齐 4 项白名单后锁屏即可准点抢；
  - iOS 内置 **锁屏后台静音保活 + 纯 CPU 图像解码**（按电源键锁屏也能准点开抢，抢完自动关闭），双端均提供 **「银杏夜守」OLED 纯黑床头时钟** 物理级双保险。
- **📖 完整功能说明与全套 6 张实机截图**：请查阅 **[📱 手机独立版 README](mobile/README.md)**。

---

## 💎 v6.0.0 核心特色

<table width="1000">
<tr>
<td width="333" valign="top">
<h3>⚡ 纯 HTTP API 直连引擎</h3>
彻底移除 Selenium / WebDriver，完整实现 AES-128-CBC 凭据加密与 HMAC-SHA256 请求签名，动态拉取 <code>baseUrl.js</code> 密钥配置，实测核心下单 <b>0.55s</b>。
</td>
<td width="333" valign="top">
<h3>🕒 服务端时钟校准 + 瞬态宽限</h3>
通过 HTTP <code>Date</code> 响应头与 RTT/2 自动校准本机与服务端时间偏差，配合 06:30:00–06:30:05 短宽限重探，毫秒卡点不抢跑、不白等。
</td>
<td width="333" valign="top">
<h3>🎯 实时空座 & 多自习室兜底</h3>
动态解析 <code>room_id</code> 与全房 <code>seat_id</code> 实时状态，首选直击 + 实时空座筛选，支持 <code>FALLBACK_ROOMS</code> 多自习室顺延，并用 76ms 空座快查跳过满员房。
</td>
</tr>
<tr>
<td width="333" valign="top">
<h3>🧠 自适应 YOLOv8 + Siamese</h3>
直接读取接口返回的 <code>wordCheckCount</code>（辅以图像槽位笔迹识别），无缝自适应路由 Click1（非高峰）与 Click3（06:30 高峰），原生 1:1 像素坐标直传。
</td>
<td width="333" valign="top">
<h3>🛡️ 限流护栏 & 协议漂移熔断</h3>
内置最小请求间隔 + 随机 Jitter + 空座刷新冷却 + 429 指数退避熔断 + 单会话请求硬顶；检测到黑名单或协议异常立即停止，绝不死循环。
</td>
<td width="333" valign="top">
<h3>📲 邮件 + 手机 Webhook 秒推</h3>
成功战报附带<b>预约单号与小票凭证</b>，除内置邮箱通知外，新增自动适配 <b>Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉</b> 与通用 JSON Webhook。
</td>
</tr>
<tr>
<td width="333" valign="top">
<h3>🧵 多账号防撞座协同</h3>
进程内 <code>SeatClaimCoordinator</code> 自动错开时段重叠的并发账号兜底座；不重叠接力时段（如 9:00-15:00 + 15:00-21:00）允许同抢心仪座。
</td>
<td width="333" valign="top">
<h3>📁 轻量脱敏会话追溯</h3>
每次会话生成独立目录：<code>session.log</code> + <code>抢座顺序.txt</code> + <b>脱敏 <code>http_trace.jsonl</code></b>（绝不落盘密码/Token）+ <b>验证码候选/点击叠加图</b>（&lt; 50KB）。
</td>
<td width="333" valign="top">
<h3>🧊 打包大幅瘦身</h3>
剔除 Selenium / webdriver-manager / mss 及本地冗余 <code>.pt/.pth</code> 训练权重（仅打 <code>*.onnx</code>），发行包立减 <b>100MB+</b>。
</td>
</tr>
</table>

---

## 🧠 验证码引擎：YOLOv8 + Siamese（v6 升级）

> 完整技术细节见 [CAPTCHA_YOLO4_SIAMESE.md](docs/CAPTCHA_YOLO4_SIAMESE.md) 与 [API_PROTOCOL_CONTRACT.md](docs/API_PROTOCOL_CONTRACT.md)。
>
> 注：源码里文件名带的 `yolo4`（如 `core/captcha_yolo4_siamese.py`）是历史实验代号，实际检测骨干是 **YOLOv8**（训练代码见 `train/`）。

```
POST /cap/captcha/<token> → 拿 330×160 背景图 + 70×36 目标字图 + wordCheckCount (1 或 3)
        ↓
   core/captcha_service.py（自适应路由 Click1 / Click3 + 线程锁）
        ↓
   YOLOv8 检测层（core/yolo_onnx.py）→ 4 个候选框
        ↓
   Siamese 相似度层（MobileNetV4-Conv-Medium ONNX）→ 1 或 3 个原生像素坐标
        ↓
   GET /cap/checkCaptcha (Base64 JSON) → POST /rest/v2/freeBook (multipart/form-data)
```

- **登录图形码**：由 [core/captcha.py](core/captcha.py)（`ddddocr`）毫秒级自动识别 `GET /auth/createCaptcha`。
- **点选验证码**：GUI/CLI 启动后后台异步预热 Click1 + Click3 ONNX（约 2s），实测单次 Click1 推理仅 **~62ms**。

---

## ☕ 求赞助 — 支持持续开发

> [!NOTE]
> v5 告别了付费验证码 API，v6 彻底告别了笨重浏览器并迎来 0.55s 纯 API 时代。
> 作者仍在持续**维护、迭代模型与打磨新特性**——**随手扫码赞助**就是最大的鼓励 ❤️

<table align="center" border="0" cellspacing="0">
<tr>
<td width="300" align="center" valign="middle">
  <b>☕ 你的赞助将用于</b><br>
  <b>模型训练 · 协议适配 · 测试</b><br>
  <sub>让免费持续 ❤️</sub>
</td>
<td align="center"><img src="wechat_pay.png" width="260" alt="微信支付赞助码"><br><b>微信支付</b></td>
</tr>
</table>

---

## 🛟 高频 FAQ

<details>
<summary><b>Q1: 我一点 Python 都不懂，需要装 Chrome / Edge 吗？</b></summary>

✅ **什么都不用装**。v6 已彻底移除浏览器依赖：下载 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 里的 zip，解压双击 `LNU-LibSeat.exe`（macOS 右键 `.command` 首启 `.app`）即可。
</details>

<details>
<summary><b>Q2: 我是 v5 老用户，原来的 config.py 还能直接用吗？</b></summary>

✅ **完全兼容**。把旧 `config.py` 复制到 v6 目录即可直接运行，旧的 `BROWSER` / `DRIVER_PATH` / `WEBDRIVER_CACHE` 字段会被自动静默忽略。详情见 [v5 → v6 升级指南](docs/MIGRATION_V5_TO_V6.md)。
</details>

<details>
<summary><b>Q3: 抢座失败了怎么排查？</b></summary>

打开 `logs/sessions/<时间戳>_<学号>/` 文件夹，里面有：
- `session.log` — 本次会话完整日志
- `抢座顺序.txt` — 本次实时空座统计与尝试队列
- `http_trace.jsonl` — 脱敏 HTTP 请求/响应流水（密码、Token、Cookie 已自动抹除）
- `*_captcha_*.png` — 目标字 + 背景图 + YOLO 候选绿圈 + 点击红点叠加诊断图

打包发给作者或在 Issue 附上脱敏日志即可快速定位。
</details>

<details>
<summary><b>Q4: 怎么配手机端即时推送（Webhook）？</b></summary>

在 GUI 账号卡片的「**手机推送**」框（或 `config.py` 的 `WEBHOOK_URL`）直接粘贴对应渠道 URL 即可自动识别：
- **Bark（iOS）**：`https://api.day.app/<你的DeviceKey>/`
- **PushPlus（微信）**：`https://www.pushplus.plus/send?token=<你的Token>`
- **Server酱（微信）**：`https://sctapi.ftqq.com/<你的SendKey>.send`
- **企业微信 / 飞书 / 钉钉群机器人**：直接粘贴机器人 Webhook 地址
</details>

<details>
<summary><b>Q5: 电脑会被休眠吗？怎么做到每天无人值守？</b></summary>

🛡️ GUI 启动时通过 `ui_qt/services/prevent_sleep.py` 自动申请系统防休眠权限，支持整晚挂机不断网；也可以用 Windows 任务计划程序（`taskschd.msc`）设每天 `06:25` 唤醒电脑运行 `LNU-LibSeat.exe`。
</details>

---

## 📖 文档导航

<table width="1000">
<tr>
<td align="center" width="250">
<h3>📱</h3>
<a href="mobile/README.md"><b>手机独立版 README</b></a><br>
<sub>iOS / Android 全功能介绍与截图</sub>
</td>
<td align="center" width="250">
<h3>🍎</h3>
<a href="docs/IOS_INSTALL_GUIDE.md"><b>iOS 零元安装教程</b></a><br>
<sub>Sideloadly / 爱思 / SideStore / 保活</sub>
</td>
<td align="center" width="250">
<h3>🛠️</h3>
<a href="docs/MOBILE_GUIDE.md"><b>手机端编译说明</b></a><br>
<sub>APK / IPA 本地一键打包指南</sub>
</td>
<td align="center" width="250">
<h3>🚀</h3>
<a href="docs/MIGRATION_V5_TO_V6.md"><b>v5 → v6 升级指南</b></a><br>
<sub>v5 老用户无缝迁移必读</sub>
</td>
</tr>
<tr>
<td align="center" width="250">
<h3>📦</h3>
<a href="docs/RELEASE_NOTES_V6.md"><b>v6.0.0 发布说明</b></a><br>
<sub>纯 API 重构与实测亮点</sub>
</td>
<td align="center" width="250">
<h3>🔌</h3>
<a href="docs/API_PROTOCOL_CONTRACT.md"><b>纯 API 协议契约</b></a><br>
<sub>脱敏端点、签名与字段参考</sub>
</td>
<td align="center" width="250">
<h3>⚙️</h3>
<a href="docs/CONFIGURATION.md"><b>配置详解</b></a><br>
<sub>config.py 全字段说明</sub>
</td>
<td align="center" width="250">
<h3>🏗️</h3>
<a href="docs/ARCHITECTURE.md"><b>架构文档</b></a><br>
<sub>v6 纯 API 四层解耦架构</sub>
</td>
</tr>
<tr>
<td align="center" width="250">
<h3>🧠</h3>
<a href="docs/CAPTCHA_YOLO4_SIAMESE.md"><b>验证码引擎</b></a><br>
<sub>YOLOv8+Siamese 技术细节</sub>
</td>
<td align="center" width="250">
<h3>🎨</h3>
<a href="docs/GUI_QT_ARCHITECTURE.md"><b>GUI 架构</b></a><br>
<sub>PySide6 模块拆分</sub>
</td>
<td align="center" width="250">
<h3>📘</h3>
<a href="docs/QUICKSTART.md"><b>桌面版快速上手</b></a><br>
<sub>从零开始的完整使用教程</sub>
</td>
<td align="center" width="250">
<h3>🗂️</h3>
<a href="docs/README.md"><b>全部文档索引</b></a><br>
<sub>含反馈消息 / 参数 / 历史档案</sub>
</td>
</tr>
</table>

---

## 🛠️ 开发者：从源码运行 / 自己打包

<details>
<summary><b>Python 源码运行与测试</b></summary>

```powershell
git clone https://github.com/XUNRANA/LNU-LibSeat-Automation
cd LNU-LibSeat-Automation
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python gui_qt.py        # 桌面 GUI
# 或 python main.py     # 纯 CLI 无界面运行
```

跑离线单元测试与 lint（全套纯离线，无需浏览器）：

```powershell
pip install pytest ruff
pytest tests/ -q
ruff check .
```
</details>

<details>
<summary><b>打包：Windows（.exe）/ macOS（.app）/ Android（.apk）/ iOS（.ipa）</b></summary>

- **Windows**：`python build.py` → 产出 `dist/LNU-LibSeat-v6.0.0/` 与 `.zip`
- **macOS**（需在 Mac 上 `git clone` 后运行）：`python3 build_mac.py` → 产出 `dist/LNU-LibSeat-v6.0.0-macOS-<arch>.zip`
- **Android**：`python build_android.py` → 产出 `dist/辽宁大学图书馆座位预约.apk`
- **iOS**（需在 Mac 上安装 Xcode + Flutter + CocoaPods）：`python3 build_ios.py` → 产出免签名 `dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`（详见 [MOBILE_GUIDE.md](docs/MOBILE_GUIDE.md)）
- 云端构建工作流 `.github/workflows/build-windows.yml` / `build-macos.yml` 仅保留手动触发（`workflow_dispatch`），推 tag 不会自动触发云端打包。
- `build.py` / `build_mac.py` 已自动排除 `.pt/.pth` 训练权重，仅随包打包运行时 `*.onnx`。
</details>

<details>
<summary><b>项目结构</b></summary>

```
LNU-LibSeat-Automation/
├── gui_qt.py                        # 🖥️ PySide6 桌面 GUI 入口
├── ui_qt/                           # 🎨 模块化桌面界面（panels / widgets / workers / services）
├── main.py                          # 🚀 CLI 入口（委托 logic.orchestrator）
├── config.example.py                # ⚙️ 配置模板（支持 FALLBACK_ROOMS / WEBHOOK_URL）
├── build.py / build_mac.py          # 📦 Windows & macOS 隔离 venv 打包脚本
├── build_android.py / build_ios.py  # 📱 Android (.apk) & iOS 免签名 (.ipa) 一键构建脚本
├── mobile/                          # 📱 Flutter 跨平台手机独立版源码（iOS & Android）
│   ├── README.md                    #   手机独立版完整说明与实机截图
│   ├── lib/                         #   纯 API 引擎 / 端侧 ONNX 识图 / 四频道 UI / 保活服务
│   ├── android/                     #   Android 原生前台服务、精确闹钟与 CPU 解码
│   └── ios/                         #   iOS UIScene、锁屏静音保活、纯 CPU ImageIO 解码
├── scripts/                         # 🔧 移动端 ONNX 模型准备与跨语言测试向量导出
├── requirements.txt                 # requests / pycryptodome / ddddocr / onnxruntime / PySide6
├── info/                            # 📋 双校区 21 间自习室离线座号预览索引
├── core/                            # 🛠️ 协议与基础设施层（零 Selenium）
│   ├── protocol.py                  #   端点常量 / baseUrl.js Global 动态解析 / 协议漂移异常
│   ├── api_crypto.py                #   AES-128-CBC 登录凭据加密 + HMAC-SHA256 签名头
│   ├── libseat_client.py            #   强类型 LibSeatClient Protocol + requests 连接池实现
│   ├── clock_sync.py                #   HTTP Date + RTT/2 服务端时钟校准
│   ├── rate_limiter.py              #   请求最小间隔 / Jitter / 空座冷却 / 429 熔断
│   ├── captcha_service.py           #   Click1 + Click3 统一自适应路由 + 线程锁 + 预热
│   ├── captcha.py                   #   ddddocr 登录 4 位图形验证码
│   ├── captcha_yolo4_siamese.py     #   Click3 求解器
│   ├── captcha_click1_yolo4_siamese.py # Click1 求解器
│   ├── yolo_onnx.py                 #   YOLOv8 ONNX 推理封装
│   ├── checkpoints/                 #   4 个运行时 ONNX 权重
│   ├── session_recorder.py          #   脱敏 http_trace.jsonl + 验证码叠加诊断图
│   ├── notifications.py             #   SMTP 邮件 + 手机端 Webhook 推送
│   ├── logger.py / paths.py / utils.py
├── logic/                           # 🧠 纯 API 业务编排层
│   ├── orchestrator.py              #   多账号调度 / 维护期重连 / Token 过期自动重登
│   ├── booker.py                    #   ApiSeatBooker（首选直击 / 实时空座 / 多房兜底 / 宽限重试）
│   ├── seat_strategy.py             #   实时空座排序 / FALLBACK_ROOMS / 多账号防撞座协调器
│   └── result_classifier.py         #   纯函数预约结果分类（含 seat_taken / not_open_yet）
├── model/ & train/                  # 🏋️ 验证码模型定义与完整自训练管线
├── tests/                           # ✅ 全套离线单元测试（pytest，零浏览器依赖）
└── docs/                            # 📖 架构 / 协议契约 / iOS 安装教程 / 发布说明
```
</details>

---

## 🏛️ 辽大图书馆官方预约规则

<table width="1000">
<tr><th align="left" width="250">规则</th><th align="left" width="750">说明</th></tr>
<tr><td><b>预约入口</b></td><td><code>libseat.lnu.edu.cn</code> / 微信公众号 / 馆内刷卡</td></tr>
<tr><td><b>登录</b></td><td>校园卡号，初始密码 <code>000000</code></td></tr>
<tr><td><b>签到</b></td><td>提前 30 分钟至迟到 30 分钟内</td></tr>
<tr><td><b>每日上限</b></td><td>≤ 3 次预约，每次 ≤ 6 小时，≤ 3 次取消</td></tr>
<tr><td><b>放座时间</b></td><td><b>每日 06:30</b></td></tr>
<tr><td><b>违约处罚</b></td><td>🚫 7 天内 3 次违约 → <b>黑名单 7 天</b></td></tr>
</table>

---

## ⚖️ 免责声明

本项目仅供**技术交流与学习**，请严格遵守学校图书馆规定。
- 请准时到馆签到，避免被列入黑名单
- 请勿修改或绕过内置限流保护对学校服务器发起高频请求
- 请勿将抢到的座位转售或用于其他商业目的
- **所有使用后果由使用者自行承担**

## 🙏 致谢

- **[geTiger/get_LibSeat](https://github.com/geTiger/get_LibSeat)** — 辽宁大学图书馆抢座的最早开源实现，项目最初的流程与思路参考自此。
- **[MgArcher/Text_select_captcha](https://github.com/MgArcher/Text_select_captcha)** — 文字点选验证码识别开源方案，自研 **YOLOv8 + Siamese** 管线架构源自此项目。
- **[@MorinGale](https://github.com/MorinGale)** — 在 [Issue #4](https://github.com/xunrana/LNU-LibSeat-Automation/issues/4) 中率先提出并实测验证了纯 API 路线，直接促成了 v6.0.0 的诞生。

## 📄 License

[MIT](https://opensource.org/licenses/MIT) © XUNRANA

---

<div align="center">

**如果这个项目帮到了你，请给个 ⭐ Star 鼓励作者持续维护！**

[⭐ 给项目加星](https://github.com/XUNRANA/LNU-LibSeat-Automation) · [☕ 赞助一杯奶茶](#-求赞助--支持持续开发) · [🐛 反馈 Bug](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues) · [📦 v6.0.0 发布说明](docs/RELEASE_NOTES_V6.md)

</div>
