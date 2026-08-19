import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

/// Typography tokens. 'Plus Jakarta Sans' everywhere, falling back to the
/// platform default if the font cannot be fetched.
class AppTextStyles {
  AppTextStyles._();

  static TextStyle get _base => GoogleFonts.plusJakartaSans();

  /// Screen titles, e.g. "Choose a method". ~28px / 800 weight.
  static TextStyle get headline => _base.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
        height: 1.2,
      );

  /// Section / app-bar titles.
  static TextStyle get title => _base.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      );

  /// Large emphasized numbers (balances, deposit codes).
  static TextStyle get amountLarge => _base.copyWith(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      );

  /// Body copy, ~15-17px.
  static TextStyle get body => _base.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      );

  static TextStyle get bodyLarge => _base.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      );

  /// 12px uppercase muted label above fields / stat blocks.
  static TextStyle get label => _base.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.textMuted,
        letterSpacing: 0.6,
      );

  /// Large readable field value text.
  static TextStyle get fieldValue => _base.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      );

  static TextStyle get muted => _base.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textMuted,
      );

  static TextStyle get button => _base.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: AppColors.textOnPrimary,
      );
}
