import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BadalAgentApp());
}

class BadalAgentApp extends StatelessWidget {
  const BadalAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Session>(
      create: (_) => Session()..bootstrap(),
      child: MaterialApp(
        title: 'Badal Exchange Agent',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: const _RootRouter(),
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
    return const Scaffold(
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
