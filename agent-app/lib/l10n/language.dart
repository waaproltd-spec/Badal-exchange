import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's language: English or Somali. Chosen in Account and remembered on
/// the device; until then it follows the phone (Somali phones start in Somali,
/// everything else in English).
class AppLanguage {
  AppLanguage._();

  static const String english = 'en';
  static const String somali = 'so';
  static const String _prefsKey = 'app_language';

  /// The whole app rebuilds when this changes (see main.dart).
  static final ValueNotifier<String> current = ValueNotifier(_phoneLanguage());

  static String _phoneLanguage() {
    try {
      return PlatformDispatcher.instance.locale.languageCode == somali ? somali : english;
    } catch (_) {
      return english;
    }
  }

  static bool get isSomali => current.value == somali;

  static Future<void> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefsKey);
    } catch (_) {}
    current.value = saved == somali || saved == english ? saved! : _phoneLanguage();
  }

  static Future<void> set(String code) async {
    current.value = code == somali ? somali : english;
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, current.value);
    } catch (_) {}
  }
}
