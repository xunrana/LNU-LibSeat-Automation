# LNU-LibSeat v6.0.0

v6.0.0 是一次底层重写（起因见 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 与 [Issue #6](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/6)）：**彻底移除了 Selenium、浏览器和 OpenCV 依赖**，改为直接调用图书馆接口，并把 5 个原版无损 ONNX 验证码模型打进本地包；同时新增了可以完全脱离电脑运行的 **手机独立版（Android & iOS）**。

> **2026-11-24 四端安装包已同步更新**：此前已下载过 v6.0.0 的同学建议重新下载覆盖安装（不丢账号与配置）。本次同步包含 **06:30 高峰反作弊延时对齐与系统繁忙容错修复**（Windows / macOS / Android / iOS 全端生效）、**手机端偏好选座顺位角标与队列条**（[Issue #9](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/9)）、**iPhone / Android 全量日志导出**，以及 **macOS 纯原生 `arm64` 架构校验**（[Issue #8](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/8)）。
>
> 老用户注意：桌面端直接兼容旧版 `config.py`，把原来的文件复制过来就能跑。

---

## 下载说明（先看这里）

| 平台 | 推荐 | 文件名 | 大小 | 上手方式 | 教程 |
| :--- | :---: | :--- | :---: | :--- | :--- |
| **Android** | **主推** | `LNU-LibSeat-Android-arm64.apk` | 166.0 MB | 直接安装，不用折腾签名；按教程开一次后台白名单即可锁屏过夜 | [Android 安装与保活教程](ANDROID_INSTALL_GUIDE.md) |
| **Windows** | **主推** | `LNU-LibSeat-v6.0.0-Windows-x86_64.zip` | 204.7 MB | 解压双击 `LNU-LibSeat.exe`，不用装 Python 或浏览器驱动 | [快速上手指南](QUICKSTART.md) |
| **iPhone / iPad** | 支持 | `LNU-LibSeat-iOS-arm64-unsigned.ipa` | 146.8 MB | 用免费 Apple ID 自签（Sideloadly / 爱思 / SideStore / 巨魔） | [iOS 免费安装教程](IOS_INSTALL_GUIDE.md) |
| **macOS (Apple Silicon)** | 支持 | `LNU-LibSeat-v6.0.0-macOS-arm64.zip` | 193.6 MB | 纯原生 `arm64`（零 Rosetta 2），解压后首次右键 `首次运行请先双击我.command` 运行 | [快速上手指南](QUICKSTART.md) |

安装包体积在 147–205 MB 左右，是因为把 5 个原版无损 ONNX 验证码识别模型直接打进了本地包里，完全离线运行，不花打码费也不走中转服务器。

---

## 这一版改了什么

### 1. 彻底去掉浏览器，直接走图书馆接口
- 完整复现了登录 AES 加密、请求 HMAC 签名与动态密钥拉取：非高峰单字码直连下单实测约 **0.55 秒**（其中本地 ONNX 推理约 62ms）；06:30 高峰三字码则会自动对齐官网服务端反作弊时间窗（`1.55s` 最小求解间隔 + `2.05s` 校验后提交缓冲 + `6.2s` 取码冷却），既省掉浏览器冷启动，又不会因为过快提交触发服务端拒判或冷却锁。
- 不再需要配 Edge / Chrome / Safari 驱动，也不会再遇到浏览器版本不匹配或动辄 1.5GB 内存占用的问题。Windows 和 macOS 双账号并发体验现在完全一致。
- **macOS 纯原生 Apple Silicon（`arm64`）**：强制 `--target-arch arm64` 构建、补齐 `Info.plist` 原生架构声明并在打包阶段自动校验全部二进制零 `x86_64` 残留，不再依赖 Rosetta 2，彻底告别系统提醒（[Issue #8](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/8)）。
- 桌面打包改用 `PySide6-Essentials`、移除 OpenCV、只保留登录所需的单个 `common_old.onnx` 并排除了训练权重，发行包比 v5 小了 400 MB 以上（Windows `613 MB → 204.7 MB`，macOS `632 MB → 193.6 MB`）。

### 2. 新增手机独立版（主推 Android，同步支持 iOS）
- 不用开电脑，也不用搭服务器。手机端与桌面端共用同一套协议和 5 个原版无损 ONNX 模型，Android 用原生 CPU `BitmapFactory`、iOS 用原生 CPU `ImageIO` 解码并逐像素对齐 Python Pillow，息屏后台不依赖 GPU，识别精度与电脑端一致。
- 内置四个频道（晨约 / 寻座 / 入馆 / 我的）：可以实时查看崇山、蒲河 21 间自习室的空座情况并进网格直接选座，支持双账号全天接力、违约次数查看、暂离计时和系统级签到提醒（开始前 15 分钟提醒、开始后 20 分钟紧急催促，划掉后台仍会响）。
- **偏好选座顺位可视化（[Issue #9](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/9)）**：在「速改 → 首选座位」点选座号后，每个已选座位右上角实时显示琥珀色顺位数字（`1 / 2 / 3…`），网格上方同步展示可横向滚动的顺位队列条（轻点直接移除，后续顺位自动递补）；首页目标摘要、夜守模式与「寻座」存入首选全面同步顺序显示。
- **06:30 过夜保活**：
  - **Android**：内置正式 `MediaSession` + 实时流不可闻防冻结音频轨（不打断刷抖音/听歌）、通知栏每秒实时倒计时、原生 250ms 心跳驱动与四段式硬件闹钟（`-35s / -15s / -5s / -1s` + 7.5s 广播租约）、Android 14 锁屏亮屏拉起、动态 WakeLock + WifiLock 与被杀/重启续抢，App 内自带 4 项权限体检；
  - **iOS**：内置静音后台保活（不打断听歌，抢完自动关）；
  - 两端首页都有纯黑“夜守”床头时钟，重要抢座日插电不锁屏放床头最稳。
- 更多功能说明和 6 张实机截图见 [手机版 README](../mobile/README.md)。

### 3. 抢座策略与 06:30 高峰稳健性改进
- **06:30 高峰反作弊对齐与系统繁忙容错**：
  - 遇到「系统繁忙, 请稍后: 06」、网关 5xx 或验证码池拥堵等高峰瞬态异常时，不再误判为协议变动而停机，改为自动解析服务端冷却秒数并足额退避重试（单座最多 12 次繁忙重试，不消耗正常验证码次数）；
  - 校验通过后若仍遇偶发验证码报错，自动递增缓冲至最高 `2.80s`；未填首选座时直接复用 `06:29:45` 预热快照，避免 `06:30:00` 浪费首轮刷图时间。
- **服务端时间校准 + 开馆宽限**：通过响应头 `Date` 和网络延迟自动估算本机与图书馆服务器的时间差；定时模式下 `06:30:00–06:30:05` 如果碰到“系统可预约时间为 06:30 ~ 22:30”的切换瞬态，会自动短退避原地重探，不再直接误停。
- **实时空座与多房兜底**：开抢前实时拉取全房座位状态，首选座位可以全部留空；支持配置 `FALLBACK_ROOMS` 备选自习室，切房前先快查空座数跳过满员房。
- **双号协同防撞座**：两个账号时段不重叠（如 `09:00-15:00` + `15:00-21:00`）时允许同抢心仪座，全天免换座；时段重叠时自动错开兜底座。
- **全天自适应点选验证码**：直接根据接口返回的 `wordCheckCount`（1 或 3）自动切换 Click1 / Click3 模型，白天错峰捡漏也能正常解，不再受限于 v5 的 `06:30–06:35` 时间窗口。
- **限流与异常熔断**：内置请求间隔、抖动、空座刷新冷却、连续 12 次限流/429 熔断与单会话 200 次请求上限；检测到黑名单或真正接口格式变动立即停机。

### 4. 推送通知与轻量排查
- 成功战报现在会带上**预约单号和凭证小票**，除了内置邮件通知，还新增了手机 Webhook 推送（自动识别 Bark / PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉及通用 JSON）。
- 去掉了笨重的 MP4 录屏，改为记录自动脱敏的 `http_trace.jsonl`（抹除密码、Token 和 Cookie）和不到 50 KB 的验证码候选/点击叠加图。
- **手机端全量日志导出**：在「我的 → 运行记录与识图回放」支持一键导出**最近一轮完整抢座日志（含双账号）**或**打包导出全部历史日志（`.zip`）**；iPhone 也可直接打开系统「文件」App →「我的 iPhone」→「LNU-LibSeat」随时查看或隔空投送。

---

## v5 老用户升级

把旧 `config.py` 直接复制到新目录就行，原来写的 `BROWSER`、`DRIVER_PATH`、`WEBDRIVER_CACHE` 会被自动忽略，不用手改。完整迁移对照见 [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)。

---

## 测试与致谢

- 已通过 **94 项** Python 离线单元测试、**23 项** Flutter 跨语言契约与界面单测，以及 `ruff check .` 零告警检查。
- 特别感谢 [@MorinGale](https://github.com/MorinGale) 在 [Issue #4](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/4) 提出的纯接口设想与实测验证，以及 [@wsr13657725124](https://github.com/wsr13657725124) 在 [Issue #8](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/8) / [Issue #9](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/9) 提出的建议与反馈。

[返回项目首页](../README.md) · [Android 安装教程](ANDROID_INSTALL_GUIDE.md) · [iOS 安装教程](IOS_INSTALL_GUIDE.md) · [手机版介绍](../mobile/README.md) · [v5 → v6 升级指南](MIGRATION_V5_TO_V6.md)
