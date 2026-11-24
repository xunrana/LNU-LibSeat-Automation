<div align="center">
  <img src="logo.png" width="160" alt="LNU-LibSeat Logo">
  <h1>LNU-LibSeat</h1>
  <p>辽宁大学图书馆自动约座与自习助手（崇山 / 蒲河双校区）</p>
  <p>
    <a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest"><img src="https://img.shields.io/github/v/release/XUNRANA/LNU-LibSeat-Automation?label=Release&color=blue" alt="Release"></a>
    <a href="https://github.com/XUNRANA/LNU-LibSeat-Automation/actions/workflows/ci.yml"><img src="https://github.com/XUNRANA/LNU-LibSeat-Automation/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="#免责声明"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License"></a>
    <a href="https://github.com/XUNRANA/LNU-LibSeat-Automation"><img src="https://img.shields.io/github/stars/XUNRANA/LNU-LibSeat-Automation?style=social" alt="Stars"></a>
  </p>
</div>

给辽大同学写的本地自动抢座工具，覆盖崇山、蒲河两个校区全部 21 间自习室。

v6 彻底去掉了浏览器和 Selenium 驱动，改为直接调用图书馆接口，并把识别点选验证码的 ONNX 模型打进本地安装包里——**不用装 Python，不用配浏览器驱动，不用花钱买打码接口，也不经过任何第三方服务器**。非高峰单字码直连下单实测约 **0.55 秒**；06:30 高峰三字码则会自动对齐官网服务端反作弊时间窗与 6 秒滑动窗口冷却，遇到「系统繁忙」自动退避重探而不会误停。

现在同时提供手机端和电脑端，**优先推荐 Android 和 Windows**，同时也支持 iPhone 和 Mac。

> [!WARNING]
> 抢到座位请务必按时到馆刷卡签到。图书馆规定 7 天内累计 **3 次违约会进黑名单 7 天**，期间无法预约。

---

## 下载哪个版本？

所有安装包都在 **[GitHub Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest)** 免费下载：

