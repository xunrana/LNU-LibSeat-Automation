/// LibSeat 纯 API 协议单一来源（端点、常量、Global 动态引导与异常定义）。
///
/// 与 Python 端 `core/protocol.py` 完全对齐。
library;

class ProtocolConstants {
  ProtocolConstants._();

  static const String defaultBaseUrl = 'http://libseat.lnu.edu.cn';
  static const String defaultReferer = 'http://libseat.lnu.edu.cn/libseat/';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0';

  static const String loginType = 'PC';
  static const String aesKey = 'server_date_time';
  static const String aesIv = 'client_date_time';
  static const String loginCredSuffix = '_encrypt';
  static const bool defaultCodeEnabled = true;
  static const String defaultNumcodeEncrypted = 'cDf+jadFUWncEn536MXItw==';

  static const String tokenExpiredCode = '12';

  static const List<String> globalJsPaths = <String>[
    '/libseat/static/baseUrl.js',
    '/libseat/baseUrl.js',
  ];

  // 全量 API 路径常量（对应前端模块 Apws）
  static const String epAnnounce = '/rest/v2/announce';
  static const String epAvailSeats = '/rest/v2/availSeats';
  static const String epSettings = '/rest/v2/settings';
  static const String epCreateLoginCaptcha = '/auth/createCaptcha';
  static const String epAuth = '/rest/auth';
  static const String epUser = '/rest/v2/user';
  static const String epUserReservations = '/rest/v2/user/reservations';
  static const String epFreeFilters = '/rest/v2/free/filters';
  static const String epCheckCaptcha = '/cap/checkCaptcha';
  static const String epFreeBook = '/rest/v2/freeBook';

  static String epRoomFloors(String buildingId) =>
      '/rest/v2/room/floors/$buildingId';
  static String epRoomStats(String buildingId, String date) =>
      '/rest/v2/room/stats2/$buildingId/$date';
  static String epRoomLayout(String roomId, String date) =>
      '/rest/v2/room/layoutByDate/$roomId/$date';
  static String epStartTimes(String seatId, String date) =>
      '/rest/v2/startTimesForSeat/$seatId/$date';
  static String epEndTimes(String seatId, String date, String start) =>
      '/rest/v2/endTimesForSeat/$seatId/$date/$start';
  static String epClickCaptcha(String token) => '/cap/captcha/$token';
  static String epHistory(int page, int pageSize) =>
      '/rest/v2/history/$page/$pageSize';
  static String epCancel(String reservationId) =>
      '/rest/v2/cancel/$reservationId';

  static const Set<String> freeSeatStatuses = <String>{'FREE', 'YESSELECT'};
  static const Set<String> occupiedSeatStatuses = <String>{
    'IN_USE',
    'BOOKED',
    'FULL',
    'AWAY',
  };
  static const Set<String> unavailableSeatStatuses = <String>{'NOSELECT'};

  static const List<String> maintenanceKeywords = <String>[
    '系统维护中',
    '系统维护',
    '维护中',
  ];

  /// 高峰期瞬态繁忙/限流关键词（应退避重试，绝不能误判为协议漂移停机）。
  static const List<String> transientBusyKeywords = <String>[
    '系统繁忙',
    '服务器繁忙',
    '繁忙',
    '操作过于频繁',
    '请求过于频繁',
    '请稍后',
    '请稍候',
    '请重试',
    'too busy',
    'try again',
  ];
}

/// 判断服务端反馈是否属于高峰瞬态繁忙/频控（排除维护提示）。
bool isTransientBusyText(String? text) {
  final cleaned = (text ?? '').trim();
  if (cleaned.isEmpty) {
    return false;
  }
  if (ProtocolConstants.maintenanceKeywords.any(cleaned.contains)) {
    return false;
  }
  final lowered = cleaned.toLowerCase();
  return ProtocolConstants.transientBusyKeywords.any(lowered.contains);
}

/// 服务端响应结构/鉴权协议与已知契约不匹配时抛出，触发立即熔断停止。
class ProtocolDriftException implements Exception {
  final String message;
  const ProtocolDriftException(this.message);

  @override
  String toString() => 'ProtocolDriftException: $message';
}

/// 服务端瞬态繁忙/网关 5xx/验证码池拥堵等可恢复异常，应退避重试而非熔断停机。
class TransientServerBusyException implements Exception {
  final String message;
  final bool isRateLimit;
  const TransientServerBusyException(
    this.message, {
    this.isRateLimit = true,
  });

  @override
  String toString() => 'TransientServerBusyException: $message';
}

/// 服务端返回 code == '12'（token 已过期）时抛出，供上层按需重登。
class TokenExpiredException implements Exception {
  final String message;
  const TokenExpiredException([this.message = 'token 已过期，请重新登录']);

  @override
  String toString() => 'TokenExpiredException: $message';
}

/// 前端 `baseUrl.js` 暴露的全局签名配置。
class GlobalConfig {
  final String baseUrl;
  final bool codeEnabled;
  final String numcodeEncrypted;

  const GlobalConfig({
    this.baseUrl = ProtocolConstants.defaultBaseUrl,
    this.codeEnabled = ProtocolConstants.defaultCodeEnabled,
    this.numcodeEncrypted = ProtocolConstants.defaultNumcodeEncrypted,
  });
}

final RegExp _reBaseUrl = RegExp(r'''BASEURL\s*:\s*["']([^"']+)["']''');
final RegExp _reCode = RegExp(r'CODE\s*:\s*(true|false)', caseSensitive: false);
final RegExp _reNumcode = RegExp(r'''NUMCODE\s*:\s*["']([^"']+)["']''');

/// 从前端 `baseUrl.js` 文本解析 `Global.BASEURL / CODE / NUMCODE`。
GlobalConfig? parseGlobalJs(
  String jsText, {
  String fallbackBaseUrl = ProtocolConstants.defaultBaseUrl,
}) {
  if (jsText.isEmpty || !jsText.contains('Global')) {
    return null;
  }

  final mNum = _reNumcode.firstMatch(jsText);
  final mCode = _reCode.firstMatch(jsText);
  if (mNum == null && mCode == null) {
    return null;
  }

  final mBase = _reBaseUrl.firstMatch(jsText);
  final rawBase = mBase != null ? mBase.group(1)! : fallbackBaseUrl;
  final baseUrl = rawBase.endsWith('/')
      ? rawBase.substring(0, rawBase.length - 1)
      : rawBase;
  final codeEnabled = mCode != null
      ? mCode.group(1)!.toLowerCase() == 'true'
      : ProtocolConstants.defaultCodeEnabled;
  final numcode = mNum != null
      ? mNum.group(1)!
      : ProtocolConstants.defaultNumcodeEncrypted;

  return GlobalConfig(
    baseUrl: baseUrl,
    codeEnabled: codeEnabled,
    numcodeEncrypted: numcode,
  );
}
