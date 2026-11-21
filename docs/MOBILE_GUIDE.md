# 🛠️ LNU-LibSeat 手机独立版（Android & iOS）技术架构与本地构建指南

> **本文面向开发者与自行编译用户。**
> - 普通用户安装与日常使用请直达：**[🤖 Android 直装与隔夜保活教程](ANDROID_INSTALL_GUIDE.md)**（主力推荐） · **[📱 手机独立版功能全览与截图](../mobile/README.md)** · **[🍎 iOS 零元安装教程](IOS_INSTALL_GUIDE.md)**。
> - 回应社区 [Issue #6](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues/6) 诉求：**100% 脱离电脑、零服务器成本**，在 Android 与 iPhone 本地直接运行与 Python 桌面端同源的纯 HTTP API 引擎 + 5 个原版无损 ONNX 验证码模型。

---

## 🏗️ 移动端分层架构（`mobile/`）

Android 与 iOS 共享 100% 相同的 Dart 业务引擎与 Flutter 界面，仅在底层保活、系统签到闹钟与 CPU 图像解码处接入各自平台原生实现：

```text
mobile/
├── lib/
│   ├── main.dart                     # App 入口与四频道底部导航（晨约/寻座/入馆/我的）
│   ├── core/                         # 协议、加解密、推理与底层基础设施（与 Python core/ 对齐）
│   │   ├── protocol.dart             #   全量端点、baseUrl.js 动态引导、ProtocolDrift/TokenExpired
│   │   ├── api_crypto.dart           #   AES-128-CBC 凭据加密 + HMAC-SHA256 全局签名
│   │   ├── libseat_client.dart       #   Dio HTTP 连接池客户端与响应 Schema 校验
│   │   ├── clock_sync.dart           #   HTTP Date + RTT/2 服务端时钟偏移校准
│   │   ├── rate_limiter.dart         #   120ms±40ms 间隔 / 1.5s 冷却 / 429 熔断 / 160 次预算硬顶
│   │   ├── session_recorder.dart     #   脱敏 http_trace.jsonl + 识图诊断记录
│   │   └── captcha/                  #   纯端侧 ONNX 验证码引擎（后台独立 Isolate 推理）
│   │       ├── captcha_service.dart  #     三级自适应路由（wordCheckCount → 槽位笔迹 → 时间窗）
│   │       ├── onnx_worker.dart      #     独立 Isolate 常驻 ONNX Runtime 推理工作线程
│   │       ├── ocr_login.dart        #     common_old.onnx (13MB) 登录 4 位图形码 OCR
│   │       ├── yolo_onnx.dart        #     YOLOv8 640×640 letterbox 检测 + NMS
│   │       ├── siamese_onnx.dart     #     MobileNetV4 112×112 相似度矩阵 + 最优匹配
│   │       └── pil_image_ops.dart    #     Python Pillow 22-bit 定点重采样 + ITU-R 601-2 灰度（原生 CPU 解码）
│   ├── logic/                        # 业务编排层（与 Python logic/ 对齐）
│   │   ├── orchestrator.dart         #   15s 预热 / 5s 保活 / +200ms 开抢 / Token 自动重登
│   │   ├── booker.dart               #   首选直击 / 实时空座 / FALLBACK_ROOMS / 5s 宽限窗
│   │   ├── seat_strategy.dart        #   实时空座排序与多账号防撞座协调
│   │   └── result_classifier.dart    #   纯函数预约结果分类（与 Python result_classifier.py 100% 一致）
│   ├── services/                     # 系统集成服务
│   │   ├── background_scheduler.dart #   MethodChannel 桥接（Android 5 重保活 / iOS 静音保活）
│   │   ├── config_store.dart         #   Android Keystore / iOS Keychain 加密凭据与本地偏好存储
│   │   ├── notification_service.dart #   本地通知 + 内置 SMTP 邮件 + 7 类 Webhook + 系统签到防违约闹钟
│   │   └── rush_controller.dart      #   界面状态机、RUN LOG 日志流与冷启动续抢接力
│   └── ui/                           # 「辽大蓝 · 暖米纸底 · 崇山银杏金」跨端统一界面
│       ├── screens/                  #   home_rush / seat_radar / my_ticket / settings / nightstand
│       ├── theme/app_theme.dart      #   全局主题常量
│       └── widgets/                  #   倒计时圆环、终端日志抽屉、座签与双号接力时间轴
├── android/app/src/main/kotlin/com/xunrana/lnulibseat/MainActivity.kt
│   └── RushAlarmStore / RushForegroundService / RushAlarmReceiver / RushBootReceiver / CheckinReminderReceiver / BitmapFactory CPU 解码
├── ios/Runner/AppDelegate.swift
│   └── AVAudioPlayer 全零静音后台保活 / ImageIO+CoreGraphics CPU 解码 / UNUserNotificationCenter 签到提醒 / lnulibseat:// 深链
└── test/                             # 19 项跨语言契约、Pillow 逐字节 SHA-256 与界面单元测试
```

---

## 🔬 关键跨端技术对齐

### 1. 5 个原版无损 ONNX 模型（零误差对齐桌面端）
由 `scripts/prepare_mobile_assets.py` 自动从仓库 `core/checkpoints/` 与 `ddddocr` 导出，默认**关闭实验性 `--fp16`**（规避移动版 ONNX Runtime 1.15.1 缺少 FP16 `ReduceMax` 算子问题），保留原版无损精度并自动校验/兼容 `IR <= 8`、`Opset <= 18`：

| 模型文件 | 用途 | 精度 | 体积 |
| :--- | :--- | :---: | :---: |
| `common_old.onnx` (+ `charset_old.json`) | 登录 4 位图形码 OCR | INT8 | `12.98 MiB` |
| `click1_yolo_plan_bg_char40_best.onnx` | 单字点选 YOLOv8 检测 | FP32 | `11.70 MiB` |
| `click1_siamese_yolo4_best.onnx` | 单字点选 MobileNetV4 匹配 | FP32 | `42.39 MiB` |
| `click3_yolo_plan_bg_char60_best.onnx` | 三字点选 YOLOv8 检测（06:30 高峰） | FP32 | `42.67 MiB` |
| `click3_siamese_yolo4_posw3_best.onnx` | 三字点选 MobileNetV4 匹配 | FP32 | `42.39 MiB` |
| **合计（5 模型）** | 全链路离线无损推理 | — | **`159.52 MB` (`152.13 MiB`)** |

### 2. 纯 CPU 图像解码与 Pillow 算子 0 误差移植
- 移动端在息屏/后台不能依赖 GPU 纹理回读（Android Impeller / iOS Metal 在锁屏态可能失败），因此统一经 MethodChannel `decodeImageRgba` 调用原生纯 CPU 解码：
  - **Android**：`BitmapFactory.decodeByteArray`（`ARGB_8888`, `inScaled=false`, `inPremultiplied=false`），底层与 Pillow 同为 `libjpeg-turbo` / `libpng`。
  - **iOS**：`ImageIO` + `CoreGraphics` 渲染至 8-bit sRGB `CGContext`。
- `pil_image_ops.dart` 完整复现 Python Pillow 22-bit 定点 `BILINEAR / BICUBIC / LANCZOS` 重采样与 ITU-R 601-2 灰度公式；`scripts/dump_test_vectors.py` 生成 Python 黄金测试向量，由 `flutter test` 做 **SHA-256 逐字节 0 误差断言**。

### 3. 双端 06:30 隔夜保活与签到防违约提醒对比

| 机制 | 🤖 Android 实现（`MainActivity.kt`） | 🍎 iOS 实现（`AppDelegate.swift`） |
| :--- | :--- | :--- |
| **前台/后台保活** | `RushForegroundService`（`FOREGROUND_SERVICE_TYPE_SPECIAL_USE`，`IMPORTANCE_DEFAULT` 静音通道）+ 动态 `PARTIAL_WAKE_LOCK`（目标后 +20m，最长 26h）+ `WifiLock` | `UIBackgroundModes: audio` 内存生成 8kHz 16-bit 全零静音 WAV 循环播放（`.mixWithOthers` 不打断音乐，结束后释放） |
| **定时唤醒 / 解冻** | 主闹钟 `AlarmManager.setAlarmClock`（`prepAt - 20s`，code `630`）+ 副闹钟 `setExactAndAllowWhileIdle`（`prepAt`，code `631`）；Android 14+ 冻结态以 `MODE_BACKGROUND_ACTIVITY_START_ALLOWED` + `CATEGORY_ALARM` 全屏唤醒通知强解冻；`RushBootReceiver` 重启自恢复 | 后台静音流持续保持进程活跃；另支持 `lnulibseat://rush?mode=auto` 快捷指令深链 |
| **物理级床头保险** | 首页「银杏夜守」OLED 纯黑 `#000000` 常亮时钟（防烧屏缓移） | 同左 |
| **签到防违约提醒** | `AlarmManager` + `CheckinReminderReceiver`（预约前 15m 温和提醒 & 开始后 20m 紧急闹钟，划掉后台仍响） | `UNUserNotificationCenter`（紧急节点启用 iOS 15+ `.timeSensitive` 时效打断级别） |

---

## 🛠️ 本地构建指南（Android 主推 · iOS 需 Mac）

### 1. 环境准备（一次性）
- **Python 3.10–3.12 虚拟环境**：安装 `numpy`、`onnxruntime`、`onnx`、`Pillow`、`pycryptodome`、`requests`、`ddddocr`。
- **Flutter SDK 3.22+**（当前实测通过 Flutter `3.50.1` / Dart `3.14.0`）：
  - 构建 Android：配置 Android SDK（Windows / macOS 均可构建）；
  - 构建 iOS：需在 **macOS** 安装 **Xcode** 与 **CocoaPods**（`brew install cocoapods`）。

### 2. 🤖 一键构建 Android 安装包（`.apk`，主力）
在 Windows 或 macOS 仓库根目录运行：

```bash
python build_android.py
```

脚本将自动执行：
1. 调用 `scripts/prepare_mobile_assets.py` 导出 5 个原版无损 ONNX 模型、21 间自习室 `room_catalog.json` 与双端蓝金校徽图标；
2. 调用 `scripts/dump_test_vectors.py` 生成跨语言黄金测试向量；
3. 自动运行 `flutter pub get` 与 `flutter test`（19 项单测全绿才继续）；
4. 执行 `flutter build apk --release --target-platform android-arm64 --split-per-abi`；
5. 输出：`dist/辽宁大学图书馆座位预约.apk`（上传 GitHub Release 时按 ASCII 规范命名为 `LNU-LibSeat-Android-arm64.apk`，二者为同一二进制文件）。

> 若仅需同步模型与测试向量不编 APK，可运行 `python build_android.py --prepare-only`。

### 3. 🍎 在 macOS 一键构建免签名 iOS 安装包（`.ipa`）
在 macOS 仓库根目录运行（**无需付费 Apple 开发者账号**）：

```bash
python3 build_ios.py
```

脚本将自动执行：
1. 导出 5 个无损 ONNX 模型、房间索引、跨语言黄金向量并跑通 `flutter test`；
2. 若旧 CocoaPods CDN 不可用，自动从微软官方 NuGet `Microsoft.ML.OnnxRuntime 1.15.1` 解包 iOS `onnxruntime.xcframework` 至 gitignored 的 `mobile/ios/.generated/onnxruntime-pods/`，并配置链接器导出 `_OrtGetApiBase` 等 Dart FFI 符号；
3. 执行 `flutter build ios --release --no-codesign` 并以 `ditto --norsrc` 封装纯净 `Payload/Runner.app`（不含 `__MACOSX` 冗余元数据）；
4. 输出：`dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`。

### 4. 单独运行移动端单测与静态分析
```bash
cd mobile
flutter pub get
flutter test
flutter analyze
```

---

## 🔗 相关文档

- 🤖 [Android 直装与隔夜保活教程](ANDROID_INSTALL_GUIDE.md) — 面向安卓用户的完整安装与分品牌白名单教程
- 📱 [手机独立版功能全览](../mobile/README.md) — 6 张实机界面图与四频道功能说明
- 🍎 [iOS 零元安装教程](IOS_INSTALL_GUIDE.md) — 面向 iPhone 用户的 5 种免费安装方式与保活教程
- 🏗️ [全仓架构文档](ARCHITECTURE.md) — 桌面端 + 移动端整体设计
- 🔌 [纯 API 协议契约](API_PROTOCOL_CONTRACT.md) — Python 与 Dart 共同遵循的接口规范
