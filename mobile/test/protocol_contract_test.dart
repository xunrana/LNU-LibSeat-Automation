import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lnu_libseat_mobile/core/api_crypto.dart';
import 'package:lnu_libseat_mobile/core/captcha/captcha_service.dart';
import 'package:lnu_libseat_mobile/core/captcha/ocr_login.dart';
import 'package:lnu_libseat_mobile/core/captcha/pil_image_ops.dart';
import 'package:lnu_libseat_mobile/core/captcha/siamese_onnx.dart';
import 'package:lnu_libseat_mobile/core/clock_sync.dart';
import 'package:lnu_libseat_mobile/core/libseat_client.dart';
import 'package:lnu_libseat_mobile/core/protocol.dart';
import 'package:lnu_libseat_mobile/core/session_recorder.dart';
import 'package:lnu_libseat_mobile/logic/result_classifier.dart';
import 'package:lnu_libseat_mobile/logic/seat_strategy.dart';
import 'package:lnu_libseat_mobile/services/config_store.dart';
import 'package:lnu_libseat_mobile/services/notification_service.dart';
import 'package:lnu_libseat_mobile/services/rush_controller.dart';

void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    final file = File('test/fixtures/protocol_test_vectors.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: '请先运行 python scripts/dump_test_vectors.py 生成跨语言黄金测试向量',
    );
    vectors =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('AES-128-CBC + PKCS7 与 NUMCODE 解密 100% 契约对齐', () {
    final constants = vectors['constants'] as Map<String, dynamic>;
    final expectedSecret = constants['decrypted_hmac_secret'] as String;
    expect(ApiCrypto.decryptHmacSecret(), equals(expectedSecret));

    final aesVectors = vectors['aes_vectors'] as List<dynamic>;
    for (final raw in aesVectors) {
      final item = raw as Map<String, dynamic>;
      final plain = item['plaintext'] as String;
      final expectedB64 = item['aes_b64'] as String;
      final expectedCred = item['login_credential'] as String;

      expect(ApiCrypto.encryptAesB64(plain), equals(expectedB64));
      expect(ApiCrypto.decryptAesB64(expectedB64), equals(plain));
      expect(ApiCrypto.encryptLoginCredential(plain), equals(expectedCred));
      // 幂等性校验
      expect(
        ApiCrypto.encryptLoginCredential(expectedCred),
        equals(expectedCred),
      );
    }
  });

  test('HMAC-SHA256 请求签名头与 Python 端逐字符一致', () {
    final hmacVectors = vectors['hmac_vectors'] as List<dynamic>;
    for (final raw in hmacVectors) {
      final item = raw as Map<String, dynamic>;
      final headers = ApiCrypto.signRequestHeaders(
        item['method'] as String,
        hmacSecret: item['hmac_secret'] as String,
        requestId: item['request_id'] as String,
        timestampMs: (item['timestamp_ms'] as num).toInt(),
      );
      final expected = Map<String, String>.from(
        item['expected_headers'] as Map,
      );
      expect(headers, equals(expected));
    }
  });

  test('点选坐标紧凑 JSON + Base64 编码与 Python 端一致', () {
    final ptsVectors = vectors['captcha_points_vectors'] as List<dynamic>;
    for (final raw in ptsVectors) {
      final item = raw as Map<String, dynamic>;
      final rawPts = item['points'] as List<dynamic>;
      final pts = rawPts
          .map(
            (p) => CaptchaPoint(
              ((p as List)[0] as num).toInt(),
              (p[1] as num).toInt(),
            ),
          )
          .toList();
      expect(
        ApiCrypto.encodeCaptchaPoints(pts),
        equals(item['encoded_a'] as String),
      );
    }
  });

  test('baseUrl.js Global 动态解析与 Python 端一致', () {
    final jsVec = vectors['global_js_vector'] as Map<String, dynamic>;
    final parsed = parseGlobalJs(jsVec['js_text'] as String);
    expect(parsed, isNotNull);
    expect(parsed!.baseUrl, equals(jsVec['base_url']));
    expect(parsed.codeEnabled, equals(jsVec['code_enabled']));
    expect(parsed.numcodeEncrypted, equals(jsVec['numcode_encrypted']));
  });

  test('预约结果分类器（含 06:30 宽限窗与限流识别）与 Python 端一致', () {
    final clsVectors = vectors['classifier_vectors'] as List<dynamic>;
    for (final raw in clsVectors) {
      final item = raw as Map<String, dynamic>;
      final res = classifyApiBookingResult(
        item['text'] as String,
        inOpenGraceWindow: item['in_open_grace_window'] as bool,
      );
      expect(res.status.wireName, equals(item['status']));
      expect(res.notOpenYet, equals(item['not_open_yet']));
      expect(res.rateLimited, equals(item['rate_limited']));
    }
  });

  test('选座策略、时间重叠与多账号防撞座协调器', () {
    for (final raw in vectors['seat_norm_vectors'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      expect(
        normalizeSeatNo(item['raw'] as String),
        equals(item['normalized']),
      );
    }

    for (final raw in vectors['time_overlap_vectors'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      final a = (item['a'] as List).cast<String>();
      final b = (item['b'] as List).cast<String>();
      expect(
        timeRangesOverlap(a[0], a[1], b[0], b[1]),
        equals(item['overlap']),
      );
    }

    final coord = SeatClaimCoordinator();
    expect(coord.tryClaim('acc1', '30', '001', '08:00', '12:00'), isTrue);
    // 重叠时段账号 B 被拦截
    expect(coord.tryClaim('acc2', '30', '1', '10:00', '14:00'), isFalse);
    // 无缝接力时段账号 B 放行
    expect(coord.tryClaim('acc2', '30', '1', '12:00', '18:00'), isTrue);
  });

  test('ClockSync HTTP Date + RTT/2 校准与SessionRecorder 脱敏', () {
    final fixedNow = DateTime.utc(2026, 11, 20, 6, 29, 55, 500);
    final clock = ClockSync(nowUtcFn: () => fixedNow);
    final sample = clock.updateFromHttpDate(
      'Fri, 20 Nov 2026 06:29:56 GMT',
      rttSeconds: 0.2,
      localReceivedUtc: fixedNow,
    );
    expect(sample, isNotNull);
    // localMid = 06:29:55.400, server = 06:29:56.000 -> offset = +0.600s
    expect(clock.offsetSeconds, closeTo(0.6, 0.001));

    final sanitized = sanitizeForTrace(<String, dynamic>{
      'username': '20230001',
      'password': 'secret_password',
      'token': '1234567890abcdef',
      'image': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA',
    }) as Map<String, dynamic>;
    expect(sanitized['username'], equals('20230001'));
    expect(sanitized['password'], equals('<REDACTED>'));
    expect(sanitized['token'], equals('<REDACTED>'));
    expect(
      (sanitized['image'] as String).startsWith('<BASE64_IMG'),
      isTrue,
    );
  });

  test('CTC 解码与 Siamese 最优指派算法', () {
    final charset = <String>['', 'a', 'b', '3', '9'];
    expect(
      LoginOcrSolver.decodeCtcIndices(<int>[0, 1, 1, 0, 2, 3, 3, 4], charset),
      equals('ab39'),
    );

    final matches = optimalMatch(<List<double>>[
      <double>[0.1, 0.92, 0.2, 0.3],
      <double>[0.85, 0.1, 0.3, 0.2],
      <double>[0.2, 0.3, 0.1, 0.95],
    ]);
    expect(matches, equals(<(int, int)>[(0, 1), (1, 0), (2, 3)]));
  });

  test('Pillow 重采样 (BILINEAR/BICUBIC/LANCZOS)、灰度与点选分类与 PC 端逐字节对齐', () {
    final pilVec = vectors['pil_ops_vectors'] as Map<String, dynamic>;

    final smallImg = RgbImage(
      width: (pilVec['small_w'] as num).toInt(),
      height: (pilVec['small_h'] as num).toInt(),
      rgb: base64Decode(pilVec['small_rgb_b64'] as String),
    );
    final wideImg = RgbImage(
      width: (pilVec['wide_w'] as num).toInt(),
      height: (pilVec['wide_h'] as num).toInt(),
      rgb: base64Decode(pilVec['wide_rgb_b64'] as String),
    );

    final bicubic = pilResizeRgb(smallImg, 101, 112, PilResampling.bicubic);
    expect(
      sha256.convert(bicubic.rgb).toString(),
      equals(pilVec['bicubic_101x112_sha256']),
    );

    final bilinear = pilResizeRgb(wideImg, 128, 56, PilResampling.bilinear);
    expect(
      sha256.convert(bilinear.rgb).toString(),
      equals(pilVec['bilinear_128x56_sha256']),
    );

    final lanczos = pilResizeRgb(wideImg, 73, 32, PilResampling.lanczos);
    expect(
      sha256.convert(lanczos.rgb).toString(),
      equals(pilVec['lanczos_73x32_sha256']),
    );

    final luma = pilRgbToLuma(wideImg);
    expect(
      sha256.convert(luma).toString(),
      equals(pilVec['luma_sha256']),
    );

    final (loginBlob, loginTw) = LoginOcrSolver.preprocessToTensor(wideImg);
    expect(loginTw, equals((pilVec['login_target_width'] as num).toInt()));
    final loginBytes = Uint8List(loginBlob.length);
    for (var i = 0; i < loginBlob.length; i++) {
      loginBytes[i] = (loginBlob[i] * 255.0).round();
    }
    expect(
      sha256.convert(loginBytes).toString(),
      equals(pilVec['login_gray_sha256']),
    );

    final click1Png = base64Decode(pilVec['target_click1_png_b64'] as String);
    final click3Png = base64Decode(pilVec['target_click3_png_b64'] as String);
    final rushTime = DateTime.utc(2026, 11, 20, 6, 31, 0);
    final nonRushTime = DateTime.utc(2026, 11, 20, 14, 0, 0);

    expect(
      detectCaptchaKind(targetBytes: click1Png, hintCount: 3),
      equals(CaptchaKind.click3),
    );
    expect(
      detectCaptchaKind(targetBytes: click3Png, hintCount: 1),
      equals(CaptchaKind.click1),
    );
    expect(
      detectCaptchaKind(targetBytes: click1Png, nowBeijing: rushTime),
      equals(CaptchaKind.click1),
    );
    expect(
      detectCaptchaKind(targetBytes: click3Png, nowBeijing: nonRushTime),
      equals(CaptchaKind.click3),
    );
    expect(
      detectCaptchaKind(targetBytes: Uint8List.fromList(<int>[1, 2, 3]), nowBeijing: rushTime),
      equals(CaptchaKind.click3),
    );
    expect(
      detectCaptchaKind(targetBytes: Uint8List.fromList(<int>[1, 2, 3]), nowBeijing: nonRushTime),
      equals(CaptchaKind.click1),
    );

    for (final raw in pilVec['py_round_cases'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      expect(
        pyRound((item['x'] as num).toDouble()),
        equals((item['expected'] as num).toInt()),
      );
    }

    // decodeDataUrl 容忍嵌入换行/空白（与 Python base64.b64decode 一致）
    final rawPng = click1Png;
    final b64WithNewlines = base64Encode(rawPng).replaceAllMapped(
      RegExp(r'.{1,20}'),
      (m) => '${m.group(0)}\r\n',
    );
    expect(
      decodeDataUrl('data:image/png;base64,$b64WithNewlines'),
      equals(rawPng),
    );

    final syncImg = decodeImageRgbSync(rawPng);
    expect(syncImg, isNotNull);
    expect(syncImg!.decoder, equals('package_image'));
  });

  test('收件邮箱留空时默认回退到内置发件箱 lnu_libseat_bot@126.com', () {
    expect(
      NotificationService.resolveReceiverEmail(''),
      equals('lnu_libseat_bot@126.com'),
    );
    expect(
      NotificationService.resolveReceiverEmail('   '),
      equals('lnu_libseat_bot@126.com'),
    );
    expect(
      NotificationService.resolveReceiverEmail(' student@qq.com '),
      equals('student@qq.com'),
    );
  });

  test('座位可约时段探测可完整列出当日所有不连续与连续分段', () async {
    // 1. 多段不连续：now — 14:00 且 20:00 — 22:00（仅 2 次 endTimes 请求）
    var calls = 0;
    final multiStarts = <SeatTimeOption>[
      const SeatTimeOption(id: 'now', value: '现在'),
      const SeatTimeOption(id: '810', value: '13:30'),
      const SeatTimeOption(id: '1200', value: '20:00'),
      const SeatTimeOption(id: '1230', value: '20:30'),
      const SeatTimeOption(id: '1260', value: '21:00'),
      const SeatTimeOption(id: '1290', value: '21:30'),
    ];
    final multiWin = await discoverSeatAvailableWindows(
      starts: multiStarts,
      fetchEndTimes: (startId) async {
        calls += 1;
        if (startId == 'now') {
          return const <SeatTimeOption>[
            SeatTimeOption(id: '810', value: '13:30'),
            SeatTimeOption(id: '840', value: '14:00'),
          ];
        }
        if (startId == '1200') {
          return const <SeatTimeOption>[
            SeatTimeOption(id: '1230', value: '20:30'),
            SeatTimeOption(id: '1260', value: '21:00'),
            SeatTimeOption(id: '1290', value: '21:30'),
            SeatTimeOption(id: '1320', value: '22:00'),
          ];
        }
        return const <SeatTimeOption>[];
      },
    );
    expect(calls, equals(2));
    expect(multiWin.map((w) => w.label).toList(), equals(<String>[
      'now — 14:00',
      '20:00 — 22:00',
    ]));
    expect(multiWin[0].startParam, equals('now'));
    expect(multiWin[0].endParam, equals('14:00'));
    expect(multiWin[1].startParam, equals('20:00'));
    expect(multiWin[1].endParam, equals('22:00'));

    // 2. 单次最长时长截断（如 now 最多到 17:00，紧接着 17:00 可约到 22:00）
    final cappedWin = await discoverSeatAvailableWindows(
      starts: const <SeatTimeOption>[
        SeatTimeOption(id: 'now', value: '现在'),
        SeatTimeOption(id: '900', value: '15:00'),
        SeatTimeOption(id: '1020', value: '17:00'),
        SeatTimeOption(id: '1140', value: '19:00'),
      ],
      fetchEndTimes: (startId) async {
        if (startId == 'now') {
          return const <SeatTimeOption>[
            SeatTimeOption(id: '900', value: '15:00'),
            SeatTimeOption(id: '1020', value: '17:00'),
          ];
        }
        if (startId == '1020') {
          return const <SeatTimeOption>[
            SeatTimeOption(id: '1140', value: '19:00'),
            SeatTimeOption(id: '1320', value: '22:00'),
          ];
        }
        return const <SeatTimeOption>[];
      },
    );
    expect(cappedWin.map((w) => w.label).toList(), equals(<String>[
      'now — 17:00',
      '17:00 — 22:00',
    ]));

    // 3. 当前已占、晚间仍有空段（无 now）
    final laterOnly = await discoverSeatAvailableWindows(
      starts: const <SeatTimeOption>[
        SeatTimeOption(id: '1200', value: '20:00'),
        SeatTimeOption(id: '1260', value: '21:00'),
      ],
      fetchEndTimes: (startId) async => const <SeatTimeOption>[
        SeatTimeOption(id: '1260', value: '21:00'),
        SeatTimeOption(id: '1320', value: '22:00'),
      ],
    );
    expect(laterOnly.map((w) => w.label).toList(), equals(<String>[
      '20:00 — 22:00',
    ]));

    // 4. 今日无任何可约起点
    final emptyWin = await discoverSeatAvailableWindows(
      starts: const <SeatTimeOption>[],
      fetchEndTimes: (_) async => const <SeatTimeOption>[],
    );
    expect(emptyWin, isEmpty);
  });

  test('馆方公告 /rest/v2/announce HTML 与滚动标题解析正确', () {
    final parsed = parseAnnouncements(<String, dynamic>{
      'announce':
          '<p>各位读者：图书馆自 2025 年 5 月 6 日起开通线上预约与线下选座功能，'
              '<strong>蒲河校区图书馆三楼智慧空间将于 2026 年 5 月 18 日正式开放座位预约</strong>，相关事宜如下：</p>\r\n\r\n'
              '<p>一、预约方式线上可通过 PC / 移动端登录<a href="https://libseat.lnu.edu.cn" target="_blank">libseat.lnu.edu.cn</a>，'
              '可登录<a href="https://opac.lnu.edu.cn" target="_blank">opac.lnu.edu.cn</a>&ldquo;我的图书馆&rdquo; 修改。</p>',
      'rollText': '蒲河校区图书馆三楼智慧空间2026年5月18日开通预约，欢迎师生使用！',
      'noticeVal': '',
    });
    expect(parsed.length, equals(1));
    expect(
      parsed.first.title,
      equals('蒲河校区图书馆三楼智慧空间2026年5月18日开通预约，欢迎师生使用！'),
    );
    expect(parsed.first.content, contains('各位读者：图书馆自 2025 年 5 月 6 日起'));
    expect(parsed.first.content, contains('“我的图书馆”'));
    expect(parsed.first.content, isNot(contains('<p>')));
    expect(parsed.first.content, isNot(contains('&ldquo;')));
    expect(parsed.first.content, contains('\n\n一、预约方式'));
  });

  test('取消预约响应解析与双账号辽大自习书简分号/合并统计', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cancelOk = parseCancelReservationResponse(<String, dynamic>{
      'status': 'success',
      'data': <String, dynamic>{'totalCancelled': 2, 'allowedCancel': 3},
      'message': '',
      'code': '0',
    });
    expect(cancelOk.ok, isTrue);
    expect(cancelOk.totalCancelled, equals(2));
    expect(cancelOk.allowedCancel, equals(3));

    final cancelFail = parseCancelReservationResponse(<String, dynamic>{
      'status': 'fail',
      'message': '今日取消次数已达上限',
      'code': '1',
    });
    expect(cancelFail.ok, isFalse);
    expect(cancelFail.message, equals('今日取消次数已达上限'));

    expect(
      extractRoomNameFromLocation('崇山校区图书馆3层三楼智慧研修空间，座位号8'),
      equals('崇山校区图书馆3层三楼智慧研修空间'),
    );
    expect(
      extractRoomNameFromLocation('崇山校区图书馆3层三楼智慧研修空间237号'),
      equals('崇山校区图书馆3层三楼智慧研修空间'),
    );

    final store = MobileConfigStore()
      ..account1 = '20250000001'
      ..account2 = '20250000002'
      ..useAccount2 = true;
    final ctrl = MobileRushController(config: store);
    ctrl.historyRecords = const <HistoryRecord>[
      HistoryRecord(
        id: '101',
        date: '2026-11-21',
        begin: '08:00',
        end: '14:00',
        location: '崇山校区图书馆3层三楼智慧研修空间8号',
        stat: 'COMPLETE',
        account: '20250000001',
      ),
      HistoryRecord(
        id: '102',
        date: '2026-11-21',
        begin: '14:00',
        end: '15:00',
        location: '崇山校区图书馆3层三楼智慧研修空间9号',
        stat: 'CANCEL',
        account: '20250000001',
      ),
      HistoryRecord(
        id: '201',
        date: '2026-11-21',
        begin: '14:00',
        end: '17:00',
        location: '崇山校区图书馆4层四楼南自习室12号',
        stat: 'RESERVE',
        account: '20250000002',
      ),
    ];

    final all = ctrl.computeStudyLetter();
    expect(all.totalVisits, equals(3));
    expect(all.totalHours, closeTo(9.0, 1e-6));
    expect(all.favoriteLocation, equals('崇山校区图书馆3层三楼智慧研修空间'));

    final s1 = ctrl.computeStudyLetter(accountFilter: '20250000001');
    expect(s1.totalVisits, equals(2));
    expect(s1.totalHours, closeTo(6.0, 1e-6));

    final s2 = ctrl.computeStudyLetter(accountFilter: '20250000002');
    expect(s2.totalVisits, equals(1));
    expect(s2.totalHours, closeTo(3.0, 1e-6));
    expect(s2.favoriteLocation, equals('崇山校区图书馆4层四楼南自习室'));
  });

  test('签到前防违约双节点闹钟时间规划（未来时段 / 临近时段 / now / 已签到）', () {
    // 1. 未来预约：当前 13:00，预约 14:00–20:00 -> 13:45（提前15分）与 14:20（截止前10分）
    final now1300 = DateTime.utc(2026, 11, 21, 13, 0);
    final futurePlan = NotificationService.planCheckinRemindersForRecord(
      const ReservationRecord(
        reservationId: '9000001',
        onDate: '2026-11-21',
        status: 'RESERVE',
        location: '崇山校区图书馆3层三楼智慧研修空间，座位号15',
        begin: '14:00',
        end: '20:00',
        account: '20250000001',
      ),
      roleLabel: '主号',
      nowBeijing: now1300,
    );
    expect(futurePlan.length, equals(2));
    expect(futurePlan[0].triggerHmLabel, equals('13:45'));
    expect(futurePlan[0].urgent, isFalse);
    expect(futurePlan[1].triggerHmLabel, equals('14:20'));
    expect(futurePlan[1].urgent, isTrue);
    expect(futurePlan[0].alarmId, isNot(equals(futurePlan[1].alarmId)));
    expect(futurePlan[0].body, contains('[主号 20250000001]'));
    expect(futurePlan[0].body, contains('14:30'));

    // 2. 当前已过前15分节点（13:50），只剩截止前10分（14:20）
    final nearPlan = NotificationService.planCheckinRemindersForRecord(
      const ReservationRecord(
        reservationId: '9000001',
        onDate: '2026-11-21',
        status: 'RESERVE',
        location: '崇山校区图书馆3层三楼智慧研修空间15号',
        begin: '14:00',
        end: '20:00',
      ),
      nowBeijing: DateTime.utc(2026, 11, 21, 13, 50),
    );
    expect(nearPlan.length, equals(1));
    expect(nearPlan.first.triggerHmLabel, equals('14:20'));
    expect(nearPlan.first.urgent, isTrue);

    // 3. now 当场约座（13:05）：自动跳过前15分，只保留截止前10分（13:25）
    final nowPlan = NotificationService.planCheckinReminders(
      reservationId: '9000999',
      location: '三楼智慧研修空间 15号座',
      begin: 'now',
      nowBeijing: DateTime.utc(2026, 11, 21, 13, 5),
    );
    expect(nowPlan.length, equals(1));
    expect(nowPlan.first.triggerHmLabel, equals('13:25'));
    expect(nowPlan.first.urgent, isTrue);

    // 4. 已签到（CHECK_IN）：不再安排提醒
    final checkedIn = NotificationService.planCheckinRemindersForRecord(
      const ReservationRecord(
        reservationId: '9000001',
        onDate: '2026-11-21',
        status: 'CHECK_IN',
        location: '三楼智慧研修空间15号',
        begin: '14:00',
        end: '20:00',
      ),
      nowBeijing: now1300,
    );
    expect(checkedIn, isEmpty);
  });
}
