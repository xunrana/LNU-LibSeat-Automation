/// 辽大书院专属基础组件：暖纸通栏顶栏、定制宣纸底栏、琥珀金胶囊按钮、双馆文化纹饰。
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 暖米白纸感顶栏：嵌蓝金校徽 `lnu_crest.png` + 衬线标题 + 桌面同款状态胶囊（无深蓝块、无版本号）。
class LnuPaperHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showCrest;

  const LnuPaperHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.showCrest = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: const BoxDecoration(
        color: LnuColors.bg,
        border: Border(
          bottom: BorderSide(color: LnuColors.border, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (showCrest) ...<Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: LnuColors.borderDark, width: 0.8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/images/lnu_crest.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const CircleAvatar(
                  backgroundColor: LnuColors.ink,
                  child: Text(
                    'LNU',
                    style: TextStyle(
                      color: LnuColors.amberLight,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: LnuTheme.serif(
                    showCrest ? 19 : 20,
                    weight: FontWeight.w700,
                    letterSpacing: showCrest ? 0.6 : 2.0,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        color: LnuColors.textMuted,
                        fontSize: 11,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 桌面端同款素雅白底状态胶囊（`● 就 绪` / `● 执 行 中` / `● 守 夜 中`）。
class LnuStatusPill extends StatelessWidget {
  final String label;
  final Color dotColor;

  const LnuStatusPill({
    super.key,
    required this.label,
    required this.dotColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: LnuColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LnuColors.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: LnuColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面端同款渐变银杏琥珀金主按钮（`立  即  约  座   →`）。
class LnuAmberButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isDanger;

  const LnuAmberButton({
    super.key,
    required this.label,
    this.onPressed,
    this.isDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final colors = !enabled
        ? const <Color>[LnuColors.border, LnuColors.border]
        : (isDanger
            ? const <Color>[Color(0xFFB54B4B), LnuColors.err]
            : const <Color>[LnuColors.amber, LnuColors.amberHot]);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          height: 50,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: enabled
                ? <BoxShadow>[
                    BoxShadow(
                      color: (isDanger ? LnuColors.err : LnuColors.amberHot)
                          .withValues(alpha: 0.28),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Text(
                label,
                style: TextStyle(
                  color: enabled ? LnuColors.textInvert : LnuColors.textDim,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.6,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面端同款素雅纸面描边次按钮（`夜 守` / `中 止`）。
class LnuOutlineButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  final IconData? icon;

  const LnuOutlineButton({
    super.key,
    required this.label,
    this.onPressed,
    this.danger = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final tint = !enabled
        ? LnuColors.textDim
        : (danger ? LnuColors.err : LnuColors.ink);
    final borderColor = !enabled
        ? LnuColors.border
        : (danger ? LnuColors.err : LnuColors.borderDark);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: LnuColors.card,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: borderColor, width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 16, color: tint),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  color: tint,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自定义宣纸底栏（彻底摒弃 Material 3 椭圆药丸，顶部 2px 银杏金细短横线指示）。
class LnuBottomNavItem {
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const LnuBottomNavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class LnuBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<LnuBottomNavItem> items;

  const LnuBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: LnuColors.bgPaper,
        border: Border(
          top: BorderSide(color: LnuColors.border, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _buildTabItem(items[i], i == currentIndex, () => onTap(i)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabItem(
    LnuBottomNavItem item,
    bool selected,
    VoidCallback onPressed,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Column(
        children: <Widget>[
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: selected ? 26 : 0,
            height: 2.5,
            decoration: BoxDecoration(
              color: LnuColors.amberHot,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Spacer(),
          Icon(
            selected ? item.activeIcon : item.icon,
            size: 21,
            color: selected ? LnuColors.ink : LnuColors.textDim,
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            style: TextStyle(
              color: selected ? LnuColors.ink : LnuColors.textDim,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 1.4,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 崇山百年银杏叶 / 蒲河溯源湖水波 极简线条暗纹绘制器。
class LnuCampusMotifPainter extends CustomPainter {
  final bool isChongshan;
  final Color color;

  const LnuCampusMotifPainter({
    required this.isChongshan,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round;

    if (isChongshan) {
      // 极简银杏叶扇面轮廓与叶脉（象征崇山校区银杏路）
      final cx = size.width * 0.78;
      final cy = size.height * 0.62;
      final r = min(size.width, size.height) * 0.42;

      final leaf = Path()
        ..moveTo(cx, cy + r * 0.55)
        ..quadraticBezierTo(cx - r * 0.08, cy + r * 0.15, cx - r * 0.75, cy - r * 0.22)
        ..quadraticBezierTo(cx - r * 0.42, cy - r * 0.75, cx - r * 0.06, cy - r * 0.52)
        ..lineTo(cx, cy - r * 0.34)
        ..lineTo(cx + r * 0.06, cy - r * 0.52)
        ..quadraticBezierTo(cx + r * 0.42, cy - r * 0.75, cx + r * 0.75, cy - r * 0.22)
        ..quadraticBezierTo(cx + r * 0.08, cy + r * 0.15, cx, cy + r * 0.55);
      canvas.drawPath(leaf, paint);

      // 细微叶柄与三条放射脉
      canvas.drawLine(Offset(cx, cy + r * 0.55), Offset(cx + r * 0.12, cy + r * 0.92), paint);
      canvas.drawLine(Offset(cx, cy + r * 0.25), Offset(cx - r * 0.35, cy - r * 0.32), paint);
      canvas.drawLine(Offset(cx, cy + r * 0.25), Offset(cx + r * 0.35, cy - r * 0.32), paint);
    } else {
      // 极简溯源湖三叠水波纹（象征蒲河校区溯源湖）
      for (var row = 0; row < 3; row++) {
        final y = size.height * (0.45 + row * 0.18);
        final path = Path()..moveTo(size.width * 0.38, y);
        for (var x = size.width * 0.38; x <= size.width; x += 18) {
          final dy = sin((x + row * 14) * 0.09) * 3.2;
          path.lineTo(x, y + dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant LnuCampusMotifPainter oldDelegate) =>
      oldDelegate.isChongshan != isChongshan || oldDelegate.color != color;
}
