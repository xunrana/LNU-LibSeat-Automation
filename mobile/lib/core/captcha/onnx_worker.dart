/// 独立后台 Isolate ONNX 推理工作线程（彻底消除主线程卡顿与 Android 5s ANR 强杀）。
///
/// 职责：
/// - 主线程仅负责从 `rootBundle` 读取模型字节与调用平台原生 CPU 解码（~2ms）
/// - 全部 5 个 ONNX 会话创建、预热、Pillow 重采样、张量构建、ORT 推理与最优指派均在
///   常驻后台 Isolate 中串行执行，保持 0ms UI 阻塞与 100% 跨平台逐像素精度对齐
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../api_crypto.dart';
import 'ocr_login.dart';
import 'pil_image_ops.dart';
import 'siamese_onnx.dart';

class WorkerClickResult {
  final bool ok;
  final List<CaptchaPoint> points;
  final List<CaptchaPoint> candidates;
  final List<double> candidateConfidences;
  final List<List<double>> similarity;
  final String error;

  const WorkerClickResult({
    required this.ok,
    this.points = const <CaptchaPoint>[],
    this.candidates = const <CaptchaPoint>[],
    this.candidateConfidences = const <double>[],
    this.similarity = const <List<double>>[],
    this.error = '',
  });
}

/// 常驻单实例后台推理 Worker（主线程通过 SendPort 异步通信）。
class OnnxCaptchaWorker {
  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _responsePort;
  ReceivePort? _exitPort;
  StreamSubscription<dynamic>? _responseSub;
  StreamSubscription<dynamic>? _exitSub;

