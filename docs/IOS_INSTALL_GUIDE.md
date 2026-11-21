# 🍎 iPhone / iOS 零元免费安装与过夜使用教程

> **无需越狱 · 无需购买 Apple 付费开发者账号 · 完全免费自签安装**
>
> 适用机型：运行 **iOS 15.0 及以上** 的所有 iPhone / iPad（已在 iPhone 17 / iOS 27 真机全流程实测通过）。
>
> 相关文档：[📱 手机独立版 README](../mobile/README.md) · [🛠️ 移动端编译指南](MOBILE_GUIDE.md) · [⬅️ 返回主 README](../README.md)

---

## 📋 安装前了解（30 秒看懂）

本项目为免费开源工具，未上架 App Store（免去每年 99 美元开发者年费与审核限制），因此提供标准的**免签名 `.ipa` 安装包**：

- **安装包下载**：前往 [GitHub Releases 最新版本](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest) 下载 **`LNU-LibSeat-iOS-arm64-unsigned.ipa`**（约 147 MB，已离线内置全部 5 个无损 ONNX 验证码识别模型）。
- **为什么需要签名？** 苹果要求装进 iPhone 的所有 App 都必须带有签名证书。使用你自己的**普通免费 Apple ID** 即可免费签发个人开发证书（**0 元**）。
- **免费自签的正常限制**：
  1. **每 7 天需要续签一次**（到期前用工具原位覆盖重签，**学号、偏好、自习方案等本地数据不会丢失**；用 SideStore 可实现手机端无线自动续签）；
  2. 同一个免费 Apple ID 最多同时在手机上装 **3 个**自签 App；
  3. 如果担心输入主 Apple ID 密码，**强烈建议专门注册一个空闲小号 Apple ID 用于签名**，与主账号完全隔离。

---

## 🧭 选择适合你的安装方式（任选其一）

| 方式 | 需要电脑吗？ | 推荐指数 | 特点与有效期 |
| :--- | :--- | :--- | :--- |
| **方式一：Sideloadly**（Win / Mac） | 仅签名时需数据线连电脑 | ⭐⭐⭐⭐⭐ | **最通用、最稳定**，Windows / Mac 通吃，7 天续签一次 |
| **方式二：爱思助手**（Win / Mac） | 仅签名时需数据线连电脑 | ⭐⭐⭐⭐⭐ | **中文界面最直观**，国内同学最熟悉，7 天续签一次 |
| **方式三：SideStore / AltStore** | 仅首次装 SideStore 需电脑 | ⭐⭐⭐⭐ | 装完后**手机连 Wi-Fi 即可自动/一键续签**，彻底告别插线 |
| **方式四：Xcode 真机直装**（Mac） | 需要 Mac + Xcode | ⭐⭐⭐ | 适合自己改代码/编译的同学，7 天续签一次 |
| **方式五：TrollStore（巨魔商店）** | 无需电脑 | ⭐⭐⭐⭐⭐ | 若手机系统版本支持巨魔，导入即**永久生效、永不过期** |

---

## 🛠️ 分步安装教程

### 方式一：使用 Sideloadly 安装（推荐，Windows / macOS 通用）

