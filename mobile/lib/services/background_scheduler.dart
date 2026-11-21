/// 双平台 06:30 定时保活与原生唤醒服务。
///
/// - **Android**：通过 MethodChannel 调用原生 `ForegroundService`（常驻通知栏倒计时）
///   + `AlarmManager.setExactAndAllowWhileIdle`（穿透 Doze 休眠在 06:29:40 唤醒 CPU）
///   + 一键打开系统「忽略电池优化」设置；
/// - **iOS / Android 通用**：通过 `WakelockPlus` 提供「OLED 纯黑极暗微光床头守夜模式」
///   以及监听 `lnulibseat://rush?mode=auto` URL Scheme（配合 iOS 快捷指令 06:29 自动拉起）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class BackgroundSchedulerService {
  static final BackgroundSchedulerService instance =
      BackgroundSchedulerService._();

  static const MethodChannel _channel = MethodChannel(
    'com.xunrana.lnulibseat/background',
  );

  final StreamController<String> _deepLinkController =
      StreamController<String>.broadcast();

  Stream<String> get onDeepLinkCommand => _deepLinkController.stream;

  BackgroundSchedulerService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onAlarmFired' || call.method == 'onDeepLink') {
      final cmd = (call.arguments ?? 'rush').toString();
      _deepLinkController.add(cmd);
    }
    return null;
  }

  /// 开启屏幕常亮防休眠（用于 OLED 床头守夜模式或抢座进行中）。
  Future<void> setKeepScreenAwake(bool enable) async {
    try {
      if (enable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  /// Android 专属：启动前台常驻守夜服务并注册 06:29:40 精确唤醒闹钟。
  Future<bool> startAndroidForegroundRushService({
    required DateTime prepAtBeijing,
    required String targetSummary,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final epochMs = prepAtBeijing
          .subtract(const Duration(hours: 8))
          .millisecondsSinceEpoch;
      final ok = await _channel.invokeMethod<bool>(
        'startForegroundRushService',
        <String, dynamic>{
          'triggerAtEpochMs': epochMs,
          'summary': targetSummary,
        },
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android 专属：停止前台常驻服务与精确闹钟。
  Future<void> stopAndroidForegroundRushService() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopForegroundRushService');
    } catch (_) {}
  }

  /// Android 专属：请求忽略电池优化（加入 Doze 白名单，防止国产 ROM 夜间杀后台）。
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
