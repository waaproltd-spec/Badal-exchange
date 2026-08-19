import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_provider.dart';
import '../theme/colors.dart';
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
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }
}
