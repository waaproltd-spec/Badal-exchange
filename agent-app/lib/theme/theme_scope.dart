import 'package:flutter/material.dart';

import '../l10n/language.dart';
import 'theme_mode.dart';

/// Rebuilds the app below it when it turns light or dark ([AppThemeMode]
/// or, on Phone, the phone's own setting) and when the language changes
/// ([AppLanguage]). Every screen rebuilds in the new
/// colors and stays where it is: open screens, typed text and scroll
/// positions are kept. [builder] makes the MaterialApp, with
/// `AppTheme.current`.
class ThemeModeScope extends StatefulWidget {
  const ThemeModeScope({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<ThemeModeScope> createState() => _ThemeModeScopeState();
}

class _ThemeModeScopeState extends State<ThemeModeScope> with WidgetsBindingObserver {
  static final _brightness =
      Listenable.merge([AppThemeMode.current, AppThemeMode.platformBrightness, AppLanguage.current]);
  bool _dark = AppThemeMode.isDark;
  String _language = AppLanguage.current.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _brightness.addListener(_onBrightness);
  }

  @override
  void dispose() {
    _brightness.removeListener(_onBrightness);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    AppThemeMode.platformBrightness.value = WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  void _onBrightness() {
    if ((_dark == AppThemeMode.isDark && _language == AppLanguage.current.value) || !mounted) return;
    setState(() {
      _dark = AppThemeMode.isDark;
      _language = AppLanguage.current.value;
    });
    // AppColors and texts are read in build methods, so every widget builds again.
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
