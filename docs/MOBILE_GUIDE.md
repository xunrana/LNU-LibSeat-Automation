# 移动端技术架构与本地构建说明

本文面向需要自己改代码或本地编译 APK / IPA 的开发者。普通同学直接看安装教程即可：
[Android 安装与保活](ANDROID_INSTALL_GUIDE.md) · [手机版功能说明](../mobile/README.md) · [iOS 免费安装](IOS_INSTALL_GUIDE.md) · [返回首页](../README.md)

---

## 一、目录结构（`mobile/`）

Android 与 iOS 共用 100% 相同的 Dart 业务逻辑和 Flutter 界面，仅在保活、系统签到闹钟和纯 CPU 图像解码处接入各自原生代码：

```text
mobile/
├── lib/
│   ├── main.dart                     # 应用入口与四频道导航（晨约 / 寻座 / 入馆 / 我的）
│   ├── core/                         # 与 Python core/ 对齐
│   │   ├── protocol.dart             #   端点常量、baseUrl.js 动态解析、漂移/过期异常
│   │   ├── api_crypto.dart           #   AES-128-CBC 加密 + HMAC-SHA256 全局签名
│   │   ├── libseat_client.dart       #   Dio HTTP 连接池客户端
│   │   ├── clock_sync.dart           #   HTTP Date + RTT/2 服务端时钟校准
│   │   ├── rate_limiter.dart         #   120ms±40ms 间隔 / 1.5s 冷却 / 0.8s–6.8s 退避 / 12 次熔断 / 200 次上限
│   │   ├── session_recorder.dart     #   脱敏 http_trace.jsonl + 识图诊断
│   │   └── captcha/                  #   独立 Isolate ONNX 推理（5 个无损模型）
│   │       ├── captcha_service.dart  #     三级自适应路由（wordCheckCount → 槽位笔迹 → 时间窗）
│   │       ├── onnx_worker.dart      #     后台 Isolate 推理线程
│   │       ├── ocr_login.dart        #     common_old.onnx 登录 4 位图形码
│   │       ├── yolo_onnx.dart        #     YOLOv8 640×640 检测 + NMS
│   │       ├── siamese_onnx.dart     #     MobileNetV4 112×112 匹配
│   │       └── pil_image_ops.dart    #     Python Pillow 22-bit 定点重采样 + 灰度
│   ├── logic/                        # 与 Python logic/ 对齐
│   │   ├── orchestrator.dart         #   15s 预热 / 5s 保活 / +200ms 开抢 / Token 自动重登
│   │   ├── booker.dart               #   首选直击 / 实时空座 / FALLBACK_ROOMS / 高峰 1.55s+2.05s 反作弊对齐 & 6.2s 冷却 / 12 次繁忙重试 / 5s 宽限
│   │   ├── seat_strategy.dart        #   实时空座排序与双号防撞座
│   │   └── result_classifier.dart    #   预约结果分类（与 Python result_classifier.py 一致）
│   ├── services/                     # 平台服务
│   │   ├── background_scheduler.dart #   MethodChannel 桥接原生保活与权限查询
│   │   ├── config_store.dart         #   Android Keystore / iOS Keychain 加密存储
│   │   ├── log_exporter.dart         #   run_log.txt 滚动落盘、最近一轮双号日志与全量脱敏 ZIP 导出
│   │   ├── notification_service.dart #   本地通知 + 内置 SMTP + Webhook + 系统签到闹钟
│   │   └── rush_controller.dart      #   界面状态机、日志流与冷启动续抢
│   └── ui/                           # 统一四频道界面（含偏好选座顺位角标与队列条）、主题与夜守时钟
├── android/app/src/main/kotlin/com/xunrana/lnulibseat/MainActivity.kt
│   └── RushAlarmStore / RushForegroundService / RushAlarmReceiver / RushBootReceiver / CheckinReminderReceiver / BitmapFactory 解码
├── ios/Runner/AppDelegate.swift
│   └── AVAudioPlayer 静音保活 / ImageIO+CoreGraphics 解码 / UNUserNotificationCenter / lnulibseat:// 深链
└── test/                             # 23 项跨语言契约、Pillow SHA-256 与界面单测
```

---

## 二、关键技术点

### 1. 5 个无损 ONNX 模型与 ORT 兼容性
`scripts/prepare_mobile_assets.py` 会从 `core/checkpoints/` 与 `ddddocr` 导出全部 5 个运行时模型到 `mobile/assets/models/`，默认保留原版无损精度（不开启实验性 `--fp16`，避免移动版 ONNX Runtime 1.15.1 缺少 FP16 `ReduceMax` 内核导致崩溃），并自动检查/兼容 `IR <= 8`、`Opset <= 18`：

