/// 纯 API 会话级可观测性与脱敏诊断产物记录器。
///
/// 与 Python 端 `core/session_recorder.py` 完全对齐：
/// 1. `http_trace.jsonl` —— 强制白名单脱敏后的 HTTP 事务流水（绝不落盘密码/Token/Cookie）
/// 2. `<prio>_<seat>_<retry>_captcha_<ts>.png` —— 拼合 target + bg + YOLO 绿圈 + 点击红点
/// 3. `抢座顺序.txt` —— 首选、实时空座统计与尝试队列清单
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'api_crypto.dart';

final RegExp _sensitiveKeyRe = RegExp(
  r'(pass|passwd|pwd|secret|token|cookie|authorization|auth|credential|session|aes|sign|smtp_pass)',
  caseSensitive: false,
);
final RegExp _opaqueLongRe = RegExp(r'^[A-Za-z0-9+/=_-]{65,}$');
final RegExp _base64DataUrlRe = RegExp(
  r'^data:image/[a-z0-9+.-]+;base64,',
  caseSensitive: false,
);

/// 递归脱敏任意结构化对象，确保密码/Token/Cookie/大段 base64 绝不落盘。
dynamic sanitizeForTrace(
  dynamic obj, {
  String parentKey = '',
  int depth = 0,
}) {
  if (depth > 6) {
    return '<TRUNCATED>';
  }
  if (obj is Map) {
    final result = <String, dynamic>{};
    for (final entry in obj.entries) {
      final k = entry.key.toString();
      result[k] = sanitizeForTrace(
        entry.value,
        parentKey: k,
        depth: depth + 1,
      );
    }
    return result;
  }
  if (obj is List) {
    final items = obj
        .take(20)
        .map((x) => sanitizeForTrace(x, parentKey: parentKey, depth: depth + 1))
        .toList();
    if (obj.length > 20) {
      items.add('<... ${obj.length - 20} more>');
    }
    return items;
  }
  if (obj is Uint8List) {
    return '<BYTES len=${obj.length}>';
  }
  if (parentKey.isNotEmpty && _sensitiveKeyRe.hasMatch(parentKey)) {
    return '<REDACTED>';
  }
  if (obj is String) {
    if (_base64DataUrlRe.hasMatch(obj)) {
      return '<BASE64_IMG len=${obj.length}>';
    }
    if (_opaqueLongRe.hasMatch(obj)) {
      return '<REDACTED_OPAQUE len=${obj.length}>';
    }
    return obj;
  }
  return obj;
}

class CaptchaDiagnosticMeta {
  final bool ok;
  final String kind;
  final List<CaptchaPoint> points;
  final List<CaptchaPoint> candidates;
  final List<double> candidateConfidences;
  final double elapsedMs;
  final String error;
  final Uint8List? renderedPngBytes;

  const CaptchaDiagnosticMeta({
    required this.ok,
    required this.kind,
    this.points = const <CaptchaPoint>[],
    this.candidates = const <CaptchaPoint>[],
    this.candidateConfidences = const <double>[],
    this.elapsedMs = 0.0,
    this.error = '',
    this.renderedPngBytes,
  });
}

class SessionRecorder {
  final Directory? sessionDir;
  final String account;

  /// 最近一次生成的验证码叠加诊断图 PNG 字节（供手机 UI 实时预览小窗展示）。
  Uint8List? latestDiagnosticPng;
  CaptchaDiagnosticMeta? latestDiagnosticMeta;

  SessionRecorder({
    required this.sessionDir,
    required this.account,
  }) {
    if (sessionDir != null) {
      try {
        sessionDir!.createSync(recursive: true);
      } catch (_) {}
    }
  }

  static String _beijingTimestamp({bool compact = false}) {
    final bj = DateTime.now().toUtc().add(const Duration(hours: 8));
    String pad2(int n) => n.toString().padLeft(2, '0');
    String pad3(int n) => n.toString().padLeft(3, '0');
    if (compact) {
      return '${bj.year}${pad2(bj.month)}${pad2(bj.day)}_'
          '${pad2(bj.hour)}${pad2(bj.minute)}${pad2(bj.second)}';
    }
    return '${bj.year}-${pad2(bj.month)}-${pad2(bj.day)} '
        '${pad2(bj.hour)}:${pad2(bj.minute)}:${pad2(bj.second)}.${pad3(bj.millisecond)}';
  }

