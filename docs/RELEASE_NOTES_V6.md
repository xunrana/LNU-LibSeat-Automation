# LNU-LibSeat v6.0.0

v6.0.0 是一次底层重写（起因见 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 与 [Issue #6](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/6)）：**彻底移除了 Selenium、浏览器和 OpenCV 依赖**，改为直接调用图书馆接口，实测从锁定空座到下单约 **0.55 秒**；同时新增了可以完全脱离电脑运行的 **手机独立版（Android & iOS）**。

> 老用户注意：桌面端直接兼容旧版 `config.py`，把原来的文件复制过来就能跑。

---

## 下载说明（先看这里）

| 平台 | 推荐 | 文件名 | 大小 | 上手方式 | 教程 |
| :--- | :---: | :--- | :---: | :--- | :--- |
| **Android** | **主推** | `LNU-LibSeat-Android-arm64.apk` | 165.9 MB | 直接安装，不用折腾签名；按教程开一次后台白名单即可锁屏过夜 | [Android 安装与保活教程](ANDROID_INSTALL_GUIDE.md) |
| **Windows** | **主推** | `LNU-LibSeat-v6.0.0-Windows-x86_64.zip` | 204.6 MB | 解压双击 `LNU-LibSeat.exe`，不用装 Python 或浏览器驱动 | [快速上手指南](QUICKSTART.md) |
| **iPhone / iPad** | 支持 | `LNU-LibSeat-iOS-arm64-unsigned.ipa` | 146.7 MB | 用免费 Apple ID 自签（Sideloadly / 爱思 / SideStore / 巨魔） | [iOS 免费安装教程](IOS_INSTALL_GUIDE.md) |
| **macOS (Apple Silicon)** | 支持 | `LNU-LibSeat-v6.0.0-macOS-arm64.zip` | 193.6 MB | 解压后首次右键 `首次运行请先双击我.command` 运行 | [快速上手指南](QUICKSTART.md) |

安装包体积在 147–205 MB 左右，是因为把 5 个原版无损 ONNX 验证码识别模型直接打进了本地包里，完全离线运行，不花打码费也不走中转服务器。

---

## 这一版改了什么

### 1. 彻底去掉浏览器，直接走图书馆接口
- 完整复现了登录 AES 加密、请求 HMAC 签名与动态密钥拉取，跳过了原网页前端人为延迟（1.5s 隐藏按钮 + 2.0s 假加载动画），从锁定空座到提交返回预约单号实测约 **0.55 秒**（其中本地 ONNX 推理约 62ms）。
- 不再需要配 Edge / Chrome / Safari 驱动，也不会再遇到浏览器版本不匹配或动辄 1.5GB 内存占用的问题。Windows 和 macOS 双账号并发体验现在完全一致。
- 桌面打包改用 `PySide6-Essentials`、移除 OpenCV、只保留登录所需的单个 `common_old.onnx` 并排除了训练权重，发行包比 v5 小了 400 MB 以上（Windows `613 MB → 204.6 MB`，macOS `632 MB → 193.6 MB`）。

### 2. 新增手机独立版（主推 Android，同步支持 iOS）
- 不用开电脑，也不用搭服务器。手机端与桌面端共用同一套协议和 5 个原版无损 ONNX 模型，Android 用原生 CPU `BitmapFactory`、iOS 用原生 CPU `ImageIO` 解码并逐像素对齐 Python Pillow，息屏后台不依赖 GPU，识别精度与电脑端一致。
- 内置四个频道（晨约 / 寻座 / 入馆 / 我的）：可以实时查看崇山、蒲河 21 间自习室的空座情况并进网格直接选座，支持双账号全天接力、违约次数查看、暂离计时和系统级签到提醒（开始前 15 分钟提醒、开始后 20 分钟紧急催促，划掉后台仍会响）。
- **06:30 过夜保活**：
  - **Android**：内置静音防冻结音频轨（`mediaPlayback` 前台服务，全零无声不打断音乐，根治国产 ROM 锁屏 10 秒冻结）、四段式硬件闹钟（`-35s / -15s / -5s / -1s`）、Android 14 锁屏亮屏拉起、动态 WakeLock + WifiLock、被杀/重启后自动续抢，App 内自带 4 项权限体检；
  - **iOS**：内置静音后台保活（不打断听歌，抢完自动关）；
  - 两端首页都有纯黑“夜守”床头时钟，重要抢座日插电不锁屏放床头最稳。
- 更多功能说明和 6 张实机截图见 [手机版 README](../mobile/README.md)。

### 3. 抢座策略与稳健性改进
- **服务端时间校准 + 开馆宽限**：通过响应头 `Date` 和网络延迟自动估算本机与图书馆服务器的时间差；定时模式下 `06:30:00–06:30:05` 如果碰到“系统可预约时间为 06:30 ~ 22:30”的切换瞬态，会自动短退避原地重探，不再直接误停。
- **实时空座与多房兜底**：开抢前实时拉取全房座位状态，首选座位可以全部留空；支持配置 `FALLBACK_ROOMS` 备选自习室，切房前先快查空座数跳过满员房。
- **双号协同防撞座**：两个账号时段不重叠（如 `09:00-15:00` + `15:00-21:00`）时允许同抢心仪座，全天免换座；时段重叠时自动错开兜底座。
- **全天自适应点选验证码**：直接根据接口返回的 `wordCheckCount`（1 或 3）自动切换 Click1 / Click3 模型，白天错峰捡漏也能正常解，不再受限于 v5 的 `06:30–06:35` 时间窗口。
- **限流与异常熔断**：内置请求间隔、抖动、空座刷新冷却、连续限流/429 熔断与单会话请求上限；检测到黑名单或接口格式变动立即停机。

### 4. 推送通知与轻量排查
- 成功战报现在会带上**预约单号和凭证小票**，除了内置邮件通知，还新增了手机 Webhook 推送（自动识别 Bark / PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉及通用 JSON）。
- 去掉了笨重的 MP4 录屏，改为记录自动脱敏的 `http_trace.jsonl`（抹除密码、Token 和 Cookie）和不到 50 KB 的验证码候选/点击叠加图。

---

## v5 老用户升级

把旧 `config.py` 直接复制到新目录就行，原来写的 `BROWSER`、`DRIVER_PATH`、`WEBDRIVER_CACHE` 会被自动忽略，不用手改。完整迁移对照见 [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)。

---

## 测试与致谢

- 已通过 92 项 Python 离线单元测试、20 项 Flutter 跨语言契约与界面单测，以及 `ruff check .` 零告警检查。
- 特别感谢 [@MorinGale](https://github.com/MorinGale) 在 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 提出的纯接口设想与实测验证。

[返回项目首页](../README.md) · [Android 安装教程](ANDROID_INSTALL_GUIDE.md) · [iOS 安装教程](IOS_INSTALL_GUIDE.md) · [手机版介绍](../mobile/README.md) · [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)
