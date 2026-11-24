# iPhone / iOS 免费安装与过夜使用教程

适用于 **iOS 15.0 及以上** 的 iPhone / iPad（已在 iPhone 17 / iOS 27 真机实测通过）。无需越狱，无需购买 99 美元苹果开发者账号，用普通免费 Apple ID 即可安装。

[← 返回首页](../README.md) · [Android 安装教程（免续签主推）](ANDROID_INSTALL_GUIDE.md) · [手机版功能说明](../mobile/README.md) · [快速上手](QUICKSTART.md)

> [!TIP]
> 如果你手头同时有 Android 手机或 Windows 电脑，建议优先用 **[Android 版](ANDROID_INSTALL_GUIDE.md)**（直接装 APK，不用每 7 天续签）或 **[Windows 电脑版](QUICKSTART.md)**。如果日常只用 iPhone，按下面教程装一次也很顺手，界面和功能与 Android 版完全一致。

---

## 安装前先知道 3 件事

1. **下载文件**：去 [GitHub Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 下载 **`LNU-LibSeat-iOS-arm64-unsigned.ipa`**（约 146.8 MB，内置全部 5 个本地 ONNX 验证码模型）。
2. **为什么需要自签**：苹果限制非 App Store 应用必须带签名证书才能装进手机，普通免费 Apple ID 可以免费签发个人开发证书。
3. **免费自签的正常限制**：
   - 证书每 **7 天过期一次**，到期前用原工具原位覆盖重签一下就行（**不要先卸载**，账号、配置和方案都不会丢；用 SideStore 可以连 Wi-Fi 无线续签）；
   - 同一个免费 Apple ID 最多同时装 **3 个**自签 App；
   - 如果介意在侧载工具里登主 Apple ID，**花 1 分钟注册一个空白小号 Apple ID 专门用来签名**最省心。

---

## 选一种适合你的安装方式

| 方式 | 要电脑吗 | 特点与有效期 |
| :--- | :---: | :--- |
| **1. Sideloadly**（推荐） | 签名时连一次 | Windows / Mac 通用、最稳定，7 天续签一次 |
| **2. 爱思助手**（推荐） | 签名时连一次 | 全中文界面最直观，Windows / Mac 通用，7 天续签一次 |
| **3. SideStore / AltStore** | 仅首次装 SideStore | 装完后手机连 Wi-Fi 就能无线续签，以后不用插线 |
| **4. Xcode 真机装** | 需 Mac + Xcode | 适合自己改代码编译的开发者，7 天续签一次 |
| **5. TrollStore（巨魔）** | 不用电脑 | 若系统版本支持巨魔，导入即**永久生效** |

---

### 方式一：Sideloadly（Windows / Mac 通用）

1. 去 [sideloadly.io](https://sideloadly.io/) 下载并安装 Sideloadly。
   - **Windows 用户注意**：需要装**网页版（非微软商店版）**的 [iTunes](https://www.apple.com/itunes/download/win64) 和 [iCloud](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe) 提供驱动（不用登录 iCloud）；Mac 不用装额外驱动。
2. 数据线连上 iPhone，手机上点 **信任此电脑** 并输入锁屏密码。
3. 打开 Sideloadly，确认 `iDevice` 识别到了你的 iPhone；把 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 拖进左侧 IPA 框，填免费 Apple ID（建议小号），点 **`Start`**，按提示输密码和 6 位验证码，跑完显示 **`Done`** 桌面就会出现图标。
4. 7 天后若点开闪退，连上电脑用同一个 Apple ID 重新拖入 `.ipa` 点 `Start` **覆盖安装**即可。

### 方式二：爱思助手（中文界面）

1. 安装并打开 [爱思助手](https://www.i4.cn/)，数据线连手机并点信任。
2. 顶部进 **工具箱 → IPA 签名** → 点 **添加 IPA 文件** 选中 `LNU-LibSeat-iOS-arm64-unsigned.ipa`。
3. 切到 **使用 Apple ID 签名** → 添加你的免费 Apple ID 并勾选 → 点 **开始签名**。
4. 签名完成后点「打开已签名 IPA 位置」，再到「我的设备 → 应用游戏 → 导入安装」选刚签好的 `.ipa` 装进手机。

### 方式三：SideStore（无线续签，不用每周插线）

1. 按 [SideStore 官方文档](https://docs.sidestore.io/docs/installation/prerequisites/) 首次用电脑把 SideStore 装到手机；
2. 把 `LNU-LibSeat-iOS-arm64-unsigned.ipa` 隔空投送或发微信存到 iPhone「文件」里；
3. 打开 SideStore 点左上角 `+` 选中该 `.ipa` 安装；
4. 以后每 7 天内连着 Wi-Fi 在手机上点一下刷新就能续签（也可配合快捷指令自动续）。

### 方式四：Mac 用 Xcode 真机直装

1. 在仓库根目录先跑完 `python3 build_ios.py`（确保 5 个 ONNX 模型与本地 Pod 已生成）；
2. 用 Xcode 打开 **`mobile/ios/Runner.xcworkspace`**（注意是 `.xcworkspace`，不是 `.xcodeproj`）；
3. 选 **Runner → TARGETS 下的 Runner → Signing & Capabilities**，勾 **Automatically manage signing**，Team 选你的个人免费账号；
4. **关键一步**：点顶部中间 `Runner` → `Edit Scheme...` → 左侧选 **Run** → **Build Configuration** 改成 **`Release`** 并**取消勾选 `Debug executable`**（不改 Release 拔掉数据线重开 App 会闪退）；
5. 设备栏选你的真机，点左上角 `▶` 安装。

### 方式五：TrollStore（巨魔商店）

把 `.ipa` 存进手机「文件」→ 分享用 TrollStore 打开 → Install。无需信任证书、没有 7 天过期限制。

---

## 首次打开必须做的两步

装完直接点桌面图标会提示「需要开发者模式」或「未受信任的开发者」，按顺序做完这两步就能进：

1. **打开开发者模式（iOS 16+）**：打开 iPhone **设置 → 隐私与安全性**，滑到最底部打开 **开发者模式**，按提示重启手机并输入锁屏密码确认。（如果底部看不到这一项，先用上面任一工具装一次 App 就会出现。）
2. **信任证书**：打开 **设置 → 通用 → VPN与设备管理** → 点你的 Apple ID 邮箱 → 点 **信任**。返回桌面就能正常打开了，顺手允许通知权限以便接收成功提醒和签到闹钟。

---

## iPhone 睡前设好 06:30 怎么过夜？

iOS 默认锁屏约 30 秒就会冻结普通后台 App，所以这里准备了两种办法：

### 办法 A：直接锁屏（内置静音后台保活，默认开启）
- 点开始定时后，看到日志输出 `已激活 iOS 锁屏后台保活`，就可以**直接按电源键锁屏**或切微信。
- 原理是利用 `UIBackgroundModes: audio` 在后台循环播放内存生成的全零静音音频（不会打断你听歌/看视频，也不占锁屏控制卡片，抢完或中止立刻自动关闭），同时验证码解码改走纯 CPU `ImageIO` 避开锁屏 GPU 限制。
- **注意 3 点**：不要在后台多任务界面把 App 上滑划掉；睡前不要再去玩大型游戏或长时间录视频（防止内存吃紧被系统回收）；关掉「低电量模式」并插上充电线。

### 办法 B：「夜守」纯黑床头时钟（期末/考研最稳妥）
- 点首页 **夜守**，屏幕切为纯黑 `#000000` 微光时钟（每分钟微移防 OLED 烧屏，保持屏幕常亮不锁屏）。
- **插上充电线直接放床头，不要按电源键锁屏**——App 始终处于前台，绝不会被系统冻结或回收内存。

---

## 常见问题

<details>
<summary><b>Q1: 过了 7 天点图标闪退怎么办？数据会丢吗？</b></summary>

这是免费个人证书到期的正常现象。**千万别先卸载 App**，直接用原来的签名工具和同一个 Apple ID 覆盖重装一次就能打开，学号密码和自习方案全都在。
</details>

<details>
<summary><b>Q2: 签名提示 "Maximum number of apps for free development profiles has been reached"？</b></summary>

普通免费 Apple ID 同一台手机最多装 3 个自签 App（7 天内最多注册 10 个 App ID）。卸掉不用的其他自签 App，或换一个空闲小号 Apple ID 签名即可。
</details>

<details>
<summary><b>Q3: iPhone 识别验证码准不准？和电脑端一样吗？</b></summary>

基本一致。安装包内置了与电脑端完全相同的 5 个原版无损 ONNX 模型，图像重采样与灰度算法也和 Python Pillow 逐字节对齐，全部在本地离线推理。
</details>

<details>
<summary><b>Q4: 抢座失败了怎么在 iPhone 上导出日志排查？</b></summary>

有两种方式：
- 在 App 里进入 **我的 → 运行记录与识图回放**，可一键导出**最近一轮完整抢座日志（含双账号）**，或**打包导出全部历史日志（`.zip`）**；
- 也可以直接打开 iPhone 系统自带的 **「文件」App →「我的 iPhone」→「LNU-LibSeat」→「lnu_libseat_logs」** 随时浏览或隔空投送（所有密码、Token 和 Cookie 均已自动脱敏）。
</details>
