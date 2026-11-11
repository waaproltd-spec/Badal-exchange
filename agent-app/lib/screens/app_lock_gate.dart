import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../l10n/tr.dart';
import '../services/app_lock.dart';
import '../state/session.dart';
import 'unlock_screen.dart';

/// Wraps the whole app (MaterialApp.builder): while the app is locked and an
/// agent is signed in, the unlock screen covers everything, dialogs and pages
/// included. It locks when the app opens and when it comes back after a
/// minute in the background.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.lock, required this.child, this.passwordCheck});

  final AppLock lock;
  final Widget child;

  /// How the account password is checked (tests pass their own); by default
  /// [AppLockGate.verifyPassword].
  final Future<void> Function(Session session, String password)? passwordCheck;

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

  /// The account password, checked the way the login checks it (nothing else changes).
  static Future<void> verifyPassword(Session session, String password) async {
    final phone = session.profile?.phone ?? '';
    if (phone.isEmpty) {
      throw ApiException(statusCode: 0, code: 'PROFILE_NOT_LOADED', message: tr('Please wait a moment and try again.'));
    }
    await session.api.client.signIn(identifier: phone, password: password);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return ListenableBuilder(
      listenable: widget.lock,
      builder: (context, _) {
        final showLock = widget.lock.locked && session.status == AuthStatus.loggedIn;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (showLock)
              Positioned.fill(
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => UnlockScreen(
                        lock: widget.lock,
                        name: session.profile?.name ?? session.agentDisplayName,
                        onVerified: widget.lock.unlock,
                        verifyPassword: (password) => (widget.passwordCheck ?? _AppLockGateState.verifyPassword)(session, password),
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
