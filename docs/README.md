# 📖 文档总索引

> 本目录是直接浏览 `docs/` 时的分类清单。四端选型与图文总览见仓库根 [README.md](../README.md)。

## 🏆 快速上手与主力端（主推 Android & Windows）
- [QUICKSTART.md](QUICKSTART.md) — **全平台快速上手指南**（Android & Windows 主力 30 秒上手 + iOS / macOS 指引）
- [ANDROID_INSTALL_GUIDE.md](ANDROID_INSTALL_GUIDE.md) — **🤖 Android 安卓 0 元直装与 06:30 隔夜防杀保活教程**（手机端主力推荐）
- [mobile/README.md](../mobile/README.md) — **📱 手机独立版功能全览与 6 张实机截图**（Android & iOS 界面 1:1 通用）

## 🍎 苹果生态（iPhone / iPad & Mac）
- [IOS_INSTALL_GUIDE.md](IOS_INSTALL_GUIDE.md) — **🍎 iPhone / iOS 零元免越狱自签与过夜保活教程**
- Mac（Apple Silicon）安装与首启步骤见 [QUICKSTART.md](QUICKSTART.md#-macosapple-silicon) 与根 [README.md](../README.md#-mac-用户macos-apple-silicon)

## ⚙️ 进阶配置与版本升级
- [CONFIGURATION.md](CONFIGURATION.md) — 桌面端 `config.py` 全字段详解（含 `FALLBACK_ROOMS` 与 `WEBHOOK_URL`）
- [MIGRATION_V5_TO_V6.md](MIGRATION_V5_TO_V6.md) — **v5 → v6 无缝升级指南**
- [RELEASE_NOTES_V6.md](RELEASE_NOTES_V6.md) — **v6.0.0 全平台发布说明**（与 GitHub Release `latest` 同步）
- 各版本精简变更记录见根目录 [CHANGELOG.md](../CHANGELOG.md)

## 🏗️ 开发者架构、协议与算法参考（v6 现役）
- [ARCHITECTURE.md](ARCHITECTURE.md) — **全仓双端架构文档**（Python 桌面端 + Flutter 移动端）
- [MOBILE_GUIDE.md](MOBILE_GUIDE.md) — **移动端技术架构与 APK / IPA 本地打包指南**
- [API_PROTOCOL_CONTRACT.md](API_PROTOCOL_CONTRACT.md) — **LibSeat 纯 API 协议契约（脱敏，双端共用）**
- [CAPTCHA_YOLO4_SIAMESE.md](CAPTCHA_YOLO4_SIAMESE.md) — **双端同源验证码引擎**（YOLOv8 + Siamese，内部代号 `yolo4`）
- [GUI_QT_ARCHITECTURE.md](GUI_QT_ARCHITECTURE.md) — **v6 PySide6 桌面端界面架构**
- [FEEDBACK_MESSAGES.md](FEEDBACK_MESSAGES.md) — **v6 纯 API 业务状态与反馈分类参考**
- [NUMERIC_PARAMETERS.md](NUMERIC_PARAMETERS.md) — **v6 桌面端 + 移动端关键数字参数清单**

## 📜 历史档案（v3 / v5 归档，仅供参考）
- [BOOKING_FLOWCHART.md](BOOKING_FLOWCHART.md) — v5 Selenium 抢座流程图（归档，现行纯 API 时序见 [ARCHITECTURE.md](ARCHITECTURE.md)）
- [V5_PERFORMANCE.md](V5_PERFORMANCE.md) — v5 浏览器版性能基线（对比参考）
- [TEST_SUMMARY.md](TEST_SUMMARY.md) — v5 模型准确率与自习室实测档案
- [RELEASE_NOTES_V5.md](RELEASE_NOTES_V5.md) — v5.0.0 历史发布说明
- [RELEASE_NOTES.md](RELEASE_NOTES.md) — v3.0.0 历史发布说明
- [MIGRATION_V3_TO_V5.md](MIGRATION_V3_TO_V5.md) — v3 → v5 历史升级指南

> 图片资源：`IOS/`（移动端真机截图 6 张，Android / iOS 界面 1:1 通用）、`screenshots/`（桌面端界面截图）、`flowcharts/`（v5 历史流程图 PNG）。
