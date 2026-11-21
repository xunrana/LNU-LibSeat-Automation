/// LibSeat 纯 API 加解密与请求签名工具（纯函数，无网络副作用）。
///
/// 与 Python 端 `core/api_crypto.py` 及前端模块 `AOJh`（AES-128-CBC + PKCS7）、
/// `6r5/`（HMAC-SHA256 请求头签名）逐字节一致。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:uuid/uuid.dart';

import 'protocol.dart';

class CaptchaPoint {
  final int x;
  final int y;
  const CaptchaPoint(this.x, this.y);

  Map<String, int> toJson() => <String, int>{'x': x, 'y': y};

  @override
  String toString() => '($x, $y)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CaptchaPoint && other.x == x && other.y == y);

  @override
  int get hashCode => Object.hash(x, y);
}

class ApiCrypto {
  ApiCrypto._();

  static const Uuid _uuid = Uuid();

  /// 使用 AES-128-CBC + PKCS7 加密 UTF-8 文本，返回标准 Base64 字符串。
  static String encryptAesB64(
    String text, {
    String key = ProtocolConstants.aesKey,
    String iv = ProtocolConstants.aesIv,
  }) {
    final aesKey = enc.Key.fromUtf8(key);
    final aesIv = enc.IV.fromUtf8(iv);
    final encrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    return encrypter.encrypt(text, iv: aesIv).base64;
  }

  /// 解密标准 Base64 编码的 AES-128-CBC + PKCS7 密文，返回 UTF-8 明文。
  static String decryptAesB64(
    String b64Text, {
    String key = ProtocolConstants.aesKey,
    String iv = ProtocolConstants.aesIv,
  }) {
    final aesKey = enc.Key.fromUtf8(key);
    final aesIv = enc.IV.fromUtf8(iv);
    final encrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    return encrypter.decrypt64(b64Text, iv: aesIv);
  }

  /// 加密登录凭据（学号或密码），附加前端约定的 `_encrypt` 后缀。
  static String encryptLoginCredential(
    String value, {
    String key = ProtocolConstants.aesKey,
    String iv = ProtocolConstants.aesIv,
  }) {
    if (value.endsWith(ProtocolConstants.loginCredSuffix)) {
      return value;
    }
    return encryptAesB64(value, key: key, iv: iv) +
        ProtocolConstants.loginCredSuffix;
  }

  /// 解密 `Global.NUMCODE` 得到 HMAC-SHA256 签名密钥明文。
  static String decryptHmacSecret([
    String numcodeEncrypted = ProtocolConstants.defaultNumcodeEncrypted,
  ]) {
    return decryptAesB64(numcodeEncrypted);
  }

  /// 生成 `X-request-id` / `X-request-date` / `X-hmac-request-key` 签名头。
  ///
  /// 原文格式：`"seat::" + uuid4 + "::" + timestamp_ms + "::" + method.toUpperCase()`
  static Map<String, String> signRequestHeaders(
    String method, {
    required String hmacSecret,
    String? requestId,
    int? timestampMs,
  }) {
    final reqId = requestId ?? _uuid.v4();
    final tsMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final payload = 'seat::$reqId::$tsMs::${method.toUpperCase()}';
    final hmac = Hmac(sha256, utf8.encode(hmacSecret));
    final signature = hmac.convert(utf8.encode(payload)).toString();
    return <String, String>{
      'X-request-id': reqId,
      'X-request-date': tsMs.toString(),
      'X-hmac-request-key': signature,
    };
  }

  /// 把点选坐标序列编码为 `/cap/checkCaptcha` 的 `a` 参数（紧凑 JSON + Base64）。
  static String encodeCaptchaPoints(List<CaptchaPoint> points) {
    final list = points
        .map((p) => <String, int>{'x': p.x, 'y': p.y})
        .toList(growable: false);
    final compactJson = jsonEncode(list);
    return base64Encode(utf8.encode(compactJson));
  }
}
