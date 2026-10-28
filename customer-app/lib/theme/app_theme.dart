import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';
import 'theme_mode.dart';

class AppTheme {
  AppTheme._();

  /// The theme for [AppThemeMode.isDark] right now; [AppColors] already
  /// follow it, so this only sets the Material defaults to match.
  static ThemeData get current {
    final brightness = AppThemeMode.isDark ? Brightness.dark : Brightness.light;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.purple,
        brightness: brightness,
      ).copyWith(
        primary: AppColors.primary,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        onSurfaceVariant: AppColors.textMuted,
        outline: AppColors.cardBorder,
        error: AppColors.error,
      ),
      scaffoldBackgroundColor: AppColors.screenBackground,
      canvasColor: AppColors.screenBackground,
      dialogBackgroundColor: AppColors.surface,
    );

    return base.copyWith(
      textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.textOnPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.textOnPrimary),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      dividerColor: AppColors.fieldBorder,
      splashFactory: InkRipple.splashFactory,
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppThemeMode.isDark ? AppColors.primaryTint : AppColors.lightGold,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: AppColors.primaryDeep.withOpacity(0.12),
        iconTheme: MaterialStateProperty.resolveWith((states) {
          final selected = states.contains(MaterialState.selected);
          return IconThemeData(color: selected ? AppColors.primaryDark : AppColors.textMuted);
        }),
        labelTextStyle: MaterialStateProperty.resolveWith((states) {
          final selected = states.contains(MaterialState.selected);
          return GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.primaryDark : AppColors.textMuted,
          );
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.primary,
        selectionColor: AppColors.lightGold.withOpacity(AppThemeMode.isDark ? 0.4 : 1),
        selectionHandleColor: AppColors.primary,
      ),
    );
  }
}
