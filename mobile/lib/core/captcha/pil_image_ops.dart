/// 与 Python 端 Pillow (`PIL.Image`) 逐像素对齐的移动端图像解码与重采样算子库。
///
/// 解决原先使用纯 Dart `package:image` 带来的三大识别率劣化根因：
/// 1. `package:image` 纯 Dart JPEG 解码器采用块状近邻色度上采样，与 Pillow (`libjpeg-turbo`)
///    像素偏差高达 `80/255`；改为优先使用 Flutter 原生 `dart:ui` (`instantiateImageCodec` +
///    `rawStraightRgba`，底层同为 Skia + `libjpeg-turbo`/`libpng`)，像素偏差 `0/255`。
/// 2. `package:image` `copyResize` 缺少 `+0.5` 像素中心对齐、缺少降采样抗锯齿滤波器缩放、
///    越界抽头回退中心像素且截断取整，导致 Siamese `20×22 -> 101×112` 字符偏移约 2.5px、
///    登录 OCR `160×70 -> 146×64` 缺少 Lanczos 抗锯齿；此处完整移植 Pillow `Resample.c`
///    双通可分离 22-bit 定点卷积（`BILINEAR` / `BICUBIC` / `LANCZOS`），与 Pillow 偏差 `0/255`。
/// 3. `package:image` `grayscale` 截断取整；此处采用 Pillow `Convert.c` 精确 ITU-R 601-2
///    定点公式 `(R * 19595 + G * 38470 + B * 7471 + 32768) >> 16`，与 Pillow `.convert("L")` 偏差 `0/255`。
library;

import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

bool _ortEnvInitialized = false;

const MethodChannel _nativeImageChannel = MethodChannel(
  'com.xunrana.lnulibseat/background',
);

/// 进程级单次初始化 ONNX Runtime 全局环境（避免多模型重复 `CreateEnv` 泄漏句柄）。
void ensureOrtEnvInitialized() {
  if (_ortEnvInitialized) {
    return;
  }
  OrtEnv.instance.init();
  _ortEnvInitialized = true;
}

/// 构造统一的移动端高性能 ONNX Runtime 会话配置（开启全图优化并限制合理 CPU 线程数，
/// 避免在 big.LITTLE 大小核手机上因线程过度竞争导致推理变慢）。
OrtSessionOptions createOptimizedOrtSessionOptions() {
  final options = OrtSessionOptions();
  try {
    options.setSessionGraphOptimizationLevel(
      GraphOptimizationLevel.ortEnableAll,
    );
  } catch (_) {}
  try {
    final cpus = Platform.numberOfProcessors;
    final intraThreads = cpus <= 2 ? cpus : min(4, cpus);
    options.setIntraOpNumThreads(max(1, intraThreads));
    options.setInterOpNumThreads(1);
  } catch (_) {}
  return options;
}

/// 与 Python 3 `int(round(x))` 一致的银行家舍入（round-half-to-even）。
int pyRound(double value) {
  final floored = value.floor();
  final frac = value - floored;
  if (frac < 0.5) {
    return floored;
  }
  if (frac > 0.5) {
    return floored + 1;
  }
  return floored.isEven ? floored : floored + 1;
}

/// 扁平 RGB 图像缓冲区（`width * height * 3` 字节，行主序交错 `R, G, B`）。
///
/// 仅当源图存在 `alpha < 255` 的半透明/透明像素时才分配 [alpha] 通道，
/// 绝大多数不透明 JPEG/PNG 保持零透明通道开销。
class RgbImage {
  final int width;
  final int height;
  final Uint8List rgb;
  final Uint8List? alpha;
  final String decoder;

  const RgbImage({
    required this.width,
    required this.height,
    required this.rgb,
    this.alpha,
    this.decoder = 'raw',
  });

  factory RgbImage.filled(
    int width,
    int height,
    int r,
    int g,
    int b,
  ) {
    final len = width * height * 3;
    final data = Uint8List(len);
    if (r == g && g == b) {
      if (r != 0) {
        data.fillRange(0, len, r);
      }
    } else {
      for (var i = 0; i < len; i += 3) {
        data[i] = r;
        data[i + 1] = g;
        data[i + 2] = b;
      }
    }
    return RgbImage(width: width, height: height, rgb: data);
  }
}

