import 'dart:async';
import 'dart:io';

import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/theme/theme_mode.dart';
import 'package:flutter/material.dart';

/// The suite runs in English and light mode. To look at the whole suite in
/// Somali and / or dark mode (layout problems show as exceptions), set
/// AGENT_TEST_LANG=so and / or AGENT_TEST_DARK=1; the tests that look for
/// English text then fail on purpose, the layout ones show their problem.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppLanguage.current.value = Platform.environment['AGENT_TEST_LANG'] == 'so' ? AppLanguage.somali : AppLanguage.english;
  AppThemeMode.current.value = Platform.environment['AGENT_TEST_DARK'] == '1' ? ThemeMode.dark : ThemeMode.light;
  await testMain();
}
