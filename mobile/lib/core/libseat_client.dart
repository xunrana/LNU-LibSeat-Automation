/// LibSeat 纯 HTTP API 客户端（强类型契约 + Dio 生产实现）。
///
/// 与 Python 端 `core/libseat_client.py` 100% 契约对齐。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../logic/result_classifier.dart';
import '../logic/seat_strategy.dart';
import 'api_crypto.dart';
import 'clock_sync.dart';
import 'protocol.dart';
import 'rate_limiter.dart';
import 'session_recorder.dart';

enum LoginFailureReason {
  ok,
  maintenance,
  badCredentials,
  captchaFailed,
  protocolDrift,
  rateLimited,
  networkError,
  stopped,
}

class UserProfile {
  final String userId;
  final String username;
  final String status;
  final int violationCount;
  final String? reservationStatus;

  const UserProfile({
    required this.userId,
    required this.username,
    this.status = 'NORMAL',
    this.violationCount = 0,
    this.reservationStatus,
  });
}

class LoginResponse {
  final bool ok;
  final LoginFailureReason reason;
  final String token;
  final UserProfile? profile;
  final String message;

  const LoginResponse({
    required this.ok,
    this.reason = LoginFailureReason.ok,
    this.token = '',
    this.profile,
    this.message = '',
  });
}

class RoomInfo {
  final String campusName;
  final String roomName;
  final String buildingId;
  final String roomId;

  const RoomInfo({
    required this.campusName,
    required this.roomName,
    required this.buildingId,
    required this.roomId,
  });
}

class RoomStats {
  final String roomId;
  final String roomName;
  final int floor;
  final int totalSeats;
  final int freeSeats;
  final int reservedSeats;
  final int inUseSeats;
  final int awaySeats;
  final int disabledSeats;

  const RoomStats({
    required this.roomId,
    required this.roomName,
    this.floor = 0,
    this.totalSeats = 0,
    this.freeSeats = 0,
    this.reservedSeats = 0,
    this.inUseSeats = 0,
    this.awaySeats = 0,
    this.disabledSeats = 0,
  });
}

class FiltersData {
  final Map<String, String> buildings; // campusName -> buildingId
  final Map<RoomTarget, RoomInfo> roomsByName;
  final List<String> dates;

  const FiltersData({
    this.buildings = const <String, String>{},
    this.roomsByName = const <RoomTarget, RoomInfo>{},
    this.dates = const <String>[],
  });
}

class ClickCaptchaChallenge {
  final String token;
  final int wordCheckCount;
  final Uint8List targetBytes;
  final Uint8List bgBytes;

  const ClickCaptchaChallenge({
    required this.token,
    required this.wordCheckCount,
    required this.targetBytes,
    required this.bgBytes,
  });
}

class ClickCaptchaCheckResult {
  final bool ok;
  final String message;

  const ClickCaptchaCheckResult({required this.ok, this.message = ''});
}

class ReservationRecord {
  final String reservationId;
  final String receipt;
  final String onDate;
  final String seatId;
  final String status;
  final String location;
  final String begin;
  final String end;
  final String message;
  final String account;

  const ReservationRecord({
    required this.reservationId,
    this.receipt = '',
    this.onDate = '',
    this.seatId = '',
    this.status = '',
    this.location = '',
    this.begin = '',
    this.end = '',
    this.message = '',
    this.account = '',
  });

  ReservationRecord copyWithAccount(String acc) {
    return ReservationRecord(
      reservationId: reservationId,
      receipt: receipt,
      onDate: onDate,
      seatId: seatId,
      status: status,
      location: location,
      begin: begin,
      end: end,
      message: message,
      account: acc,
    );
  }
}

class CancelReservationResult {
  final bool ok;
  final String message;
  final int? totalCancelled;
  final int? allowedCancel;

  const CancelReservationResult({
    required this.ok,
    this.message = '',
    this.totalCancelled,
    this.allowedCancel,
  });
}

/// 解析 `/rest/v2/cancel/{id}` 响应（含 `totalCancelled` / `allowedCancel`）。
CancelReservationResult parseCancelReservationResponse(
  Map<String, dynamic> data,
) {
  final ok = data['status'] == 'success';
  final msg = (data['message'] ?? '').toString().trim();
  int? totalCancelled;
  int? allowedCancel;
  final payload = data['data'];
  if (payload is Map) {
    final tc = payload['totalCancelled'];
    final ac = payload['allowedCancel'];
    if (tc is num) {
      totalCancelled = tc.toInt();
    } else if (tc != null) {
      totalCancelled = int.tryParse(tc.toString());
    }
    if (ac is num) {
      allowedCancel = ac.toInt();
    } else if (ac != null) {
      allowedCancel = int.tryParse(ac.toString());
    }
  }
  return CancelReservationResult(
    ok: ok,
    message: msg,
    totalCancelled: totalCancelled,
    allowedCancel: allowedCancel,
  );
}

/// 从场馆位置文本中提取干净的自习室名称（去掉尾部 `，座位号8` / `237号` 等座号后缀）。
String extractRoomNameFromLocation(String location) {
  final trimmed = location.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final cleaned = trimmed
      .replaceAll(
        RegExp(r'[，,\s]*(座位号\s*)?([A-Za-z]-\d+-\d+|\d+\s*号?)$'),
        '',
      )
      .trim();
  return cleaned.isNotEmpty ? cleaned : trimmed;
}

class AnnouncementItem {
  final String id;
  final String title;
  final String content;
  final String date;

  const AnnouncementItem({
    required this.id,
    required this.title,
    this.content = '',
    this.date = '',
  });
}

/// 将 `/rest/v2/announce` 返回的富文本 HTML 转为整洁可读的纯文本段落。
String stripAnnouncementHtml(String raw) {
  if (raw.isEmpty) {
    return '';
  }
  var text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</\s*(p|div|li|h[1-6])\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');

  const namedEntities = <String, String>{
    '&nbsp;': ' ',
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&lsquo;': '‘',
    '&rsquo;': '’',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&amp;': '&',
  };
  namedEntities.forEach((entity, ch) {
    text = text.replaceAll(entity, ch);
  });

  text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });

  final lines = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .toList();
  final paragraphs = <String>[];
  for (final line in lines) {
    if (line.isNotEmpty) {
      paragraphs.add(line);
    }
  }
  return paragraphs.join('\n\n');
}

