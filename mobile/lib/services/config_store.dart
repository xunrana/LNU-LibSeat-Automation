/// 移动端配置存储、多套自习方案卡、座位宝藏标签与离线自习室目录管理。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/protocol.dart';
import '../logic/orchestrator.dart';
import '../logic/seat_strategy.dart';

class StudyPlanPreset {
  final String id;
  final String name;
  final String campus;
  final String room;
  final List<String> preferSeats;
  final String start1;
  final String end1;
  final String start2;
  final String end2;
  final List<RoomTarget> fallbackRooms;

  const StudyPlanPreset({
    required this.id,
    required this.name,
    required this.campus,
    required this.room,
    this.preferSeats = const <String>[],
    this.start1 = '08:00',
    this.end1 = '14:00',
    this.start2 = '14:00',
    this.end2 = '20:00',
    this.fallbackRooms = const <RoomTarget>[],
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'campus': campus,
        'room': room,
        'preferSeats': preferSeats,
        'start1': start1,
        'end1': end1,
        'start2': start2,
        'end2': end2,
        'fallbackRooms':
            fallbackRooms.map((r) => <String>[r.campus, r.room]).toList(),
      };

  static StudyPlanPreset fromJson(Map<String, dynamic> m) {
    return StudyPlanPreset(
      id: (m['id'] ?? DateTime.now().millisecondsSinceEpoch.toString())
          .toString(),
      name: (m['name'] ?? '默认方案').toString(),
      campus: (m['campus'] ?? '崇山校区图书馆').toString(),
      room: (m['room'] ?? '三楼智慧研修空间').toString(),
      preferSeats: ((m['preferSeats'] as List?) ?? const <dynamic>[])
          .map((e) => normalizeSeatNo(e.toString()))
          .where((s) => s.isNotEmpty)
          .toList(),
      start1: (m['start1'] ?? '08:00').toString(),
      end1: (m['end1'] ?? '14:00').toString(),
      start2: (m['start2'] ?? '14:00').toString(),
      end2: (m['end2'] ?? '20:00').toString(),
      fallbackRooms: ((m['fallbackRooms'] as List?) ?? const <dynamic>[])
          .whereType<List<dynamic>>()
          .where((p) => p.length == 2)
          .map((p) => RoomTarget(p[0].toString(), p[1].toString()))
          .toList(),
    );
  }
}

class RoomCatalog {
  final Map<String, List<String>> campuses;
  final Map<String, List<String>> roomSeats;

  const RoomCatalog({
    required this.campuses,
    required this.roomSeats,
  });

  static const RoomCatalog fallback = RoomCatalog(
    campuses: <String, List<String>>{
      '崇山校区图书馆': <String>[
        '二楼书库北',
        '二楼书库南',
        '二楼背诵长廊',
        '三楼智慧研修空间',
        '三楼理科书库',
        '四楼北自习室',
        '四楼南自习室',
        '四楼自习室406',
      ],
      '蒲河校区图书馆': <String>[
        '三楼走廊',
        '4楼阅览室',
        '四楼走廊',
        '5楼阅览室',
        '五楼走廊',
        '6楼阅览室',
        '六楼走廊',
        '704',
        '706',
        '707',
        '708',
        '七楼走廊',
        '智慧空间',
      ],
    },
    roomSeats: <String, List<String>>{},
  );

  /// 常见热门自习室的设施特点参考（贴合辽大同学实际习惯）。
  static String roomFacilityHint(String roomName) {
    if (roomName.contains('智慧')) {
      return '独立台灯与电源 · 研讨学习两宜';
    }
    if (roomName.contains('背诵')) {
      return '朗读背书区 · 考研背诵常选';
    }
    if (roomName.contains('走廊')) {
      return '采光通透 · 适合背诵与短时自习';
    }
    if (roomName.contains('阅览室')) {
      return '宽敞安静 · 常规阅览自习区';
    }
    if (roomName.contains('书库')) {
      return '古籍与藏书相伴 · 静谧沉浸';
    }
    return '常规自习空间';
  }

  List<String> roomsForCampus(String campus) =>
      campuses[campus] ?? const <String>[];

