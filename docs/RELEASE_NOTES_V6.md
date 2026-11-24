# LNU-LibSeat v6.0.1

> **此前安装过 `v6.0.0` 的同学请直接下载覆盖升级**（不丢账号、密码、方案与笔记）。
> 本次 `v6.0.1` 彻底根治了 `06:30` 高峰期「验证码通过后下单仍报验证码错误」与「`系统繁忙, 请稍后: 06` 连续 12 次熔断」问题（经真机 `06:30` 双号实战验证全中），新增手机端偏好选座顺位角标（[Issue #9](https://github.com/xunrana/LNU-LibSeat-Automation/issues/9)）、全量脱敏日志导出、macOS 纯原生 `arm64` 校验（[Issue #8](https://github.com/xunrana/LNU-LibSeat-Automation/issues/8)），并将四端版本号统一对齐至 `v6.0.1`。

---

## 直接下载（点击文件名即可下载）

| 平台 | 推荐 | 安装包（点此直下） | 大小 | 上手方式 | 教程 |
| :--- | :---: | :--- | :---: | :--- | :--- |
| **Android** | **主推** | [`LNU-LibSeat-Android-arm64.apk`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-Android-arm64.apk) | 约 166 MB | 直接覆盖安装，免签名续签；按教程开一次后台白名单即可锁屏过夜 | [Android 安装与保活](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/ANDROID_INSTALL_GUIDE.md) |
| **Windows** | **主推** | [`LNU-LibSeat-v6.0.1-Windows-x86_64.zip`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-v6.0.1-Windows-x86_64.zip) | 约 205 MB | 解压双击 `LNU-LibSeat.exe`，零 Python / 零浏览器驱动 | [快速上手指南](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/QUICKSTART.md) |
| **iPhone / iPad** | 支持 | [`LNU-LibSeat-iOS-arm64-unsigned.ipa`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-iOS-arm64-unsigned.ipa) | 约 147 MB | 免费 Apple ID 自签（Sideloadly / 爱思 / SideStore / 巨魔） | [iOS 免费安装教程](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/IOS_INSTALL_GUIDE.md) |
| **macOS (Apple Silicon)** | 支持 | [`LNU-LibSeat-v6.0.1-macOS-arm64.zip`](https://github.com/xunrana/LNU-LibSeat-Automation/releases/download/v6.0.1/LNU-LibSeat-v6.0.1-macOS-arm64.zip) | 约 194 MB | 纯原生 `arm64`（零 Rosetta 2），首次右键 `首次运行请先双击我.command` | [快速上手指南](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/QUICKSTART.md) |

> 安装包内置 5 个原版无损 ONNX 识图模型（约 159 MB），完全本地离线运行，零打码费、不经过任何第三方服务器。v5 老用户把旧 `config.py` 直接复制到新目录即可无缝沿用。

---

## v6.0.1 核心改进

1. **彻底修复 `06:30` 高峰下单被拒与繁忙熔断（全四端生效）**
   - 对齐官网 Vue 前端在 `06:30` 三字点选下的 `1.5s + 2.0s` 反作弊校验节奏（求解补齐 `1.55s`、校验通过后缓冲 `2.05s` 再提交 `freeBook`），根治 `checkCaptcha` 已通过却被服务端判「验证码错误」的问题；非高峰单字码依然保持 ~0.55 秒秒抢。
   - 遇到 `系统繁忙, 请稍后: 05/06` 或网关 5xx 时自动归类为可恢复繁忙（不再误判为协议漂移停机），精准解析倒计时并等足 `冷却 + 0.60s`，且跨次/跨座取码自动保持 `6.20s` 间隔，不再反复重置服务端 6 秒滑动锁导致 12 次熔断。
   - 未配首选座时直接复用 `06:29:45` 预热座表，不浪费 `06:30:00` 首轮时间重复刷图。
2. **手机端偏好选座顺位可视化（[Issue #9](https://github.com/xunrana/LNU-LibSeat-Automation/issues/9)）**
   - 在「速改 → 首选座位」点选座号后，每个已选座位右上角实时显示琥珀色顺位角标（`1 / 2 / 3…`），网格上方新增可横向滚动顺位队列条（轻点移除，后续顺位自动递补）；首页摘要、夜守模式与「寻座」存入首选同步显示顺位。
3. **手机端一键日志导出 & 四端统一版本号**
   - 在「我的 → 运行记录与识图回放」可一键导出**最近一轮完整抢座日志（含双账号）**或**打包全部历史日志（`.zip`）**；iPhone 也可直接打开系统「文件」App →「我的 iPhone」→「LNU-LibSeat」查看或隔空投送。
   - 手机端「我的」底部、桌面端底部栏以及每次 `session.log` 首行均标识 `v6.0.1`，排查问题时一眼确认是否为最新版本。
4. **macOS 纯原生 Apple Silicon `arm64` 构建校验（[Issue #8](https://github.com/xunrana/LNU-LibSeat-Automation/issues/8)）**
   - 强制 `--target-arch arm64`、`Info.plist` 写入原生架构声明并校验包内全部二进制零 `x86_64` 残留，彻底摆脱 Rosetta 2 提示。

---

<details>
<summary><b>展开查看 v6 系列基础特性与工程技术细节</b></summary>

### 1. 纯 HTTP API 引擎（零浏览器 / 零 Selenium / 零 OpenCV）
- 完整复现登录 AES 加密、HMAC-SHA256 请求签名与动态 `baseUrl.js` 密钥拉取，省去浏览器冷启动与驱动错配，Windows / macOS 桌面包比 v5 瘦身 400 MB+。
- 通过 HTTP 响应头 `Date + RTT/2` 自动校准服务端时钟；`06:30:00–06:30:05` 命中未放座瞬态自动短退避重探。
- 支持实时拉取全房空座（首选可留空）、`FALLBACK_ROOMS` 多自习室兜底、双账号接力防撞座（不重叠时段允许同抢心仪座，重叠时段自动错开）、全天自适应 Click1 / Click3 识别，以及 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉 Webhook 推送。

### 2. 手机独立离线版（Android 主推 · 同步支持 iOS）
- 与桌面端共用 5 个原版无损 ONNX 模型；Android 走原生 CPU `BitmapFactory`、iOS 走原生 CPU `ImageIO` 解码并逐字节对齐 Python Pillow，息屏后台不依赖 GPU。
- 内置「晨约 / 寻座 / 入馆 / 我的」四频道：21 间自习室实时余座雷达、网格直订、宝藏座笔记、违约守护与系统级签到防违约提醒（开始前 15 分钟温和提醒、开始后 20 分钟紧急催促，划掉后台仍会响）。
- **06:30 过夜保活**：Android 内置 `MediaSession` + 实时流不可闻防冻结音频轨、通知栏每秒倒计时、原生 250ms 心跳、四段式硬件闹钟（`-35s / -15s / -5s / -1s` + 7.5s 广播租约）、Android 14 锁屏亮屏拉起与 4 项权限体检；iOS 内置静音后台保活；双端均配备纯黑「夜守」床头时钟。

### 3. 测试与致谢
- 已通过 **94 项** Python 离线单元测试、**23 项** Flutter 跨语言契约与界面单测，以及 `ruff check .` 零告警检查。
- 感谢 [@MorinGale](https://github.com/MorinGale)（[Issue #4](https://github.com/xunrana/LNU-LibSeat-Automation/issues/4)）与 [@wsr13657725124](https://github.com/wsr13657725124)（[Issue #8](https://github.com/xunrana/LNU-LibSeat-Automation/issues/8) / [Issue #9](https://github.com/xunrana/LNU-LibSeat-Automation/issues/9)）的建议与反馈。

</details>

---

[项目首页](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/README.md) · [Android 安装与保活](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/ANDROID_INSTALL_GUIDE.md) · [iOS 安装教程](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/IOS_INSTALL_GUIDE.md) · [手机版介绍](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/mobile/README.md) · [v5 → v6 升级指南](https://github.com/xunrana/LNU-LibSeat-Automation/blob/master/docs/MIGRATION_V5_TO_V6.md)
