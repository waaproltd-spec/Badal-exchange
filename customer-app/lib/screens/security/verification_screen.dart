import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../services/app_lock.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../widgets/brand/baari_logo.dart';
import 'pin_pad.dart';

/// Customer verification: fingerprint (asked for as soon as the screen opens,
/// when the customer turned it on), the PIN pad, and the account password as
/// the way in when the fingerprint is not available or the PIN is forgotten.
///
/// It is used full screen over the app when the app is locked, and as a page
/// when a setting must be confirmed ([confirm]).
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({
    super.key,
    required this.lock,
    required this.onVerified,
    required this.verifyPassword,
    this.onTooManyAttempts,
    this.onCancel,
    this.name,
  });

  final AppLock lock;

  /// Called once, after the fingerprint, the PIN or the password was accepted.
  final VoidCallback onVerified;

  /// Checks the account password with the server; throws [ApiException] when it is wrong.
  final Future<void> Function(String password) verifyPassword;

  /// Ten wrong PINs: the app signs the customer out so they log in with the password.
  final VoidCallback? onTooManyAttempts;

  /// Shows a close button (when opened as a page).
  final VoidCallback? onCancel;
  final String? name;

  /// Opens verification as a page; true when the customer verified.
  static Future<bool> confirm(BuildContext context, {AppLock? lock}) async {
    final appLock = lock ?? AppLock.instance;
    final auth = context.read<AuthProvider>();
    final api = context.read<CustomerApi>();
    final navigator = Navigator.of(context);
    final ok = await navigator.push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (routeContext) => VerificationScreen(
        lock: appLock,
        name: auth.user?.name,
        onVerified: () => Navigator.of(routeContext).pop(true),
        onCancel: () => Navigator.of(routeContext).pop(false),
        verifyPassword: (password) => api.verifyPassword(phone: auth.user?.phone ?? '', password: password),
        onTooManyAttempts: () {
          Navigator.of(routeContext).pop(false);
          unawaited(auth.logoutToLogin(AppStrings.tooManyPins));
        },
      ),
    ));
    return ok == true;
  }

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  String _pin = '';
  String? _error;
  bool _busy = false;
  bool _passwordMode = false;
  bool _showPassword = false;
  DateTime? _waitUntil;
  Timer? _ticker;
  final _password = TextEditingController();
  bool _done = false;

  bool get _waiting => _waitUntil != null && DateTime.now().isBefore(_waitUntil!);

  @override
  void initState() {
    super.initState();
    if (widget.lock.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fingerprint());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _password.dispose();
    super.dispose();
  }

  void _verified() {
    if (_done) return;
    _done = true;
    widget.onVerified();
  }

  Future<void> _fingerprint() async {
    if (_busy || _done || !widget.lock.biometricEnabled) return;
    _busy = true;
    final ok = await widget.lock.authenticateBiometric(AppStrings.fingerprintReason);
    _busy = false;
    if (!mounted) return;
    if (ok) {
      _verified();
    } else {
      setState(() => _error = AppStrings.fingerprintFailed);
    }
  }

  Future<void> _digit(String d) async {
    if (_busy || _waiting || _pin.length >= AppLock.pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == AppLock.pinLength) await _submitPin();
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _submitPin() async {
    _busy = true;
    final attempt = await widget.lock.checkPin(_pin);
    _busy = false;
    if (!mounted) return;
    switch (attempt.result) {
      case PinCheck.ok:
        _verified();
      case PinCheck.tooMany:
        setState(() {
          _pin = '';
          _error = AppStrings.tooManyPins;
        });
        widget.onTooManyAttempts?.call();
      case PinCheck.wrong:
      case PinCheck.waiting:
        setState(() => _pin = '');
        if (attempt.wait > Duration.zero) {
          _startWait(attempt.wait);
        } else {
          setState(() => _error = AppStrings.wrongPin);
        }
    }
  }

  void _startWait(Duration wait) {
    _waitUntil = DateTime.now().add(wait);
    _ticker?.cancel();
    void update() {
      final left = _waitUntil!.difference(DateTime.now());
      if (left <= Duration.zero) {
        _ticker?.cancel();
        if (mounted) setState(() => _error = null);
      } else if (mounted) {
        setState(() => _error = AppStrings.pinWait(left.inSeconds + 1));
      }
    }

    update();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => update());
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
      await widget.lock.passwordVerified();
      if (!mounted) return;
      _verified();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.invalidLogin);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bio = widget.lock.biometricEnabled;
    return Scaffold(
      key: const Key('verification-screen'),
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The app behind is blurred and darkened; the card floats over it.
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(color: AppColors.purpleDark.withOpacity(0.86)),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Container(
                    key: const Key('verification-card'),
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.42),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white.withOpacity(0.14)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onCancel != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: const Key('verification-close'),
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded, color: Colors.white),
                              onPressed: widget.onCancel,
                            ),
                          )
                        else
                          const SizedBox(height: 8),
                        SizedBox(
                          width: 84,
                          height: 78,
                          child: Stack(clipBehavior: Clip.none, children: [
                            const Positioned(left: 0, top: 0, child: BaariLogoMark(size: 72, onDark: true)),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: AppColors.purple,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black.withOpacity(0.4), width: 2),
                                ),
                                child: const Icon(Icons.lock_rounded, color: Colors.white, size: 15),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 10),
                        Text(AppStrings.welcomeBack,
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                        if ((widget.name ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(widget.name!, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          _passwordMode ? AppStrings.verifyPasswordSubtitle : AppStrings.verifySubtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13.5),
                        ),
                        const SizedBox(height: 10),
                        Divider(height: 1, color: Colors.white.withOpacity(0.14)),
                        const SizedBox(height: 14),
                        if (_passwordMode) _passwordPanel() else _pinPanel(bio),
                        TextButton(
                          key: const Key('switch-method'),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _passwordMode = !_passwordMode;
                                    _error = null;
                                    _pin = '';
                                  }),
                          child: Text(_passwordMode ? AppStrings.usePinInstead : AppStrings.usePasswordInstead,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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

  Widget _pinPanel(bool bio) => PinPad(
        entered: _pin.length,
        error: _error,
        enabled: !_busy && !_waiting,
        onDigit: _digit,
        onBackspace: _backspace,
        leading: bio ? FingerprintKey(onTap: _fingerprint) : null,
      );

  Widget _passwordPanel() => Padding(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            TextField(
              key: const Key('verify-password-field'),
              controller: _password,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submitPassword(),
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                labelText: AppStrings.accountPassword,
                labelStyle: TextStyle(color: Colors.white.withOpacity(0.75)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withOpacity(0.5))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white, width: 1.6)),
                suffixIcon: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      color: Colors.white.withOpacity(0.8)),
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
                      key: const Key('password-error'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFFB3C1), fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                key: const Key('verify-password'),
                onPressed: _busy ? null : _submitPassword,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.purpleDark,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : Text(AppStrings.unlock, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      );
}
