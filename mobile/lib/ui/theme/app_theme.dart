/// 辽大书院金石美学移动端视觉主题。
///
/// 1:1 对齐桌面端 `ui_qt/theme.py`：
/// - 古籍宣纸米白 `#F5F1E8`
/// - 溯源湖海蓝 `#003876` / `#002654`
/// - 崇山银杏金 `#D4A574` / `#B8854A`
library;

import 'package:flutter/material.dart';

class LnuColors {
  LnuColors._();

  // 古籍宣纸底色
  static const Color bg = Color(0xFFF5F1E8);
  static const Color bgPaper = Color(0xFFFAF6EC);

  // 卡片与边框
  static const Color card = Color(0xFFFDFCF8);
  static const Color cardSunk = Color(0xFFF0EAD9);
  static const Color border = Color(0xFFE8E2D3);
  static const Color borderDark = Color(0xFFCBBE97);

  // 溯源湖海蓝（主墨色）
  static const Color ink = Color(0xFF003876);
  static const Color inkLight = Color(0xFF1E5599);
  static const Color inkDark = Color(0xFF002654);
  static const Color inkTint = Color(0xFFE2EAF3);

  // 崇山银杏金（点睛色）
  static const Color amber = Color(0xFFD4A574);
  static const Color amberHot = Color(0xFFB8854A);
  static const Color amberDeep = Color(0xFF8E6534);
  static const Color amberLight = Color(0xFFE8C896);
  static const Color amberGlow = Color(0xFFF5E2C4);

  // 文字色
  static const Color text = Color(0xFF1A1A1A);
  static const Color textMuted = Color(0xFF5A5A5A);
  static const Color textDim = Color(0xFF9A9A9A);
  static const Color textInvert = Color(0xFFFDFCF8);

  // 状态色
  static const Color ok = Color(0xFF5B8C5A);
  static const Color warn = Color(0xFFC8923C);
  static const Color err = Color(0xFF9B3838);
  static const Color errLight = Color(0xFFF0D8D8);

  // 桌面同款深海蓝 RUN LOG
  static const Color terminalBg = inkDark;
  static const Color terminalText = Color(0xFFE2E8F0);
}

class LnuTheme {
  LnuTheme._();

  static TextStyle serif(
    double size, {
    FontWeight weight = FontWeight.w600,
    Color color = LnuColors.ink,
    double letterSpacing = 0.8,
    double? height,
  }) {
    return TextStyle(
      fontFamilyFallback: const <String>[
        'Noto Serif SC',
        'Songti SC',
        'STSong',
        'serif',
      ],
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextStyle mono(
    double size, {
    FontWeight weight = FontWeight.w500,
    Color color = LnuColors.ink,
    double letterSpacing = 0.5,
  }) {
    return TextStyle(
      fontFamily: 'monospace',
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
  }

  static ThemeData buildLightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: LnuColors.ink,
      primary: LnuColors.ink,
      secondary: LnuColors.amberHot,
      surface: LnuColors.card,
      error: LnuColors.err,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: LnuColors.bg,
      dividerColor: LnuColors.border,
      appBarTheme: const AppBarTheme(
        backgroundColor: LnuColors.bg,
        foregroundColor: LnuColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: LnuColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: LnuColors.border, width: 1),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: LnuColors.cardSunk.withValues(alpha: 0.65),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: LnuColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: LnuColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: LnuColors.ink, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: LnuColors.inkDark,
        contentTextStyle: const TextStyle(color: LnuColors.textInvert),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
