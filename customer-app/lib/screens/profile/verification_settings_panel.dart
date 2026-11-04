import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/app_lock.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../security/pin_setup_screen.dart';
import '../security/verification_screen.dart';

/// Profile: customer verification. One switch turns the PIN lock on (choose a
/// PIN, then optionally the fingerprint) and off (after verifying); when it is
/// on, the fingerprint can be switched and the PIN changed -- both only after
/// the customer verified. Nothing here touches the server.
class VerificationSettingsPanel extends StatefulWidget {
  const VerificationSettingsPanel({super.key, this.lock});

  /// Tests pass their own; the app uses [AppLock.instance].
  final AppLock? lock;

  @override
  State<VerificationSettingsPanel> createState() => _VerificationSettingsPanelState();
}

class _VerificationSettingsPanelState extends State<VerificationSettingsPanel> {
  AppLock get _lock => widget.lock ?? AppLock.instance;
  bool _fingerprintAvailable = false;

  @override
  void initState() {
    super.initState();
    _lock.biometricAvailable().then((v) {
      if (mounted) setState(() => _fingerprintAvailable = v);
    });
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _turnOn() async {
    final pin = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinSetupScreen()));
    if (pin == null || !mounted) return;
    var fingerprint = false;
    if (_fingerprintAvailable) {
      final want = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surface,
          icon: Icon(Icons.fingerprint_rounded, size: 40, color: AppColors.primary),
          content: Text(AppStrings.useFingerprintToo, textAlign: TextAlign.center),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(AppStrings.cancel)),
            TextButton(
              key: const Key('fingerprint-yes'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(AppStrings.useFingerprint),
            ),
          ],
        ),
      );
      if (want == true) fingerprint = await _lock.authenticateBiometric(AppStrings.fingerprintReason);
    }
    await _lock.setPin(pin, biometric: fingerprint);
    if (mounted) _say(AppStrings.verificationLockEnabled);
  }

  Future<void> _turnOff() async {
    if (!await VerificationScreen.confirm(context, lock: _lock)) return;
    await _lock.disable();
    if (mounted) _say(AppStrings.verificationLockDisabled);
  }

  Future<void> _fingerprint(bool on) async {
    if (!on) {
      await _lock.setBiometric(false);
      return;
    }
    if (await _lock.authenticateBiometric(AppStrings.fingerprintReason)) await _lock.setBiometric(true);
  }

  Future<void> _changePin() async {
    if (!await VerificationScreen.confirm(context, lock: _lock) || !mounted) return;
    final pin = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => PinSetupScreen(title: AppStrings.changePin)));
    if (pin == null) return;
    await _lock.setPin(pin);
    if (mounted) _say(AppStrings.pinChanged);
  }

  @override
  Widget build(BuildContext context) {
    final title = AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    return ListenableBuilder(
      listenable: _lock,
      builder: (context, _) {
        final on = _lock.enabled;
        return Container(
          key: const Key('verification-settings'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.cardBorder, width: 1.1),
          ),
          child: Column(children: [
            Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(color: Color(0xFF1B7F5C), shape: BoxShape.circle),
                child: const Icon(Icons.fingerprint_rounded, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(AppStrings.verificationLock, style: title),
                  Text(on ? AppStrings.verificationLockOn : AppStrings.verificationLockOff,
                      key: const Key('verification-state'),
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ]),
              ),
              Switch(key: const Key('lock-switch'), value: on, onChanged: (v) => v ? _turnOn() : _turnOff()),
            ]),
            if (on) ...[
              Row(children: [
                const SizedBox(width: 42),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(AppStrings.fingerprint, style: title.copyWith(fontSize: 14)),
                    if (!_fingerprintAvailable)
                      Text(AppStrings.noFingerprintSet, style: TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
                  ]),
                ),
                Switch(
                  key: const Key('fingerprint-switch'),
                  value: _lock.biometricEnabled,
                  onChanged: _fingerprintAvailable ? _fingerprint : null,
                ),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: TextButton(
                    key: const Key('change-pin'),
                    onPressed: _changePin,
                    child: Text(AppStrings.changePin, style: TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          ]),
        );
      },
    );
  }
}