  Future<void>? _starting;
  bool _disposed = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};

  bool _loginLoaded = false;
  bool _click1Loaded = false;
  bool _click3Loaded = false;

  Future<void> _ensureStarted() async {
    if (_disposed) {
      throw StateError('OnnxCaptchaWorker has been disposed');
    }
    if (_workerPort != null) {
      return;
    }
    if (_starting != null) {
      return _starting!;
    }

    final completer = Completer<void>();
    _starting = completer.future;

    try {
      final readyPort = ReceivePort();
      final responsePort = ReceivePort();
      final exitPort = ReceivePort();

      final isolate = await Isolate.spawn<List<SendPort>>(
        _workerEntry,
        <SendPort>[readyPort.sendPort, responsePort.sendPort],
        debugName: 'LnuOnnxCaptchaWorker',
      );
      isolate.addOnExitListener(exitPort.sendPort);

      final sendPort = await readyPort.first as SendPort;
      readyPort.close();

      _isolate = isolate;
      _workerPort = sendPort;
      _responsePort = responsePort;
      _exitPort = exitPort;

      _responseSub = responsePort.listen((dynamic raw) {
        if (raw is! Map) {
          return;
        }
        final map = Map<String, dynamic>.from(raw);
        final id = (map['id'] as num?)?.toInt();
        if (id == null) {
          return;
        }
        final req = _pending.remove(id);
        if (req != null && !req.isCompleted) {
          final err = map['error'] as String?;
          if (err != null && err.isNotEmpty) {
            req.completeError(StateError(err));
          } else {
            req.complete(map);
          }
        }
      });

      _exitSub = exitPort.listen((_) {
        _workerPort = null;
        _isolate = null;
        _loginLoaded = false;
        _click1Loaded = false;
        _click3Loaded = false;
        final pendingCopy =
            List<Completer<Map<String, dynamic>>>.from(_pending.values);
        _pending.clear();
        for (final c in pendingCopy) {
          if (!c.isCompleted) {
            c.completeError(StateError('ONNX worker isolate exited unexpectedly'));
          }
        }
      });

      completer.complete();
    } catch (exc, st) {
      completer.completeError(exc, st);
      rethrow;
    } finally {
      _starting = null;
    }
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> payload) async {
    await _ensureStarted();
    final port = _workerPort;
    if (port == null) {
      throw StateError('ONNX worker port unavailable');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    payload['id'] = id;
    port.send(payload);
    return completer.future;
  }

  static Future<TransferableTypedData> _loadAssetTransferable(
    String assetPath,
  ) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return TransferableTypedData.fromList(<Uint8List>[bytes]);
  }

  static Map<String, dynamic> _packImage(RgbImage img) {
    return <String, dynamic>{
      'w': img.width,
      'h': img.height,
      'rgb': TransferableTypedData.fromList(<Uint8List>[img.rgb]),
      if (img.alpha != null)
        'alpha': TransferableTypedData.fromList(<Uint8List>[img.alpha!]),
    };
  }

  Future<void> ensureLoginLoaded() async {
    if (_loginLoaded) {
      return;
    }
    final charsetJson =
        await rootBundle.loadString(LoginOcrSolver.defaultCharsetAsset);
    final charset = (jsonDecode(charsetJson) as List<dynamic>)
        .map((e) => e.toString())
        .toList(growable: false);
    final modelData =
        await _loadAssetTransferable(LoginOcrSolver.defaultModelAsset);
    await _call(<String, dynamic>{
      'op': 'load_login',
      'model': modelData,
      'charset': charset,
    });
    _loginLoaded = true;
  }

  Future<void> ensureClickLoaded({required bool isClick3, bool warmup = false}) async {
    if (isClick3 ? _click3Loaded : _click1Loaded) {
      if (warmup) {
        await _call(<String, dynamic>{
          'op': 'warmup_click',
          'isClick3': isClick3,
        });
      }
      return;
    }
    final template = isClick3
        ? YoloSiameseClickSolver.click3()
        : YoloSiameseClickSolver.click1();
    final yoloData = await _loadAssetTransferable(template.yoloModelAsset);
    final siameseData =
        await _loadAssetTransferable(template.siameseModelAsset);
    await _call(<String, dynamic>{
      'op': 'load_click',
      'isClick3': isClick3,
      'yolo': yoloData,
      'siamese': siameseData,
      'warmup': warmup,
    });
    if (isClick3) {
      _click3Loaded = true;
    } else {
      _click1Loaded = true;
    }
  }

  Future<String> solveLoginDecoded(RgbImage decoded) async {
    await ensureLoginLoaded();
    final resp = await _call(<String, dynamic>{
      'op': 'solve_login',
      'image': _packImage(decoded),
    });
    return (resp['text'] as String?) ?? '';
  }

  Future<WorkerClickResult> solveClickDecoded({
    required bool isClick3,
    required RgbImage targetImg,
    required RgbImage bgImg,
  }) async {
    await ensureClickLoaded(isClick3: isClick3);
    final resp = await _call(<String, dynamic>{
      'op': 'solve_click',
      'isClick3': isClick3,
      'target': _packImage(targetImg),
      'bg': _packImage(bgImg),
    });

    final ok = resp['ok'] == true;
    final rawPts = (resp['points'] as List<dynamic>?) ?? const <dynamic>[];
    final rawCands =
        (resp['candidates'] as List<dynamic>?) ?? const <dynamic>[];
    final rawConfs = (resp['confs'] as List<dynamic>?) ?? const <dynamic>[];
    final rawSim = (resp['sim'] as List<dynamic>?) ?? const <dynamic>[];

    List<CaptchaPoint> parsePts(List<dynamic> src) {
      return <CaptchaPoint>[
        for (final item in src)
          CaptchaPoint(
            ((item as List)[0] as num).toInt(),
            (item[1] as num).toInt(),
          ),
      ];
    }

    return WorkerClickResult(
      ok: ok,
      points: parsePts(rawPts),
      candidates: parsePts(rawCands),
      candidateConfidences: <double>[
        for (final c in rawConfs) (c as num).toDouble(),
      ],
      similarity: <List<double>>[
        for (final row in rawSim)
          <double>[for (final v in (row as List)) (v as num).toDouble()],
      ],
      error: (resp['solveError'] as String?) ?? '',
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      _workerPort?.send(const <String, dynamic>{'op': 'dispose'});
    } catch (_) {}
    _responseSub?.cancel();
    _exitSub?.cancel();
    _responsePort?.close();
    _exitPort?.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _workerPort = null;
  }
}