/// 优先使用平台原生 CPU 图像解码器，保证与 Python Pillow 逐像素一致且零 GPU 依赖：
/// 1. Android / iOS：优先走原生 CPU 解码（Android `BitmapFactory` / iOS `ImageIO + CoreGraphics`，
///    不依赖 Impeller/Metal GPU 纹理回读，锁屏/后台 06:30 定时守夜期间同样 100% 稳定）
/// 2. 桌面 / 兜底：走 Flutter `dart:ui`（`rawStraightRgba` 优先，失败自动回退 `rawRgba` 反预乘）
/// 3. 无 Flutter 引擎环境（纯 Dart 离线单测）：回退 `package:image`
Future<RgbImage?> decodeImageRgb(Uint8List bytes) async {
  if (bytes.isEmpty) {
    return null;
  }

  // 1. 移动端原生 CPU 解码（Android BitmapFactory / iOS ImageIO，零 GPU 依赖，锁屏后台安全）
  if (Platform.isAndroid || Platform.isIOS) {
    final nativeDecoded = await _decodeViaNativeCpu(bytes);
    if (nativeDecoded != null) {
      return nativeDecoded;
    }
  }

  // 2. Flutter 原生 dart:ui (Skia/Impeller)
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui
        .instantiateImageCodec(bytes)
        .timeout(const Duration(seconds: 3));
    final frame =
        await codec.getNextFrame().timeout(const Duration(seconds: 3));
    image = frame.image;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) {
      return null;
    }
    ByteData? byteData;
    var premultiplied = false;
    try {
      byteData = await image
          .toByteData(format: ui.ImageByteFormat.rawStraightRgba)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      byteData = null;
    }
    if (byteData == null) {
      byteData = await image
          .toByteData(format: ui.ImageByteFormat.rawRgba)
          .timeout(const Duration(seconds: 3));
      premultiplied = true;
    }
    if (byteData != null) {
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return premultiplied
          ? _fromPremultipliedRgba(rgba, width, height, decoder: 'dart_ui_premul')
          : _fromStraightRgba(rgba, width, height, decoder: 'dart_ui');
    }
  } catch (_) {
    // 非 Flutter 引擎环境或罕见编码格式回退到纯 Dart 解码器
  } finally {
    image?.dispose();
    codec?.dispose();
  }
  return decodeImageRgbSync(bytes);
}

Future<RgbImage?> _decodeViaNativeCpu(Uint8List bytes) async {
  try {
    final res = await _nativeImageChannel
        .invokeMapMethod<String, dynamic>(
          'decodeImageRgba',
          <String, dynamic>{'bytes': bytes},
        )
        .timeout(const Duration(seconds: 3));
    if (res == null) {
      return null;
    }
    final width = (res['width'] as num?)?.toInt() ?? 0;
    final height = (res['height'] as num?)?.toInt() ?? 0;
    final rawRgba = res['rgba'];
    if (width <= 0 || height <= 0 || rawRgba is! Uint8List) {
      return null;
    }
    if (rawRgba.length < width * height * 4) {
      return null;
    }
    final premultiplied = res['premultiplied'] == true;
    final decoderName = Platform.isIOS ? 'ios_cpu' : 'android_cpu';
    return premultiplied
        ? _fromPremultipliedRgba(rawRgba, width, height, decoder: '${decoderName}_premul')
        : _fromStraightRgba(rawRgba, width, height, decoder: decoderName);
  } catch (_) {
    return null;
  }
}

/// 同步解码图片（供无异步上下文的同步辅助函数如 `detectCaptchaKind` 使用）。
RgbImage? decodeImageRgbSync(Uint8List bytes) {
  if (bytes.isEmpty) {
    return null;
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    return null;
  }
  return rgbImageFromPackageImage(decoded);
}

/// 将 `package:image` 的 `Image` 转换为扁平 [RgbImage]。
RgbImage rgbImageFromPackageImage(img.Image src) {
  final w = src.width;
  final h = src.height;
  final pixelCount = w * h;
  final rgb = Uint8List(pixelCount * 3);
  Uint8List? alpha;
  final hasAlphaChannel = src.numChannels >= 4;

  var rgbOffset = 0;
  var pixIdx = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = src.getPixel(x, y);
      rgb[rgbOffset++] = p.r.toInt().clamp(0, 255);
      rgb[rgbOffset++] = p.g.toInt().clamp(0, 255);
      rgb[rgbOffset++] = p.b.toInt().clamp(0, 255);
      if (hasAlphaChannel) {
        final a = p.a.toInt().clamp(0, 255);
        if (a < 255) {
          alpha ??= Uint8List(pixelCount)..fillRange(0, pixelCount, 255);
          alpha[pixIdx] = a;
        }
      }
      pixIdx++;
    }
  }
  return RgbImage(
    width: w,
    height: h,
    rgb: rgb,
    alpha: alpha,
    decoder: 'package_image',
  );
}

