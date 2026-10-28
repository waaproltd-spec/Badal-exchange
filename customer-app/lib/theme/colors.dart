import 'package:flutter/material.dart';

import 'theme_mode.dart';

/// Design tokens for BAARI.
///
/// Palette: deep purple headers, purple card gradients, light gold for
/// deposit / highlights, orange for withdraw / important accents, on a
/// warm cream background. The role colors below follow
/// [AppThemeMode]: in dark mode the background is a deep plum, cards are a
/// lighter plum and text is light.
class AppColors {
  AppColors._();

  // Brand palette
  static const Color purpleDark = Color(0xFF3A0353);
  static const Color purple = Color(0xFF804A8A);
  static const Color purpleSecondary = Color(0xFF8B5FA3);
  static const Color lightGold = Color(0xFFF8D299);
  static const Color accentOrange = Color(0xFFF59E51);
  static const Color cream = Color(0xFFFFF4E6);

  // Roles
  static bool get _dark => AppThemeMode.isDark;

  static Color get primary => _dark ? const Color(0xFF9F6AAB) : purple;

  /// Strong brand text and icons: deep purple, light lavender when dark.
  static Color get primaryDark => _dark ? const Color(0xFFE6CDEE) : purpleDark;
  static const Color primaryDeep = purpleDark;
  static Color get primaryTint => _dark ? const Color(0xFF33213F) : const Color(0xFFF3E8F5);
  static const Color header = purpleDark;

  static const Color gold = lightGold;
  static const Color goldDark = accentOrange;
  static Color get goldTint => _dark ? const Color(0xFF3B2F1C) : const Color(0xFFFDF0DA);

  /// Header sections (home wallet header).
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purpleDark, Color(0xFF4A0D66)],
  );

  /// Main cards (balance card).
  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purple, purpleSecondary],
  );

  /// Logo tile.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purpleSecondary, purple, purpleDark],
    stops: [0.0, 0.5, 1.0],
  );

  // Screen / surface backgrounds
  static Color get screenBackground => _dark ? const Color(0xFF140A1B) : cream;
  static Color get appBackground => screenBackground;

  /// Cards, tiles, sheets and the navigation bar.
  static Color get surface => _dark ? const Color(0xFF22152B) : Colors.white;

  // Cards
  static Color get cardBorder => _dark ? const Color(0xFF3A2A45) : const Color(0xFFF0DFC8);
  static Color get cardBorderSoft => _dark ? const Color(0xFF2C1F35) : const Color(0xFFF5E8D6);

  // Fields
  static Color get fieldBackground => _dark ? const Color(0xFF2A1C34) : Colors.white;
  static Color get fieldBorder => _dark ? const Color(0xFF3A2A45) : const Color(0xFFF0DFC8);

  // Text
  static Color get textPrimary => _dark ? const Color(0xFFF4ECF7) : const Color(0xFF24062F);
  static Color get textMuted => _dark ? const Color(0xFFB7A6C0) : const Color(0xFF7B6683);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Payment method icons
  static Color get evcMethod => primary;
  static const Color winwinMethod = accentOrange;

  // Status (semantic, independent of the brand palette)
  static const Color statusPending = Color(0xFFF59E0B);
  static const Color statusProcessing = Color(0xFF3B82F6);
  static const Color statusCompleted = Color(0xFF16A34A);
  static const Color statusFailed = Color(0xFFDC2626);
  static const Color statusCancelled = Color(0xFF9CA3AF);

  static const Color error = Color(0xFFDC2626);
  static const Color success = Color(0xFF16A34A);
}