1. **准备软件**
   - 前往 [sideloadly.io](https://sideloadly.io/) 下载并安装 **Sideloadly**。
   - **Windows 用户必看**：需额外安装**非 Microsoft Store 网页版**的 [iTunes](https://www.apple.com/itunes/download/win64) 与 [iCloud](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe)（仅装驱动即可，无需登录 iCloud）。macOS 用户无需装额外驱动。
2. **连接 iPhone**
   - 用数据线将 iPhone 连到电脑，手机弹出「要信任此电脑吗？」时点击 **信任** 并输入锁屏密码。
3. **导入 IPA 并签名安装**
   - 打开 Sideloadly，确认 `iDevice` 一栏已识别到你的 iPhone；
   - 将下载好的 `LNU-LibSeat-iOS-arm64-unsigned.ipa` **拖入**左侧 IPA 图标框；
   - 在 `Apple ID` 输入框填写你的免费 Apple ID（建议用小号）；
   - 点击 **`Start`** → 按提示输入 Apple ID 密码与双重认证 6 位验证码；
   - 等待进度条走完显示 **`Done`**，手机桌面就会出现蓝金校徽的 **LNU-LibSeat** 图标！
4. **7 天后续签**
   - 7 天后若点击 App 闪退，只需数据线连电脑再用 Sideloadly **重新拖入同一个 `.ipa` 点 `Start` 覆盖安装**（**不要先卸载 App**），原有账号配置和自习方案会完整保留。

---

### 方式二：使用爱思助手安装（中文界面，Windows / macOS 通用）

1. 下载并打开 **[爱思助手](https://www.i4.cn/)**，数据线连接 iPhone 并在手机上点「信任此电脑」。
2. 顶部点击 **「工具箱」▸「IPA 签名」**。
3. 点击 **「添加 IPA 文件」**，选中 `LNU-LibSeat-iOS-arm64-unsigned.ipa`。
4. 切换到 **「使用 Apple ID 签名」**，点击 **「添加 Apple ID」** 输入你的免费 Apple ID 与密码，勾选该账号后点 **「开始签名」**。
5. 签名成功后，点击「打开已签名 IPA 位置」，再在爱思助手「我的设备 ▸ 应用游戏 ▸ 导入安装」选中刚签好的 `.ipa` 装进手机即可。

---

### 方式三：使用 SideStore 无线自动续签（一次配置，长期省心）

如果你不想每 7 天插一次数据线，推荐使用开源工具 **[SideStore](https://sidestore.io/)**：
1. 按 [SideStore 官方入门引导](https://docs.sidestore.io/docs/installation/prerequisites/) 首次用电脑把 SideStore 装到你的 iPhone；
2. 将 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 通过隔空投送（AirDrop）或微信传到 iPhone 的「文件」App 中；
3. 打开手机上的 SideStore → 点左上角 **`+`** → 选中 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 安装；
4. 之后每隔 7 天内，只要手机连着 Wi-Fi（按 SideStore 提示开着 WireGuard 本地回环），在手机上点一下刷新（或配合快捷指令自动刷新）即可续签，**全程不再需要电脑**。

---

### 方式四：Mac 开发者用 Xcode 真机直装

如果你已经克隆了本仓库并装有 Xcode：
1. 在仓库根目录跑完 `python3 build_ios.py`（确保 5 个 ONNX 模型与本地 Pod 已准备完毕）；
2. 用 Xcode 打开 **`mobile/ios/Runner.xcworkspace`**（⚠️ 必须打开白底的 `.xcworkspace`，不要打开 `.xcodeproj`）；
3. 左侧选中 **Runner ▸ TARGETS 下的 Runner ▸ Signing & Capabilities**：
   - 勾选 **Automatically manage signing**；
   - **Team** 下拉选择你的免费个人账号（`Personal Team`）；
4. **关键步骤——切换为 Release 模式**：
   - 点击顶部中间 **`Runner`** → **`Edit Scheme...`** → 左侧选 **Run** → **Build Configuration** 改为 **`Release`**，并**取消勾选 `Debug executable`** → 点 Close；
   - *(不改 Release 的话，拔掉数据线后再次点开 App 会直接闪退！)*
5. 顶部设备栏选中你的真实 iPhone，点击左上角 **`▶`** 等待安装完成（首次会弹窗询问钥匙串权限，输入 Mac 开机密码并点 **「始终允许」**）。

---

### 方式五：TrollStore（巨魔商店，永久免续签）

如果你的 iPhone 系统版本已安装 TrollStore：
1. 将 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 发送到手机「文件」App；
2. 分享 → 用 **TrollStore** 打开 → 点击 **Install**；
3. 安装后**无需信任证书、无 7 天过期限制、永久生效**。

---

## 🔓 首次打开必做两步（缺一不可！）

安装完成后，首次在桌面点击图标可能会提示「需要开发者模式」或「未受信任的开发者」，请按顺序完成这两步：

### 第一步：开启「开发者模式」（iOS 16 及以上必需）
1. 打开 iPhone **设置 ▸ 隐私与安全性**，滑到最底部找到 **「开发者模式」**；
2. 打开开关 → 按提示重启手机 → 重启解锁后在弹窗中点击 **「开启」** 并输入锁屏密码。
   > *若在「隐私与安全性」底部看不到「开发者模式」，请先用数据线完成一次 Sideloadly / 爱思助手 / Xcode 安装，它会自动出现。*

### 第二步：信任个人开发者证书
1. 打开 iPhone **设置 ▸ 通用 ▸ VPN与设备管理**；
2. 在「开发者 App」下方点击你的 **Apple ID 邮箱**；
3. 点击蓝字 **「信任 “Apple Development: ...”」** → 弹窗再点 **「信任」**；
4. 返回桌面点击 **LNU-LibSeat** 图标，即可正常进入使用！（建议同步允许 App 的「通知权限」，用于抢座成功推送与防违约签到提醒。）

---

## ⏰ iPhone 睡前设定次日 06:30 准点抢座秘籍

iOS 系统默认会在锁屏约 30 秒后冻结普通后台 App，导致普通定时脚本失效。本 App 为 iOS 提供了**双保险保活方案**：

### 方案 A：内置「iOS 锁屏后台静音保活」（默认自动启用，可锁屏）
- 点击开始定时抢座后，若日志中出现 **`🌙 已激活 iOS 锁屏后台保活`**，即可**直接按电源键锁屏或切去回微信**；
- 原理：使用 `UIBackgroundModes: audio` 极低功耗全零静音流维持进程活跃（`.mixWithOthers` 不打断你听歌/刷视频、不抢占锁屏媒体卡片），并配合纯 CPU `ImageIO` 图像解码绕过锁屏 GPU 限制；**抢座结束或手动中止后立刻自动关闭释放**。
- **过夜防踩坑 3 条铁律**：
  1. **绝对不要**在多任务后台界面把本 App **上滑划掉**；
  2. 设好定时准备过夜后，**不要再切出去打大型游戏或长时间拍视频**（防止内存吃紧触发 iOS Jetsam 回收后台进程）；
  3. 睡前**关闭「低电量模式」**与系统自动重启更新，**插上充电线**放床头。

### 方案 B：「银杏夜守」OLED 纯黑床头模式（期末/考研 100% 绝对稳妥）
- 在 App 首页点击 **「夜守」**，屏幕会切换为 **纯黑 `#000000` 极微光书桌时钟**（OLED 黑色像素几乎零发光、每分钟自动微移防烧屏，并自动阻止自动息屏）；
- **插上充电线直接放床头，不要手动按电源键锁屏**——App 始终处于 iOS 最高优先级前台，绝不会触发后台内存回收，次日 `06:29:45` 自动无声预热、`06:30:00.200` 毫秒级落座并弹提醒！

---

## 🛟 常见安装与使用问题（FAQ）

<details>
<summary><b>Q1: 安装 7 天后点图标秒退怎么办？我的配置会丢吗？</b></summary>

这是免费个人 Apple ID 证书 7 天到期的正常现象。**千万不要先卸载 App！** 直接用原来的工具（Sideloadly / 爱思助手 / SideStore / Xcode）用同一个 Apple ID **重新覆盖安装一次**即可恢复打开，你的学号密码、首选座位和自习方案全部都在。
</details>

<details>
<summary><b>Q2: 签名时报「Maximum number of apps for free development profiles has been reached」？</b></summary>

免费 Apple ID 同一台手机最多同时安装 **3 个**自签 App（且 7 天内最多注册 10 个 App ID）。删掉手机上其他不用的免费自签 App，或换一个空闲小号 Apple ID 签名即可。
</details>

<details>
<summary><b>Q3: 为什么我以前直接锁屏会失效，现在锁屏可以了？</b></summary>

早期版本未开启后台保活时，锁屏 30 秒后会被 iOS 冻结进程。当前 Release 里的 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 已内置**锁屏后台静音保活 + 纯 CPU 验证码解码**，启动定时看到日志 `🌙 已激活 iOS 锁屏后台保活` 即可锁屏等待。如果遇到极度重要的抢座日（如期末周），仍建议开启 **「夜守」** 插电不锁屏作为 100% 保险。
</details>

<details>
<summary><b>Q4: iPhone 上的验证码识别成功率和电脑端一样吗？</b></summary>

**基本一致。** iPhone 安装包完整内置了与电脑端相同的 **5 个原版无损 FP32 / INT8 ONNX 模型**，以及逐像素对齐 Python Pillow 的重采样与灰度算法，全部在手机本地离线推理，无需任何云端打码服务。
</details>

<details>
<summary><b>Q5: Sideloadly / 爱思助手需要输入 Apple ID 密码安全吗？</b></summary>

侧载工具需要向苹果官方服务器申请你个人的免费 7 天开发证书，因此需要 Apple ID 验证。如果介意主账号隐私，最简单的做法是**花 1 分钟在苹果官网注册一个全新的空白小号 Apple ID 专门用来签名**，安全又省心。
</details>