| 文件名 | 用途 | 精度 | 大小 |
| :--- | :--- | :---: | :---: |
| `common_old.onnx` (+ `charset_old.json`) | 登录 4 位图形码 | INT8 | 12.98 MiB |
| `click1_yolo_plan_bg_char40_best.onnx` | 单字点选 YOLOv8 检测 | FP32 | 11.70 MiB |
| `click1_siamese_yolo4_best.onnx` | 单字点选 MobileNetV4 匹配 | FP32 | 42.39 MiB |
| `click3_yolo_plan_bg_char60_best.onnx` | 三字点选 YOLOv8 检测 | FP32 | 42.67 MiB |
| `click3_siamese_yolo4_posw3_best.onnx` | 三字点选 MobileNetV4 匹配 | FP32 | 42.39 MiB |
| **合计** | 5 个模型 | — | **159.52 MB (152.13 MiB)** |

### 2. 纯 CPU 解码与 Pillow 算子对齐
锁屏后台无法可靠依赖 GPU 纹理回读，所以两端均经 MethodChannel `decodeImageRgba` 走原生 CPU 解码：
- Android：`BitmapFactory.decodeByteArray`（`ARGB_8888`, `inScaled=false`, `inPremultiplied=false`）；
- iOS：`ImageIO` + `CoreGraphics` 渲染至 8-bit sRGB `CGContext`。

`pil_image_ops.dart` 复现了 Python Pillow 22-bit 定点 `BILINEAR / BICUBIC / LANCZOS` 与 ITU-R 601-2 灰度转换，由 `scripts/dump_test_vectors.py` 生成黄金测试向量并在 `flutter test` 里做 SHA-256 逐字节校验。

### 3. 双端原生保活与签到闹钟实现对照

| 项 | Android (`MainActivity.kt`) | iOS (`AppDelegate.swift`) |
| :--- | :--- | :--- |
| 后台保活 | `RushForegroundService`（`mediaPlayback\|specialUse` + `MediaSession STATE_PLAYING` + `Notification.MediaStyle` 实时倒计时）+ `SilentAudioKeepAlive`（`MODE_STREAM` 24kHz/-90dB 不可闻非零 PCM 活跃流，不占 AudioFocus）+ 原生 250ms 心跳直推 Dart `onNativeTick` + 动态 `PARTIAL_WAKE_LOCK`（上限 26h）+ `WifiLock` | `UIBackgroundModes: audio` 内存生成 8kHz 16-bit 全零静音 WAV 循环播放（`.mixWithOthers`，结束后停止释放） |
| 准点唤醒 | 四段式硬件闹钟链（630/631/632/633）+ `goAsync()` 7.5s 广播租约保活；守夜期动态开启 `showWhenLocked + turnScreenOn`，息屏自动点亮 15s + `fullScreenIntent`；`RushBootReceiver` 重启恢复 | 静音音频流维持进程存活；支持 `lnulibseat://rush?mode=auto` 快捷指令深链 |
| 签到提醒 | `AlarmManager` + `CheckinReminderReceiver`（预约前 15m 温和提醒、开始后 20m 紧急闹钟） | `UNUserNotificationCenter`（紧急节点启用 iOS 15+ `.timeSensitive`） |

---

## 三、本地构建步骤

### 环境准备
- Python 3.10–3.12 虚拟环境（安装 `numpy`、`onnxruntime`、`onnx`、`Pillow`、`pycryptodome`、`requests`、`ddddocr`）
- Flutter 3.22+（实测通过 Flutter 3.50.1 / Dart 3.14.0）
  - Android 构建需配置 Android SDK（Windows / macOS 均可）；
  - iOS 构建需在 macOS 安装 Xcode 和 CocoaPods（`brew install cocoapods`）。

### 构建 Android APK（主推）
```bash
python build_android.py
```
会自动导出 5 个无损 ONNX 模型、打包 21 间自习室 `room_catalog.json`、生成黄金测试向量、跑通 `flutter test`（23 项全绿），并输出 `dist/辽宁大学图书馆座位预约.apk`（Releases 中命名为 `LNU-LibSeat-Android-arm64.apk`）。若只想准备资源不编 APK，运行 `python build_android.py --prepare-only`。

### 在 Mac 上构建免签名 iOS IPA
```bash
python3 build_ios.py
```
会自动准备模型与测试向量并跑通 `flutter test`；若旧 CocoaPods 归档源不可用，自动从微软 NuGet `Microsoft.ML.OnnxRuntime 1.15.1` 解包 `onnxruntime.xcframework` 至本地 Pod 并导出 `_OrtGetApiBase` 符号；最后执行 `flutter build ios --release --no-codesign` 并封装干净的 `dist/LNU-LibSeat-iOS-arm64-unsigned.ipa`。

### 单独跑单测与分析
```bash
cd mobile
flutter pub get
flutter test
flutter analyze
```
