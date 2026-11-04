import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme_mode.dart';

/// Theme for the Badal Exchange agent app, using the BAARI palette shared
/// with the customer app: dark purple headers, purple primary actions,
/// light gold / orange accents on a warm cream background.
///
/// This is a field-operations tool for trained agents: the palette favors
/// clarity and fast scanning (large tap targets, unambiguous status colors)
/// over decoration.
class AppColors {
  AppColors._();

  static bool get _dark => AppThemeMode.isDark;

  // BAARI palette (the brand colors: the same in light and dark)
  static const Color purpleDark = Color(0xFF3A0353);
  static const Color purple = Color(0xFF804A8A);
  static const Color purpleSecondary = Color(0xFF8B5FA3);
  static const Color lightGold = Color(0xFFF8D299);
  static const Color accentOrange = Color(0xFFF59E51);
  static const Color cream = Color(0xFFFFF4E6);

  // Roles. Light is a clean white design, dark is black with purple accents.
  static Color get background => _dark ? const Color(0xFF0C0A10) : const Color(0xFFF7F5FB);
  static Color get surface => _dark ? const Color(0xFF16131D) : const Color(0xFFFFFFFF);
  static Color get surfaceRaised => _dark ? const Color(0xFF1D1927) : const Color(0xFFFCFBFE);
  static Color get border => _dark ? const Color(0xFF2E2839) : const Color(0xFFE6DFEF);
  static Color get textPrimary => _dark ? const Color(0xFFF3EEF8) : const Color(0xFF1E0A2B);
  static Color get textSecondary => _dark ? const Color(0xFFB9AEC6) : const Color(0xFF665A72);
  static Color get textFaint => _dark ? const Color(0xFF8C8199) : const Color(0xFF9B90A7);

  /// App bars and the headers of screens.
  static Color get header => _dark ? const Color(0xFF1B0F29) : purpleDark;
  static const Color onHeader = Color(0xFFFFFFFF);

  /// Buttons and active controls.
  static Color get primary => _dark ? const Color(0xFF9A5FDB) : purple;

  /// Strong brand text and icons: deep purple, light lavender when dark.
  static Color get primaryDark => _dark ? const Color(0xFFE7D6F8) : purpleDark;
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// A soft tint of the brand for chips and badges.
  static Color get primaryTint => _dark ? const Color(0xFF2A1D3B) : const Color(0xFFEFE6FA);

  // Status colors — kept consistent across the whole app.
  static const Color statusPending = Color(0xFFE0A63A); // amber
  static const Color statusProcessing = Color(0xFF3B8FE0); // blue
  static const Color statusCompleted = Color(0xFF32B26B); // green
  static const Color statusFailed = Color(0xFFE0503B); // red
  static const Color statusDuplicate = Color(0xFF8A97A3); // gray
  static const Color statusUnmatched = Color(0xFFB07DE0); // purple

  static Color statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return statusPending;
      case 'processing':
        return statusProcessing;
      case 'completed':
      case 'matched':
        return statusCompleted;
      case 'failed':
        return statusFailed;
      case 'duplicate':
        return statusDuplicate;
      case 'unmatched':
        return statusUnmatched;
      default:
        return textSecondary;
    }
  }
}

class AppTheme {
  AppTheme._();

  static ThemeData get current {
    final dark = AppThemeMode.isDark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
    ).copyWith(
      brightness: brightness,
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      secondary: AppColors.accentOrange,
      onSecondary: AppColors.purpleDark,
      tertiary: AppColors.lightGold,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.statusFailed,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.primary,
      dividerColor: AppColors.border,
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.onHeader,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: const TextStyle(
          color: AppColors.onHeader,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceRaised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.statusFailed),
        ),
        labelStyle: TextStyle(color: AppColors.textSecondary),
        hintStyle: TextStyle(color: AppColors.textFaint),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primaryDark,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: AppColors.primary),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: dark ? AppColors.primaryDark : AppColors.primary,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark ? const Color(0xFF2B2140) : AppColors.purpleDark,
        contentTextStyle: const TextStyle(color: AppColors.onHeader),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.surface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textFaint,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: AppColors.surface,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accentOrange,
        foregroundColor: AppColors.purpleDark,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.onPrimary : null,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
      dividerTheme: DividerThemeData(color: AppColors.border),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: AppColors.surface),
      popupMenuTheme: PopupMenuThemeData(color: AppColors.surface),
      chipTheme: ChipThemeData(backgroundColor: AppColors.primaryTint, labelStyle: TextStyle(color: AppColors.textPrimary)),
    );
  }
}

/// A compact, high-contrast pill used everywhere an order/transaction
/// status needs to be shown at a glance.
class StatusBadge extends StatelessWidget {
  final String status;
  final String? label;

  const StatusBadge({super.key, required this.status, this.label});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.statusColor(status);
    final text = (label ?? status).toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
