import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/app_lock.dart';
import '../../theme/colors.dart';
import 'pin_pad.dart';

/// Choosing a PIN: typed twice. Pops with the PIN, or null when cancelled.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, this.title});

  /// Defaults to "Create a PIN".
  final String? title;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _pin = '';
  String? _first;
  String? _error;

  void _digit(String d) {
    if (_pin.length >= AppLock.pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == AppLock.pinLength) _complete();
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  void _complete() {
    final first = _first;
    if (first == null) {
      if (!AppLock.isStrongPin(_pin)) {
        setState(() {
          _pin = '';
          _error = AppStrings.weakPin;
        });
        return;
      }
      setState(() {
        _first = _pin;
        _pin = '';
      });
      return;
    }
    if (first != _pin) {
      setState(() {
        _first = null;
        _pin = '';
        _error = AppStrings.pinsDontMatch;
      });
      return;
    }
    Navigator.of(context).pop(first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('pin-setup-screen'),
      backgroundColor: AppColors.purpleDark,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.headerGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        key: const Key('pin-setup-close'),
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    Text(widget.title ?? AppStrings.createPin,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(_first == null ? AppStrings.createPinHelp : AppStrings.confirmPinHelp,
                        key: const Key('pin-setup-help'),
                        style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14.5)),
                    const SizedBox(height: 14),
                    PinPad(entered: _pin.length, error: _error, onDigit: _digit, onBackspace: _backspace),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(AppStrings.fingerprintPrivacy,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12)),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
