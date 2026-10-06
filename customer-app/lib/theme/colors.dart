import 'package:flutter/material.dart';

/// Design tokens for BAARI.
///
/// Brand palette: a deep "Baari green" paired with a warm gold, inspired by
/// Somali colours and tuned for a clean fintech / wallet look.
class AppColors {
  AppColors._();

  // Brand
  static const Color primary = Color(0xFF0A8F4E);
  static const Color primaryDark = Color(0xFF056B39);
  static const Color primaryDeep = Color(0xFF033D21);
  static const Color primaryTint = Color(0xFFE6F5EC);

  static const Color gold = Color(0xFFF7B500);
  static const Color goldDark = Color(0xFFD99A00);
  static const Color goldTint = Color(0xFFFFF6DC);

  /// Hero gradient used behind the wallet header and on the logo mark.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0FA65C), primaryDark, primaryDeep],
    stops: [0.0, 0.55, 1.0],
  );

  // Screen / surface backgrounds
  static const Color screenBackground = Color(0xFFFFFFFF);
  static const Color appBackground = Color(0xFFF4F7F5);

  // Cards
  static const Color cardBorder = Color(0xFFE3ECE6);
  static const Color cardBorderSoft = Color(0xFFEAF0EC);

  // Fields
  static const Color fieldBackground = Color(0xFFF8FAF9);
  static const Color fieldBorder = Color(0xFFE3ECE6);

  // Text
  static const Color textPrimary = Color(0xFF0F1F17);
  static const Color textMuted = Color(0xFF66756D);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Method brand colors
  static const Color evcGreen = Color(0xFF149954);
  static const Color winwinGreen = Color(0xFF0FA968);

  // Status
  static const Color statusPending = Color(0xFFF59E0B);
  static const Color statusProcessing = Color(0xFF3B82F6);
  static const Color statusCompleted = Color(0xFF16A34A);
  static const Color statusFailed = Color(0xFFDC2626);
  static const Color statusCancelled = Color(0xFF9CA3AF);

  static const Color error = Color(0xFFDC2626);
  static const Color success = Color(0xFF16A34A);
}