  List<String> seatsForRoom(String room) =>
      roomSeats[room] ??
      List<String>.generate(120, (index) => (index + 1).toString());
}

class MobileConfigStore extends ChangeNotifier {
  static const String _prefKeyJson = 'lnu_libseat_mobile_config_v61';
  static const String _secKeyPwd1 = 'lnu_libseat_pwd_1';
  static const String _secKeyPwd2 = 'lnu_libseat_pwd_2';

  static const List<String> availableSeatTags = <String>[
    '电源',
    '靠窗',
    '宝藏座',
    '避雷',
  ];

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  RoomCatalog catalog = RoomCatalog.fallback;
  Directory? logBaseDir;

  String campus = '崇山校区图书馆';
  String room = '三楼智慧研修空间';
  List<RoomTarget> fallbackRooms = <RoomTarget>[];
  List<String> preferSeats = <String>[];

  String account1 = '';
  String password1 = '';
  String start1 = '08:00';
  String end1 = '14:00';

  bool useAccount2 = false;
  String account2 = '';
  String password2 = '';
  String start2 = '14:00';
  String end2 = '20:00';

  bool scheduledMode = true;
  int schedHour = 6;
  int schedMin = 30;
  int apiFireOffsetMs = 200;
  String apiBaseUrl = ProtocolConstants.defaultBaseUrl;
  String receiverEmail = '';
  String webhookUrl = '';
  bool autoCheckinReminder = true;

  // 多套自习方案卡
  List<StudyPlanPreset> presets = <StudyPlanPreset>[];
  String activePresetId = '';

  // 座位个人宝藏笔记标签：key = "$room::$seatNo"
  Map<String, List<String>> seatTags = <String, List<String>>{};

  bool _initialized = false;
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    await _loadRoomCatalog();
    await _initLogDir();
    await loadFromDisk();
    _ensureDefaultPresets();
    _initialized = true;
    notifyListeners();
  }

  void _ensureDefaultPresets() {
    if (presets.isEmpty) {
      presets = <StudyPlanPreset>[
        StudyPlanPreset(
          id: 'default_weekday',
          name: '平日·智慧研修',
          campus: campus,
          room: room,
          preferSeats: List<String>.from(preferSeats),
          start1: start1,
          end1: end1,
          start2: start2,
          end2: end2,
          fallbackRooms: List<RoomTarget>.from(fallbackRooms),
        ),
        const StudyPlanPreset(
          id: 'default_evening',
          name: '晚自习冲刺',
          campus: '崇山校区图书馆',
          room: '四楼南自习室',
          start1: '18:00',
          end1: '22:00',
        ),
      ];
      activePresetId = presets.first.id;
    }
  }

