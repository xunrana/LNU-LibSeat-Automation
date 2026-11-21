/// 预约结果文本分类（纯函数，无网络/UI 依赖）。
///
/// 与 Python 端 `logic/result_classifier.py` 100% 对齐。
library;

enum ApiOutcomeStatus {
  success,
  stop,
  blacklist,
  retryCaptcha,
  seatTaken,
  failed;

  String get wireName {
    switch (this) {
      case ApiOutcomeStatus.success:
        return 'success';
      case ApiOutcomeStatus.stop:
        return 'stop';
      case ApiOutcomeStatus.blacklist:
        return 'blacklist';
      case ApiOutcomeStatus.retryCaptcha:
        return 'retry_captcha';
      case ApiOutcomeStatus.seatTaken:
        return 'seat_taken';
      case ApiOutcomeStatus.failed:
        return 'failed';
    }
  }
}

class ApiBookingClassification {
  final ApiOutcomeStatus status;
  final bool notOpenYet;
  final bool rateLimited;

  const ApiBookingClassification({
    required this.status,
    this.notOpenYet = false,
    this.rateLimited = false,
  });
}

final RegExp _blacklistFeedbackRe = RegExp(
  r'对不起[，,]?您已被加入黑名单[，,]?'
  r'预约权限将在\d{4}年\d{1,2}月\d{1,2}日恢复[。.!！]?'
  r'原因[:：]7天内迟到违约[，,]超过3次[，,]加入黑名单7天',
);

const List<String> _seatTakenKeywords = <String>[
  '已被他人预约',
  '座位已被预约',
  '该座位不可用',
  '没有可用时间',
  '没有可约时间',
  '已被占用',
];

const List<String> _rateLimitKeywords = <String>[
  '操作过于频繁',
  '请求过于频繁',
  '系统繁忙',
];

bool isBlacklistFeedback(String? resultText) {
  final text = (resultText ?? '').replaceAll(RegExp(r'\s+'), '');
  if (text.isEmpty) {
    return false;
  }
  return _blacklistFeedbackRe.hasMatch(text);
}

bool isStopBookingFeedback(String? resultText) {
  var text = (resultText ?? '').replaceAll(RegExp(r'\s+'), '');
  if (text.isEmpty) {
    return false;
  }
  text = text
      .replaceAll('～', '~')
      .replaceAll('〜', '~')
      .replaceAll('-', '~');
  return text.contains('系统可预约时间') &&
      text.contains('06:30') &&
      text.contains('22:30');
}

bool isSeatTakenFeedback(String? resultText) {
  final text = resultText ?? '';
  return _seatTakenKeywords.any(text.contains);
}

bool isRateLimitedFeedback(String? resultText) {
  final text = resultText ?? '';
  return _rateLimitKeywords.any(text.contains);
}

ApiBookingClassification classifyApiBookingResult(
  String? resultText, {
  bool inOpenGraceWindow = false,
}) {
  final text = resultText ?? '';

  if (isStopBookingFeedback(text)) {
    if (inOpenGraceWindow) {
      return const ApiBookingClassification(
        status: ApiOutcomeStatus.retryCaptcha,
        notOpenYet: true,
      );
    }
    return const ApiBookingClassification(status: ApiOutcomeStatus.stop);
  }

  if (text.contains('预约成功')) {
    return const ApiBookingClassification(status: ApiOutcomeStatus.success);
  }
  if (text.contains('有效预约') ||
      text.contains('每日限制') ||
      text.contains('部分读者')) {
    return const ApiBookingClassification(status: ApiOutcomeStatus.stop);
  }

  if (isBlacklistFeedback(text)) {
    return const ApiBookingClassification(status: ApiOutcomeStatus.blacklist);
  }

  if (isRateLimitedFeedback(text)) {
    return const ApiBookingClassification(
      status: ApiOutcomeStatus.retryCaptcha,
      rateLimited: true,
    );
  }

  if (text.contains('验证码错误') ||
      text.contains('请稍后') ||
      text.contains('请重试')) {
    return const ApiBookingClassification(
      status: ApiOutcomeStatus.retryCaptcha,
    );
  }

  if (isSeatTakenFeedback(text)) {
    return const ApiBookingClassification(status: ApiOutcomeStatus.seatTaken);
  }

  return const ApiBookingClassification(status: ApiOutcomeStatus.failed);
}
