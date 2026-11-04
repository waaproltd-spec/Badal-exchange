import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../services/app_lock.dart';
import '../../state/auth_provider.dart';
import 'verification_screen.dart';

/// Wraps the whole app (MaterialApp.builder): while the app is locked and a
/// customer is signed in, the verification screen covers everything, dialogs
/// and pages included. It locks when the app opens and when it comes back
/// after a minute in the background.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.lock, required this.child});

  final AppLock lock;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      widget.lock.appPaused();
    } else if (state == AppLifecycleState.resumed) {
      widget.lock.appResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return ListenableBuilder(
      listenable: widget.lock,
      builder: (context, _) {
        final showLock = widget.lock.locked && auth.isAuthenticated;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (showLock)
              Positioned.fill(
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => VerificationScreen(
                        lock: widget.lock,
                        name: auth.user?.name,
                        onVerified: widget.lock.unlock,
                        verifyPassword: (password) =>
                            context.read<CustomerApi>().verifyPassword(phone: auth.user?.phone ?? '', password: password),
                        onTooManyAttempts: () => unawaited(auth.logoutToLogin(AppStrings.tooManyPins)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
