/// YOLOv8 ONNX 候选框检测器（纯 Dart + ONNX Runtime）。
///
/// 与 Python 端 `core/yolo_onnx.py` 100% 逐像素算子对齐：
/// - 640×640 Letterbox 填充（深灰值 114）+ Pillow 等价 `BILINEAR` 双通重采样
/// - BGR 通道顺序（与 Python `_image_bytes_to_bgr` 传入 `YoloOnnxPredictor.predict` 完全一致）
/// - `[1, 3, 640, 640]` 归一化 `float32` 输入，动态读取模型首输入节点名
/// - 输出 `[1, 5, 8400]` 解码 + IoU NMS 去重 + 置信度降序裁剪
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import 'pil_image_ops.dart';

class YoloDetection {
  final double conf;
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const YoloDetection({
    required this.conf,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  double get centerX => (x1 + x2) / 2.0;
  double get centerY => (y1 + y2) / 2.0;
}

class LetterboxResult {
  final RgbImage canvas;
  final int padTop;
  final int padLeft;
  final double scale;

  const LetterboxResult({
    required this.canvas,
    required this.padTop,
    required this.padLeft,
    required this.scale,
  });
}

class YoloOnnxPredictor {
  final String modelAsset;
  final double confThreshold;
  final double iouThreshold;
  final int imgsz;

  OrtSession? _session;
  String _inputName = 'images';

  YoloOnnxPredictor({
    required this.modelAsset,
    this.confThreshold = 0.05,
    this.iouThreshold = 0.45,
    this.imgsz = 640,
  });

  bool get isLoaded => _session != null;

  Future<void> ensureLoaded() async {
    if (_session != null) {
      return;
    }
    final data = await rootBundle.load(modelAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    loadFromBytes(bytes);
  }

  /// 直接从内存模型字节加载 YOLOv8 ONNX 会话（供后台推理 Isolate 复用）。
  void loadFromBytes(Uint8List bytes) {
    if (_session != null) {
      return;
    }
    ensureOrtEnvInitialized();
    final options = createOptimizedOrtSessionOptions();
    try {
      _session = OrtSession.fromBuffer(bytes, options);
      if (_session!.inputNames.isNotEmpty) {
        _inputName = _session!.inputNames.first;
      }
    } finally {
      options.release();
    }
  }

  /// 对拼合图像执行 YOLOv8 检测，返回经 NMS 去重且按置信度降序的检测框列表。
  Future<List<YoloDetection>> predict(
    RgbImage composedImage, {
    int maxDet = 300,
  }) async {
    await ensureLoaded();
    final lb = letterboxRgb(composedImage, imgsz);

    // 构造 (1, 3, H, W) 张量；与 Python `core/yolo_onnx.py` 传入 BGR 数组一致：ch0=B, ch1=G, ch2=R
    final planeSize = imgsz * imgsz;
    final blob = Float32List(3 * planeSize);
    final rgb = lb.canvas.rgb;
    final plane2 = 2 * planeSize;
    for (var i = 0, p = 0; i < planeSize; i++, p += 3) {
      blob[i] = rgb[p + 2] / 255.0;
      blob[planeSize + i] = rgb[p + 1] / 255.0;
      blob[plane2 + i] = rgb[p] / 255.0;
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      blob,
      <int>[1, 3, imgsz, imgsz],
    );
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session!.run(
        runOptions,
        <String, OrtValue>{_inputName: inputTensor},
      );
      if (outputs.isEmpty || outputs[0] == null) {
        return const <YoloDetection>[];
      }
      final raw = outputs[0]!.value;
      final candidates = _parseYoloOutput(
        raw,
        padTop: lb.padTop,
        padLeft: lb.padLeft,
        scale: lb.scale,
      );
      final kept = nms(candidates, iouThreshold);
      if (kept.length > maxDet) {
        return kept.sublist(0, maxDet);
      }
      return kept;
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

  List<YoloDetection> _parseYoloOutput(
    dynamic raw, {
    required int padTop,
    required int padLeft,
    required double scale,
  }) {
    if (raw is! List || raw.isEmpty) {
      return const <YoloDetection>[];
    }
    final batch0 = raw[0];
    if (batch0 is! List || batch0.isEmpty) {
      return const <YoloDetection>[];
    }

    final detections = <YoloDetection>[];

    // YOLOv8 标准输出形状为 [1, 5, 8400]：batch0 长度为 5，每个元素长度为 8400
    if (batch0.length == 5 && batch0[0] is List) {
      final cxList = batch0[0] as List;
      final cyList = batch0[1] as List;
      final wList = batch0[2] as List;
      final hList = batch0[3] as List;
      final confList = batch0[4] as List;
      final numAnchors = confList.length;

      for (var i = 0; i < numAnchors; i++) {
        final objConf = (confList[i] as num).toDouble();
        if (objConf < confThreshold) {
          continue;
        }
        final cx = (cxList[i] as num).toDouble();
        final cy = (cyList[i] as num).toDouble();
        final w = (wList[i] as num).toDouble();
        final h = (hList[i] as num).toDouble();

        final x1 = (cx - w / 2.0 - padLeft) / scale;
        final y1 = (cy - h / 2.0 - padTop) / scale;
        final x2 = (cx + w / 2.0 - padLeft) / scale;
        final y2 = (cy + h / 2.0 - padTop) / scale;
        detections.add(
          YoloDetection(conf: objConf, x1: x1, y1: y1, x2: x2, y2: y2),
        );
      }
    } else {
      // [1, 8400, 5]
      for (final item in batch0) {
        if (item is! List || item.length < 5) {
          continue;
        }
        final objConf = (item[4] as num).toDouble();
        if (objConf < confThreshold) {
          continue;
        }
        final cx = (item[0] as num).toDouble();
        final cy = (item[1] as num).toDouble();
        final w = (item[2] as num).toDouble();
        final h = (item[3] as num).toDouble();

        final x1 = (cx - w / 2.0 - padLeft) / scale;
        final y1 = (cy - h / 2.0 - padTop) / scale;
        final x2 = (cx + w / 2.0 - padLeft) / scale;
        final y2 = (cy + h / 2.0 - padTop) / scale;
        detections.add(
          YoloDetection(conf: objConf, x1: x1, y1: y1, x2: x2, y2: y2),
        );
      }
    }

    return detections;
  }

  /// 与 Python `YoloOnnxPredictor._letterbox` 100% 逐像素对齐的 Letterbox 预处理。
  static LetterboxResult letterboxRgb(RgbImage src, int targetSize) {
    final w = src.width;
    final h = src.height;
    final scale = min(targetSize / w, targetSize / h);
    final nw = max(1, (w * scale).floor());
    final nh = max(1, (h * scale).floor());

    final resized = pilResizeRgb(src, nw, nh, PilResampling.bilinear);
    final canvas = RgbImage.filled(targetSize, targetSize, 114, 114, 114);
    final padTop = (targetSize - nh) ~/ 2;
    final padLeft = (targetSize - nw) ~/ 2;
    pasteRgb(canvas, resized, padLeft, padTop);

    return LetterboxResult(
      canvas: canvas,
      padTop: padTop,
      padLeft: padLeft,
      scale: scale,
    );
  }

  static List<YoloDetection> nms(
    List<YoloDetection> dets,
    double iouThreshold,
  ) {
    if (dets.isEmpty) {
      return const <YoloDetection>[];
    }
    final sorted = List<YoloDetection>.from(dets)
      ..sort((a, b) => b.conf.compareTo(a.conf));
    final keep = <YoloDetection>[];
    while (sorted.isNotEmpty) {
      final best = sorted.removeAt(0);
      keep.add(best);
      sorted.removeWhere((d) => computeIou(best, d) >= iouThreshold);
    }
    return keep;
  }

  static double computeIou(YoloDetection a, YoloDetection b) {
    final x1 = max(a.x1, b.x1);
    final y1 = max(a.y1, b.y1);
    final x2 = min(a.x2, b.x2);
    final y2 = min(a.y2, b.y2);
    final inter = max(0.0, x2 - x1) * max(0.0, y2 - y1);
    final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
    final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
    final union = areaA + areaB - inter;
    return union > 0.0 ? inter / union : 0.0;
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
