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

enum PendingRushAction {
  none,
  resumeScheduled,
  fireImmediately,
}

class ForegroundGuardStartResult {
  final bool ok;
  final bool fgsStarted;
  final String fgsMessage;
  final bool alarmScheduled;
  final String alarmMode;

  const ForegroundGuardStartResult({
    this.ok = false,
    this.fgsStarted = false,
    this.fgsMessage = '',
    this.alarmScheduled = false,
    this.alarmMode = '',
  });
}

class AndroidKeepAliveStatus {
  final bool ignoringBatteryOptimizations;
  final bool canScheduleExactAlarms;
  final bool notificationsEnabled;
  final bool canUseFullScreenIntent;
  final bool armed;
  final int fireAtEpochMs;

  const AndroidKeepAliveStatus({
    this.ignoringBatteryOptimizations = true,
    this.canScheduleExactAlarms = true,
    this.notificationsEnabled = true,
    this.canUseFullScreenIntent = true,
    this.armed = false,
    this.fireAtEpochMs = 0,
  });

  bool get allReady =>
      ignoringBatteryOptimizations &&
      canScheduleExactAlarms &&
      notificationsEnabled &&
      canUseFullScreenIntent;
}

/// 纯函数：根据原生持久化守夜状态，决定冷启动 / 闹钟唤醒后的接力动作。
///
/// - 处于 `[now < fireAt]`：无论是 06:29:25 闹钟冷启动还是中途重开，均自动恢复定时守夜；
/// - 处于 `[fireAt <= now <= fireAt + 10min]` 且由闹钟冷启动：说明刚过放座点（如 06:30:05），
///   切入立即开抢，绝不误顺延到明天；
/// - 超过 `fireAt + 10min`：视为过期历史状态，忽略。
PendingRushAction decidePendingRushAction({
  required bool armed,
  required bool coldAlarmFired,
  required int fireAtEpochMs,
  required int nowEpochMs,
  int graceAfterFireMs = 10 * 60 * 1000,
}) {
  if (!armed && !coldAlarmFired) {
    return PendingRushAction.none;
  }
  if (fireAtEpochMs <= 0) {
    return coldAlarmFired
        ? PendingRushAction.fireImmediately
        : PendingRushAction.none;
  }
  if (nowEpochMs > fireAtEpochMs + graceAfterFireMs) {
    return PendingRushAction.none;
  }
  if (nowEpochMs >= fireAtEpochMs) {
    return coldAlarmFired
        ? PendingRushAction.fireImmediately
        : PendingRushAction.none;
  }
  return PendingRushAction.resumeScheduled;
}

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

  /// Android 专属：启动隔夜前台常驻守夜服务（动态 26h WakeLock + WifiLock）
  /// 并注册系统最高优先级 AlarmClock 唤醒闹钟（提前 prepAt 20 秒唤醒，给冷启动/解冻留足加载时间）。
  Future<ForegroundGuardStartResult> startAndroidForegroundRushService({
    required DateTime prepAtBeijing,
    DateTime? fireAtBeijing,
    required String targetSummary,
  }) async {
    if (!Platform.isAndroid) {
      return const ForegroundGuardStartResult();
    }
    try {
      final wakeBj = prepAtBeijing.subtract(const Duration(seconds: 20));
      final fireBj =
          fireAtBeijing ?? prepAtBeijing.add(const Duration(seconds: 15));
      final triggerEpochMs = wakeBj
          .subtract(const Duration(hours: 8))
          .millisecondsSinceEpoch;
      final prepEpochMs = prepAtBeijing
          .subtract(const Duration(hours: 8))
          .millisecondsSinceEpoch;
      final fireEpochMs = fireBj
          .subtract(const Duration(hours: 8))
          .millisecondsSinceEpoch;
      final raw = await _channel.invokeMethod<dynamic>(
        'startForegroundRushService',
        <String, dynamic>{
          'triggerAtEpochMs': triggerEpochMs,
          'prepAtEpochMs': prepEpochMs,
          'fireAtEpochMs': fireEpochMs,
          'summary': targetSummary,
        },
      );
      if (raw is Map) {
        return ForegroundGuardStartResult(
          ok: raw['ok'] == true,
          fgsStarted: raw['fgsStarted'] == true,
          fgsMessage: (raw['fgsMessage'] ?? '').toString(),
          alarmScheduled: raw['alarmScheduled'] == true,
          alarmMode: (raw['alarmMode'] ?? '').toString(),
        );
      }
      if (raw == true) {
        return const ForegroundGuardStartResult(
          ok: true,
          fgsStarted: true,
          alarmScheduled: true,
          alarmMode: 'AlarmClock',
        );
      }
      return const ForegroundGuardStartResult();
    } catch (exc) {
      return ForegroundGuardStartResult(
        ok: false,
        fgsMessage: '$exc',
      );
    }
  }

  /// Android 专属：冷启动后主动拉取原生持久化状态，若为隔夜闹钟拉起或守夜中断恢复则返回对应接力动作。
  Future<PendingRushAction> consumePendingWakeupRush() async {
    if (!Platform.isAndroid) {
      return PendingRushAction.none;
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'consumePendingAlarmRush',
      );
      if (raw is! Map) {
        return PendingRushAction.none;
      }
      final armed = raw['armed'] == true;
      final coldAlarmFired = raw['coldAlarmFired'] == true;
      final fireAtMs = (raw['fireAtEpochMs'] as num?)?.toInt() ?? 0;
      return decidePendingRushAction(
        armed: armed,
        coldAlarmFired: coldAlarmFired,
        fireAtEpochMs: fireAtMs,
        nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    } catch (_) {
      return PendingRushAction.none;
    }
  }

  /// Android 专属：查询电池白名单、精确闹钟与通知权限真实授权状态。
  Future<AndroidKeepAliveStatus> getAndroidKeepAliveStatus() async {
    if (!Platform.isAndroid) {
      return const AndroidKeepAliveStatus();
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('getKeepAliveStatus');
      if (raw is! Map) {
        return const AndroidKeepAliveStatus();
      }
      return AndroidKeepAliveStatus(
        ignoringBatteryOptimizations:
            raw['ignoringBatteryOptimizations'] == true,
        canScheduleExactAlarms: raw['canScheduleExactAlarms'] == true,
        notificationsEnabled: raw['notificationsEnabled'] == true,
        canUseFullScreenIntent: raw['canUseFullScreenIntent'] != false,
        armed: raw['armed'] == true,
        fireAtEpochMs: (raw['fireAtEpochMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const AndroidKeepAliveStatus();
    }
  }

  /// Android 专属：停止前台常驻服务、释放 WakeLock/WifiLock 并撤回 AlarmClock 闹钟。
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

  /// Android 12+ 专属：打开精确闹钟授权页。
  Future<void> requestExactAlarmPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestExactAlarmPermission');
    } catch (_) {}
  }

  /// Android 专属：打开应用系统通知设置页。
  Future<void> openAppNotificationSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openAppNotificationSettings');
    } catch (_) {}
  }

  /// Android 专属：打开应用信息详情页（方便 vivo/小米/华为/OPPO 开启「自启动」「后台弹出界面」「锁屏显示」）。
  Future<void> openAppDetailsSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openAppDetailsSettings');
    } catch (_) {}
  }

  /// Android 14+ 专属：打开全屏锁屏通知授权页（允许闹钟到点亮屏解冻）。
  Future<void> requestFullScreenIntentPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestFullScreenIntentPermission');
    } catch (_) {}
  }
}
