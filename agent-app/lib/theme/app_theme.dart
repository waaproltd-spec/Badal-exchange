import 'package:flutter/material.dart';

/// Dark, high-contrast theme for the Badal Exchange agent app.
///
/// This is a field-operations tool for trained agents: the palette favors
/// clarity and fast scanning (large tap targets, unambiguous status colors)
/// over decoration.
class AppColors {
  AppColors._();

  static const Color background = Color(0xFF0B0F14);
  static const Color surface = Color(0xFF141A21);
  static const Color surfaceRaised = Color(0xFF1C242D);
  static const Color border = Color(0xFF2A333D);
  static const Color textPrimary = Color(0xFFF3F6F9);
  static const Color textSecondary = Color(0xFF9AA7B2);
  static const Color textFaint = Color(0xFF6B7885);

  static const Color primary = Color(0xFF2FB8A5);
  static const Color primaryDark = Color(0xFF1F8C7D);

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

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final colorScheme = base.colorScheme.copyWith(
      brightness: Brightness.dark,
      primary: AppColors.primary,
      onPrimary: Colors.black,
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
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
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
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceRaised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.statusFailed),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textFaint),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.border),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceRaised,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textFaint,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
      ),
      navigationDrawerTheme: const NavigationDrawerThemeData(
        backgroundColor: AppColors.surface,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
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
