/// Click1 & Click3 YOLOv8 + Siamese 点选验证码端到端求解器。
///
/// 与 Python 端 `core/captcha_click1_yolo4_siamese.py` 和 `core/captcha_yolo4_siamese.py`
/// 100% 逐像素对齐：
/// 1. `dart:ui` 原生 Skia/libjpeg 解码目标图与背景图（与 Pillow 偏差 0/255）
/// 2. 裁剪目标字槽位（Click1: `x=[25:45], y=[5:27]`；Click3: `x=[5:25, 25:45, 45:65], y=[5:27]`）
/// 3. 拼合到 `44px` 顶部白底槽位条 + `330×160` 背景图 → `330×204` 组合图，Pillow `BILINEAR` Letterbox 送入 YOLOv8
/// 4. 过滤落入背景区 (`cy >= 44`) 的 Top-4 候选框，严格执行「恰好 4 个候选框」硬门槛
/// 5. 裁剪 `60×60` 候选字块与目标字块，Pillow 等价 `BICUBIC` 缩放到 `112×112`（灰值 128 填充）
/// 6. 送入 Siamese ONNX（`input1=char`, `input2=plan`），输出相似度矩阵并求解最优点击坐标
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../api_crypto.dart';
import 'pil_image_ops.dart';
import 'yolo_onnx.dart';

class SiameseSolveDetail {
  final List<CaptchaPoint> points;
  final List<CaptchaPoint> candidates;
  final List<double> candidateConfidences;
  final List<List<double>> similarityMatrix;

  const SiameseSolveDetail({
    required this.points,
    required this.candidates,
    required this.candidateConfidences,
    required this.similarityMatrix,
  });
}

double _sigmoid(double x) => 1.0 / (1.0 + exp(-x));

/// Siamese 单张字块预处理：Pillow 等价 Bicubic 缩放到 112×112（128 灰底），输出 RGB `[3, 112, 112]`。
Float32List preprocessSiamesePatchRgb(RgbImage patch, {int inputSize = 112}) {
  final iw = max(1, patch.width);
  final ih = max(1, patch.height);
  final scale = min(inputSize / iw, inputSize / ih);
  final nw = max(1, (iw * scale).floor());
  final nh = max(1, (ih * scale).floor());

  final resized = pilResizeRgb(patch, nw, nh, PilResampling.bicubic);
  final canvas = RgbImage.filled(inputSize, inputSize, 128, 128, 128);
  final dx = (inputSize - nw) ~/ 2;
  final dy = (inputSize - nh) ~/ 2;
  pasteRgb(canvas, resized, dx, dy);

  final plane = inputSize * inputSize;
  final plane2 = 2 * plane;
  final out = Float32List(3 * plane);
  final rgb = canvas.rgb;
  for (var i = 0, p = 0; i < plane; i++, p += 3) {
    out[i] = rgb[p] / 255.0;
    out[plane + i] = rgb[p + 1] / 255.0;
    out[plane2 + i] = rgb[p + 2] / 255.0;
  }
  return out;
}

/// 求解 `nRows × nCols` 相似度矩阵的最大权重无冲突指派（对应 Python `_optimal_match`）。
List<(int, int)> optimalMatch(List<List<double>> sim) {
  final nRows = sim.length;
  if (nRows == 0) {
    return const <(int, int)>[];
  }
  final nCols = sim[0].length;
  if (nCols == 0 || nRows > nCols) {
    return const <(int, int)>[];
  }

  var bestScore = double.negativeInfinity;
  var best = <(int, int)>[];

  void search(int row, List<bool> usedCols, List<int> chosen, double acc) {
    if (row == nRows) {
      if (acc > bestScore) {
        bestScore = acc;
        best = <(int, int)>[
          for (var r = 0; r < nRows; r++) (r, chosen[r]),
        ];
      }
      return;
    }
    for (var col = 0; col < nCols; col++) {
      if (usedCols[col]) {
        continue;
      }
      usedCols[col] = true;
      chosen.add(col);
      search(row + 1, usedCols, chosen, acc + sim[row][col]);
      chosen.removeLast();
      usedCols[col] = false;
    }
  }

  search(0, List<bool>.filled(nCols, false), <int>[], 0.0);
  return best;
}

class YoloSiameseClickSolver {
  final bool isClick3;
  final YoloOnnxPredictor _yolo;
  final String siameseModelAsset;
  final int topK;
  final int charCropSize;
  final int planSlotHeight;

  OrtSession? _siameseSession;
  String _input1Name = 'input1';
  String _input2Name = 'input2';

  YoloSiameseClickSolver.click1({
    String yoloAsset = 'assets/models/click1_yolo_plan_bg_char40_best.onnx',
    this.siameseModelAsset = 'assets/models/click1_siamese_yolo4_best.onnx',
    this.topK = 4,
    this.charCropSize = 60,
    this.planSlotHeight = 44,
  })  : isClick3 = false,
        _yolo = YoloOnnxPredictor(
          modelAsset: yoloAsset,
          confThreshold: 0.05,
          iouThreshold: 0.7,
          imgsz: 640,
        );