RgbImage _fromStraightRgba(
  Uint8List rgba,
  int width,
  int height, {
  String decoder = 'dart_ui',
}) {
  final pixelCount = width * height;
  final rgb = Uint8List(pixelCount * 3);
  Uint8List? alpha;

  var srcIdx = 0;
  var dstIdx = 0;
  for (var i = 0; i < pixelCount; i++) {
    rgb[dstIdx++] = rgba[srcIdx];
    rgb[dstIdx++] = rgba[srcIdx + 1];
    rgb[dstIdx++] = rgba[srcIdx + 2];
    final a = rgba[srcIdx + 3];
    if (a < 255) {
      alpha ??= Uint8List(pixelCount)..fillRange(0, pixelCount, 255);
      alpha[i] = a;
    }
    srcIdx += 4;
  }
  return RgbImage(
    width: width,
    height: height,
    rgb: rgb,
    alpha: alpha,
    decoder: decoder,
  );
}

RgbImage _fromPremultipliedRgba(
  Uint8List rgba,
  int width,
  int height, {
  String decoder = 'dart_ui_premul',
}) {
  final pixelCount = width * height;
  final rgb = Uint8List(pixelCount * 3);
  Uint8List? alpha;

  var srcIdx = 0;
  var dstIdx = 0;
  for (var i = 0; i < pixelCount; i++) {
    final a = rgba[srcIdx + 3];
    if (a == 255) {
      rgb[dstIdx++] = rgba[srcIdx];
      rgb[dstIdx++] = rgba[srcIdx + 1];
      rgb[dstIdx++] = rgba[srcIdx + 2];
    } else if (a == 0) {
      alpha ??= Uint8List(pixelCount)..fillRange(0, pixelCount, 255);
      alpha[i] = 0;
      dstIdx += 3;
    } else {
      alpha ??= Uint8List(pixelCount)..fillRange(0, pixelCount, 255);
      alpha[i] = a;
      final half = a >> 1;
      rgb[dstIdx++] = _clampByte((rgba[srcIdx] * 255 + half) ~/ a);
      rgb[dstIdx++] = _clampByte((rgba[srcIdx + 1] * 255 + half) ~/ a);
      rgb[dstIdx++] = _clampByte((rgba[srcIdx + 2] * 255 + half) ~/ a);
    }
    srcIdx += 4;
  }
  return RgbImage(
    width: width,
    height: height,
    rgb: rgb,
    alpha: alpha,
    decoder: decoder,
  );
}

/// Pillow `Image.Resampling` 滤波核枚举。
enum PilResampling {
  bilinear,
  bicubic,
  lanczos,
}

double _bilinearFilter(double x) {
  final ax = x < 0.0 ? -x : x;
  return ax < 1.0 ? 1.0 - ax : 0.0;
}

double _bicubicFilter(double x) {
  const a = -0.5;
  final ax = x < 0.0 ? -x : x;
  if (ax < 1.0) {
    return ((a + 2.0) * ax - (a + 3.0)) * ax * ax + 1.0;
  }
  if (ax < 2.0) {
    return (((ax - 5.0) * ax + 8.0) * ax - 4.0) * a;
  }
  return 0.0;
}

double _lanczosFilter(double x) {
  final ax = x < 0.0 ? -x : x;
  if (ax == 0.0) {
    return 1.0;
  }
  if (ax >= 3.0) {
    return 0.0;
  }
  final px = pi * ax;
  return (sin(px) / px) * (sin(px / 3.0) / (px / 3.0));
}

class _ResamplePlan {
  final int ksize;
  final Int32List bounds; // [xmin0, count0, xmin1, count1, ...]
  final Int32List coeffs; // 定点权重（22-bit 精度）

  const _ResamplePlan({
    required this.ksize,
    required this.bounds,
    required this.coeffs,
  });
}

