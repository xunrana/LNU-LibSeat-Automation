---
name: Bug 反馈
about: 抢座失败、锁屏冻结、程序报错或行为异常
title: "[Bug] "
labels: bug
---

## 问题描述

<!-- 清楚描述出现了什么问题 -->

## 复现步骤

1.
2.
3.

## 期望行为

<!-- 你期望发生什么 -->

## 运行环境

- 使用平台（可勾选）：
  - [ ] Android 手机（请注明品牌与系统版本，如 vivo OriginOS 4 / Android 14）
  - [ ] Windows 电脑（Windows 10 / 11）
  - [ ] iPhone / iPad（机型、iOS 版本、安装工具如 Sideloadly / 爱思 / SideStore）
  - [ ] macOS 电脑（Apple Silicon / Intel）
- 使用方式：[ ] Releases 预打包安装包　[ ] 本地源码运行
- 版本 / commit：（可在手机端「我的」底部、桌面端底部栏或 `session.log` 首行查看，如 `v6.0.1`；提交前请先确认已升级到 [Releases 最新版](https://github.com/xunrana/LNU-LibSeat-Automation/releases/latest)）

## 日志与排查附件

> - **Android / iOS 手机端**：进入 **「我的 ▸ 运行记录与识图回放」** 可一键导出**最近一轮完整日志**或打包全部历史日志（`.zip`）；iPhone 也可直接在系统「文件」App →「我的 iPhone」→「LNU-LibSeat」找到日志。若涉及 06:30 锁屏问题，请附带「晨约守夜与后台保活」页 4 项体检状态截图。
> - **Windows / macOS 桌面端**：排查文件在 `logs/sessions/<时间戳>_<学号>/`（含 `session.log` + `抢座顺序.txt` + 脱敏 `http_trace.jsonl` + `*_captcha_*.png` 叠加诊断图）。
> - ⚠️ 上传前请**先打码学号、个人邮箱等敏感信息**，**切勿直接粘贴 `config.py`**。

<!-- 把相关日志片段或打码后的截图贴在这里 -->
