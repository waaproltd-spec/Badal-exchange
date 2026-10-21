import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light, dark or the phone's setting. Chosen in Profile and remembered on
/// the device; until then it follows the phone.
class AppThemeMode {
  AppThemeMode._();

  static const String _prefsKey = 'theme_mode';

  /// The whole app rebuilds when this (or, on System, the phone's
  /// brightness) changes (see main.dart).
  static final ValueNotifier<ThemeMode> current = ValueNotifier(ThemeMode.system);

  /// The phone's brightness, kept up to date by main.dart.
  static final ValueNotifier<Brightness> platformBrightness =
      ValueNotifier(WidgetsBinding.instance.platformDispatcher.platformBrightness);

  /// Whether the app is dark right now; [AppColors] reads this.
  static bool get isDark => switch (current.value) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system => platformBrightness.value == Brightness.dark,
      };

  static Future<void> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefsKey);
    } catch (_) {}
    current.value = _parse(saved);
  }

  static Future<void> set(ThemeMode mode) async {
    current.value = mode;
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, mode.name);
    } catch (_) {}
  }

  static ThemeMode _parse(String? name) =>
      ThemeMode.values.firstWhere((m) => m.name == name, orElse: () => ThemeMode.system);
}