  YoloSiameseClickSolver.click3({
    String yoloAsset = 'assets/models/click3_yolo_plan_bg_char60_best.onnx',
    this.siameseModelAsset =
        'assets/models/click3_siamese_yolo4_posw3_best.onnx',
    this.topK = 4,
    this.charCropSize = 60,
    this.planSlotHeight = 44,
  })  : isClick3 = true,
        _yolo = YoloOnnxPredictor(
          modelAsset: yoloAsset,
          confThreshold: 0.05,
          iouThreshold: 0.45,
          imgsz: 640,
        );

  bool get isLoaded => _yolo.isLoaded && _siameseSession != null;

  Future<void> ensureLoaded() async {
    await _yolo.ensureLoaded();
    if (_siameseSession != null) {
      return;
    }
    final data = await rootBundle.load(siameseModelAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    loadSiameseFromBytes(bytes);
  }

  /// 直接从内存模型字节加载 YOLO 与 Siamese 会话（供后台推理 Isolate 复用）。
  void loadFromBytes(Uint8List yoloBytes, Uint8List siameseBytes) {
    _yolo.loadFromBytes(yoloBytes);
    loadSiameseFromBytes(siameseBytes);
  }

  void loadSiameseFromBytes(Uint8List bytes) {
    if (_siameseSession != null) {
      return;
    }
    ensureOrtEnvInitialized();
    final options = createOptimizedOrtSessionOptions();
    try {
      _siameseSession = OrtSession.fromBuffer(bytes, options);
      final names = _siameseSession!.inputNames;
      if (names.length >= 2) {
        _input1Name = names[0];
        _input2Name = names[1];
      }
    } finally {
      options.release();
    }
  }

  String get yoloModelAsset => _yolo.modelAsset;

  Future<void> warmup() async {
    await ensureLoaded();
    final dummyTarget = RgbImage.filled(70, 36, 255, 255, 255);
    final dummyBg = RgbImage.filled(300, 120, 255, 255, 255);

    final plans = _extractPlanCrops(dummyTarget);
    final composed = _composePlanBg(plans, dummyBg);
    await _yolo.predict(composed, maxDet: 1);

    final dummyChars = List<RgbImage>.generate(
      4,
      (_) => RgbImage.filled(charCropSize, charCropSize, 128, 128, 128),
    );
    await _scoreSiamese(plans, dummyChars);
  }

  List<RgbImage> _extractPlanCrops(RgbImage targetImg) {
    if (!isClick3) {
      return <RgbImage>[
        cropWithPaddingRgb(
          targetImg,
          25,
          5,
          45,
          27,
          fillR: 255,
          fillG: 255,
          fillB: 255,
        ),
      ];
    }
    const xs = <int>[5, 25, 45, 65];
    return <RgbImage>[
      for (var i = 0; i < 3; i++)
        cropWithPaddingRgb(
          targetImg,
          xs[i],
          5,
          xs[i + 1],
          27,
          fillR: 255,
          fillG: 255,
          fillB: 255,
        ),
    ];
  }

  RgbImage _composePlanBg(List<RgbImage> planCrops, RgbImage bgImg) {
    final bgW = bgImg.width;
    final bgH = bgImg.height;
    final canvas = RgbImage.filled(bgW, planSlotHeight + bgH, 255, 255, 255);

    if (!isClick3) {
      final crop = planCrops[0];
      final x = (bgW - crop.width) ~/ 2;
      final y = (planSlotHeight - crop.height) ~/ 2;
      pasteRgb(canvas, crop, x, y);
    } else {
      final slotW = bgW ~/ 3;
      for (var i = 0; i < planCrops.length; i++) {
        final crop = planCrops[i];
        final x = i * slotW + (slotW - crop.width) ~/ 2;
        final y = (planSlotHeight - crop.height) ~/ 2;
        pasteRgb(canvas, crop, x, y);
      }
    }

    pasteRgb(canvas, bgImg, 0, planSlotHeight);
    return canvas;
  }

  Future<List<YoloDetection>> _detectCandidates(RgbImage composed) async {
    final raw = await _yolo.predict(composed, maxDet: 300);
    final filtered = <YoloDetection>[];
    final imageW = composed.width.toDouble();
    final imageH = composed.height.toDouble();
    for (final det in raw) {
      final cx = det.centerX;
      final cy = det.centerY;
      if (cx >= 0 &&
          cx <= imageW &&
          cy >= planSlotHeight &&
          cy <= imageH) {
        filtered.add(det);
      }
    }
    if (filtered.length > topK) {
      return filtered.sublist(0, topK);
    }
    return filtered;
  }

  Future<List<List<double>>> _scoreSiamese(
    List<RgbImage> planCrops,
    List<RgbImage> charCrops,
  ) async {
    await ensureLoaded();
    final numPlans = planCrops.length;
    final numChars = charCrops.length;
    final batchSize = numPlans * numChars;
    const singlePatchFloats = 3 * 112 * 112;

    final x1 = Float32List(batchSize * singlePatchFloats);
    final x2 = Float32List(batchSize * singlePatchFloats);

    final planTensors = planCrops
        .map((p) => preprocessSiamesePatchRgb(p, inputSize: 112))
        .toList(growable: false);
    final charTensors = charCrops
        .map((c) => preprocessSiamesePatchRgb(c, inputSize: 112))
        .toList(growable: false);

    var pairIdx = 0;
    for (var pIdx = 0; pIdx < numPlans; pIdx++) {
      final planBlob = planTensors[pIdx];
      for (var cIdx = 0; cIdx < numChars; cIdx++) {
        final charBlob = charTensors[cIdx];
        final offset = pairIdx * singlePatchFloats;
        // 训练顺序：input1 为候选字符 char，input2 为目标字符 plan
        x1.setRange(offset, offset + singlePatchFloats, charBlob);
        x2.setRange(offset, offset + singlePatchFloats, planBlob);
        pairIdx++;
      }
    }

    final shape = <int>[batchSize, 3, 112, 112];
    final t1 = OrtValueTensor.createTensorWithDataList(x1, shape);
    final t2 = OrtValueTensor.createTensorWithDataList(x2, shape);
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _siameseSession!.run(
        runOptions,
        <String, OrtValue>{_input1Name: t1, _input2Name: t2},
      );
      final raw = outputs.isNotEmpty ? outputs[0]?.value : null;
      final flatLogits = _flattenLogits(raw, batchSize);

      final matrix = <List<double>>[];
      var k = 0;
      for (var p = 0; p < numPlans; p++) {
        final row = <double>[];
        for (var c = 0; c < numChars; c++) {
          row.add(_sigmoid(flatLogits[k++]));
        }
        matrix.add(row);
      }
      return matrix;
    } finally {
      t1.release();
      t2.release();
      runOptions.release();
      if (outputs != null) {
        for (final out in outputs) {
          out?.release();
        }
      }
    }
  }