/// 解析 `/rest/v2/announce` 的 `data` 字段（支持辽大真实字段 `announce` / `rollText` / `noticeVal` 及列表格式）。
List<AnnouncementItem> parseAnnouncements(dynamic raw) {
  if (raw == null) {
    return const <AnnouncementItem>[];
  }
  if (raw is String) {
    final cleaned = stripAnnouncementHtml(raw);
    if (cleaned.isEmpty) {
      return const <AnnouncementItem>[];
    }
    return <AnnouncementItem>[
      AnnouncementItem(id: '0', title: '图书馆公告', content: cleaned),
    ];
  }
  final items =
      raw is List ? raw : (raw is Map ? <dynamic>[raw] : const <dynamic>[]);
  final result = <AnnouncementItem>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is Map) {
      final rawTitle =
          (item['title'] ?? item['subject'] ?? item['rollText'] ?? '')
              .toString();
      final rawContent = (item['announce'] ??
              item['content'] ??
              item['body'] ??
              item['noticeVal'] ??
              item['message'] ??
              '')
          .toString();
      final title = stripAnnouncementHtml(rawTitle);
      final content = stripAnnouncementHtml(rawContent);
      final date =
          (item['date'] ?? item['createTime'] ?? item['time'] ?? '')
              .toString()
              .trim();
      if (title.isNotEmpty || content.isNotEmpty) {
        result.add(
          AnnouncementItem(
            id: (item['id'] ?? i).toString(),
            title: title.isNotEmpty ? title : '图书馆公告',
            content: content.isNotEmpty ? content : title,
            date: date,
          ),
        );
      }
    } else if (item is String) {
      final cleaned = stripAnnouncementHtml(item);
      if (cleaned.isNotEmpty) {
        result.add(
          AnnouncementItem(
            id: i.toString(),
            title: '图书馆公告',
            content: cleaned,
          ),
        );
      }
    }
  }
  return result;
}

class HistoryRecord {
  final String id;
  final String date;
  final String begin;
  final String end;
  final String location;
  final String stat;
  final String account;

  const HistoryRecord({
    required this.id,
    this.date = '',
    this.begin = '',
    this.end = '',
    this.location = '',
    this.stat = '',
    this.account = '',
  });

  HistoryRecord copyWithAccount(String acc) {
    return HistoryRecord(
      id: id,
      date: date,
      begin: begin,
      end: end,
      location: location,
      stat: stat,
      account: acc,
    );
  }
}

class SeatTimeOption {
  final String id;
  final String value;

  const SeatTimeOption({required this.id, required this.value});
}

class SeatAvailableWindow {
  final String startId;
  final String endId;
  final String startParam;
  final String endParam;
  final List<SeatTimeOption> endOptions;

  const SeatAvailableWindow({
    required this.startId,
    required this.endId,
    required this.startParam,
    required this.endParam,
    this.endOptions = const <SeatTimeOption>[],
  });

  String get label => '$startParam — $endParam';
}

class SeatTimeProbeResult {
  final List<SeatTimeOption> starts;
  final List<SeatAvailableWindow> windows;
  final String error;

  const SeatTimeProbeResult({
    this.starts = const <SeatTimeOption>[],
    this.windows = const <SeatAvailableWindow>[],
    this.error = '',
  });

  bool get ok => error.isEmpty;
}