  Future<void> _loadRoomCatalog() async {
    try {
      final raw = await rootBundle.loadString('assets/rooms/room_catalog.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final rawCampuses = map['campuses'] as Map<String, dynamic>? ?? {};
      final rawSeats = map['room_seats'] as Map<String, dynamic>? ?? {};

      final campuses = <String, List<String>>{
        for (final entry in rawCampuses.entries)
          entry.key: (entry.value as List).map((e) => e.toString()).toList(),
      };
      final roomSeats = <String, List<String>>{
        for (final entry in rawSeats.entries)
          entry.key: (entry.value as List).map((e) => e.toString()).toList(),
      };
      if (campuses.isNotEmpty) {
        catalog = RoomCatalog(campuses: campuses, roomSeats: roomSeats);
      }
    } catch (_) {}
  }

  Future<void> _initLogDir() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${docDir.path}/lnu_libseat_logs');
      dir.createSync(recursive: true);
      logBaseDir = dir;
    } catch (_) {}
  }

  Future<void> loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKeyJson);
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        campus = (data['campus'] as String?) ?? campus;
        room = (data['room'] as String?) ?? room;
        preferSeats = ((data['preferSeats'] as List?) ?? const <dynamic>[])
            .map((e) => normalizeSeatNo(e.toString()))
            .where((s) => s.isNotEmpty)
            .toList();

        fallbackRooms = ((data['fallbackRooms'] as List?) ?? const <dynamic>[])
            .whereType<List<dynamic>>()
            .where((pair) => pair.length == 2)
            .map((pair) => RoomTarget(pair[0].toString(), pair[1].toString()))
            .toList();

        account1 = (data['account1'] as String?) ?? '';
        start1 = (data['start1'] as String?) ?? '08:00';
        end1 = (data['end1'] as String?) ?? '14:00';

        useAccount2 = (data['useAccount2'] as bool?) ?? false;
        account2 = (data['account2'] as String?) ?? '';
        start2 = (data['start2'] as String?) ?? '14:00';
        end2 = (data['end2'] as String?) ?? '20:00';

        scheduledMode = (data['scheduledMode'] as bool?) ?? true;
        schedHour = (data['schedHour'] as int?) ?? 6;
        schedMin = (data['schedMin'] as int?) ?? 30;
        apiFireOffsetMs = (data['apiFireOffsetMs'] as int?) ?? 200;
        apiBaseUrl =
            (data['apiBaseUrl'] as String?) ?? ProtocolConstants.defaultBaseUrl;
        receiverEmail = (data['receiverEmail'] as String?) ?? '';
        webhookUrl = (data['webhookUrl'] as String?) ?? '';
        autoCheckinReminder = (data['autoCheckinReminder'] as bool?) ?? true;

        final rawPresets = data['presets'];
        if (rawPresets is List) {
          presets = rawPresets
              .whereType<Map<String, dynamic>>()
              .map(StudyPlanPreset.fromJson)
              .toList();
        }
        activePresetId = (data['activePresetId'] as String?) ?? '';

        final rawTags = data['seatTags'];
        if (rawTags is Map) {
          seatTags = <String, List<String>>{
            for (final entry in rawTags.entries)
              entry.key.toString(): (entry.value as List)
                  .map((e) => e.toString())
                  .toList(),
          };
        }
      }
      password1 = (await _secureStorage.read(key: _secKeyPwd1)) ?? '';
      password2 = (await _secureStorage.read(key: _secKeyPwd2)) ?? '';
    } catch (_) {}
  }

  Future<void> saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        'campus': campus,
        'room': room,
        'preferSeats': preferSeats,
        'fallbackRooms':
            fallbackRooms.map((t) => <String>[t.campus, t.room]).toList(),
        'account1': account1.trim(),
        'start1': start1.trim(),
        'end1': end1.trim(),
        'useAccount2': useAccount2,
        'account2': account2.trim(),
        'start2': start2.trim(),
        'end2': end2.trim(),
        'scheduledMode': scheduledMode,
        'schedHour': schedHour,
        'schedMin': schedMin,
        'apiFireOffsetMs': apiFireOffsetMs,
        'apiBaseUrl': apiBaseUrl.trim(),
        'receiverEmail': receiverEmail.trim(),
        'webhookUrl': webhookUrl.trim(),
        'autoCheckinReminder': autoCheckinReminder,
        'presets': presets.map((p) => p.toJson()).toList(),
        'activePresetId': activePresetId,
        'seatTags': seatTags,
      };
      await prefs.setString(_prefKeyJson, jsonEncode(data));
      await _secureStorage.write(key: _secKeyPwd1, value: password1);
      await _secureStorage.write(key: _secKeyPwd2, value: password2);
    } catch (_) {}
    notifyListeners();
  }

  /// 应用指定自习方案卡到当前运行参数。
  Future<void> applyPreset(StudyPlanPreset preset) async {
    activePresetId = preset.id;
    campus = preset.campus;
    room = preset.room;
    preferSeats = List<String>.from(preset.preferSeats);
    start1 = preset.start1;
    end1 = preset.end1;
    start2 = preset.start2;
    end2 = preset.end2;
    fallbackRooms = List<RoomTarget>.from(preset.fallbackRooms);
    await saveToDisk();
  }

  /// 将当前配置另存为一个新的自习方案卡。
  Future<void> saveCurrentAsPreset(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final id = 'preset_${DateTime.now().millisecondsSinceEpoch}';
    final preset = StudyPlanPreset(
      id: id,
      name: trimmed,
      campus: campus,
      room: room,
      preferSeats: List<String>.from(preferSeats),
      start1: start1,
      end1: end1,
      start2: start2,
      end2: end2,
      fallbackRooms: List<RoomTarget>.from(fallbackRooms),
    );
    presets.add(preset);
    activePresetId = id;
    await saveToDisk();
  }

  Future<void> deletePreset(String id) async {
    presets.removeWhere((p) => p.id == id);
    if (activePresetId == id) {
      activePresetId = presets.isNotEmpty ? presets.first.id : '';
    }
    await saveToDisk();
  }

  /// 座位个人标签辅助方法。
  String _seatTagKey(String roomName, String seatNo) =>
      '$roomName::${normalizeSeatNo(seatNo)}';

  List<String> tagsForSeat(String roomName, String seatNo) =>
      seatTags[_seatTagKey(roomName, seatNo)] ?? const <String>[];

  Future<void> toggleSeatTag(
    String roomName,
    String seatNo,
    String tag,
  ) async {
    final key = _seatTagKey(roomName, seatNo);
    final list = List<String>.from(seatTags[key] ?? const <String>[]);
    if (list.contains(tag)) {
      list.remove(tag);
    } else {
      list.add(tag);
    }
    if (list.isEmpty) {
      seatTags.remove(key);
    } else {
      seatTags[key] = list;
    }
    await saveToDisk();
  }

  Future<void> addPreferSeat(String campusName, String roomName, String seatNo) async {
    final norm = normalizeSeatNo(seatNo);
    if (norm.isEmpty) {
      return;
    }
    if (campus != campusName || room != roomName) {
      campus = campusName;
      room = roomName;
      preferSeats = <String>[norm];
    } else if (!preferSeats.contains(norm)) {
      preferSeats.add(norm);
    }
    await saveToDisk();
  }

  (bool, String) validate() {
    if (account1.trim().isEmpty) {
      return (false, '请先在「我的 → 校园卡账号」中填写主账号学号');
    }
    if (password1.trim().isEmpty) {
      return (false, '请填写主账号密码（初始密码通常为 000000）');
    }
    if (parseHhmmMinutes(start1) == null && start1.trim().toLowerCase() != 'now') {
      return (false, '主账号开始时段格式应为 HH:MM 或 now');
    }
    if (parseHhmmMinutes(end1) == null) {
      return (false, '主账号结束时段格式应为 HH:MM（如 14:00）');
    }
    if (useAccount2) {
      if (account2.trim().isEmpty || password2.trim().isEmpty) {
        return (false, '已启用副账号，请补全副账号的学号与密码');
      }
      if (account2.trim() == account1.trim()) {
        return (false, '主副账号学号不能重复: ${account1.trim()}');
      }
      if ((parseHhmmMinutes(start2) == null &&
              start2.trim().toLowerCase() != 'now') ||
          parseHhmmMinutes(end2) == null) {
        return (false, '副账号预约时段格式应为 HH:MM 或 now');
      }
    }
    if (room.trim().isEmpty) {
      return (false, '请选择目标自习室');
    }
    if (scheduledMode &&
        (schedHour < 0 || schedHour > 23 || schedMin < 0 || schedMin > 59)) {
      return (false, '定时时间必须在 00:00 ~ 23:59');
    }
    return (true, '');
  }

  RushSessionConfig toRushSessionConfig({bool? overrideWaitForSchedule}) {
    final accounts = <AccountTaskConfig>[
      AccountTaskConfig(
        account: account1.trim(),
        password: password1,
        startTime: start1.trim(),
        endTime: end1.trim(),
      ),
      if (useAccount2 && account2.trim().isNotEmpty)
        AccountTaskConfig(
          account: account2.trim(),
          password: password2,
          startTime: start2.trim(),
          endTime: end2.trim(),
        ),
    ];

    return RushSessionConfig(
      accounts: accounts,
      targetCampus: campus,
      targetRoom: room,
      fallbackRooms: List<RoomTarget>.from(fallbackRooms),
      preferSeats: List<String>.from(preferSeats),
      waitForSchedule: overrideWaitForSchedule ?? scheduledMode,
      scheduleHour: schedHour,
      scheduleMinute: schedMin,
      apiBaseUrl: apiBaseUrl.trim().isNotEmpty
          ? apiBaseUrl.trim()
          : ProtocolConstants.defaultBaseUrl,
      apiFireOffsetMs: apiFireOffsetMs,
      webhookUrl: webhookUrl.trim(),
      baseLogDir: logBaseDir,
    );
  }
}