| 平台 | 推荐程度 | 下载文件（点击直链） | 大小 | 说明 | 教程 |
| :--- | :---: | :--- | :---: | :--- | :--- |
| **Android** | **主推** | [`LNU-LibSeat-Android-arm64.apk`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-Android-arm64.apk) | 约 166 MB | 直接安装，不用签名续签，脱离电脑独立运行 | [安装与防杀后台教程](docs/ANDROID_INSTALL_GUIDE.md) |
| **Windows** | **主推** | [`LNU-LibSeat-v6.0.1-Windows-x86_64.zip`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-v6.0.1-Windows-x86_64.zip) | 约 205 MB | 解压双击 `LNU-LibSeat.exe` 就跑，自动防休眠 | [快速上手指南](docs/QUICKSTART.md) |
| **iPhone / iPad** | 支持 | [`LNU-LibSeat-iOS-arm64-unsigned.ipa`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-iOS-arm64-unsigned.ipa) | 约 147 MB | 免费 Apple ID 自签安装（7 天续签 / 巨魔永久） | [iOS 免费安装教程](docs/IOS_INSTALL_GUIDE.md) |
| **macOS** | 支持 | [`LNU-LibSeat-v6.0.1-macOS-arm64.zip`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-v6.0.1-macOS-arm64.zip) | 约 194 MB | 纯原生 Apple Silicon `arm64`（零 Rosetta 2），首次右键 `.command` 启动 | [下方 Mac 说明](#mac-版本apple-silicon) |

选型建议很直接：
- 日常图省心、不想每天开着电脑：**直接用 Android 版**，装完就能查全馆实时空座、睡前挂 6:30、到点前还能弹签到提醒。
- 期末或者考研追求绝对稳妥、习惯电脑挂机：**用 Windows 版**，没有手机系统杀后台的烦恼，也能配合任务计划程序自动唤醒。
- 手里只有 iPhone 或 Mac 也能正常用，功能和主力版完全一致，只是首次安装多一步签名或系统授权。

---

## 手机端（主推 Android，iOS 界面与功能一致）

手机端用 Flutter 开发，所有验证码模型都放在手机本地离线推理，账号密码存在系统安全库（Android Keystore / iOS Keychain）里，只直连 `libseat.lnu.edu.cn`。

下面是实机界面（Android 和 iOS 共用同一套界面，完整 6 张截图和功能细节见 [mobile/README.md](mobile/README.md)）：

<div align="center">
<table>
<tr>
<td align="center" width="33%">
<img src="docs/IOS/01_home_rush.png" width="220" alt="晨约主界面"><br>
<sub><b>晨约</b>：立即 / 06:30 定时、快捷方案、实时日志</sub>
</td>
<td align="center" width="33%">
<img src="docs/IOS/03_seat_radar.png" width="220" alt="全馆实时余座雷达"><br>
<sub><b>寻座</b>：双校区 21 室实时空座与网格选座</sub>
</td>
<td align="center" width="33%">
<img src="docs/IOS/05_my_ticket_pass.png" width="220" alt="入馆座签与签到提醒"><br>
<sub><b>入馆</b>：电子座签、违约次数、暂离计时与签到提醒</sub>
</td>
</tr>
</table>
</div>

主要功能：
- **定时 06:30 / 立即捡漏**：定时模式会在 `06:29:45` 提前登录并拉取座位表，`06:29:55` 二次校准图书馆服务端时间，`06:30:00.200` 准点提交（高峰自动对齐服务端反作弊延时与 6 秒冷却，遇系统繁忙自动退避不误停）；平时也可以随时切到“寻座”看哪个自习室还有空位，点进去直接约。
- **偏好选座顺位可视化**：在「速改 → 首选座位」点选心仪座号时，每个已选座位右上角会实时显示顺位角标（`1 / 2 / 3…`），网格上方同步展示可点击移除的横向顺位队列条（如 `1 194号 × → 2 88号 ×`），首页目标摘要、夜守模式与「寻座」存入首选全面同步顺序。
- **双号接力免换座**：在“我的”里配好主副两个校园卡号（比如 `09:00-15:00` + `15:00-21:00`），两段不重叠时会自动尝试抢同一个座；时间重叠则自动错开，不会自己人撞座。
- **自动设防违约提醒**：约座成功后自动注册系统级闹钟（预约开始前 15 分钟提醒一次，开始后 20 分钟、也就是距离 30 分钟违约截止剩 10 分钟再急催一次），划掉后台也能响。

### Android 使用要点（重要）

1. 去 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 下载 `LNU-LibSeat-Android-arm64.apk` 安装（未上架应用商店，遇系统“未知来源/未备案”提示点继续安装即可；后续升级直接覆盖，不丢配置）。
2. 打开后在 **我的 → 校园卡账号** 填学号密码（初始密码一般为 `000000`），回首页点 **速改** 选校区、自习室、时段和首选座号（可留空）。
3. **如果你打算睡前设好 6:30 锁屏过夜**，请务必花 1 分钟做一次后台白名单设置：
   - 先在 App 里进 **我的 → 晨约守夜与后台保活**，把里面 4 项系统权限体检点绿；
   - 再按手机品牌（vivo / 小米 / 华为 / OPPO）打开“允许后台高耗电 / 自启动 / 锁屏显示”，并在多任务界面给 App 加锁。
   - 国产 Android 12–16 系统如果不给白名单，锁屏十几秒就会冻结进程。App 已内置 `MediaSession` 实时流防冻结音频、通知栏每秒实时倒计时、四段式系统硬件闹钟和 Android 14 锁屏强拉起逻辑，配完白名单后建议先设“当前时间 + 2 分钟”锁屏自测一次。
   - 实在怕系统抽风（比如期末周），首页点 **夜守** 会切到纯黑床头时钟页，插着电不锁屏放床头是最稳的做法。

分品牌详细设置步骤见 👉 **[docs/ANDROID_INSTALL_GUIDE.md](docs/ANDROID_INSTALL_GUIDE.md)**。

### iPhone / iPad 安装说明

因为没有交苹果开发者年费上架 App Store，iOS 提供的是免签名包 `LNU-LibSeat-iOS-arm64-unsigned.ipa`。用自己的免费 Apple ID（建议注册个小号）通过 **Sideloadly、爱思助手、SideStore 或巨魔（TrollStore）** 都能 0 元装进手机。

普通免费 Apple ID 签名有效期 7 天，到期前原位覆盖重签就行，不会丢账号和配置（SideStore 支持连 Wi-Fi 无线续签）。App 里也内置了锁屏静音后台保活和纯黑“夜守”时钟，详细步骤见 👉 **[docs/IOS_INSTALL_GUIDE.md](docs/IOS_INSTALL_GUIDE.md)**。

---

## 电脑端（主推 Windows，也支持 Mac）

电脑端适合放宿舍桌上挂机，不用操心手机省电策略。界面用 PySide6 写的，精简打包后比 v5 小了 400 MB 以上（Windows 包从 613 MB 降到约 205 MB）。

### Windows 三步上手

1. 去 [Releases](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest) 下载 `LNU-LibSeat-v6.0.1-Windows-x86_64.zip` 并解压。
2. 双击目录里的 `LNU-LibSeat.exe` 启动（不需要 Python，也不需要 Edge/Chrome 驱动）。
3. 选好校区、自习室，填学号密码、时段和收件邮箱（想收微信/Bark 通知可以顺手填“手机推送”框），点 **开始抢座** 即可。首选座位可以全部留空，程序会自动抢当前空座。

<table>
<tr>
<td align="center" width="50%">
<img src="docs/screenshots/01_folder_structure.png" width="380" alt="解压目录结构"><br>
<sub>解压后直接双击 exe</sub>
</td>
<td align="center" width="50%">
<img src="docs/screenshots/02_gui_main.png" width="380" alt="桌面端主界面"><br>
<sub>左侧填配置，右侧看实时日志（不再弹出浏览器）</sub>
</td>
</tr>
</table>

程序运行期间会自动阻止 Windows 休眠（调用 `SetThreadExecutionState` + 心跳，结束后自动还原）。如果想让电脑平时睡眠、每天 6:25 自动醒来运行，可以用 Windows 任务计划程序，配置步骤写在 [docs/QUICKSTART.md](docs/QUICKSTART.md)。

### Mac 版本（Apple Silicon）

1. 去 [Releases](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest) 下载 `LNU-LibSeat-v6.0.1-macOS-arm64.zip` 并解压。
2. 首次运行需要**右键**点击 `首次运行请先双击我.command` → 打开 → 再点一次打开（软件没做苹果付费公证，首次需手动放行；如果被拦，去 **系统设置 → 隐私与安全性 → 仍要打开**）。之后直接双击 `LNU-LibSeat.app` 就行。
3. v6 去掉浏览器后，Mac 端和 Windows 体验完全一致，支持双账号并行，挂机期间自动用系统 `caffeinate` 防休眠。`config.py` 和 `logs/` 就在 `.app` 同级目录。
4. **纯原生 Apple Silicon（`arm64`）**：包内全部二进制均为原生 `arm64`，**不依赖 Rosetta 2**（不受后续 macOS 取消 Rosetta 影响）。如果此前安装的是旧版 `v5.0.0-macOS-x86_64` 并频繁收到系统 Rosetta 提示，直接升级到 v6 即可（旧 `config.py` 复制到新目录可无缝沿用）。

---

## 常见问题

<details>
<summary><b>1. 为什么 Android 安装包约 166 MB、Windows 约 205 MB？</b></summary>

安装包里直接内置了 5 个原版无损的 ONNX 神经网络模型（登录 4 位图形码 + Click1/Click3 的 YOLOv8 检测和 MobileNetV4 匹配，光模型就占约 159 MB）。这样设计的好处是完全本地离线识别、识别率稳、不用花一分钱买打码平台 API，也不用担心作者服务器挂掉。
</details>

<details>
<summary><b>2. 为什么 06:30 日志里会提示等待 2.05s 或 6s 冷却窗口？是不是卡住了？</b></summary>

这是**正常保护机制，不是卡死**。图书馆服务端在 `06:30` 三字验证码高峰期间会校验官网前端固有的 `1.5s + 2.0s` 延时，并对重新拉取验证码设置了 `6s` 滑动冷却锁（过快重拉会反复返回「系统繁忙, 请稍后: 06」）。v6.0.1 主动对齐了这套节奏：首轮命中约 **4 秒**即可抢中（仍比模拟浏览器快），即便偶发重刷也会稳稳等完冷却再取新图，不会触发 12 次繁忙熔断。
</details>

<details>
<summary><b>3. 为什么白天立即抢座时，首选座该时段明明不空闲，日志里还显示“验证码一次通过”？</b></summary>

因为图书馆的验证码接口只校验账号，不绑定具体座位与时段；v6 纯 API 为了在 `06:30` 极致提速，省去了点击座位前的时段查询接口，直接通过下单接口让服务端判定该时段能否预约。白天非高峰单字码极快，遇到已被占的首选座约 **0.5 秒**就会自动跳到下一个座位，属于正常行为。
</details>

<details>
<summary><b>4. Android 锁屏后倒计时卡住、解锁才开始跑怎么办？</b></summary>

这是国产系统（尤其是 vivo OriginOS / 小米 HyperOS / 华为鸿蒙）的锁屏冻结机制导致的。请确认已装最新版 APK（可在 **我的** 页面最底部核对版本号），并按 [Android 保活教程](docs/ANDROID_INSTALL_GUIDE.md) 开启「电池优化白名单 / 允许后台高耗电 / 自启动 / 后台弹出界面 / 多任务加锁」，然后把时间设成“当前时间 + 2 分钟”锁屏测一次确认能准时拉起。
</details>

<details>
<summary><b>5. 我以前用 v5，原来的 config.py 还能直接用吗？</b></summary>

可以。直接把旧 `config.py` 复制到 v6 同级目录即可，废弃的 `BROWSER`、`DRIVER_PATH`、`WEBDRIVER_CACHE` 字段会被自动忽略。详见 [docs/MIGRATION_V5_TO_V6.md](docs/MIGRATION_V5_TO_V6.md)。
</details>

<details>
<summary><b>6. 抢座失败了怎么看原因？</b></summary>

- **手机端**：进入 **我的 → 运行记录与识图回放**，可以直接看每次验证码识别的红绿点，支持一键导出**最近一轮完整日志（含双账号）**或**打包全部历史日志（`.zip`）**；iPhone 也可以直接打开系统「文件」App →「我的 iPhone」→「LNU-LibSeat」随时查看。
- **电脑端**：打开 `logs/sessions/<时间>_<学号>/`，里面有 `session.log`（首行含当前版本号）、`抢座顺序.txt`、自动抹除了密码和 Token 的 `http_trace.jsonl`，以及验证码红绿点叠加图（`*_captcha_*.png`）。
</details>

<details>
<summary><b>7. 怎么把抢座结果推送到微信或 iPhone 通知？</b></summary>

在电脑版“手机推送”框（或 `config.py` 里的 `WEBHOOK_URL`，手机版在 **我的 → 邮件与推送通知**）粘贴对应地址就行，程序会自动按域名适配：
- Bark（iOS）：`https://api.day.app/<DeviceKey>/`
- PushPlus（微信）：`https://www.pushplus.plus/send?token=<Token>`
- Server酱（微信）：`https://sctapi.ftqq.com/<SendKey>.send`
- 企业微信 / 飞书 / 钉钉群机器人：直接填机器人 Webhook 地址
</details>

<details>
<summary><b>8. v6 相比旧版 v5（Selenium 浏览器）改了什么？</b></summary>

| 对比项 | v5（Selenium 浏览器） | v6（纯 HTTP API） |
| :--- | :--- | :--- |
| 运行依赖 | 依赖 Edge / Chrome / Safari 及驱动 | 无需任何浏览器和 WebDriver |
| 提前准备 & 下单节奏 | 提前 30s 开浏览器，加载慢且不稳定 | 提前 15s 登录；非高峰实测约 **0.55s** 下单，06:30 高峰自动对齐官网防风控窗口与 6s 冷却 |
| 选座方式 | 按座号逐个试错，必须填至少 1 个首选 | 实时拉取全房空座，首选可留空（手机端支持顺位角标与队列条），支持多自习室兜底 |
| 时间对齐与繁忙容错 | 依赖本机系统时钟 + 硬等 2 秒 | HTTP `Date` 校准服务端时间 + 5 秒宽限重探 + 高峰系统繁忙退避不误停 |
| 验证码识别 | 仅 06:30–06:35 启用本地模型 | 按接口返回字数全天自动识别 Click1 / Click3 |
| 终端与体积 | 仅电脑端（Win 613MB / Mac 632MB） | 新增 Android / iOS 独立版；桌面端缩至 ~200MB（Mac 纯原生 `arm64`） |

</details>

---

## 文档目录

**日常使用**
- [docs/ANDROID_INSTALL_GUIDE.md](docs/ANDROID_INSTALL_GUIDE.md) — Android 安装、分品牌防杀后台与 2 分钟锁屏自测（主推）
- [docs/QUICKSTART.md](docs/QUICKSTART.md) — 全平台上手与 Windows 定时唤醒教程
- [mobile/README.md](mobile/README.md) — 手机端完整功能说明与 6 张实机截图
- [docs/IOS_INSTALL_GUIDE.md](docs/IOS_INSTALL_GUIDE.md) — iPhone / iPad 免费自签安装与过夜保活
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — 桌面端 `config.py` 全字段说明（含多自习室兜底 `FALLBACK_ROOMS`）
- [docs/MIGRATION_V5_TO_V6.md](docs/MIGRATION_V5_TO_V6.md) — v5 老用户迁移到 v6

**架构与开发参考**
- [docs/RELEASE_NOTES_V6.md](docs/RELEASE_NOTES_V6.md) — v6.0.0 完整更新日志（[CHANGELOG.md](CHANGELOG.md)）
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 桌面 Python + 移动 Flutter 双端架构说明
- [docs/MOBILE_GUIDE.md](docs/MOBILE_GUIDE.md) — 移动端目录结构与本地编译 APK / IPA
- [docs/API_PROTOCOL_CONTRACT.md](docs/API_PROTOCOL_CONTRACT.md) — 纯 API 接口契约（脱敏）
- [docs/CAPTCHA_YOLO4_SIAMESE.md](docs/CAPTCHA_YOLO4_SIAMESE.md) — YOLOv8 + Siamese 本地验证码识别说明（注：源码里的 `yolo4` 只是早期实验代号，实际骨干是 YOLOv8）
- [docs/README.md](docs/README.md) — 全部文档与历史归档总索引

---

## 开发者：源码运行与本地打包

<details>
<summary><b>展开查看 Python / Flutter 运行与打包命令</b></summary>

**桌面端从源码运行（Python 3.10+，推荐 3.12）：**

```powershell
git clone https://github.com/XUNRANA/LNU-LibSeat-Automation
cd LNU-LibSeat-Automation
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python gui_qt.py        # 启动桌面界面
# python main.py        # 纯命令行运行
```

**运行测试与静态检查（纯离线，无需浏览器）：**

```powershell
pip install pytest ruff
pytest tests/ -q        # 94 项 Python 单测
ruff check .
cd mobile && flutter test  # 23 项 Flutter 跨语言契约与界面单测
```

**本地打包各端安装包：**
- Android：`python build_android.py` → `dist/辽宁大学图书馆座位预约.apk`
- Windows：`python build.py` → `dist/LNU-LibSeat-v6.0.1-Windows-x86_64.zip`
- iOS（需 macOS + Xcode + CocoaPods）：`python3 build_ios.py` → `dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`
- macOS（需 Apple Silicon Mac）：`python3 build_mac.py` → `dist/LNU-LibSeat-v6.0.1-macOS-arm64.zip`

</details>

<details>
<summary><b>仓库目录结构</b></summary>

```text
LNU-LibSeat-Automation/
├── build_android.py / build_ios.py  # Android (.apk) & iOS 免签名 (.ipa) 构建脚本
├── build.py / build_mac.py          # Windows & macOS 精简隔离打包脚本
├── mobile/                          # Flutter 跨平台手机端源码（Android & iOS）
│   ├── lib/                         #   纯 API 引擎、端侧 5 ONNX 推理、四频道界面、全量日志导出
│   ├── android/                     #   MediaSession 实时流保活、四段式闹钟、签到闹钟、BitmapFactory 解码
│   └── ios/                         #   锁屏静音保活、ImageIO 解码、文件 App 日志共享、深链
├── scripts/                         # 移动端 ONNX 模型准备与跨语言测试向量导出
├── gui_qt.py & ui_qt/               # PySide6 桌面界面
├── main.py                          # CLI 入口
├── core/                            # 纯 API 客户端、AES/HMAC 签名、时钟校准、限流、ONNX 推理、通知
├── logic/                           # 多账号调度、抢座闭环、实时空座策略、结果分类
├── info/                            # 崇山 & 蒲河 21 间自习室离线座号清单
├── model/ & train/                  # 验证码模型定义与完整训练管线
├── tests/                           # Python 离线单元测试
└── docs/                            # 各端安装教程、架构与协议文档
```

</details>

---

## 辽大图书馆基本规则备忘

- **预约系统**：`libseat.lnu.edu.cn` / 微信公众号 / 馆内终端（校园卡号登录，初始密码 `000000`）
- **放座时间**：每日 `06:30`
- **签到窗口**：预约开始前 30 分钟 ～ 开始后 30 分钟内
- **限额与处罚**：每日最多预约 3 次、单次最长 6 小时、每日最多取消 3 次；7 天内违约 3 次进黑名单 7 天

## 赞助支持

项目完全免费开源，所有识别都在本地跑，没有收费功能。如果这个工具帮你在早八或考研复习期间多睡了一会儿，觉得有帮助可以给个 Star，也可以随手请作者喝杯奶茶，用于后续维护协议适配和更新模型。

<div align="center">
  <img src="wechat_pay.png" width="220" alt="微信支付赞助码"><br>
  <sub>微信赞赏</sub>
</div>

## 免责声明

本项目仅供技术学习与个人自习便利，请遵守学校图书馆管理规定：
- 约到座位请按时到馆签到，不要恶意占座或转卖座位；
- 请勿修改或绕过内置限流机制对学校服务器发起高频请求；
- 使用本工具产生的一切后果由使用者自行承担。

## 致谢

- [geTiger/get_LibSeat](https://github.com/geTiger/get_LibSeat) — 最早开源的辽大图书馆约座项目，早期流程参考自此。
- [MgArcher/Text_select_captcha](https://github.com/MgArcher/Text_select_captcha) — 点选验证码识别方案，本项目的 YOLOv8 + Siamese 管线源自此思路。
- [@MorinGale](https://github.com/MorinGale) — 在 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 中提出并实测验证了纯 API 方案，促成了 v6 的重写。

## License

[MIT](https://opensource.org/licenses/MIT) © XUNRANA
