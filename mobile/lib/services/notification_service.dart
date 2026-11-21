/// 手机端本地高优通知 + 内置 SMTP_SSL 邮件战报 + 外部 Webhook 秒推服务。
///
/// 与桌面端 `core/notifications.py` 完全对齐：
/// - 本地原生通知栏弹窗 + 震动提醒（Android & iOS）
/// - 内置 126 邮箱发件通道（用户只需填写收件邮箱，零 SMTP 配置）
/// - Bark (iOS) / PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉 / 通用 JSON Webhook
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/libseat_client.dart';
import '../logic/orchestrator.dart';
import '../logic/seat_strategy.dart';

class ScheduledCheckinReminder {
  final int alarmId;
  final String reservationId;
  final String account;
  final DateTime triggerAtUtc;
  final String triggerHmLabel;
  final String title;
  final String body;
  final bool urgent;

  const ScheduledCheckinReminder({
    required this.alarmId,
    required this.reservationId,
    required this.account,
    required this.triggerAtUtc,
    required this.triggerHmLabel,
    required this.title,
    required this.body,
    required this.urgent,
  });
}

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const MethodChannel _bgChannel = MethodChannel(
    'com.xunrana.lnulibseat/background',
  );
  static const String _prefScheduledAlarmsKey =
      'lnu_scheduled_checkin_alarms_v1';

  // 与桌面端 core/notifications.py 一致的内置发件邮箱，学生无需自配 SMTP
  static const String builtinSmtpUser = 'lnu_libseat_bot@126.com';
  static const String _builtinSmtpPass = 'DGZLX38ytQqYkVB3';

  final Map<int, Timer> _fallbackTimers = <int, Timer>{};

  /// 与桌面端 `core/notifications.py` 一致：用户留空收件邮箱时默认发往内置发件箱自身。
  static String resolveReceiverEmail(
    String receiverEmail, {
    String smtpUser = builtinSmtpUser,
  }) {
    final trimmed = receiverEmail.trim();
    return trimmed.isNotEmpty ? trimmed : smtpUser.trim();
  }

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    try {
      await _plugin.initialize(settings);
      _initialized = true;
      await requestNotificationPermission();
    } catch (_) {}
  }

  Future<void> requestNotificationPermission() async {
    try {
      if (Platform.isAndroid) {
        final androidImpl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await androidImpl?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        final iosImpl = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        await iosImpl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
    } catch (_) {}
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  static int _baseAlarmIdForReservation(String reservationId) {
    final trimmed = reservationId.trim();
    final parsed = int.tryParse(trimmed);
    final seed = parsed != null ? parsed.abs() : trimmed.hashCode.abs();
    return 20000000 + (seed % 9000000) * 2;
  }

  /// 计算单个预约对应的双节点签到防违约提醒：
  /// - 节点 1：预约开始前 15 分钟（温和提前提醒，如 `14:00` → `13:45`）
  /// - 节点 2：签到宽限截止前 10 分钟，即开始后 20 分钟（防违约紧急催促，如 `14:00` → `14:20`）
  /// 若已签到（状态非 `RESERVE`）或节点时间已过，自动跳过。
  static List<ScheduledCheckinReminder> planCheckinReminders({
    required String reservationId,
    required String location,
    required String begin,
    String onDate = '',
    String status = 'RESERVE',
    String account = '',
    String? roleLabel,
    DateTime? nowBeijing,
  }) {
    final trimmedId = reservationId.trim();
    if (trimmedId.isEmpty) {
      return const <ScheduledCheckinReminder>[];
    }
    final upperStatus = status.trim().toUpperCase();
    if (upperStatus.isNotEmpty && upperStatus != 'RESERVE') {
      return const <ScheduledCheckinReminder>[];
    }

    final nowBj = nowBeijing ?? currentBeijingTime();
    final nowUtc = nowBj.subtract(const Duration(hours: 8));

    // 解析预约日期（默认当天北京时间）
    var year = nowBj.year;
    var month = nowBj.month;
    var day = nowBj.day;
    final dateMatch = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(onDate.trim());
    if (dateMatch != null) {
      year = int.tryParse(dateMatch.group(1)!) ?? year;
      month = int.tryParse(dateMatch.group(2)!) ?? month;
      day = int.tryParse(dateMatch.group(3)!) ?? day;
    }

    DateTime? startBj;
    final lowerBegin = begin.trim().toLowerCase();
    if (lowerBegin == 'now' || lowerBegin == '-1' || lowerBegin == '现在') {
      startBj = nowBj;
    } else {
      final mins = parseHhmmMinutes(begin);
      if (mins != null) {
        startBj = DateTime.utc(year, month, day, mins ~/ 60, mins % 60);
      }
    }
    if (startBj == null) {
      return const <ScheduledCheckinReminder>[];
    }

    final deadlineBj = startBj.add(const Duration(minutes: 30));
    final deadlineHm = '${_pad2(deadlineBj.hour)}:${_pad2(deadlineBj.minute)}';
    final beginHm = '${_pad2(startBj.hour)}:${_pad2(startBj.minute)}';
    final place = location.trim().isNotEmpty ? location.trim() : '辽宁大学图书馆';
    final roomShort = extractRoomNameFromLocation(place);
    final accPrefix = (roleLabel != null && roleLabel.isNotEmpty)
        ? '[$roleLabel${account.trim().isNotEmpty ? " ${account.trim()}" : ""}] '
        : '';

    final baseId = _baseAlarmIdForReservation(trimmedId);
    final candidates = <(int id, DateTime atBj, String title, String body, bool urgent)>[
      (
        baseId,
        startBj.subtract(const Duration(minutes: 15)),
        '即将到达签到时段 · ${roomShort.isNotEmpty ? roomShort : "图书馆"}',
        '${accPrefix}你预约的 $place 将于 $beginHm 开始，请记得前往馆内刷卡签到（最晚 $deadlineHm 截止）。',
        false,
      ),
      (
        baseId + 1,
        startBj.add(const Duration(minutes: 20)),
        '距签到截止仅剩 10 分钟 · 请尽快刷卡',
        '${accPrefix}$place 将于 $deadlineHm 超时违约，请立即前往馆内刷卡签到！',
        true,
      ),
    ];

    final out = <ScheduledCheckinReminder>[];
    final minFutureUtc = nowUtc.add(const Duration(seconds: 15));
    for (final c in candidates) {
      final triggerUtc = c.$2.subtract(const Duration(hours: 8));
      if (!triggerUtc.isAfter(minFutureUtc)) {
        continue;
      }
      out.add(
        ScheduledCheckinReminder(
          alarmId: c.$1,
          reservationId: trimmedId,
          account: account.trim(),
          triggerAtUtc: triggerUtc,
          triggerHmLabel: '${_pad2(c.$2.hour)}:${_pad2(c.$2.minute)}',
          title: c.$3,
          body: c.$4,
          urgent: c.$5,
        ),
      );
    }
    return out;
  }

  static List<ScheduledCheckinReminder> planCheckinRemindersForRecord(
    ReservationRecord rec, {
    String? roleLabel,
    DateTime? nowBeijing,
  }) {
    return planCheckinReminders(
      reservationId: rec.reservationId,
      location: rec.location,
      begin: rec.begin,
      onDate: rec.onDate,
      status: rec.status,
      account: rec.account,
      roleLabel: roleLabel,
      nowBeijing: nowBeijing,
    );
  }

  static List<ScheduledCheckinReminder> planCheckinRemindersForEvent(
    BookingSuccessEvent event, {
    String? roleLabel,
    DateTime? nowBeijing,
  }) {
    final loc = '${event.roomName} ${event.seatNo}号座'.trim();
    return planCheckinReminders(
      reservationId: event.reservationId,
      location: loc,
      begin: event.startTime,
      status: 'RESERVE',
      account: event.account,
      roleLabel: roleLabel,
      nowBeijing: nowBeijing,
    );
  }

  static (String, String) buildSuccessTitleAndBody(BookingSuccessEvent event) {
    final title = '预约成功 · ${event.roomName} ${event.seatNo}号座';
    final extra = StringBuffer();
    if (event.reservationId.isNotEmpty) {
      extra.writeln('预约单号：${event.reservationId}');
    }
    if (event.receipt.isNotEmpty) {
      extra.writeln('凭证编号：${event.receipt}');
    }
    final content = '辽宁大学图书馆座位已为你锁定\n'
        '────────────────────\n'
        '预约账号：${event.account}\n'
        '目标场馆：${event.roomName}\n'
        '座位编号：${event.seatNo} 号\n'
        '预约时段：${event.startTime} — ${event.endTime}\n'
        '$extra'
        '────────────────────\n'
        '请于预约开始前后 30 分钟内到馆签到，避免违约。';
    return (title, content);
  }

  static (String, Map<String, dynamic>) buildWebhookPayload(
    String url,
    String title,
    String content,
  ) {
    final low = url.toLowerCase();
    final uri = Uri.tryParse(low);
    final host = uri?.host ?? '';

    if (host.contains('api.day.app') || low.contains('/bark')) {
      return (
        'json',
        <String, dynamic>{
          'title': title,
          'body': content,
          'group': 'LNU-LibSeat',
        },
      );
    }
    if (host.contains('pushplus.plus')) {
      return (
        'json',
        <String, dynamic>{
          'title': title,
          'content': content,
          'template': 'txt',
        },
      );
    }
    if (host.contains('sctapi.ftqq.com')) {
      return ('form', <String, dynamic>{'title': title, 'desp': content});
    }
    if (host.contains('qyapi.weixin.qq.com') ||
        host.contains('oapi.dingtalk.com')) {
      return (
        'json',
        <String, dynamic>{
          'msgtype': 'text',
          'text': <String, String>{'content': '$title\n$content'},
        },
      );
    }
    if (host.contains('open.feishu.cn') ||
        host.contains('open.larksuite.com')) {
      return (
        'json',
        <String, dynamic>{
          'msg_type': 'text',
          'content': <String, String>{'text': '$title\n$content'},
        },
      );
    }
    return ('json', <String, dynamic>{'title': title, 'content': content});
  }

  Future<void> showLocalNotification({
    required String title,
    required String body,
    int id = 630,
  }) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      'lnu_libseat_rush_channel',
      'LNU LibSeat 预约与签到提醒',
      channelDescription: '预约成功战报与到馆签到提醒',
      importance: Importance.max,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(''),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    } catch (_) {}
  }

  /// 纯 Dart SMTP_SSL（端口 465，AUTH LOGIN）邮件发送，复用项目内置发件箱。
  /// 若 `receiverEmail` 留空，则与桌面端保持一致，默认发送至 `smtpUser`（`lnu_libseat_bot@126.com`）。
  Future<bool> sendEmail({
    String receiverEmail = '',
    required String title,
    required String content,
    String smtpUser = builtinSmtpUser,
    String smtpPass = _builtinSmtpPass,
  }) async {
    final to = resolveReceiverEmail(receiverEmail, smtpUser: smtpUser);
    if (to.isEmpty || !to.contains('@')) {
      return false;
    }

    final host = smtpUser.contains('126.com') ? 'smtp.126.com' : 'smtp.qq.com';
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        465,
        timeout: const Duration(seconds: 10),
      );
      final lines = utf8.decoder
          .bind(socket)
          .transform(const LineSplitter());
      final iterator = StreamIterator<String>(lines);

      Future<int> readReplyCode() async {
        var code = 0;
        while (await iterator.moveNext()
            .timeout(const Duration(seconds: 10))) {
          final line = iterator.current;
          if (line.length >= 3) {
            code = int.tryParse(line.substring(0, 3)) ?? code;
            // 多行回复形如 "250-..."，最后一行形如 "250 ..."
            if (line.length == 3 || line[3] == ' ') {
              break;
            }
          }
        }
        return code;
      }

      Future<int> sendCmd(String cmd) async {
        socket!.write('$cmd\r\n');
        await socket.flush();
        return readReplyCode();
      }

      if (await readReplyCode() != 220) {
        return false;
      }
      if (await sendCmd('EHLO lnu-libseat.local') != 250) {
        return false;
      }
      if (await sendCmd('AUTH LOGIN') != 334) {
        return false;
      }
      if (await sendCmd(base64Encode(utf8.encode(smtpUser))) != 334) {
        return false;
      }
      if (await sendCmd(base64Encode(utf8.encode(smtpPass))) != 235) {
        return false;
      }
      if (await sendCmd('MAIL FROM:<$smtpUser>') != 250) {
        return false;
      }
      if (await sendCmd('RCPT TO:<$to>') != 250) {
        return false;
      }
      if (await sendCmd('DATA') != 354) {
        return false;
      }

      final b64Subject = base64Encode(utf8.encode(title));
      final b64Body = base64Encode(utf8.encode(content));
      final message = StringBuffer()
        ..write('From: LNU LibSeat <$smtpUser>\r\n')
        ..write('To: <$to>\r\n')
        ..write('Subject: =?UTF-8?B?$b64Subject?=\r\n')
        ..write('MIME-Version: 1.0\r\n')
        ..write('Content-Type: text/plain; charset="utf-8"\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n')
        ..write('\r\n')
        ..write('$b64Body\r\n')
        ..write('.\r\n');
      socket.write(message.toString());
      await socket.flush();

      final dataCode = await readReplyCode();
      try {
        socket.write('QUIT\r\n');
        await socket.flush();
      } catch (_) {}
      await iterator.cancel();
      return dataCode == 250;
    } catch (_) {
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  Future<bool> sendWebhook({
    required String webhookUrl,
    required String title,
    required String content,
  }) async {
    final url = webhookUrl.trim();
    if (url.isEmpty) {
      return false;
    }
    final (mode, payload) = buildWebhookPayload(url, title, content);
    try {
      final resp = await _dio.post<dynamic>(
        url,
        data: mode == 'form' ? FormData.fromMap(payload) : payload,
      );
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  Future<void> notifyBookingSuccess(
    BookingSuccessEvent event, {
    String receiverEmail = '',
    String webhookUrl = '',
    bool autoCheckinReminder = true,
    String? roleLabel,
  }) async {
    final (title, body) = buildSuccessTitleAndBody(event);
    await showLocalNotification(title: title, body: body);
    if (autoCheckinReminder) {
      await scheduleCheckinRemindersForEvent(
        event,
        enabled: true,
        roleLabel: roleLabel,
      );
    }
    await sendEmail(
      receiverEmail: resolveReceiverEmail(receiverEmail),
      title: title,
      content: body,
    );
    if (webhookUrl.trim().isNotEmpty) {
      await sendWebhook(
        webhookUrl: webhookUrl,
        title: title,
        content: body,
      );
    }
  }

  Future<Map<String, List<int>>> _loadTrackedAlarms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefScheduledAlarmsKey);
      if (raw == null || raw.isEmpty) {
        return <String, List<int>>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, List<int>>{};
      }
      final out = <String, List<int>>{};
      decoded.forEach((key, value) {
        if (value is List) {
          out[key.toString()] = value
              .map((x) => x is num ? x.toInt() : int.tryParse(x.toString()))
              .whereType<int>()
              .toList();
        }
      });
      return out;
    } catch (_) {
      return <String, List<int>>{};
    }
  }

  Future<void> _saveTrackedAlarms(Map<String, List<int>> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefScheduledAlarmsKey, jsonEncode(map));
    } catch (_) {}
  }

  Future<bool> _scheduleSingleReminderNative(
    ScheduledCheckinReminder rem,
  ) async {
    final delay = rem.triggerAtUtc.difference(DateTime.now().toUtc());
    if (delay <= Duration.zero) {
      return false;
    }
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final ok = await _bgChannel.invokeMethod<bool>(
          'scheduleCheckinReminder',
          <String, dynamic>{
            'alarmId': rem.alarmId,
            'triggerAtEpochMs': rem.triggerAtUtc.millisecondsSinceEpoch,
            'title': rem.title,
            'body': rem.body,
            'urgent': rem.urgent,
          },
        );
        return ok ?? false;
      }
    } catch (_) {}

    // 非 Android 平台或无原生通道时的内存定时器兜底
    _fallbackTimers[rem.alarmId]?.cancel();
    _fallbackTimers[rem.alarmId] = Timer(delay, () {
      _fallbackTimers.remove(rem.alarmId);
      unawaited(
        showLocalNotification(
          id: rem.alarmId,
          title: rem.title,
          body: rem.body,
        ),
      );
    });
    return true;
  }

  Future<void> _cancelSingleReminderNative(int alarmId) async {
    _fallbackTimers.remove(alarmId)?.cancel();
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await _bgChannel.invokeMethod<void>(
          'cancelCheckinReminder',
          <String, dynamic>{'alarmId': alarmId},
        );
      }
    } catch (_) {}
  }

  /// 为单次刚约成功的座位注册系统级签到防违约提醒。
  Future<List<ScheduledCheckinReminder>> scheduleCheckinRemindersForEvent(
    BookingSuccessEvent event, {
    required bool enabled,
    String? roleLabel,
  }) async {
    if (!enabled) {
      await cancelCheckinRemindersForReservation(event.reservationId);
      return const <ScheduledCheckinReminder>[];
    }
    await requestNotificationPermission();
    final planned = planCheckinRemindersForEvent(event, roleLabel: roleLabel);
    if (planned.isEmpty) {
      return const <ScheduledCheckinReminder>[];
    }
    final tracked = await _loadTrackedAlarms();
    final ids = <int>[];
    for (final rem in planned) {
      if (await _scheduleSingleReminderNative(rem)) {
        ids.add(rem.alarmId);
      }
    }
    if (ids.isNotEmpty) {
      tracked[event.reservationId.trim()] = ids;
      await _saveTrackedAlarms(tracked);
    }
    return planned;
  }

  /// 按当前全部有效预约列表对账系统签到闹钟：
  /// - 开关关闭：撤回所有已注册的签到闹钟；
  /// - 开关开启：为每条 `RESERVE` 预约注册/更新提醒，并自动撤回已签到或已取消预约的旧闹钟。
  Future<int> syncCheckinRemindersForReservations(
    List<ReservationRecord> records, {
    required bool enabled,
    String Function(String account)? roleLabelOf,
  }) async {
    if (!enabled) {
      await cancelAllCheckinReminders();
      return 0;
    }
    await requestNotificationPermission();
    final tracked = await _loadTrackedAlarms();
    final desired = <String, List<ScheduledCheckinReminder>>{};
    for (final rec in records) {
      final id = rec.reservationId.trim();
      if (id.isEmpty) {
        continue;
      }
      final role = (roleLabelOf != null && rec.account.trim().isNotEmpty)
          ? roleLabelOf(rec.account)
          : null;
      final planned = planCheckinRemindersForRecord(rec, roleLabel: role);
      if (planned.isNotEmpty) {
        desired[id] = planned;
      }
    }

    // 1. 撤回不再需要提醒的旧闹钟（已签到 / 已取消 / 已过期）
    final staleKeys = tracked.keys
        .where((k) => !desired.containsKey(k))
        .toList(growable: false);
    for (final k in staleKeys) {
      for (final alarmId in tracked[k] ?? const <int>[]) {
        await _cancelSingleReminderNative(alarmId);
      }
      tracked.remove(k);
    }

    // 2. 注册或刷新当前有效的签到提醒
    var scheduledCount = 0;
    for (final entry in desired.entries) {
      final newIds = <int>[];
      final oldIds = tracked[entry.key] ?? const <int>[];
      for (final rem in entry.value) {
        if (await _scheduleSingleReminderNative(rem)) {
          newIds.add(rem.alarmId);
          scheduledCount += 1;
        }
      }
      for (final oldId in oldIds) {
        if (!newIds.contains(oldId)) {
          await _cancelSingleReminderNative(oldId);
        }
      }
      if (newIds.isNotEmpty) {
        tracked[entry.key] = newIds;
      } else {
        tracked.remove(entry.key);
      }
    }
    await _saveTrackedAlarms(tracked);
    return scheduledCount;
  }

  Future<void> cancelCheckinRemindersForReservation(
    String reservationId,
  ) async {
    final key = reservationId.trim();
    if (key.isEmpty) {
      return;
    }
    final tracked = await _loadTrackedAlarms();
    final ids = <int>{
      ...(tracked.remove(key) ?? const <int>[]),
      _baseAlarmIdForReservation(key),
      _baseAlarmIdForReservation(key) + 1,
    };
    for (final id in ids) {
      await _cancelSingleReminderNative(id);
    }
    await _saveTrackedAlarms(tracked);
  }

  Future<void> cancelAllCheckinReminders() async {
    final tracked = await _loadTrackedAlarms();
    for (final ids in tracked.values) {
      for (final id in ids) {
        await _cancelSingleReminderNative(id);
      }
    }
    for (final t in _fallbackTimers.values) {
      t.cancel();
    }
    _fallbackTimers.clear();
    await _saveTrackedAlarms(<String, List<int>>{});
  }
}
