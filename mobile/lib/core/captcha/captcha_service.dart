/// 点选验证码统一推理服务（Click1 + Click3 自适应路由 + 登录 OCR）。
///
/// 与 Python 端 `core/captcha_service.py` 100% 逻辑对齐：
/// 1. 优先读取接口 `wordCheckCount` (`1` -> Click1, `3` -> Click3)
/// 2. 其次分析 `targetBytes` 左右槽位笔迹占空比（采用 Pillow 等价 ITU-R 601-2 灰度）
/// 3. 兜底回退北京时间 `06:30:00–06:35:00` 高峰窗口规则
library;

import 'dart:async';
import 'dart:typed_data';

import '../api_crypto.dart';
import '../session_recorder.dart';
import 'onnx_worker.dart';
import 'pil_image_ops.dart';

enum CaptchaKind {
  click1,
  click3;

  String get wireName => this == CaptchaKind.click3 ? 'click3' : 'click1';
}

class CaptchaSolveOutcome {
  final bool ok;
  final CaptchaKind kind;
  final List<CaptchaPoint> points;
  final List<CaptchaPoint> candidates;
  final List<double> candidateConfidences;
  final List<List<double>> similarity;
  final double elapsedMs;
  final String error;
  final String decoder;

  const CaptchaSolveOutcome({
    required this.ok,
    required this.kind,
    this.points = const <CaptchaPoint>[],
    this.candidates = const <CaptchaPoint>[],
    this.candidateConfidences = const <double>[],
    this.similarity = const <List<double>>[],
    this.elapsedMs = 0.0,
    this.error = '',
    this.decoder = '',
  });

  CaptchaDiagnosticMeta toDiagnosticMeta() {
    return CaptchaDiagnosticMeta(
      ok: ok,
      kind: kind.wireName,
      points: points,
      candidates: candidates,
      candidateConfidences: candidateConfidences,
      elapsedMs: elapsedMs,
      error: error,
    );
  }
}

const int _slotY1 = 5;
const int _slotY2 = 27;
const List<(int, int)> _slotXs = <(int, int)>[(5, 25), (25, 45), (45, 65)];
const int _inkGrayThreshold = 180;
const double _slotPresentRatio = 0.02;
const double _slotEmptyRatio = 0.01;

bool inRushWindow([DateTime? nowBeijing]) {
  final bj =
      nowBeijing ?? DateTime.now().toUtc().add(const Duration(hours: 8));
  final secOfDay = bj.hour * 3600 + bj.minute * 60 + bj.second;
  const startSec = 6 * 3600 + 30 * 60; // 06:30:00
  const endSec = 6 * 3600 + 35 * 60; // 06:35:00
  return secOfDay >= startSec && secOfDay <= endSec;
}

double _slotInkRatioLuma(
  Uint8List gray,
  int width,
  int height,
  int x1,
  int y1,
  int x2,
  int y2,
) {
  final sx1 = x1.clamp(0, width);
  final sy1 = y1.clamp(0, height);
  final sx2 = x2.clamp(0, width);
  final sy2 = y2.clamp(0, height);
  final total = (sx2 - sx1) * (sy2 - sy1);
  if (total <= 0) {
    return 0.0;
  }
  var dark = 0;
  for (var y = sy1; y < sy2; y++) {
    final rowOff = y * width;
    for (var x = sx1; x < sx2; x++) {
      if (gray[rowOff + x] < _inkGrayThreshold) {
        dark++;
      }
    }
  }
  return dark / total;
}

/// 自适应判定验证码为 click1（1 字）还是 click3（3 字）。
CaptchaKind detectCaptchaKind({
  Uint8List? targetBytes,
  RgbImage? targetImage,
  int? hintCount,
  DateTime? nowBeijing,
}) {
  if (hintCount == 3) {
    return CaptchaKind.click3;
  }
  if (hintCount == 1) {
    return CaptchaKind.click1;
  }

  final decoded = targetImage ??
      ((targetBytes != null && targetBytes.isNotEmpty)
          ? decodeImageRgbSync(targetBytes)
          : null);
  if (decoded != null && decoded.width >= 65 && decoded.height >= _slotY2) {
    try {
      final gray = pilRgbToLuma(decoded);
      final leftRatio = _slotInkRatioLuma(
        gray,
        decoded.width,
        decoded.height,
        _slotXs[0].$1,
        _slotY1,
        _slotXs[0].$2,
        _slotY2,
      );
      final midRatio = _slotInkRatioLuma(
        gray,
        decoded.width,
        decoded.height,
        _slotXs[1].$1,
        _slotY1,
        _slotXs[1].$2,
        _slotY2,
      );
      final rightRatio = _slotInkRatioLuma(
        gray,
        decoded.width,
        decoded.height,
        _slotXs[2].$1,
        _slotY1,
        _slotXs[2].$2,
        _slotY2,
      );
      if (leftRatio >= _slotPresentRatio && rightRatio >= _slotPresentRatio) {
        return CaptchaKind.click3;
      }
      if (midRatio >= _slotPresentRatio &&
          leftRatio < _slotEmptyRatio &&
          rightRatio < _slotEmptyRatio) {
        return CaptchaKind.click1;
      }
    } catch (_) {}
  }

  return inRushWindow(nowBeijing) ? CaptchaKind.click3 : CaptchaKind.click1;
}

