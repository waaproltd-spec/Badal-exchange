import 'package:flutter/material.dart';

import '../l10n/language.dart';
import '../l10n/tr.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';
import '../theme/theme_mode.dart';
import 'console_widgets.dart';

/// Account > Settings: the language (English / Somali), the appearance (light /
/// dark / the phone's setting) and the fingerprint unlock. The language and the
/// appearance are kept on this phone and the whole app changes at once.
class AppSettingsPanel extends StatefulWidget {
  const AppSettingsPanel({super.key, this.lock});

  /// Tests pass their own; the app uses [AppLock.instance].
  final AppLock? lock;

  @override
  State<AppSettingsPanel> createState() => _AppSettingsPanelState();
}

class _AppSettingsPanelState extends State<AppSettingsPanel> {
  AppLock get _lock => widget.lock ?? AppLock.instance;
  bool _fingerprintAvailable = false;

  @override
  void initState() {
    super.initState();
    _lock.biometricAvailable().then((v) {
      if (mounted) setState(() => _fingerprintAvailable = v);
    });
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _fingerprint(bool on) async {
    if (!on) {
      await _lock.disable();
      if (mounted) _say(tr('Fingerprint unlock is off.'));
      return;
    }
    if (!_fingerprintAvailable) {
      _say(tr('No fingerprint is set up on this phone.'));
      return;
    }
    // Switched on only after the fingerprint matched once, so it is known to work.
    if (await _lock.authenticate(tr('Verify your identity to open Badal Exchange'))) {
      await _lock.enable();
      if (mounted) _say(tr('Fingerprint unlock is on.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      key: const Key('app-settings'),
      child: ListenableBuilder(
        listenable: Listenable.merge([AppLanguage.current, AppThemeMode.current, _lock]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(
              icon: Icons.language_rounded,
              title: tr('Language'),
              child: _Seg<String>(
                key: const Key('language'),
                value: AppLanguage.current.value,
                onChanged: AppLanguage.set,
                options: const [(AppLanguage.english, 'English'), (AppLanguage.somali, 'Soomaali')],
              ),
            ),
            const SizedBox(height: 14),
            _Row(
              icon: Icons.dark_mode_rounded,
              title: tr('Appearance'),
              child: _Seg<ThemeMode>(
                key: const Key('theme-mode'),
                value: AppThemeMode.current.value,
                onChanged: AppThemeMode.set,
                options: [
                  (ThemeMode.light, tr('Light')),
                  (ThemeMode.dark, tr('Dark')),
                  (ThemeMode.system, tr('Phone')),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: AppColors.border),
            Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(color: Color(0xFF1B7F5C), shape: BoxShape.circle),
                child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Tx('Fingerprint unlock', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  Tx(
                    _lock.enabled
                        ? 'On: the app asks for your fingerprint when it opens. Your password is the backup.'
                        : 'Off',
                    key: const Key('fingerprint-state'),
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              Switch(key: const Key('fingerprint-switch'), value: _lock.enabled, onChanged: _fingerprint),
            ]),
            Tx('Your fingerprint stays on your phone. It is never sent to our servers.',
                style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.child});
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 20, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        ]),
        const SizedBox(height: 8),
        child,
      ]);
}

/// A pill selector (language, appearance).
class _Seg<T> extends StatelessWidget {
  const _Seg({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(22)),
        child: Row(children: [
          for (final (v, label) in options)
            Expanded(
              child: GestureDetector(
                key: Key('seg-$label'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                  decoration: BoxDecoration(
                    gradient: v == value ? const LinearGradient(colors: [Color(0xFF8A1CF0), Color(0xFF5A22C9)]) : null,
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: v == value ? Colors.white : AppColors.textSecondary)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}
