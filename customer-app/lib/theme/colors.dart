import 'package:flutter/material.dart';

/// Design tokens for BAARI.
///
/// Palette: deep purple headers, purple card gradients, light gold for
/// deposit / highlights, orange for withdraw / important accents, on a
/// warm cream background.
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
  static const Color primary = purple;
  static const Color primaryDark = purpleDark;
  static const Color primaryDeep = purpleDark;
  static const Color primaryTint = Color(0xFFF3E8F5);
  static const Color header = purpleDark;

  static const Color gold = lightGold;
  static const Color goldDark = accentOrange;
  static const Color goldTint = Color(0xFFFDF0DA);

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
  static const Color screenBackground = cream;
  static const Color appBackground = cream;

  // Cards
  static const Color cardBorder = Color(0xFFF0DFC8);
  static const Color cardBorderSoft = Color(0xFFF5E8D6);

  // Fields
  static const Color fieldBackground = Color(0xFFFFFFFF);
  static const Color fieldBorder = Color(0xFFF0DFC8);

  // Text
  static const Color textPrimary = Color(0xFF24062F);
  static const Color textMuted = Color(0xFF7B6683);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Payment method icons
  static const Color evcMethod = purple;
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
