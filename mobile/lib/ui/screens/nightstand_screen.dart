/// 银杏夜守 · 全屏 OLED 纯黑极暗书桌时钟（专为 iOS & Android 06:30 晨约过夜守候设计）。
///
/// - 纯黑 `#000000` 零发光底色 + 崇山银杏叶极简微光暗纹 + 暖琥珀细体大时钟
/// - 每整分钟像素级缓移防 OLED 烧屏
/// - 自动开启 `WakelockPlus` 阻止锁屏断网，06:29:45 无声预热，06:30:00 落座唤醒
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../logic/orchestrator.dart';
import '../../services/background_scheduler.dart';
import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/lnu_chrome.dart';

class NightstandScreen extends StatefulWidget {
  final MobileRushController controller;

  const NightstandScreen({super.key, required this.controller});

  @override
  State<NightstandScreen> createState() => _NightstandScreenState();
}

class _NightstandScreenState extends State<NightstandScreen> {
  Timer? _clockTimer;
  DateTime _nowBj = currentBeijingTime();
  final Random _rng = Random();
  double _offsetX = 0.0;
  double _offsetY = 0.0;
  bool _ultraDim = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    BackgroundSchedulerService.instance.setKeepScreenAwake(true);

    if (!widget.controller.isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.startRush(overrideScheduled: true);
      });
    }

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final bj = currentBeijingTime();
      if (!mounted) {
        return;
      }
      setState(() {
        _nowBj = bj;
        if (bj.second == 0) {
          _offsetX = (_rng.nextDouble() * 32.0) - 16.0;
          _offsetY = (_rng.nextDouble() * 44.0) - 22.0;
        }
      });
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!widget.controller.isRunning) {
      BackgroundSchedulerService.instance.setKeepScreenAwake(false);
    }
    super.dispose();
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final cfg = widget.controller.config;
        final sched = buildCustomSchedule(
          cfg.schedHour,
          cfg.schedMin,
          nowBeijing: _nowBj,
        );
        final diff = sched.fireAt.difference(_nowBj);
        final remH = diff.inHours.clamp(0, 99);
        final remM = (diff.inMinutes % 60).clamp(0, 59);
        final remS = (diff.inSeconds % 60).clamp(0, 59);
        final hasSuccess = widget.controller.lastSuccessEvent != null;

        final fgColor = hasSuccess
            ? LnuColors.amberLight
            : (_ultraDim ? const Color(0xFF6B5330) : LnuColors.amberLight);
        final subColor = hasSuccess
            ? LnuColors.amber
            : (_ultraDim ? const Color(0xFF3E3323) : const Color(0xFF9C886B));

        return Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _ultraDim = !_ultraDim),
            onLongPress: () => Navigator.of(context).pop(),
            child: SafeArea(
              child: Center(
                child: Transform.translate(
                  offset: Offset(_offsetX, _offsetY),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        // 极简银杏叶线条徽记
                        SizedBox(
                          width: 66,
                          height: 44,
                          child: CustomPaint(
                            painter: LnuCampusMotifPainter(
                              isChongshan: true,
                              color: fgColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '银 杏 夜 守 · 辽 宁 大 学 图 书 馆',
                          style: TextStyle(
                            color: subColor,
                            fontSize: 11,
                            letterSpacing: 2.6,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          '${_pad2(_nowBj.hour)}:${_pad2(_nowBj.minute)}',
                          style: LnuTheme.mono(
                            68,
                            weight: FontWeight.w300,
                            color: fgColor,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          ':${_pad2(_nowBj.second)}  BEIJING',
                          style: LnuTheme.mono(
                            12,
                            color: subColor,
                            letterSpacing: 2.4,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: subColor.withValues(alpha: 0.45),
                              width: 0.9,
                            ),
                          ),
                          child: Text(
                            hasSuccess
                                ? '已锁定 · ${widget.controller.lastSuccessEvent!.roomName} '
                                    '${widget.controller.lastSuccessEvent!.seatNo} 号座'
                                : '距 ${_pad2(cfg.schedHour)}:${_pad2(cfg.schedMin)} 晨约还有 '
                                    '${_pad2(remH)}:${_pad2(remM)}:${_pad2(remS)}',
                            style: TextStyle(
                              color: fgColor,
                              fontSize: 13.5,
                              letterSpacing: 1.0,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          '${cfg.campus.replaceAll("图书馆", "")} · ${cfg.room}'
                          ' · ${cfg.preferSeats.isEmpty ? "全室实时空座" : "首选 ${cfg.preferSeats.join(" → ")}"}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: subColor,
                            fontSize: 12,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 52),
                        Text(
                          '轻触切换微光 · 长按屏幕退出夜守',
                          style: TextStyle(
                            color: subColor.withValues(alpha: 0.65),
                            fontSize: 11,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
