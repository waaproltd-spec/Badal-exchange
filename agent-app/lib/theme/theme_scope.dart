import 'package:flutter/material.dart';

import 'theme_mode.dart';

/// Rebuilds the app below it when it turns light or dark ([AppThemeMode]
/// or, on Phone, the phone's own setting). Every screen rebuilds in the new
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
  static final _brightness = Listenable.merge([AppThemeMode.current, AppThemeMode.platformBrightness]);
  bool _dark = AppThemeMode.isDark;

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
    if (_dark == AppThemeMode.isDark || !mounted) return;
    setState(() => _dark = AppThemeMode.isDark);
    // AppColors are read in build methods, so every widget builds again.
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