abstract class CaptchaService {
  bool get preloaded;

  String get lastPreloadError => '';

  Future<bool> preload({String account = 'system'});

  Future<String> solveLoginCaptcha(Uint8List imageBytes);

  Future<CaptchaSolveOutcome> solve(
    Uint8List targetBytes,
    Uint8List bgBytes, {
    CaptchaKind? kind,
    int? hintCount,
    DateTime? nowBeijing,
  });
}

class OnnxCaptchaService implements CaptchaService {
  final OnnxCaptchaWorker _worker = OnnxCaptchaWorker();

  bool _preloaded = false;
  String _lastPreloadError = '';
  Future<void> _lockTail = Future<void>.value();

  @override
  bool get preloaded => _preloaded;

  @override
  String get lastPreloadError => _lastPreloadError;

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _lockTail;
    final gate = Completer<void>();
    _lockTail = gate.future;
    await prev;
    try {
      return await action();
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  @override
  Future<bool> preload({String account = 'system'}) async {
    if (_preloaded) {
      return true;
    }
    return _synchronized<bool>(() async {
      if (_preloaded) {
        return true;
      }
      final errors = <String>[];
      try {
        await _worker.ensureLoginLoaded();
      } catch (exc) {
        errors.add('login_ocr: $exc');
      }
      try {
        await _worker.ensureClickLoaded(isClick3: false, warmup: true);
      } catch (exc) {
        errors.add('click1: $exc');
      }
      try {
        await _worker.ensureClickLoaded(isClick3: true, warmup: true);
      } catch (exc) {
        errors.add('click3: $exc');
      }
      _lastPreloadError = errors.join('; ');
      _preloaded = errors.isEmpty;
      return _preloaded;
    });
  }

  @override
  Future<String> solveLoginCaptcha(Uint8List imageBytes) async {
    final decoded = await decodeImageRgb(imageBytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      return '';
    }
    return _synchronized<String>(() => _worker.solveLoginDecoded(decoded));
  }

  @override
  Future<CaptchaSolveOutcome> solve(
    Uint8List targetBytes,
    Uint8List bgBytes, {
    CaptchaKind? kind,
    int? hintCount,
    DateTime? nowBeijing,
  }) async {
    final sw = Stopwatch()..start();
    final targetImg = await decodeImageRgb(targetBytes);
    final resolvedKind = kind ??
        detectCaptchaKind(
          targetImage: targetImg,
          targetBytes: targetImg == null ? targetBytes : null,
          hintCount: hintCount,
          nowBeijing: nowBeijing,
        );

    try {
      final bgImg = await decodeImageRgb(bgBytes);
      if (targetImg == null || bgImg == null) {
        sw.stop();
        return CaptchaSolveOutcome(
          ok: false,
          kind: resolvedKind,
          elapsedMs: sw.elapsedMicroseconds / 1000.0,
          error: 'image_decode_failed',
        );
      }
      final decoderUsed = bgImg.decoder;

      return await _synchronized<CaptchaSolveOutcome>(() async {
        final res = await _worker.solveClickDecoded(
          isClick3: resolvedKind == CaptchaKind.click3,
          targetImg: targetImg,
          bgImg: bgImg,
        );
        sw.stop();
        final elapsedMs = sw.elapsedMicroseconds / 1000.0;
        if (!res.ok) {
          return CaptchaSolveOutcome(
            ok: false,
            kind: resolvedKind,
            elapsedMs: elapsedMs,
            error: res.error.isNotEmpty
                ? res.error
                : (resolvedKind == CaptchaKind.click3
                    ? 'click3_no_solution'
                    : 'click1_no_solution'),
            decoder: decoderUsed,
          );
        }
        return CaptchaSolveOutcome(
          ok: true,
          kind: resolvedKind,
          points: res.points,
          candidates: res.candidates,
          candidateConfidences: res.candidateConfidences,
          similarity: res.similarity,
          elapsedMs: elapsedMs,
          decoder: decoderUsed,
        );
      });
    } catch (exc) {
      sw.stop();
      return CaptchaSolveOutcome(
        ok: false,
        kind: resolvedKind,
        elapsedMs: sw.elapsedMicroseconds / 1000.0,
        error: exc.toString(),
      );
    }
  }

  void dispose() {
    _worker.dispose();
  }
}
