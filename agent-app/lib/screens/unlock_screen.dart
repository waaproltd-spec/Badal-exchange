import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../api/api_exception.dart';
import '../l10n/tr.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';

/// Unlocking the app: the fingerprint (asked for as soon as the screen opens)
/// and the account password as the other way in, for a fingerprint that does
/// not work or a phone without one. Purple and white like the login screen,
/// over the blurred app.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({
    super.key,
    required this.lock,
    required this.onVerified,
    required this.verifyPassword,
    this.name,
    this.onCancel,
  });

  final AppLock lock;

  /// Called once, after the fingerprint or the password was accepted.
  final VoidCallback onVerified;

  /// Checks the account password with the server; throws [ApiException] when it is wrong.
  final Future<void> Function(String password) verifyPassword;
  final String? name;

  /// Shows a close button (when opened as a page).
  final VoidCallback? onCancel;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _password = TextEditingController();
  bool _passwordMode = false;
  bool _showPassword = false;
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fingerprint());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _verified() {
    if (_done) return;
    _done = true;
    widget.onVerified();
  }

  Future<void> _fingerprint() async {
    if (_busy || _done || _passwordMode) return;
    _busy = true;
    final ok = await widget.lock.authenticate(tr('Verify your identity to open Badal Exchange'));
    _busy = false;
    if (!mounted) return;
    if (ok) {
      _verified();
    } else {
      setState(() => _error = tr('Fingerprint not recognized. Use your password.'));
    }
  }

  Future<void> _submitPassword() async {
    final password = _password.text;
    if (_busy || password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.verifyPassword(password);
      if (!mounted) return;
      _verified();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = tr(e.message));
    } catch (_) {
      if (mounted) setState(() => _error = tr('Something went wrong. Please try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('unlock-screen'),
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(color: AppColors.purpleDark.withOpacity(0.86)),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
                    key: const Key('unlock-card'),
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: AppColors.border),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 30, offset: const Offset(0, 12))],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onCancel != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: const Key('unlock-close'),
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.close_rounded, color: AppColors.textSecondary),
                              onPressed: widget.onCancel,
                            ),
                          )
                        else
                          const SizedBox(height: 8),
                        SizedBox(
                          width: 84,
                          height: 78,
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned(
                              left: 0,
                              top: 0,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: Image.asset('assets/brand/logo.png', width: 72, height: 72),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: AppColors.surface, width: 2),
                                ),
                                child: const Icon(Icons.lock_rounded, color: Colors.white, size: 15),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Tx('Welcome back',
                            style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
                        if ((widget.name ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(widget.name!, style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                        ],
                        const SizedBox(height: 4),
                        Tx(
                          _passwordMode ? 'Enter your account password' : 'Touch the fingerprint sensor to unlock',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5),
                        ),
                        const SizedBox(height: 18),
                        if (_passwordMode) _passwordPanel() else _fingerprintPanel(),
                        TextButton(
                          key: const Key('unlock-switch'),
                          onPressed: _busy
                              ? null
                              : () {
                                  setState(() {
                                    _passwordMode = !_passwordMode;
                                    _error = null;
                                  });
                                  if (!_passwordMode) _fingerprint();
                                },
                          child: Tx(_passwordMode ? 'Use fingerprint' : 'Use password instead',
                              style: TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fingerprintPanel() => Column(children: [
        InkWell(
          key: const Key('unlock-fingerprint'),
          customBorder: const CircleBorder(),
          onTap: _busy ? null : _fingerprint,
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF8A1CF0), Color(0xFF4B0A8F)]),
              boxShadow: [BoxShadow(color: AppColors.purpleDark.withOpacity(0.35), blurRadius: 18, offset: const Offset(0, 8))],
            ),
            child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 54),
          ),
        ),
        Container(
          height: 44,
          alignment: Alignment.center,
          child: _error == null
              ? null
              : Text(_error!,
                  key: const Key('unlock-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.statusFailed, fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
      ]);

  Widget _passwordPanel() => Column(children: [
        TextField(
          key: const Key('unlock-password-field'),
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _submitPassword(),
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: tr('Account password'),
            prefixIcon: Icon(Icons.lock_rounded, color: AppColors.primaryDark),
            suffixIcon: IconButton(
              key: const Key('unlock-toggle-password'),
              tooltip: _showPassword ? tr('Hide password') : tr('Show password'),
              icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: AppColors.primaryDark),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
        Container(
          height: 40,
          alignment: Alignment.center,
          child: _error == null
              ? null
              : Text(_error!,
                  key: const Key('unlock-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.statusFailed, fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF8A1CF0), Color(0xFF4B0A8F)]),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('unlock-password-submit'),
                borderRadius: BorderRadius.circular(18),
                onTap: _busy ? null : _submitPassword,
                child: Center(
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white))
                      : Tx('Unlock', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ),
        ),
      ]);
}