RgbImage _unpackImage(Map<String, dynamic> map) {
  final w = (map['w'] as num).toInt();
  final h = (map['h'] as num).toInt();
  final rgb = (map['rgb'] as TransferableTypedData).materialize().asUint8List();
  final rawAlpha = map['alpha'];
  final alpha = rawAlpha is TransferableTypedData
      ? rawAlpha.materialize().asUint8List()
      : null;
  return RgbImage(width: w, height: h, rgb: rgb, alpha: alpha);
}

Future<void> _workerEntry(List<SendPort> ports) async {
  final readyPort = ports[0];
  final responsePort = ports[1];
  final inbox = ReceivePort();
  readyPort.send(inbox.sendPort);

  final loginSolver = LoginOcrSolver();
  final click1Solver = YoloSiameseClickSolver.click1();
  final click3Solver = YoloSiameseClickSolver.click3();

  await for (final dynamic raw in inbox) {
    if (raw is! Map) {
      continue;
    }
    final req = Map<String, dynamic>.from(raw);
    final op = req['op'] as String? ?? '';
    final id = req['id'];

    if (op == 'dispose') {
      loginSolver.dispose();
      click1Solver.dispose();
      click3Solver.dispose();
      inbox.close();
      return;
    }

    try {
      switch (op) {
        case 'load_login':
          final modelBytes = (req['model'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final charset = (req['charset'] as List<dynamic>)
              .map((e) => e.toString())
              .toList(growable: false);
          loginSolver.loadFromBytes(modelBytes, charset);
          responsePort.send(<String, dynamic>{'id': id, 'ok': true});
          break;

        case 'load_click':
          final isClick3 = req['isClick3'] == true;
          final solver = isClick3 ? click3Solver : click1Solver;
          final yoloBytes = (req['yolo'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final siameseBytes = (req['siamese'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          solver.loadFromBytes(yoloBytes, siameseBytes);
          if (req['warmup'] == true) {
            await solver.warmup();
          }
          responsePort.send(<String, dynamic>{'id': id, 'ok': true});
          break;

        case 'warmup_click':
          final isClick3 = req['isClick3'] == true;
          final solver = isClick3 ? click3Solver : click1Solver;
          await solver.warmup();
          responsePort.send(<String, dynamic>{'id': id, 'ok': true});
          break;

        case 'solve_login':
          final img =
              _unpackImage(Map<String, dynamic>.from(req['image'] as Map));
          final text = loginSolver.solveDecodedSync(img);
          responsePort.send(<String, dynamic>{'id': id, 'text': text});
          break;

        case 'solve_click':
          final isClick3 = req['isClick3'] == true;
          final solver = isClick3 ? click3Solver : click1Solver;
          final targetImg =
              _unpackImage(Map<String, dynamic>.from(req['target'] as Map));
          final bgImg =
              _unpackImage(Map<String, dynamic>.from(req['bg'] as Map));
          final detail = await solver.solveDecoded(targetImg, bgImg);
          final expectedCount = isClick3 ? 3 : 1;
          if (detail == null || detail.points.length != expectedCount) {
            responsePort.send(<String, dynamic>{
              'id': id,
              'ok': false,
              'solveError':
                  isClick3 ? 'click3_no_solution' : 'click1_no_solution',
            });
          } else {
            responsePort.send(<String, dynamic>{
              'id': id,
              'ok': true,
              'points': <List<int>>[
                for (final p in detail.points) <int>[p.x, p.y],
              ],
              'candidates': <List<int>>[
                for (final c in detail.candidates) <int>[c.x, c.y],
              ],
              'confs': detail.candidateConfidences,
              'sim': detail.similarityMatrix,
            });
          }
          break;

        default:
          responsePort.send(<String, dynamic>{
            'id': id,
            'error': 'Unknown worker op: $op',
          });
      }
    } catch (exc) {
      responsePort.send(<String, dynamic>{
        'id': id,
        'error': exc.toString(),
      });
    }
  }
}