const int _precisionBits = 22;
const int _precisionHalf = 1 << (_precisionBits - 1);
const double _precisionScale = 4194304.0; // 1 << 22

_ResamplePlan _buildResamplePlan(
  int inSize,
  int outSize,
  PilResampling resampling,
) {
  final double baseSupport;
  final double Function(double) filterFn;
  switch (resampling) {
    case PilResampling.bilinear:
      baseSupport = 1.0;
      filterFn = _bilinearFilter;
      break;
    case PilResampling.bicubic:
      baseSupport = 2.0;
      filterFn = _bicubicFilter;
      break;
    case PilResampling.lanczos:
      baseSupport = 3.0;
      filterFn = _lanczosFilter;
      break;
  }

  final scale = inSize / outSize;
  final filterScale = scale >= 1.0 ? scale : 1.0;
  final invFilterScale = 1.0 / filterScale;
  final support = baseSupport * filterScale;
  final ksize = support.ceil() * 2 + 1;

  final bounds = Int32List(outSize * 2);
  final coeffs = Int32List(outSize * ksize);
  final weights = Float64List(ksize);

  for (var xx = 0; xx < outSize; xx++) {
    final center = (xx + 0.5) * scale;
    var xmin = (center - support + 0.5).toInt();
    if (xmin < 0) {
      xmin = 0;
    }
    var xmax = (center + support + 0.5).toInt();
    if (xmax > inSize) {
      xmax = inSize;
    }
    final count = xmax - xmin;
    bounds[xx * 2] = xmin;
    bounds[xx * 2 + 1] = count;

    var ww = 0.0;
    for (var x = 0; x < count; x++) {
      final w = filterFn((x + xmin - center + 0.5) * invFilterScale);
      weights[x] = w;
      ww += w;
    }

    final coeffBase = xx * ksize;
    if (ww != 0.0) {
      final invWw = 1.0 / ww;
      for (var x = 0; x < count; x++) {
        final wn = weights[x] * invWw;
        coeffs[coeffBase + x] = wn >= 0.0
            ? (0.5 + wn * _precisionScale).floor()
            : (-0.5 + wn * _precisionScale).ceil();
      }
    }
  }

  return _ResamplePlan(ksize: ksize, bounds: bounds, coeffs: coeffs);
}