  static List<double> _flattenLogits(dynamic raw, int expectedCount) {
    final result = <double>[];
    void walk(dynamic node) {
      if (node is List) {
        for (final item in node) {
          walk(item);
        }
      } else if (node is num) {
        result.add(node.toDouble());
      }
    }

    walk(raw);
    while (result.length < expectedCount) {
      result.add(0.0);
    }
    return result;
  }

  /// 端到端求解点选验证码；若 YOLO 候选数 != 4 或匹配不足则返回 null。
  Future<SiameseSolveDetail?> solve(
    Uint8List targetBytes,
    Uint8List bgBytes,
  ) async {
    final targetImg = await decodeImageRgb(targetBytes);
    final bgImg = await decodeImageRgb(bgBytes);
    if (targetImg == null || bgImg == null) {
      return null;
    }
    return solveDecoded(targetImg, bgImg);
  }

  /// 对已解码的 [RgbImage] 执行端到端求解（避免 `CaptchaService` 重复解码）。
  Future<SiameseSolveDetail?> solveDecoded(
    RgbImage targetImg,
    RgbImage bgImg,
  ) async {
    final planCrops = _extractPlanCrops(targetImg);
    final composed = _composePlanBg(planCrops, bgImg);
    final detections = await _detectCandidates(composed);

    // 生产级硬门槛：YOLO 必须检出恰好 4 个候选框，否则直接刷新重取
    if (detections.length != 4) {
      return null;
    }

    final half = charCropSize ~/ 2;
    final charCrops = <RgbImage>[];
    final centers = <CaptchaPoint>[];
    for (final det in detections) {
      final bx = pyRound(det.centerX);
      final by = pyRound(det.centerY - planSlotHeight);
      final crop = cropWithPaddingRgb(
        bgImg,
        bx - half,
        by - half,
        bx + half,
        by + half,
        fillR: 128,
        fillG: 128,
        fillB: 128,
      );
      charCrops.add(crop);
      centers.add(CaptchaPoint(bx, by));
    }

    final simMatrix = await _scoreSiamese(planCrops, charCrops);

    if (!isClick3) {
      final row = simMatrix[0];
      var bestIdx = 0;
      var bestScore = double.negativeInfinity;
      for (var i = 0; i < row.length; i++) {
        if (row[i] > bestScore) {
          bestScore = row[i];
          bestIdx = i;
        }
      }
      return SiameseSolveDetail(
        points: <CaptchaPoint>[centers[bestIdx]],
        candidates: centers,
        candidateConfidences:
            detections.map((d) => d.conf).toList(growable: false),
        similarityMatrix: simMatrix,
      );
    }

    final matches = optimalMatch(simMatrix);
    if (matches.length < 3) {
      return null;
    }
    final orderedPoints = <CaptchaPoint>[
      for (final (_, charIdx) in matches) centers[charIdx],
    ];
    return SiameseSolveDetail(
      points: orderedPoints,
      candidates: centers,
      candidateConfidences:
          detections.map((d) => d.conf).toList(growable: false),
      similarityMatrix: simMatrix,
    );
  }

  void dispose() {
    _yolo.dispose();
    _siameseSession?.release();
    _siameseSession = null;
  }
}
