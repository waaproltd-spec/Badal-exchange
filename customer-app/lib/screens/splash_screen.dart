import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/customer_api.dart';
import '../state/auth_provider.dart';
import '../theme/colors.dart';
import '../widgets/brand/baari_logo.dart';
import 'auth/login_screen.dart';
import 'root/root_shell.dart';

/// Waits for [AuthProvider] to restore any persisted session, then routes
/// to the app shell or the login screen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late final AuthProvider _auth;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    // Shared payment-method catalog; doesn't block startup.
    unawaited(context.read<CustomerApi>().loadMethodCatalog());
    if (_auth.initializing) {
      _auth.addListener(_onAuthChanged);
    } else {
      _redirect();
    }
  }

  void _onAuthChanged() {
    if (!_auth.initializing) {
      _auth.removeListener(_onAuthChanged);
      _redirect();
    }
  }

  void _redirect() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _auth.isAuthenticated ? const RootShell() : const LoginScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BaariLogo(markSize: 64),
            SizedBox(height: 40),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
