import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'l10n/language.dart';
import 'screens/app_lock_gate.dart';
import 'services/app_lock.dart';
import 'theme/theme_scope.dart';
import 'theme/theme_mode.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiClient.initialize();
  await AppLanguage.load();
  await AppThemeMode.load();
  // Fingerprint unlock: the app starts locked when the agent turned it on.
  await AppLock.instance.load();
  runApp(const BadalAgentApp());
}

class BadalAgentApp extends StatelessWidget {
  const BadalAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Session>(
      create: (_) => Session()..bootstrap(),
      // Light <-> dark and English <-> Somali repaint every screen in place: open
      // screens, typed text and scroll positions stay.
      child: ThemeModeScope(
        builder: (context) => MaterialApp(
          title: 'Badal Exchange Agent',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.current,
          builder: (context, child) => AppLockGate(lock: AppLock.instance, child: child ?? const SizedBox.shrink()),
          home: const _RootRouter(),
        ),
      ),
    );
  }
}

/// Routes between the login screen and the authenticated shell based on
/// [Session.status]. Shown a loading splash while the persisted session
/// (if any) is being restored on cold start.
class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final status = context.watch<Session>().status;
    switch (status) {
      case AuthStatus.unknown:
        return const _SplashScreen();
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        return const HomeShell();
    }
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.currency_exchange_rounded, color: AppColors.primary, size: 48),
            SizedBox(height: 16),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
