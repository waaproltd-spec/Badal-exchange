import 'package:flutter/material.dart';

/// Design tokens for Badal Exchange, matching the signed-off mockup.
class AppColors {
  AppColors._();

  // Brand
  static const Color primary = Color(0xFF7C3AED);
  static const Color primaryDark = Color(0xFF5B21B6);
  static const Color primaryTint = Color(0xFFF1E9FE);

  // Screen / surface backgrounds
  static const Color screenBackground = Color(0xFFFFFFFF);
  static const Color appBackground = Color(0xFFEDEAF3);

  // Cards
  static const Color cardBorder = Color(0xFFEAE4F7);
  static const Color cardBorderSoft = Color(0xFFECE7F6);

  // Fields
  static const Color fieldBackground = Color(0xFFFAF9FC);
  static const Color fieldBorder = Color(0xFFECE7F6);

  // Text
  static const Color textPrimary = Color(0xFF1E1B29);
  static const Color textMuted = Color(0xFF6E6580);
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