  /// 追加一条会话运行日志到 `session.log`。
  void appendSessionLog(String line) {
    if (sessionDir == null) {
      return;
    }
    try {
      final logFile = File('${sessionDir!.path}/session.log');
      logFile.writeAsStringSync(
        '[${_beijingTimestamp()}] $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// 追加一条脱敏后的 HTTP 事务记录到 `http_trace.jsonl`。
  void recordHttp({
    required String stage,
    required String method,
    required String path,
    required int? statusCode,
    required double rttMs,
    Map<String, dynamic>? reqSummary,
    Map<String, dynamic>? respSummary,
    String bizMsg = '',
    String error = '',
  }) {
    if (sessionDir == null) {
      return;
    }

    final record = <String, dynamic>{
      'ts': _beijingTimestamp(),
      'stage': stage,
      'method': method.toUpperCase(),
      'path': path,
      'status': statusCode,
      'rtt_ms': double.parse(rttMs.toStringAsFixed(2)),
    };
    if (bizMsg.isNotEmpty) {
      record['biz_msg'] = bizMsg;
    }
    if (error.isNotEmpty) {
      record['error'] = error;
    }
    if (reqSummary != null) {
      record['req'] = sanitizeForTrace(reqSummary);
    }
    if (respSummary != null) {
      record['resp'] = sanitizeForTrace(respSummary);
    }

    try {
      final traceFile = File('${sessionDir!.path}/http_trace.jsonl');
      traceFile.writeAsStringSync(
        '${jsonEncode(record)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// 生成 target + bg + YOLO 候选绿圈 + 预测点击红点十字的 PNG 诊断图。
  File? saveCaptchaDiagnostic({
    required Uint8List targetBytes,
    required Uint8List bgBytes,
    required CaptchaDiagnosticMeta outcome,
    int priority = 0,
    String seat = 'unknown',
    int retry = 0,
  }) {
    try {
      final targetImg = img.decodeImage(targetBytes);
      final bgImg = img.decodeImage(bgBytes);
      if (targetImg == null || bgImg == null) {
        return null;
      }

      final headerH = targetImg.height + 8 > 36 ? targetImg.height + 8 : 36;
      const footerH = 22;
      var canvasW = bgImg.width > targetImg.width + 16
          ? bgImg.width
          : targetImg.width + 16;
      if (canvasW < 280) {
        canvasW = 280;
      }
      final canvasH = headerH + bgImg.height + footerH;

      final canvas = img.Image(width: canvasW, height: canvasH);
      img.fill(canvas, color: img.ColorRgb8(245, 245, 245));

      img.compositeImage(
        canvas,
        targetImg,
        dstX: 8,
        dstY: (headerH - targetImg.height) ~/ 2,
      );
      final bgY0 = headerH;
      img.compositeImage(canvas, bgImg, dstX: 0, dstY: bgY0);

      final green = img.ColorRgb8(34, 197, 94);
      final red = img.ColorRgb8(220, 38, 38);

      // 绿色圆圈标出 YOLO 候选中心
      for (final c in outcome.candidates) {
        final py = bgY0 + c.y;
        img.drawCircle(canvas, x: c.x, y: py, radius: 12, color: green);
        img.drawCircle(canvas, x: c.x, y: py, radius: 11, color: green);
      }

      // 红色十字 + 圆圈标出最终点击顺序
      for (var i = 0; i < outcome.points.length; i++) {
        final p = outcome.points[i];
        final py = bgY0 + p.y;
        const arm = 8;
        img.drawLine(
          canvas,
          x1: p.x - arm,
          y1: py,
          x2: p.x + arm,
          y2: py,
          color: red,
          thickness: 2,
        );
        img.drawLine(
          canvas,
          x1: p.x,
          y1: py - arm,
          x2: p.x,
          y2: py + arm,
          color: red,
          thickness: 2,
        );
        img.drawCircle(canvas, x: p.x, y: py, radius: 5, color: red);
        img.drawString(
          canvas,
          '${i + 1}',
          font: img.arial14,
          x: p.x + 7,
          y: py - 7,
          color: red,
        );
      }

      final statusTxt =
          '${outcome.kind} | ok=${outcome.ok} | ${outcome.elapsedMs.round()}ms'
          '${outcome.error.isNotEmpty ? " | ${outcome.error}" : ""}';
      img.drawString(
        canvas,
        statusTxt,
        font: img.arial14,
        x: 8,
        y: headerH + bgImg.height + 4,
        color: img.ColorRgb8(40, 40, 40),
      );

      final pngBytes = Uint8List.fromList(img.encodePng(canvas));
      latestDiagnosticPng = pngBytes;
      latestDiagnosticMeta = CaptchaDiagnosticMeta(
        ok: outcome.ok,
        kind: outcome.kind,
        points: outcome.points,
        candidates: outcome.candidates,
        candidateConfidences: outcome.candidateConfidences,
        elapsedMs: outcome.elapsedMs,
        error: outcome.error,
        renderedPngBytes: pngBytes,
      );

      if (sessionDir == null) {
        return null;
      }
      final ts = _beijingTimestamp(compact: true);
      final outFile = File(
        '${sessionDir!.path}/${priority}_${seat}_${retry}_captcha_$ts.png',
      );
      outFile.writeAsBytesSync(pngBytes, flush: true);
      return outFile;
    } catch (_) {
      return null;
    }
  }

  /// 写出本次会话的 `抢座顺序.txt`。
  File? writeSeatPlan({
    required String campus,
    required String room,
    required List<String> preferSeats,
    required List<String> fallbackSeats,
    required String startTime,
    required String endTime,
    int? totalRoomSeats,
    int? freeRoomSeats,
  }) {
    if (sessionDir == null) {
      return null;
    }
    try {
      final lines = <String>[
        '账号: $account',
        '校区: $campus',
        '自习室: $room',
        '时间: ${_beijingTimestamp()}',
        '开始: $startTime  结束: $endTime',
      ];
      if (totalRoomSeats != null && freeRoomSeats != null) {
        lines.add('实时空座: $freeRoomSeats / $totalRoomSeats');
      }
      lines.add('');
      lines.add('=== 抢座顺序 ===');
      var seq = 1;
      for (final s in preferSeats) {
        lines.add('$seq. [首选] 座位 $s');
        seq += 1;
      }
      for (final s in fallbackSeats) {
        lines.add('$seq. [兜底] 座位 $s');
        seq += 1;
      }
      lines.add('');
      lines.add('共 ${preferSeats.length + fallbackSeats.length} 个座位待尝试');

      final planFile = File('${sessionDir!.path}/抢座顺序.txt');
      planFile.writeAsStringSync('${lines.join('\n')}\n', flush: true);
      return planFile;
    } catch (_) {
      return null;
    }
  }
}
