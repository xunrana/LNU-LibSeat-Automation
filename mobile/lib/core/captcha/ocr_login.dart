/// 登录 4 位图形验证码本地 ONNX OCR 求解器。
///
/// 与 Python 端 `core/captcha.py` (`_LiteOnnxOcr`) 100% 逐像素算子对齐：
/// - `dart:ui` 原生解码 + Pillow 等价 `LANCZOS` 降采样到高度 64px（宽度 `floor(w * 64 / h)`）
/// - Pillow 等价 ITU-R 601-2 灰度 `L`，归一化 `pixel / 255.0`
/// - 输入张量形状 `[1, 1, 64, W]` (`float32`)，动态读取模型首输入节点名
/// - 输出张量沿类别维取 `argmax` 并执行 CTC 邻接去重（跳过 blank 0）
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import 'pil_image_ops.dart';

class LoginOcrSolver {
  static const String defaultModelAsset = 'assets/models/common_old.onnx';
  static const String defaultCharsetAsset = 'assets/models/charset_old.json';

  OrtSession? _session;
  String _inputName = 'input1';
  List<String>? _charset;

  bool get isLoaded => _session != null && _charset != null;

  Future<void> ensureLoaded({
    String modelAsset = defaultModelAsset,
    String charsetAsset = defaultCharsetAsset,
  }) async {
    if (isLoaded) {
      return;
    }
    final charsetJson = await rootBundle.loadString(charsetAsset);
    final rawList = jsonDecode(charsetJson) as List<dynamic>;
    final charset = rawList.map((e) => e.toString()).toList(growable: false);

    final modelData = await rootBundle.load(modelAsset);
    final modelBytes = modelData.buffer.asUint8List(
      modelData.offsetInBytes,
      modelData.lengthInBytes,
    );
    loadFromBytes(modelBytes, charset);
  }

  /// 直接从内存模型字节与字符表加载会话（供后台推理 Isolate 复用，零 rootBundle 依赖）。
  void loadFromBytes(Uint8List modelBytes, List<String> charset) {
    if (isLoaded) {
      return;
    }
    ensureOrtEnvInitialized();
    _charset = List<String>.unmodifiable(charset);
    final options = createOptimizedOrtSessionOptions();
    try {
      _session = OrtSession.fromBuffer(modelBytes, options);
      if (_session!.inputNames.isNotEmpty) {
        _inputName = _session!.inputNames.first;
      }
    } finally {
      options.release();
    }
  }

  /// 与 Python `_LiteOnnxOcr.classification` 完全一致的预处理：
  /// `resize((max(1, int(w * 64 / h)), 64), LANCZOS).convert("L") / 255.0`。
  static (Float32List blob, int targetWidth) preprocessToTensor(
    RgbImage decoded,
  ) {
    const targetHeight = 64;
    final targetWidth = max(
      1,
      (decoded.width * (targetHeight / decoded.height)).floor(),
    );
    final resized = pilResizeRgb(
      decoded,
      targetWidth,
      targetHeight,
      PilResampling.lanczos,
    );
    final gray = pilRgbToLuma(resized);
    final blob = Float32List(gray.length);
    for (var i = 0; i < gray.length; i++) {
      blob[i] = gray[i] / 255.0;
    }
    return (blob, targetWidth);
  }

  /// 对输入 PNG/JPEG 字节流执行本地 CTC OCR，返回识别出的字符串。
  Future<String> solveBytes(Uint8List imageBytes) async {
    await ensureLoaded();
    final decoded = await decodeImageRgb(imageBytes);
    if (decoded == null || decoded.height <= 0 || decoded.width <= 0) {
      return '';
    }
    return solveDecodedSync(decoded);
  }

  /// 对已解码的 [RgbImage] 执行同步 CTC OCR（调用前需确保 [isLoaded] 为 true）。
  String solveDecodedSync(RgbImage decoded) {
    if (!isLoaded || decoded.height <= 0 || decoded.width <= 0) {
      return '';
    }

    const targetHeight = 64;
    final (blob, targetWidth) = preprocessToTensor(decoded);

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      blob,
      <int>[1, 1, targetHeight, targetWidth],
    );
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session!.run(
        runOptions,
        <String, OrtValue>{_inputName: inputTensor},
      );
      if (outputs.isEmpty || outputs[0] == null) {
        return '';
      }
      final rawValue = outputs[0]!.value;
      final indices = _extractCtcArgmaxIndices(rawValue);
      return decodeCtcIndices(indices, _charset!);
    } finally {
      inputTensor.release();
      runOptions.release();
      if (outputs != null) {
        for (final out in outputs) {
          out?.release();
        }
      }
    }
  }

  /// 从 ONNX 输出（`[seq_len, 1, num_classes]` 或 `[1, seq_len, num_classes]`）提取时间步类别索引。
  static List<int> _extractCtcArgmaxIndices(dynamic rawValue) {
    if (rawValue is! List || rawValue.isEmpty) {
      return const <int>[];
    }

    // 情况 1: 3D `[seq_len, 1, num_classes]` 或 `[1, seq_len, num_classes]`
    final first = rawValue[0];
    if (first is List && first.isNotEmpty && first[0] is List) {
      if (first.length == 1) {
        // `[seq_len, 1, num_classes]`
        final seqLen = rawValue.length;
        final indices = List<int>.filled(seqLen, 0);
        for (var t = 0; t < seqLen; t++) {
          final logits = (rawValue[t] as List)[0] as List;
          indices[t] = _argmaxList(logits);
        }
        return indices;
      } else {
        // `[1, seq_len, num_classes]`
        final seq = first;
        final indices = List<int>.filled(seq.length, 0);
        for (var t = 0; t < seq.length; t++) {
          indices[t] = _argmaxList(seq[t] as List);
        }
        return indices;
      }
    }

    // 情况 2: 2D `[seq_len, num_classes]` -> 沿最后一维取 argmax（与 Python np.argmax(output, axis=-1) 一致）
    if (first is List && first.isNotEmpty) {
      if (rawValue.length > 1) {
        return <int>[
          for (final row in rawValue) _argmaxList(row as List),
        ];
      }
      // `[1, seq_len]` 若直接是整数索引
      return first.map((e) => (e as num).toInt()).toList(growable: false);
    }

    return rawValue.map((e) => (e as num).toInt()).toList(growable: false);
  }

  static int _argmaxList(List<dynamic> logits) {
    var bestIdx = 0;
    var bestVal = double.negativeInfinity;
    for (var i = 0; i < logits.length; i++) {
      final v = (logits[i] as num).toDouble();
      if (v > bestVal) {
        bestVal = v;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// CTC 贪心邻接去重并映射字符表（跳过 blank=0）。
  static String decodeCtcIndices(List<int> indices, List<String> charset) {
    final buffer = StringBuffer();
    int? prevIdx;
    final charsetLen = charset.length;
    for (final idx in indices) {
      if (idx != prevIdx && idx > 0 && idx < charsetLen) {
        buffer.write(charset[idx]);
      }
      prevIdx = idx;
    }
    return buffer.toString();
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