String formatMinutesHhmm(int totalMinutes) {
  final h = (totalMinutes ~/ 60).clamp(0, 24);
  final m = (totalMinutes % 60).clamp(0, 59);
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

int? seatTimeOptionMinutes(SeatTimeOption opt) {
  final id = opt.id.trim().toLowerCase();
  if (id == 'now' || id == '-1') {
    return null;
  }
  final parsedId = int.tryParse(id);
  if (parsedId != null && parsedId >= 0 && parsedId <= 24 * 60) {
    return parsedId;
  }
  return parseHhmmMinutes(opt.value);
}

String seatTimeOptionParam(SeatTimeOption opt) {
  final id = opt.id.trim().toLowerCase();
  if (id == 'now' || id == '-1') {
    return 'now';
  }
  final val = opt.value.trim();
  if (parseHhmmMinutes(val) != null) {
    return val;
  }
  final parsedId = int.tryParse(id);
  if (parsedId != null && parsedId >= 0 && parsedId <= 24 * 60) {
    return formatMinutesHhmm(parsedId);
  }
  return val.isNotEmpty ? val : opt.id.trim();
}

/// 贪心跳跃探测单个座位当日全部连续可约时段（如 `now — 14:00`、`20:00 — 22:00`）。
///
/// 从最早可约开始时间出发，查询其最晚可约结束时间 `maxEnd` 得到一个完整可约段，
/// 随后直接跳过落在 `[start, maxEnd)` 内部的中间开始点，跳到下一个 `>= maxEnd` 的起点继续探测。
/// 每个独立可约段仅需 1 次 `endTimesForSeat` 请求。
Future<List<SeatAvailableWindow>> discoverSeatAvailableWindows({
  required List<SeatTimeOption> starts,
  required Future<List<SeatTimeOption>> Function(String startId) fetchEndTimes,
  int maxProbes = 12,
}) async {
  if (starts.isEmpty) {
    return const <SeatAvailableWindow>[];
  }

  final seenIds = <String>{};
  final sorted = <SeatTimeOption>[];
  for (final s in starts) {
    final key = s.id.trim();
    if (key.isEmpty || !seenIds.add(key)) {
      continue;
    }
    sorted.add(s);
  }
  sorted.sort((a, b) {
    final ma = seatTimeOptionMinutes(a);
    final mb = seatTimeOptionMinutes(b);
    if (ma == null && mb == null) {
      return 0;
    }
    if (ma == null) {
      return -1;
    }
    if (mb == null) {
      return 1;
    }
    return ma.compareTo(mb);
  });

  final windows = <SeatAvailableWindow>[];
  var idx = 0;
  var probes = 0;

  while (idx < sorted.length && probes < maxProbes) {
    final st = sorted[idx];
    probes += 1;
    final ends = await fetchEndTimes(st.id);
    if (ends.isEmpty) {
      idx += 1;
      continue;
    }

    var furthest = ends.last;
    var furthestMins = seatTimeOptionMinutes(furthest);
    for (final e in ends) {
      final m = seatTimeOptionMinutes(e);
      if (m != null && (furthestMins == null || m > furthestMins)) {
        furthest = e;
        furthestMins = m;
      }
    }

    windows.add(
      SeatAvailableWindow(
        startId: st.id,
        endId: furthest.id,
        startParam: seatTimeOptionParam(st),
        endParam: seatTimeOptionParam(furthest),
        endOptions: ends,
      ),
    );

    if (furthestMins == null) {
      idx += 1;
      continue;
    }

    var nextIdx = idx + 1;
    while (nextIdx < sorted.length) {
      final nm = seatTimeOptionMinutes(sorted[nextIdx]);
      if (nm != null && nm < furthestMins) {
        nextIdx += 1;
      } else {
        break;
      }
    }
    idx = nextIdx;
  }

  return windows;
}

class BookResponse {
  final ApiOutcomeStatus status;
  final String message;
  final String seatNo;
  final String reservationId;
  final String receipt;
  final String location;
  final bool notOpenYet;
  final bool rateLimited;

  const BookResponse({
    required this.status,
    this.message = '',
    this.seatNo = '',
    this.reservationId = '',
    this.receipt = '',
    this.location = '',
    this.notOpenYet = false,
    this.rateLimited = false,
  });
}

abstract class LibSeatClient {
  ClockSync get clockSync;
  RateLimiter get rateLimiter;
  UserProfile? get profile;
  String get token;

  Future<GlobalConfig> bootstrapGlobal({CancelTokenSource? stopToken});

  Future<LoginResponse> login(
    String account,
    String password, {
    CancelTokenSource? stopToken,
    int maxAttempts = 6,
  });

  Future<bool> keepalive({CancelTokenSource? stopToken});

  Future<List<ReservationRecord>> listActiveReservations({
    CancelTokenSource? stopToken,
  });

  Future<FiltersData> fetchFilters({CancelTokenSource? stopToken});

  Future<List<RoomStats>> listRoomStats(
    String buildingId,
    String dateStr, {
    CancelTokenSource? stopToken,
  });

  Future<RoomInfo?> resolveRoom(
    String campusName,
    String roomName,
    String dateStr, {
    CancelTokenSource? stopToken,
  });

  Future<List<SeatCandidate>> listRoomSeats(
    String roomId,
    String dateStr, {
    CancelTokenSource? stopToken,
  });

  Future<ClickCaptchaChallenge> fetchClickCaptcha({
    CancelTokenSource? stopToken,
  });

  Future<ClickCaptchaCheckResult> checkClickCaptcha(
    ClickCaptchaChallenge challenge,
    List<CaptchaPoint> points, {
    CancelTokenSource? stopToken,
  });

  Future<BookResponse> freeBook({
    required String seatId,
    required String seatNo,
    required String startTime,
    required String endTime,
    required String dateStr,
    required String authid,
    bool inOpenGraceWindow = false,
    CancelTokenSource? stopToken,
  });

  Future<bool> cancelReservation(
    String reservationId, {
    CancelTokenSource? stopToken,
  });

  Future<CancelReservationResult> cancelReservationDetail(
    String reservationId, {
    CancelTokenSource? stopToken,
  });

  Future<List<AnnouncementItem>> fetchAnnouncements({
    CancelTokenSource? stopToken,
  });

  Future<List<HistoryRecord>> fetchHistory({
    int page = 1,
    int pageSize = 50,
    CancelTokenSource? stopToken,
  });

  Future<List<SeatTimeOption>> listSeatStartTimes(
    String seatId,
    String dateStr, {
    CancelTokenSource? stopToken,
  });

  Future<List<SeatTimeOption>> listSeatEndTimes(
    String seatId,
    String dateStr,
    String startId, {
    CancelTokenSource? stopToken,
  });

  void close();
}

Uint8List decodeDataUrl(String raw) {
  if (raw.isEmpty) {
    return Uint8List(0);
  }
  final idx = raw.indexOf(',');
  final payload = idx >= 0 ? raw.substring(idx + 1) : raw;
  return base64Decode(payload.replaceAll(RegExp(r'\s+'), ''));
}

bool isMaintenanceText(String? text) {
  final s = (text ?? '').trim();
  if (s.isEmpty) {
    return false;
  }
  return ProtocolConstants.maintenanceKeywords.any(s.contains);
}

String toApiTimeParam(String timeStr) {
  final s = timeStr.trim().toLowerCase();
  if (s == 'now' || s == '-1' || s == '现在') {
    return '-1';
  }
  if (RegExp(r'^\d+$').hasMatch(s)) {
    return s;
  }
  final mins = parseHhmmMinutes(timeStr);
  if (mins == null) {
    throw ArgumentError('无法解析时间参数: $timeStr');
  }
  return mins.toString();
}

SeatStatus mapSeatStatus(bool enabled, String rawStatus) {
  if (!enabled) {
    return SeatStatus.unavailable;
  }
  final st = rawStatus.toUpperCase();
  if (ProtocolConstants.freeSeatStatuses.contains(st)) {
    return SeatStatus.free;
  }
  if (ProtocolConstants.occupiedSeatStatuses.contains(st)) {
    return SeatStatus.occupied;
  }
  return SeatStatus.unavailable;
}

typedef LoginOcrFn = Future<String> Function(Uint8List imageBytes);

class HttpLibSeatClient implements LibSeatClient {
  final String baseUrl;
  final Dio _dio;
  final bool _ownsDio;
  final ClockSync _clockSync;
  final RateLimiter _rateLimiter;
  final SessionRecorder? _recorder;
  final LoginOcrFn _loginOcr;

  GlobalConfig _globalCfg;
  late String _hmacSecret;
  bool _globalBootstrapped;

  String _token = '';
  String _account = '';
  UserProfile? _profile;
  FiltersData? _filtersCache;

  HttpLibSeatClient({
    String baseUrl = ProtocolConstants.defaultBaseUrl,
    Dio? dio,
    ClockSync? clockSync,
    RateLimiter? rateLimiter,
    SessionRecorder? recorder,
    required LoginOcrFn loginOcrFn,
    GlobalConfig? globalConfig,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 8),
                sendTimeout: const Duration(seconds: 6),
                responseType: ResponseType.plain,
                validateStatus: (_) => true,
              ),
            ),
        _clockSync = clockSync ?? ClockSync(),
        _rateLimiter = rateLimiter ?? RateLimiter(),
        _recorder = recorder,
        _loginOcr = loginOcrFn,
        _globalCfg = globalConfig ??
            GlobalConfig(
              baseUrl: baseUrl.endsWith('/')
                  ? baseUrl.substring(0, baseUrl.length - 1)
                  : baseUrl,
            ),
        _globalBootstrapped = globalConfig != null {
    _hmacSecret = ApiCrypto.decryptHmacSecret(_globalCfg.numcodeEncrypted);
  }

  @override
  ClockSync get clockSync => _clockSync;

  @override
  RateLimiter get rateLimiter => _rateLimiter;

  @override
  String get token => _token;

  @override
  UserProfile? get profile => _profile;

  @override
  void close() {
    if (_ownsDio) {
      _dio.close();
    }
  }

  Map<String, String> _buildHeaders(
    String method, {
    Map<String, String>? extra,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': ProtocolConstants.defaultReferer,
      'User-Agent': ProtocolConstants.defaultUserAgent,
      'loginType': ProtocolConstants.loginType,
    };
    if (_token.isNotEmpty) {
      headers['Authorization'] = _token;
    }
    if (method.toUpperCase() == 'POST') {
      headers['Origin'] = baseUrl;
    }
    if (_globalCfg.codeEnabled) {
      headers.addAll(
        ApiCrypto.signRequestHeaders(method, hmacSecret: _hmacSecret),
      );
    }
    if (extra != null) {
      headers.addAll(extra);
    }
    return headers;
  }

  Future<Response<String>> _requestRaw(
    String stage,
    String method,
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? extraHeaders,
    Object? data,
    CancelTokenSource? stopToken,
    bool bypassRateLimit = false,
  }) async {
    if (!bypassRateLimit) {
      final allowed = await _rateLimiter.waitSlot(stopToken: stopToken);
      if (!allowed) {
        throw StateError('收到停止信号，取消 HTTP 请求');
      }
    }

    final url = '$baseUrl$path';
    final headers = _buildHeaders(method, extra: extraHeaders);
    final sw = Stopwatch()..start();
    int? statusCode;
    try {
      final resp = await _dio.request<String>(
        url,
        queryParameters: params,
        data: data,
        options: Options(
          method: method.toUpperCase(),
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );
      sw.stop();
      final rttS = sw.elapsedMicroseconds / 1000000.0;
      statusCode = resp.statusCode;

      final dateHdr = resp.headers.value('date');
      if (dateHdr != null && dateHdr.isNotEmpty) {
        _clockSync.updateFromHttpDate(
          dateHdr,
          rttSeconds: rttS,
          localReceivedUtc: DateTime.now().toUtc(),
        );
      }

      if (statusCode == 429 || (statusCode != null && statusCode >= 500)) {
        _recorder?.recordHttp(
          stage: stage,
          method: method,
          path: path,
          statusCode: statusCode,
          rttMs: rttS * 1000.0,
          reqSummary: params,
          error: 'HTTP $statusCode',
        );
        await _rateLimiter.waitBackoff(
          stopToken: stopToken,
          isRateLimit: statusCode == 429,
        );
      }
      return resp;
    } on DioException catch (exc) {
      sw.stop();
      final rttMs = sw.elapsedMicroseconds / 1000.0;
      _recorder?.recordHttp(
        stage: stage,
        method: method,
        path: path,
        statusCode: statusCode,
        rttMs: rttMs,
        reqSummary: params,
        error: 'DioException(${exc.type}): ${exc.message}',
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _requestJson(
    String stage,
    String method,
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? extraHeaders,
    Object? data,
    CancelTokenSource? stopToken,
  }) async {
    final sw = Stopwatch()..start();
    final resp = await _requestRaw(
      stage,
      method,
      path,
      params: params,
      extraHeaders: extraHeaders,
      data: data,
      stopToken: stopToken,
    );
    sw.stop();
    final rttMs = sw.elapsedMicroseconds / 1000.0;
    final code = resp.statusCode ?? 0;

    if (code == 404 || code == 405) {
      throw ProtocolDriftException(
        '端点 ${method.toUpperCase()} $path 返回 HTTP $code，协议可能已变更',
      );
    }
    if (code == 429) {
      throw RateLimitCircuitOpenException('端点 $path 返回 HTTP 429 限流');
    }

    final bodyText = resp.data ?? '';
    dynamic decoded;
    try {
      decoded = jsonDecode(bodyText);
    } catch (_) {
      final snippet = bodyText.length > 160
          ? bodyText.substring(0, 160)
          : bodyText;
      if (isMaintenanceText(snippet)) {
        return <String, dynamic>{
          'status': 'fail',
          'message': '系统维护中',
          'code': 'maintenance',
        };
      }
      _recorder?.recordHttp(
        stage: stage,
        method: method,
        path: path,
        statusCode: code,
        rttMs: rttMs,
        reqSummary: params,
        error: 'non_json: $snippet',
      );
      if (code >= 500 || isTransientBusyText(snippet)) {
        throw TransientServerBusyException(
          '端点 $path 返回瞬态非 JSON 响应 (HTTP $code): $snippet',
          isRateLimit: isTransientBusyText(snippet),
        );
      }
      throw ProtocolDriftException(
        '端点 $path 返回非 JSON 响应 (HTTP $code): $snippet',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw ProtocolDriftException(
        '端点 $path 响应体不是 JSON 对象: ${decoded.runtimeType}',
      );
    }

    final bizMsg = (decoded['message'] ?? '').toString();
    _recorder?.recordHttp(
      stage: stage,
      method: method,
      path: path,
      statusCode: code,
      rttMs: rttMs,
      reqSummary: params,
      respSummary: <String, dynamic>{
        for (final entry in decoded.entries)
          if (entry.key != 'data' ||
              entry.value is! Map ||
              (entry.value as Map).length <= 12)
            entry.key: entry.value,
      },
      bizMsg: bizMsg,
    );

    if ((decoded['code'] ?? '').toString() ==
        ProtocolConstants.tokenExpiredCode) {
      throw TokenExpiredException(
        bizMsg.isNotEmpty ? bizMsg : 'token 已过期，请重新登录',
      );
    }

    if (code >= 500) {
      throw TransientServerBusyException(
        '端点 $path 返回 HTTP $code: ${bizMsg.isNotEmpty ? bizMsg : (decoded['status'] ?? '')}',
        isRateLimit: isTransientBusyText(bizMsg),
      );
    }

    if (code >= 200 && code < 300 && !isTransientBusyText(bizMsg)) {
      _rateLimiter.recordSuccess();
    }

    return decoded;
  }

  @override
  Future<GlobalConfig> bootstrapGlobal({CancelTokenSource? stopToken}) async {
    if (_globalBootstrapped) {
      return _globalCfg;
    }

    for (final relPath in ProtocolConstants.globalJsPaths) {
      try {
        final resp = await _requestRaw(
          'bootstrap_global',
          'GET',
          relPath,
          stopToken: stopToken,
          bypassRateLimit: true,
        );
        final text = resp.data ?? '';
        if (resp.statusCode == 200 && text.isNotEmpty) {
          final parsed = parseGlobalJs(text, fallbackBaseUrl: baseUrl);
          if (parsed != null) {
            _globalCfg = parsed;
            _hmacSecret = ApiCrypto.decryptHmacSecret(parsed.numcodeEncrypted);
            _globalBootstrapped = true;
            return _globalCfg;
          }
        }
      } catch (_) {}
    }

    _globalBootstrapped = true;
    return _globalCfg;
  }

  Future<(String, Uint8List)> _fetchLoginCaptcha({
    CancelTokenSource? stopToken,
  }) async {
    final data = await _requestJson(
      'login_captcha',
      'GET',
      ProtocolConstants.epCreateLoginCaptcha,
      stopToken: stopToken,
    );
    final captchaId = (data['captchaId'] ?? '').toString().trim();
    final captchaImage = (data['captchaImage'] ?? '').toString().trim();
    if (captchaId.isEmpty || captchaImage.isEmpty) {
      final msg = (data['message'] ?? '').toString();
      if (isMaintenanceText(msg)) {
        return ('', Uint8List(0));
      }
      if (isTransientBusyText(msg)) {
        throw TransientServerBusyException('/auth/createCaptcha 暂不可用: $msg');
      }
      throw ProtocolDriftException(
        '/auth/createCaptcha 缺少 captchaId/captchaImage 字段: keys=${data.keys.toList()}',
      );
    }
    return (captchaId, decodeDataUrl(captchaImage));
  }

  Future<UserProfile> _fetchUserProfile({
    CancelTokenSource? stopToken,
  }) async {
    final data = await _requestJson(
      'user_profile',
      'GET',
      ProtocolConstants.epUser,
      params: <String, dynamic>{'token': _token},
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! Map) {
      final msg = (data['message'] ?? data['status'] ?? '').toString();
      if (isTransientBusyText(msg)) {
        throw TransientServerBusyException('/rest/v2/user 暂不可用: $msg');
      }
      throw ProtocolDriftException(
        '/rest/v2/user 响应异常: $msg',
      );
    }
    final u = Map<String, dynamic>.from(data['data'] as Map);
    final uid = u['id'];
    if (uid == null) {
      throw const ProtocolDriftException('/rest/v2/user 响应缺少 data.id');
    }
    return UserProfile(
      userId: uid.toString(),
      username: (u['username'] ?? _account).toString(),
      status: (u['status'] ?? 'NORMAL').toString(),
      violationCount: int.tryParse((u['violationCount'] ?? '0').toString()) ?? 0,
      reservationStatus: u['reservationStatus']?.toString(),
    );
  }

  @override
  Future<LoginResponse> login(
    String account,
    String password, {
    CancelTokenSource? stopToken,
    int maxAttempts = 6,
  }) async {
    _account = account;
    _token = '';
    _profile = null;
    _filtersCache = null;

    try {
      await bootstrapGlobal(stopToken: stopToken);
    } on StateError {
      return const LoginResponse(
        ok: false,
        reason: LoginFailureReason.stopped,
        message: '已取消',
      );
    }

    final encUser = ApiCrypto.encryptLoginCredential(account);
    final encPass = ApiCrypto.encryptLoginCredential(password);

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (stopToken != null && stopToken.isCancelled) {
        return const LoginResponse(
          ok: false,
          reason: LoginFailureReason.stopped,
          message: '收到停止信号',
        );
      }

      Map<String, dynamic> authData;
      try {
        final (captchaId, imgBytes) = await _fetchLoginCaptcha(
          stopToken: stopToken,
        );
        if (captchaId.isEmpty) {
          return const LoginResponse(
            ok: false,
            reason: LoginFailureReason.maintenance,
            message: '系统维护中',
          );
        }

        final code = (await _loginOcr(imgBytes)).trim();
        if (code.length != 4) {
          continue;
        }

        authData = await _requestJson(
          'login_auth',
          'GET',
          ProtocolConstants.epAuth,
          params: <String, dynamic>{'answer': code, 'captchaId': captchaId},
          extraHeaders: <String, String>{
            'username': encUser,
            'password': encPass,
          },
          stopToken: stopToken,
        );
      } on StateError {
        return const LoginResponse(
          ok: false,
          reason: LoginFailureReason.stopped,
          message: '收到停止信号',
        );
      } on ProtocolDriftException catch (exc) {
        return LoginResponse(
          ok: false,
          reason: LoginFailureReason.protocolDrift,
          message: exc.message,
        );
      } on RateLimitCircuitOpenException catch (exc) {
        return LoginResponse(
          ok: false,
          reason: LoginFailureReason.rateLimited,
          message: exc.message,
        );
      } on TransientServerBusyException catch (exc) {
        try {
          final cont = await _rateLimiter.waitBackoff(
            stopToken: stopToken,
            isRateLimit: exc.isRateLimit,
          );
          if (!cont) {
            return const LoginResponse(
              ok: false,
              reason: LoginFailureReason.stopped,
              message: '收到停止信号',
            );
          }
        } on RateLimitCircuitOpenException catch (rlExc) {
          return LoginResponse(
            ok: false,
            reason: LoginFailureReason.rateLimited,
            message: rlExc.message,
          );
        }
        continue;
      } on DioException {
        final cont = await _rateLimiter.waitBackoff(stopToken: stopToken);
        if (!cont) {
          return const LoginResponse(
            ok: false,
            reason: LoginFailureReason.stopped,
            message: '收到停止信号',
          );
        }
        continue;
      }

      final msg = (authData['message'] ?? '').toString();
      if (isMaintenanceText(msg)) {
        return LoginResponse(
          ok: false,
          reason: LoginFailureReason.maintenance,
          message: msg.isNotEmpty ? msg : '系统维护中',
        );
      }

      if (authData['status'] == 'success') {
        final payload = authData['data'];
        if (payload is! Map ||
            (payload['token'] ?? '').toString().trim().isEmpty) {
          return const LoginResponse(
            ok: false,
            reason: LoginFailureReason.protocolDrift,
            message: '/rest/auth 成功响应缺少 data.token',
          );
        }
        _token = payload['token'].toString();
        String? profileBusyErr;
        for (var profTry = 1; profTry <= 3; profTry++) {
          try {
            _profile = await _fetchUserProfile(stopToken: stopToken);
            profileBusyErr = null;
            break;
          } on ProtocolDriftException catch (exc) {
            return LoginResponse(
              ok: false,
              reason: LoginFailureReason.protocolDrift,
              message: exc.message,
            );
          } on TransientServerBusyException catch (exc) {
            profileBusyErr = exc.message;
            try {
              final cont = await _rateLimiter.waitBackoff(
                stopToken: stopToken,
                isRateLimit: exc.isRateLimit,
              );
              if (!cont) {
                return const LoginResponse(
                  ok: false,
                  reason: LoginFailureReason.stopped,
                  message: '收到停止信号',
                );
              }
            } on RateLimitCircuitOpenException catch (rlExc) {
              return LoginResponse(
                ok: false,
                reason: LoginFailureReason.rateLimited,
                message: rlExc.message,
              );
            }
          } catch (exc) {
            return LoginResponse(
              ok: false,
              reason: LoginFailureReason.networkError,
              message: exc.toString(),
            );
          }
        }
        if (profileBusyErr != null) {
          return LoginResponse(
            ok: false,
            reason: LoginFailureReason.networkError,
            message: profileBusyErr,
          );
        }

        return LoginResponse(
          ok: true,
          reason: LoginFailureReason.ok,
          token: _token,
          profile: _profile,
          message: '登录成功',
        );
      }

      if (msg.contains('验证码')) {
        continue;
      }
      if (const <String>['密码', '用户名', '账号', '不存在', '锁定']
          .any(msg.contains)) {
        return LoginResponse(
          ok: false,
          reason: LoginFailureReason.badCredentials,
          message: msg,
        );
      }

      final cont = await _rateLimiter.waitBackoff(stopToken: stopToken);
      if (!cont) {
        return const LoginResponse(
          ok: false,
          reason: LoginFailureReason.stopped,
          message: '收到停止信号',
        );
      }
    }

    return LoginResponse(
      ok: false,
      reason: LoginFailureReason.captchaFailed,
      message: '登录连续 $maxAttempts 次未通过',
    );
  }

  @override
  Future<bool> keepalive({CancelTokenSource? stopToken}) async {
    try {
      final path = _token.isNotEmpty
          ? ProtocolConstants.epUser
          : ProtocolConstants.epAvailSeats;
      final params = _token.isNotEmpty
          ? <String, dynamic>{'token': _token}
          : null;
      final data = await _requestJson(
        'keepalive',
        'GET',
        path,
        params: params,
        stopToken: stopToken,
      );
      return data['status'] == 'success';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ReservationRecord>> listActiveReservations({
    CancelTokenSource? stopToken,
  }) async {
    final data = await _requestJson(
      'active_reservations',
      'GET',
      ProtocolConstants.epUserReservations,
      params: <String, dynamic>{'token': _token},
      stopToken: stopToken,
    );
    if (data['status'] != 'success') {
      return const <ReservationRecord>[];
    }
    final raw = data['data'];
    if (raw == null) {
      return const <ReservationRecord>[];
    }
    final list = raw is List ? raw : (raw is Map ? <dynamic>[raw] : <dynamic>[]);
    final records = <ReservationRecord>[];
    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      records.add(
        ReservationRecord(
          reservationId: (item['id'] ?? '').toString(),
          receipt: (item['receipt'] ?? '').toString(),
          onDate: (item['onDate'] ?? '').toString(),
          seatId: (item['seatId'] ?? '').toString(),
          status: (item['status'] ?? '').toString(),
          location: (item['location'] ?? '').toString(),
          begin: (item['begin'] ?? '').toString(),
          end: (item['end'] ?? '').toString(),
          message: (item['message'] ?? '').toString(),
        ),
      );
    }
    return records;
  }

  @override
  Future<FiltersData> fetchFilters({CancelTokenSource? stopToken}) async {
    if (_filtersCache != null) {
      return _filtersCache!;
    }

    final data = await _requestJson(
      'free_filters',
      'GET',
      ProtocolConstants.epFreeFilters,
      params: <String, dynamic>{'token': _token},
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! Map) {
      final msg = (data['message'] ?? data['status'] ?? '').toString();
      if (isTransientBusyText(msg)) {
        throw TransientServerBusyException('/rest/v2/free/filters 暂不可用: $msg');
      }
      throw ProtocolDriftException(
        '/rest/v2/free/filters 响应异常: $msg',
      );
    }
    final payload = Map<String, dynamic>.from(data['data'] as Map);

    final buildings = <String, String>{};
    final idToCampus = <String, String>{};
    final rawBuildings = payload['buildings'];
    if (rawBuildings is List) {
      for (final row in rawBuildings) {
        if (row is List && row.length >= 2) {
          final bid = row[0].toString();
          final cname = row[1].toString().trim();
          buildings[cname] = bid;
          idToCampus[bid] = cname;
        }
      }
    }

    final roomsByName = <RoomTarget, RoomInfo>{};
    final rawRooms = payload['rooms'];
    if (rawRooms is List) {
      for (final row in rawRooms) {
        if (row is List && row.length >= 3) {
          final rid = row[0].toString();
          final rname = row[1].toString().trim();
          final bid = row[2].toString();
          final cname = idToCampus[bid] ?? '';
          final info = RoomInfo(
            campusName: cname,
            roomName: rname,
            buildingId: bid,
            roomId: rid,
          );
          roomsByName[RoomTarget(cname, rname)] = info;
        }
      }
    }

    final rawDates = payload['dates'];
    final dates = rawDates is List
        ? rawDates
            .where((d) => d != null && d.toString().isNotEmpty)
            .map((d) => d.toString())
            .toList(growable: false)
        : const <String>[];

    _filtersCache = FiltersData(
      buildings: buildings,
      roomsByName: roomsByName,
      dates: dates,
    );
    return _filtersCache!;
  }

  @override
  Future<List<RoomStats>> listRoomStats(
    String buildingId,
    String dateStr, {
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epRoomStats(buildingId, dateStr);
    final data = await _requestJson(
      'room_stats',
      'GET',
      path,
      params: <String, dynamic>{
        'buildingId': buildingId,
        'date': dateStr,
        'token': _token,
      },
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! List) {
      final msg = (data['message'] ?? data['status'] ?? '').toString();
      if (isTransientBusyText(msg)) {
        throw TransientServerBusyException('$path 暂不可用: $msg');
      }
      throw ProtocolDriftException('$path 响应异常: $msg');
    }

    final stats = <RoomStats>[];
    for (final item in data['data'] as List) {
      if (item is! Map) {
        continue;
      }
      stats.add(
        RoomStats(
          roomId: (item['roomId'] ?? '').toString(),
          roomName: (item['room'] ?? '').toString().trim(),
          floor: int.tryParse((item['floor'] ?? '0').toString()) ?? 0,
          totalSeats: int.tryParse((item['totalSeats'] ?? '0').toString()) ?? 0,
          freeSeats: int.tryParse((item['free'] ?? '0').toString()) ?? 0,
          reservedSeats:
              int.tryParse((item['reserved'] ?? '0').toString()) ?? 0,
          inUseSeats: int.tryParse((item['inUse'] ?? '0').toString()) ?? 0,
          awaySeats: int.tryParse((item['away'] ?? '0').toString()) ?? 0,
          disabledSeats:
              int.tryParse((item['disableSeat'] ?? '0').toString()) ?? 0,
        ),
      );
    }
    return stats;
  }

  @override
  Future<RoomInfo?> resolveRoom(
    String campusName,
    String roomName,
    String dateStr, {
    CancelTokenSource? stopToken,
  }) async {
    final filters = await fetchFilters(stopToken: stopToken);
    var targetC = campusName.trim();
    final targetR = roomName.trim();

    final exact = filters.roomsByName[RoomTarget(targetC, targetR)];
    if (exact != null) {
      return exact;
    }

    var bid = filters.buildings[targetC];
    if (bid == null) {
      for (final entry in filters.buildings.entries) {
        if (targetC.isNotEmpty &&
            (targetC.contains(entry.key) || entry.key.contains(targetC))) {
          bid = entry.value;
          targetC = entry.key;
          break;
        }
      }
    }

    final candidateBids =
        bid != null ? <String>[bid] : filters.buildings.values.toList();
    for (final bId in candidateBids) {
      final stats = await listRoomStats(bId, dateStr, stopToken: stopToken);
      for (final st in stats) {
        if (st.roomName == targetR ||
            (targetR.isNotEmpty && st.roomName.contains(targetR))) {
          var resolvedCampus = targetC;
          for (final entry in filters.buildings.entries) {
            if (entry.value == bId) {
              resolvedCampus = entry.key;
              break;
            }
          }
          return RoomInfo(
            campusName: resolvedCampus,
            roomName: st.roomName,
            buildingId: bId,
            roomId: st.roomId,
          );
        }
      }
    }

    for (final entry in filters.roomsByName.entries) {
      final rn = entry.key.room;
      if (targetR.isNotEmpty && (rn == targetR || rn.contains(targetR))) {
        return entry.value;
      }
    }
    return null;
  }

  @override
  Future<List<SeatCandidate>> listRoomSeats(
    String roomId,
    String dateStr, {
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epRoomLayout(roomId, dateStr);
    final data = await _requestJson(
      'room_layout',
      'GET',
      path,
      params: <String, dynamic>{
        'id': roomId,
        'date': dateStr,
        'token': _token,
      },
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! Map) {
      final msg = (data['message'] ?? data['status'] ?? '').toString();
      if (isTransientBusyText(msg)) {
        throw TransientServerBusyException('$path 暂不可用: $msg');
      }
      throw ProtocolDriftException('$path 响应异常: $msg');
    }
    final payload = data['data'] as Map;
    final layout = payload['layout'];
    if (layout is! Map) {
      throw ProtocolDriftException('$path 响应缺少 data.layout 字典');
    }

    final seats = <SeatCandidate>[];
    for (final node in layout.values) {
      if (node is! Map || node['type'] != 'seat') {
        continue;
      }
      final sid = node['id'];
      final rawName = (node['name'] ?? '').toString().trim();
      if (sid == null || rawName.isEmpty) {
        continue;
      }
      final enabled = node['enabled'] is bool ? node['enabled'] as bool : true;
      final status = mapSeatStatus(enabled, (node['status'] ?? '').toString());
      seats.add(
        SeatCandidate(
          seatNo: normalizeSeatNo(rawName),
          seatId: sid.toString(),
          roomId: roomId,
          status: status,
        ),
      );
    }
    return seats;
  }

  @override
  Future<ClickCaptchaChallenge> fetchClickCaptcha({
    CancelTokenSource? stopToken,
  }) async {
    final username = _profile?.username ?? _account;
    final path = ProtocolConstants.epClickCaptcha(_token);
    final data = await _requestJson(
      'click_captcha_fetch',
      'POST',
      path,
      params: <String, dynamic>{'username': username},
      stopToken: stopToken,
    );
    final statusUpper = (data['status'] ?? '').toString().toUpperCase();
    if (statusUpper != 'OK') {
      final msg = (data['message'] ?? data['status'] ?? '').toString();
      if (isTransientBusyText(msg) || statusUpper == 'FAIL') {
        throw TransientServerBusyException(
          '/cap/captcha 暂不可用: $msg',
          isRateLimit: true,
        );
      }
      throw ProtocolDriftException('/cap/captcha 返回非 OK: $msg');
    }
    final capToken = (data['token'] ?? '').toString().trim();
    final bgRaw = (data['image'] ?? '').toString();
    final targetRaw = (data['wordImage'] ?? '').toString();
    if (capToken.isEmpty || bgRaw.isEmpty || targetRaw.isEmpty) {
      throw ProtocolDriftException(
        '/cap/captcha 缺少必需字段: keys=${data.keys.toList()}',
      );
    }
    final wordCount =
        int.tryParse((data['wordCheckCount'] ?? '1').toString()) ?? 1;
    return ClickCaptchaChallenge(
      token: capToken,
      wordCheckCount: wordCount,
      targetBytes: decodeDataUrl(targetRaw),
      bgBytes: decodeDataUrl(bgRaw),
    );
  }

  @override
  Future<ClickCaptchaCheckResult> checkClickCaptcha(
    ClickCaptchaChallenge challenge,
    List<CaptchaPoint> points, {
    CancelTokenSource? stopToken,
  }) async {
    final username = _profile?.username ?? _account;
    final userId = _profile?.userId ?? '';
    final encoded = ApiCrypto.encodeCaptchaPoints(points);
    final params = <String, dynamic>{
      'a': encoded,
      'token': challenge.token,
      'username': username,
      if (userId.isNotEmpty) 'userId': userId,
    };

    final data = await _requestJson(
      'click_captcha_check',
      'GET',
      ProtocolConstants.epCheckCaptcha,
      params: params,
      stopToken: stopToken,
    );
    final ok = (data['status'] ?? '').toString().toUpperCase() == 'OK';
    return ClickCaptchaCheckResult(
      ok: ok,
      message: (data['message'] ?? data['status'] ?? '').toString(),
    );
  }

  @override
  Future<BookResponse> freeBook({
    required String seatId,
    required String seatNo,
    required String startTime,
    required String endTime,
    required String dateStr,
    required String authid,
    bool inOpenGraceWindow = false,
    CancelTokenSource? stopToken,
  }) async {
    final username = _profile?.username ?? _account;
    final userId = _profile?.userId ?? '';
    final startParam = toApiTimeParam(startTime);
    final endParam = toApiTimeParam(endTime);

    final formData = FormData.fromMap(<String, dynamic>{
      'startTime': startParam,
      'endTime': endParam,
      'seat': seatId,
      'date': dateStr,
      'userId': userId,
      'username': username,
      'authid': authid,
    });

    final data = await _requestJson(
      'free_book',
      'POST',
      ProtocolConstants.epFreeBook,
      params: <String, dynamic>{'token': _token},
      data: formData,
      stopToken: stopToken,
    );

    if (data['status'] == 'success') {
      final payload = data['data'] is Map
          ? Map<String, dynamic>.from(data['data'] as Map)
          : const <String, dynamic>{};
      return BookResponse(
        status: ApiOutcomeStatus.success,
        message: (data['message'] ?? '预约成功').toString(),
        seatNo: seatNo,
        reservationId: (payload['id'] ?? '').toString(),
        receipt: (payload['receipt'] ?? '').toString(),
        location: (payload['location'] ?? '').toString(),
      );
    }

    final msg = (data['message'] ?? '').toString();
    final classified = classifyApiBookingResult(
      msg,
      inOpenGraceWindow: inOpenGraceWindow,
    );
    return BookResponse(
      status: classified.status,
      message: msg.isNotEmpty
          ? msg
          : (data['status'] ?? '预约失败').toString(),
      seatNo: seatNo,
      notOpenYet: classified.notOpenYet,
      rateLimited: classified.rateLimited,
    );
  }

  @override
  Future<CancelReservationResult> cancelReservationDetail(
    String reservationId, {
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epCancel(reservationId);
    final data = await _requestJson(
      'cancel_reservation',
      'GET',
      path,
      params: <String, dynamic>{'id': reservationId, 'token': _token},
      stopToken: stopToken,
    );
    return parseCancelReservationResponse(data);
  }

  @override
  Future<bool> cancelReservation(
    String reservationId, {
    CancelTokenSource? stopToken,
  }) async {
    final res = await cancelReservationDetail(
      reservationId,
      stopToken: stopToken,
    );
    return res.ok;
  }

  @override
  Future<List<AnnouncementItem>> fetchAnnouncements({
    CancelTokenSource? stopToken,
  }) async {
    final data = await _requestJson(
      'announcements',
      'GET',
      ProtocolConstants.epAnnounce,
      params: _token.isNotEmpty ? <String, dynamic>{'token': _token} : null,
      stopToken: stopToken,
    );
    if (data['status'] != 'success') {
      return const <AnnouncementItem>[];
    }
    return parseAnnouncements(data['data']);
  }

  @override
  Future<List<HistoryRecord>> fetchHistory({
    int page = 1,
    int pageSize = 50,
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epHistory(page, pageSize);
    final data = await _requestJson(
      'history',
      'GET',
      path,
      params: <String, dynamic>{
        'page': page,
        'pageSize': pageSize,
        'token': _token,
      },
      stopToken: stopToken,
    );
    if (data['status'] != 'success') {
      return const <HistoryRecord>[];
    }
    final payload = data['data'];
    final rawList = payload is Map
        ? (payload['reservations'] ?? payload['list'] ?? payload['records'])
        : payload;
    if (rawList is! List) {
      return const <HistoryRecord>[];
    }
    final result = <HistoryRecord>[];
    for (final item in rawList) {
      if (item is! Map) {
        continue;
      }
      result.add(
        HistoryRecord(
          id: (item['id'] ?? '').toString(),
          date: (item['date'] ?? item['onDate'] ?? '').toString(),
          begin: (item['begin'] ?? '').toString(),
          end: (item['end'] ?? '').toString(),
          location: (item['loc'] ?? item['location'] ?? '').toString(),
          stat: (item['stat'] ?? item['status'] ?? '').toString(),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<SeatTimeOption>> listSeatStartTimes(
    String seatId,
    String dateStr, {
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epStartTimes(seatId, dateStr);
    final data = await _requestJson(
      'seat_start_times',
      'GET',
      path,
      params: <String, dynamic>{
        'seatId': seatId,
        'date': dateStr,
        'token': _token,
      },
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! Map) {
      return const <SeatTimeOption>[];
    }
    final raw = (data['data'] as Map)['startTimes'];
    if (raw is! List) {
      return const <SeatTimeOption>[];
    }
    return <SeatTimeOption>[
      for (final x in raw)
        if (x is Map)
          SeatTimeOption(
            id: (x['id'] ?? '').toString(),
            value: (x['value'] ?? '').toString(),
          ),
    ];
  }

  @override
  Future<List<SeatTimeOption>> listSeatEndTimes(
    String seatId,
    String dateStr,
    String startId, {
    CancelTokenSource? stopToken,
  }) async {
    final path = ProtocolConstants.epEndTimes(seatId, dateStr, startId);
    final data = await _requestJson(
      'seat_end_times',
      'GET',
      path,
      params: <String, dynamic>{
        'id': seatId,
        'date': dateStr,
        'start': startId,
        'token': _token,
      },
      stopToken: stopToken,
    );
    if (data['status'] != 'success' || data['data'] is! Map) {
      return const <SeatTimeOption>[];
    }
    final raw = (data['data'] as Map)['endTimes'];
    if (raw is! List) {
      return const <SeatTimeOption>[];
    }
    return <SeatTimeOption>[
      for (final x in raw)
        if (x is Map)
          SeatTimeOption(
            id: (x['id'] ?? '').toString(),
            value: (x['value'] ?? '').toString(),
          ),
    ];
  }
}
