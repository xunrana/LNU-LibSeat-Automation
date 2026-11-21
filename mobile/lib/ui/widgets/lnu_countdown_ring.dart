/// 1:1 复刻桌面端 `ui_qt/widgets/countdown_ring.py` 的手绘双线印章计时仪。
///
/// 视觉构成：
/// 1. 双层辽大海军蓝细线外印章圈 + 四象限微刻度菱点
/// 2. 浅米灰内轨 + 四段圆头银杏琥珀弧（运行中平滑旋转）
/// 3. 12 点钟方向辽大海军蓝定位星点
/// 4. 居中衬线大字（立即模式显示「立  即」，定时模式显示等宽 `HH:MM:SS`）
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum SealRingMode {
  immediate,
  scheduled,
  running,
  done,
}

class LnuCountdownRing extends StatefulWidget {
  final SealRingMode mode;
  final String centerText;
  final String topHint;
  final String bottomHint;
  final double progress;
  final double size;
  final VoidCallback? onTap;

  const LnuCountdownRing({
    super.key,
    required this.mode,
    required this.centerText,
    required this.topHint,
    required this.bottomHint,
    this.progress = 0.0,
    this.size = 212,
    this.onTap,
  });

  @override
  State<LnuCountdownRing> createState() => _LnuCountdownRingState();
}

class _LnuCountdownRingState extends State<LnuCountdownRing>
    with SingleTickerProviderStateMixin {
  late AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant LnuCountdownRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.mode == SealRingMode.running) {
      if (!_spinCtrl.isAnimating) {
        _spinCtrl.repeat();
      }
    } else {
      _spinCtrl.stop();
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isChineseBig = widget.centerText.contains('立') ||
        widget.centerText.contains('成');

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _spinCtrl,
          builder: (context, child) {
            return CustomPaint(
              painter: _SealRingPainter(
                mode: widget.mode,
                progress: widget.progress,
                spinRadians: _spinCtrl.value * 2 * pi,
              ),
              child: child,
            );
          },
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.topHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: LnuColors.amberHot,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 3.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.centerText,
                    textAlign: TextAlign.center,
                    style: isChineseBig
                        ? LnuTheme.serif(
                            32,
                            weight: FontWeight.w700,
                            color: LnuColors.ink,
                            letterSpacing: 8,
                          )
                        : LnuTheme.mono(
                            27,
                            weight: FontWeight.w700,
                            color: LnuColors.ink,
                            letterSpacing: 1.5,
                          ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.bottomHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: LnuColors.textMuted,
                      fontSize: 10,
                      letterSpacing: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SealRingPainter extends CustomPainter {
  final SealRingMode mode;
  final double progress;
  final double spinRadians;

  const _SealRingPainter({
    required this.mode,
    required this.progress,
    required this.spinRadians,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final side = min(size.width, size.height);

    final sealOuterR = side * 0.485;
    final sealInnerR = side * 0.462;
    final trackMidR = side * 0.375;
    final arcStroke = side * 0.072;

    // 1. 宣纸圆底填充
    canvas.drawCircle(
      center,
      sealInnerR,
      Paint()..color = LnuColors.bgPaper,
    );

    // 2. 双层辽大海军蓝细线外印章圈（复刻桌面端双线边框）
    final outerPen = Paint()
      ..color = LnuColors.ink.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    final innerPen = Paint()
      ..color = LnuColors.ink.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    canvas.drawCircle(center, sealOuterR, outerPen);
    canvas.drawCircle(center, sealInnerR, innerPen);

    // 四方向微刻度点
    final tickPaint = Paint()..color = LnuColors.amberHot;
    for (var i = 0; i < 4; i++) {
      final angle = -pi / 2 + i * (pi / 2);
      final pt = Offset(
        cx + cos(angle) * sealOuterR,
        cy + sin(angle) * sealOuterR,
      );
      canvas.drawCircle(pt, 2.0, tickPaint);
    }

    // 3. 内环底轨
    final trackPaint = Paint()
      ..color = LnuColors.cardSunk
      ..style = PaintingStyle.stroke
      ..strokeWidth = arcStroke;
    canvas.drawCircle(center, trackMidR, trackPaint);

    // 4. 四段圆头银杏琥珀弧（与桌面端 02_gui_main.png 一致）
    final rect = Rect.fromCircle(center: center, radius: trackMidR);
    final arcColor = mode == SealRingMode.done
        ? LnuColors.ok
        : (mode == SealRingMode.running
            ? LnuColors.amberHot
            : LnuColors.amber);
    final arcPaint = Paint()
      ..color = arcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = arcStroke
      ..strokeCap = StrokeCap.round;

    if (mode == SealRingMode.scheduled && progress > 0.02) {
      // 定时模式：按倒计时进度绘制平滑弧线
      canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * progress.clamp(0.05, 1.0),
        false,
        arcPaint,
      );
    } else {
      // 立即模式 / 运行中：四段对称琥珀圆弧（运行中顺时针缓慢旋转）
      const sweep = pi / 5.2;
      final baseOffset = mode == SealRingMode.running ? spinRadians : 0.0;
      for (var i = 0; i < 4; i++) {
        final start = -pi / 2 - sweep / 2 + i * (pi / 2) + baseOffset;
        canvas.drawArc(rect, start, sweep, false, arcPaint);
      }
    }

    // 5. 12 点钟方向辽大海军蓝定位圆点
    final dotAngle = -pi / 2 + (mode == SealRingMode.running ? spinRadians : 0);
    final dotPos = Offset(
      cx + cos(dotAngle) * trackMidR,
      cy + sin(dotAngle) * trackMidR,
    );
    canvas.drawCircle(dotPos, 3.6, Paint()..color = LnuColors.ink);
  }

  @override
  bool shouldRepaint(covariant _SealRingPainter oldDelegate) =>
      oldDelegate.mode != mode ||
      oldDelegate.progress != progress ||
      oldDelegate.spinRadians != spinRadians;
}
