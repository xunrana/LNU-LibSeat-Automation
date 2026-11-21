# 📱 LNU-LibSeat 手机独立版（Android & iOS）编译、安装与使用指南

> 回应社区 [Issue #6](https://github.com/xunrana/LNU-LibSeat-Automation/issues/6) 诉求：**100% 脱离电脑、零服务器成本**，在 Android 与 iPhone 本地直接运行 **v6 纯 HTTP API 0.55 秒直连引擎 + 原版无损 FP32 YOLOv8 & Siamese ONNX 验证码识别**。

---

## 🌟 手机端四大核心模块

1. **🎯 抢座总控台**：
   - 实时倒计时圆环 + 定时模式（默认 `06:30`）/ 立即模式一键切换。
   - **端侧 AI 点选实时诊断小窗**：每次识别自动在手机屏幕渲染 **目标字 + 背景图 + YOLO 候选绿圈 + 最终点击红点十字与耗时（~40ms）**。
   - 彩色滚动终端日志抽屉 + 脱敏 `http_trace.jsonl` 一键分享导出。
2. **🗺️ 全馆实时空座雷达（错峰捡漏神器）**：
   - `76ms` 拉取崇山 / 蒲河双校区 21 间自习室实时剩余空座排行榜。
   - 点击任意自习室展开 **可视化座位状态网格（绿=空闲 / 红=占用 / 灰=不可用）**，点击任意绿色空位 **0.55 秒直接锁定下单**！
3. **🎫 我的预约票夹**：
   - 展示当前生效中的电子预约凭证小票（`receipt`）、预约单号、近期违约计数（`x/3` 次防黑名单预警）及 **一键取消预约**。
4. **🌙 OLED 纯黑极暗微光「床头守夜模式」**：
   - 专为 iOS / Android 睡前 `06:30` 挂机设计：纯黑 `#000000` 零发光背景 + 每分钟防烧屏微移时钟 + `WakelockPlus` 阻止锁屏，`06:29:45` 自动预热登录，`06:30:00.200` 秒抢并弹出通知！

---

## 🛠️ 开发者：本地打包 Android `.apk` 与 iOS `.ipa`

手机端源码位于 [`mobile/`](../mobile)，模型量化与跨语言测试向量脚本位于 [`scripts/`](../scripts)。

### 1. 准备环境（一次性）
- **Python 虚拟环境**：已安装仓库根目录 `requirements.txt`（含 `onnx`、`onnxruntime`、`ddddocr`）。
- **Flutter SDK**：安装 [Flutter 3.22+](https://docs.flutter.dev/get-started/install)。
  - 编译 Android 需安装 Android Studio / Android SDK。
  - 编译 iOS 需在你的 **Mac 电脑** 上安装 Xcode。

### 2. 一键打包 Android 安装包 (`.apk`)
在 Windows 或 Mac 终端运行：

```powershell
python build_android.py
```

脚本将自动完成：
1. 将 5 个 ONNX 模型转换为移动端 `FP16`（体积从 `159.5 MB` 减至 `86.8 MB`，立省 `72.7 MB`）；
2. 将 `info/*.txt` 21 间自习室座号打包为 `mobile/assets/rooms/room_catalog.json`；
3. 生成跨语言黄金测试向量并跑通 `flutter test`；
4. 产出：`dist/LNU-LibSeat-v6.1.0-Android-arm64.apk`（安卓手机直接安装即用）。

### 3. 在 Mac 上一键免付费打包 iOS 安装包 (`.ipa`)
在你的 Mac 终端运行（**无需 $99/年付费开发者账号**）：

```bash
python3.12 build_ios.py
```

脚本将通过 `flutter build ios --release --no-codesign` 编译并自动封装产出：
- `dist/LNU-LibSeat-v6.1.0-iOS-arm64-unsigned.ipa`

---

## 🍎 iOS 用户 0 元免费安装指南

由于未采用付费企业签名，iPhone / iPad 用户可通过以下任一免费方式安装 `.ipa`：

| 方式 | 适用人群 | 操作步骤 |
| :--- | :--- | :--- |
| **1. Xcode 真机直装** | 有 Mac 电脑的开发者/同学 | 用 Xcode 打开 `mobile/ios/Runner.xcworkspace` → `Signing & Capabilities` 登录自己的免费 Apple ID (`Personal Team`) → 插上 iPhone 点击 ▶ Run 即可装入手机。 |
| **2. 爱思助手 / Sideloadly** | Windows / Mac 普通同学 | 打开爱思助手「工具箱 ▸ IPA 签名」或 Sideloadly → 导入 `LNU-LibSeat-v6.1.0-iOS-arm64-unsigned.ipa` → 用个人免费 Apple ID 签名并安装到手机。首次打开前到 **设置 ▸ 通用 ▸ VPN 与设备管理** 信任证书。 |
| **3. SideStore / AltStore** | 希望手机端每 7 天自动无线续签 | 在手机端用 SideStore / AltStore 导入 `.ipa`，连接校园网/家庭 Wi-Fi 即可自动后台续期，永不掉签。 |
| **4. TrollStore（巨魔商店）** | 支持巨魔的 iOS 系统版本 | 直接在 TrollStore 导入 `.ipa` 点击 Install，**永久生效、永不过期**。 |

---

## ⏰ 每天 06:30 定时抢座：安卓 & 苹果保活秘籍

### 🤖 Android 手机（支持锁屏后台自动唤醒）
1. 在「⚙️ 账号与策略」页点击 **「安卓后台保活：加入电池优化白名单」**，允许 App 忽略电池优化（小米澎湃 / 华为鸿蒙 / vivo / OPPO 必开）。
2. 在首页选好「定时模式 (`06:30`)」并点击 **「启动 06:30 定时抢座」**。
3. App 会在通知栏常驻「🎯 LNU-LibSeat 定时守夜已激活」并注册 `06:29:40` Doze 穿透精确闹钟，**可直接锁屏息屏睡觉**！

### 🍎 iPhone / iOS 手机（双方案突破 iOS 后台冻结限制）
iOS 系统底层禁止普通 App 在锁屏后台精确卡点唤醒，请使用以下方案：

- **方案一（最稳妥，100% 准点）：开启「🌙 床头守夜」模式**
  1. 睡前给 iPhone 插上充电线，在 App 首页点击 **「🌙 床头守夜」** 按钮。
  2. 屏幕会自动变为 **纯黑 `#000000` OLED 极暗微光时钟**（黑色像素完全不发光，不伤屏幕、不刺眼）并锁定防休眠。
  3. 放在床头即可安睡，次日 `06:29:45` 自动预热登录、`06:30:00.200` 秒抢并推送战报！
- **方案二（进阶联动）：配合 iOS「快捷指令 (Shortcuts)」06:29 自动拉起**
  1. 在 App「⚙️ 账号与策略」页点击复制 `lnulibseat://rush?mode=auto`。
  2. 打开 iPhone 自带「**快捷指令**」App → 底部「**自动化**」→ 新建个人自动化 → 选择「**特定时间：每天 06:29**」且设为「**立即运行**（关闭运行前询问）」。
  3. 添加动作：「**打开 URL**」→ 粘贴 `lnulibseat://rush?mode=auto`（到达 `06:29` 拉起 App 后将自动触发抢座流程）。