int _clampByte(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

Uint8List _resampleRgbBuffer(
  Uint8List src,
  int inW,
  int inH,
  int outW,
  int outH,
  PilResampling resampling,
) {
  Uint8List cur = src;
  var curW = inW;
  final curH = inH;

  // Pass 1: Horizontal (inW -> outW)
  if (outW != inW) {
    final plan = _buildResamplePlan(inW, outW, resampling);
    final ksize = plan.ksize;
    final bounds = plan.bounds;
    final coeffs = plan.coeffs;
    final tmp = Uint8List(inH * outW * 3);

    for (var y = 0; y < inH; y++) {
      final srcRow = y * inW * 3;
      final dstRow = y * outW * 3;
      for (var xx = 0; xx < outW; xx++) {
        final xmin = bounds[xx * 2];
        final count = bounds[xx * 2 + 1];
        final coeffBase = xx * ksize;
        var sr = _precisionHalf;
        var sg = _precisionHalf;
        var sb = _precisionHalf;
        var p = srcRow + xmin * 3;
        for (var i = 0; i < count; i++) {
          final k = coeffs[coeffBase + i];
          sr += cur[p] * k;
          sg += cur[p + 1] * k;
          sb += cur[p + 2] * k;
          p += 3;
        }
        final d = dstRow + xx * 3;
        tmp[d] = _clampByte(sr >> _precisionBits);
        tmp[d + 1] = _clampByte(sg >> _precisionBits);
        tmp[d + 2] = _clampByte(sb >> _precisionBits);
      }
    }
    cur = tmp;
    curW = outW;
  }

  // Pass 2: Vertical (inH -> outH)
  if (outH != curH) {
    final plan = _buildResamplePlan(curH, outH, resampling);
    final ksize = plan.ksize;
    final bounds = plan.bounds;
    final coeffs = plan.coeffs;
    final out = Uint8List(outH * curW * 3);
    final rowStride = curW * 3;

    for (var yy = 0; yy < outH; yy++) {
      final ymin = bounds[yy * 2];
      final count = bounds[yy * 2 + 1];
      final coeffBase = yy * ksize;
      final dstRow = yy * rowStride;
      for (var x = 0; x < curW; x++) {
        var sr = _precisionHalf;
        var sg = _precisionHalf;
        var sb = _precisionHalf;
        final colOff = x * 3;
        var p = ymin * rowStride + colOff;
        for (var i = 0; i < count; i++) {
          final k = coeffs[coeffBase + i];
          sr += cur[p] * k;
          sg += cur[p + 1] * k;
          sb += cur[p + 2] * k;
          p += rowStride;
        }
        final d = dstRow + colOff;
        out[d] = _clampByte(sr >> _precisionBits);
        out[d + 1] = _clampByte(sg >> _precisionBits);
        out[d + 2] = _clampByte(sb >> _precisionBits);
      }
    }
    return out;
  }

  return identical(cur, src) ? Uint8List.fromList(src) : cur;
}

Uint8List _resamplePlaneBuffer(
  Uint8List src,
  int inW,
  int inH,
  int outW,
  int outH,
  PilResampling resampling,
) {
  Uint8List cur = src;
  var curW = inW;
  final curH = inH;

  if (outW != inW) {
    final plan = _buildResamplePlan(inW, outW, resampling);
    final ksize = plan.ksize;
    final bounds = plan.bounds;
    final coeffs = plan.coeffs;
    final tmp = Uint8List(inH * outW);
    for (var y = 0; y < inH; y++) {
      final srcRow = y * inW;
      final dstRow = y * outW;
      for (var xx = 0; xx < outW; xx++) {
        final xmin = bounds[xx * 2];
        final count = bounds[xx * 2 + 1];
        final coeffBase = xx * ksize;
        var s = _precisionHalf;
        var p = srcRow + xmin;
        for (var i = 0; i < count; i++) {
          s += cur[p++] * coeffs[coeffBase + i];
        }
        tmp[dstRow + xx] = _clampByte(s >> _precisionBits);
      }
    }
    cur = tmp;
    curW = outW;
  }

  if (outH != curH) {
    final plan = _buildResamplePlan(curH, outH, resampling);
    final ksize = plan.ksize;
    final bounds = plan.bounds;
    final coeffs = plan.coeffs;
    final out = Uint8List(outH * curW);
    for (var yy = 0; yy < outH; yy++) {
      final ymin = bounds[yy * 2];
      final count = bounds[yy * 2 + 1];
      final coeffBase = yy * ksize;
      final dstRow = yy * curW;
      for (var x = 0; x < curW; x++) {
        var s = _precisionHalf;
        var p = ymin * curW + x;
        for (var i = 0; i < count; i++) {
          s += cur[p] * coeffs[coeffBase + i];
          p += curW;
        }
        out[dstRow + x] = _clampByte(s >> _precisionBits);
      }
    }
    return out;
  }

  return identical(cur, src) ? Uint8List.fromList(src) : cur;
}

/// 与 Pillow `Image.resize((outW, outH), resampling)` 逐像素一致的双通重采样。
///
/// 若图像包含半透明像素（[RgbImage.alpha] 非空），自动按 Pillow 规则执行预乘 Alpha 重采样再反预乘。
RgbImage pilResizeRgb(
  RgbImage src,
  int outW,
  int outH,
  PilResampling resampling,
) {
  final targetW = max(1, outW);
  final targetH = max(1, outH);
  if (src.width == targetW && src.height == targetH) {
    return RgbImage(
      width: targetW,
      height: targetH,
      rgb: Uint8List.fromList(src.rgb),
      alpha: src.alpha == null ? null : Uint8List.fromList(src.alpha!),
    );
  }

  final alpha = src.alpha;
  if (alpha == null) {
    final outRgb = _resampleRgbBuffer(
      src.rgb,
      src.width,
      src.height,
      targetW,
      targetH,
      resampling,
    );
    return RgbImage(width: targetW, height: targetH, rgb: outRgb);
  }

  // RGBA 含透明像素：与 Pillow 一致先预乘 Alpha，再分别重采样，最后反预乘
  final pixelCount = src.width * src.height;
  final premul = Uint8List(pixelCount * 3);
  for (var i = 0, p = 0; i < pixelCount; i++, p += 3) {
    final a = alpha[i];
    if (a == 255) {
      premul[p] = src.rgb[p];
      premul[p + 1] = src.rgb[p + 1];
      premul[p + 2] = src.rgb[p + 2];
    } else if (a > 0) {
      premul[p] = (src.rgb[p] * a + 127) ~/ 255;
      premul[p + 1] = (src.rgb[p + 1] * a + 127) ~/ 255;
      premul[p + 2] = (src.rgb[p + 2] * a + 127) ~/ 255;
    }
  }

  final outPremul = _resampleRgbBuffer(
    premul,
    src.width,
    src.height,
    targetW,
    targetH,
    resampling,
  );
  final outAlpha = _resamplePlaneBuffer(
    alpha,
    src.width,
    src.height,
    targetW,
    targetH,
    resampling,
  );

  final outPixels = targetW * targetH;
  final outRgb = Uint8List(outPixels * 3);
  for (var i = 0, p = 0; i < outPixels; i++, p += 3) {
    final a = outAlpha[i];
    if (a == 255) {
      outRgb[p] = outPremul[p];
      outRgb[p + 1] = outPremul[p + 1];
      outRgb[p + 2] = outPremul[p + 2];
    } else if (a > 0) {
      final half = a >> 1;
      outRgb[p] = _clampByte((outPremul[p] * 255 + half) ~/ a);
      outRgb[p + 1] = _clampByte((outPremul[p + 1] * 255 + half) ~/ a);
      outRgb[p + 2] = _clampByte((outPremul[p + 2] * 255 + half) ~/ a);
    }
  }
  return RgbImage(
    width: targetW,
    height: targetH,
    rgb: outRgb,
    alpha: outAlpha,
  );
}

/// 与 Pillow `.convert("L")` 逐字节一致的 ITU-R 601-2 灰度转换。
Uint8List pilRgbToLuma(RgbImage src) {
  final pixelCount = src.width * src.height;
  final rgb = src.rgb;
  final gray = Uint8List(pixelCount);
  for (var i = 0, p = 0; i < pixelCount; i++, p += 3) {
    gray[i] = (rgb[p] * 19595 + rgb[p + 1] * 38470 + rgb[p + 2] * 7471 + 32768) >> 16;
  }
  return gray;
}

/// 带越界填充的矩形裁剪（对应 Python `_crop_with_padding`，扁平字节行复制）。
RgbImage cropWithPaddingRgb(
  RgbImage src,
  int x1,
  int y1,
  int x2,
  int y2, {
  required int fillR,
  required int fillG,
  required int fillB,
}) {
  final outW = max(1, x2 - x1);
  final outH = max(1, y2 - y1);
  final canvas = RgbImage.filled(outW, outH, fillR, fillG, fillB);

  final sx1 = max(0, x1);
  final sy1 = max(0, y1);
  final sx2 = min(src.width, x2);
  final sy2 = min(src.height, y2);

  if (sx2 > sx1 && sy2 > sy1) {
    final copyBytes = (sx2 - sx1) * 3;
    final srcStride = src.width * 3;
    final dstStride = outW * 3;
    final dstColOff = (sx1 - x1) * 3;
    final srcColOff = sx1 * 3;
    for (var sy = sy1; sy < sy2; sy++) {
      final dstStart = (sy - y1) * dstStride + dstColOff;
      final srcStart = sy * srcStride + srcColOff;
      canvas.rgb.setRange(dstStart, dstStart + copyBytes, src.rgb, srcStart);
    }
  }
  return canvas;
}

/// 直接像素块覆盖粘贴（无 Alpha 混合开销，与 numpy 切片赋值一致）。
void pasteRgb(RgbImage dst, RgbImage src, int dstX, int dstY) {
  final sx1 = dstX < 0 ? -dstX : 0;
  final sy1 = dstY < 0 ? -dstY : 0;
  final sx2 = min(src.width, dst.width - dstX);
  final sy2 = min(src.height, dst.height - dstY);
  if (sx2 <= sx1 || sy2 <= sy1) {
    return;
  }
  final copyBytes = (sx2 - sx1) * 3;
  final srcStride = src.width * 3;
  final dstStride = dst.width * 3;
  for (var sy = sy1; sy < sy2; sy++) {
    final srcStart = sy * srcStride + sx1 * 3;
    final dstStart = (dstY + sy) * dstStride + (dstX + sx1) * 3;
    dst.rgb.setRange(dstStart, dstStart + copyBytes, src.rgb, srcStart);
  }
}
