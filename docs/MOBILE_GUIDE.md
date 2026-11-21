# 📱 LNU-LibSeat 手机独立版（Android & iOS）编译与技术说明

> 完整用户功能介绍与实机截图请看 **[手机独立版 README](../mobile/README.md)**；安卓直装与国产 ROM 隔夜防冻结指南请看 **[Android 直装与保活教程](ANDROID_INSTALL_GUIDE.md)**；iPhone 零元安装保姆教程请看 **[iOS 安装教程](IOS_INSTALL_GUIDE.md)**。
>
> 回应社区 [Issue #6](https://github.com/xunrana/LNU-LibSeat-Automation/issues/6) 诉求：**100% 脱离电脑、零服务器成本**，在 Android 与 iPhone 本地直接运行 **纯 HTTP API 毫秒级直连引擎 + 原版无损 FP32/INT8 YOLOv8 & Siamese ONNX 验证码识别**。

---

## 🌟 手机端四大频道

1. **🎯 晨约总控台**：
   - 实时倒计时圆环 + 定时模式（默认 `06:30`）/ 立即模式一键切换 + 快捷方案与半屏「速改」面板。
   - **双账号无缝接力**：支持主副号分时段无缝衔接，不重叠时段允许同抢同一心仪座位。
   - 彩色滚动 `RUN LOG` 终端日志抽屉 + 识图回放与脱敏 `http_trace.jsonl` 一键分享导出。
2. **🧭 全馆实时寻座雷达（错峰捡漏神器）**：
   - 秒级拉取崇山 / 蒲河双校区 21 间自习室实时空座率与楼层排行，支持满员房间低频合规蹲空座。
   - 点击任意自习室展开 **可视化座位状态网格**，支持 `只看空座 / 宝藏座` 筛选、长按标记电源/靠窗笔记，并可一键直订空座。
3. **📖 入馆伴侣**：
   - 电子阅览座签（支持合并/主号/副号三视角 + 一键取消 + 系统级签到防违约提醒开关）。
   - 七日违约信用双号守护（`x / 3` 防黑名单预警）、暂离防丢座倒计时、馆内专注计时、官方公告与「辽大自习书简」。
4. **🌙 双端 06:30 过夜保活 + 银杏夜守**：
   - **Android**：5 重隔夜防杀——前台常驻守夜服务（`IMPORTANCE_DEFAULT` 静音通道）+ 动态 26 小时 `PARTIAL_WAKE_LOCK` + `WifiLock` 防息屏断网 + `AlarmClock` 主唤醒 / `prepAt` 预热轻推双闹钟 + Android 14 `MODE_BACKGROUND_ACTIVITY_START_ALLOWED` / `CATEGORY_ALARM` 锁屏全屏强制解冻 + 进程被杀冷启动续抢 / 手机重启自动重挂闹钟 + App 内 4 项实时权限体检与国产 ROM 白名单引导。
   - **iOS**：内置 **锁屏后台静音保活**（`UIBackgroundModes: audio` 全零静音流，不打断听歌、抢完自动释放）+ **纯 CPU `ImageIO + CoreGraphics` 图像解码**（息屏零 Metal GPU 依赖）+ **OLED 纯黑「银杏夜守」**防烧屏床头时钟 + `lnulibseat://rush?mode=auto` 快捷指令深链。

---

## 🛠️ 开发者：本地打包 Android `.apk` 与 iOS `.ipa`

手机端源码位于 [`mobile/`](../mobile)，模型准备与跨语言黄金测试向量脚本位于 [`scripts/`](../scripts)。

### 1. 准备环境（一次性）
- **Python 3.12 虚拟环境**：安装 `numpy`、`onnxruntime`、`onnx`、`Pillow`、`pycryptodome`、`requests`、`ddddocr`。
- **Flutter SDK**：安装 [Flutter 3.22+](https://docs.flutter.dev/get-started/install)（已在 Flutter `3.50.1` / Dart `3.14.0` 实测通过）。
  - 编译 Android 需配置 Android SDK；
  - 编译 iOS 需在 **macOS** 上安装 **Xcode** 与 **CocoaPods**（推荐 `brew install cocoapods`）。

### 2. 一键打包 Android 安装包 (`.apk`)
在 Windows 或 macOS 仓库根目录运行：

```bash
python build_android.py
```

脚本将自动完成：
1. 导出全部 **5 个原版无损 ONNX 模型**（总计 `159.52 MB`，自动确保 IR≤8 / Opset≤18 兼容移动版 ONNX Runtime 1.15.1，数值偏差 `0.00000`）；
2. 将 `info/*.txt` 双校区 21 间自习室离线座号打包为 `mobile/assets/rooms/room_catalog.json` 并生成双端校徽图标；
3. 导出跨语言黄金测试向量并跑通 `flutter test`（19 项契约与界面单测，含 Python Pillow 逐字节 SHA-256 校验）；
4. 产出：`dist/辽宁大学图书馆座位预约.apk`（ARM64 独立离线包，与 Releases 发布的 `LNU-LibSeat-Android-arm64.apk` 为同一构建产物）。

### 3. 在 Mac 上一键免付费打包 iOS 安装包 (`.ipa`)
在 macOS 仓库根目录运行（**无需付费 Apple 开发者账号**）：

```bash
python3 build_ios.py
```

脚本将自动完成：
1. 资源、5 个无损 ONNX 模型与跨语言黄金测试向量准备，并通过 `flutter test`；
2. 自动准备官方 iOS `onnxruntime.xcframework 1.15.1` 本地 Pod（从微软官方 NuGet `Microsoft.ML.OnnxRuntime 1.15.1` 解包至 gitignored 的 `mobile/ios/.generated/onnxruntime-pods/`，规避旧 CocoaPods CDN 404，并通过链接器参数强制导出 `_OrtGetApiBase` 等 Dart FFI 符号）；
3. 执行 `flutter build ios --release --no-codesign` 并使用 `ditto --norsrc` 封装纯净 `Payload/Runner.app`（不含 `__MACOSX` 冗余元数据），产出：
   - `dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`

---

## 🍎 iOS 安装与过夜保活速览

详细图文步骤与避坑 FAQ 请直接查阅 **[iOS 零元安装教程](IOS_INSTALL_GUIDE.md)**：

- **安装方式**：支持 **Sideloadly / 爱思助手 / SideStore / AltStore / Xcode 真机直装 / TrollStore（巨魔）**，0 元免越狱安装；首次打开需在 iPhone 开启「开发者模式」并在「VPN与设备管理」中信任个人证书。
- **06:30 过夜抢座**：
  - **常规锁屏**：启动定时看到日志 `🌙 已激活 iOS 锁屏后台保活` 即可锁屏（勿上滑强杀、勿开低电量模式、建议插电）；
  - **极致稳妥**：点击首页 **「夜守」** 进入 OLED 纯黑床头模式插电不锁屏，始终处于前台最高优先级。
