import 'package:flutter/material.dart';

import '../../services/app_lock.dart';

/// The PIN dots and the number keys, shared by the verification screen and
/// the PIN setup. White on the purple brand background.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.entered,
    required this.onDigit,
    required this.onBackspace,
    this.leading,
    this.error,
    this.enabled = true,
  });

  /// How many digits are typed so far.
  final int entered;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// The key at the bottom left (the fingerprint key), or empty space.
  final Widget? leading;
  final String? error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          key: const Key('pin-dots'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < AppLock.pinLength; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < entered ? Colors.white : Colors.transparent,
                  border: Border.all(color: Colors.white.withOpacity(0.8), width: 1.6),
                ),
              ),
          ],
        ),
        Container(
          height: 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: error == null
              ? null
              : Text(error!,
                  key: const Key('pin-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFFB3C1), fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final d in row) _Key(label: d, onTap: enabled ? () => onDigit(d) : null),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _KeySlot(child: leading),
            _Key(label: '0', onTap: enabled ? () => onDigit('0') : null),
            _KeySlot(
              child: _RoundButton(
                key: const Key('pin-backspace'),
                onTap: enabled ? onBackspace : null,
                child: const Icon(Icons.backspace_outlined, color: Colors.white, size: 24),
                plain: true,
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

class _KeySlot extends StatelessWidget {
  const _KeySlot({this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: SizedBox(width: 62, height: 62, child: child));
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _KeySlot(
        child: _RoundButton(
          key: Key('pin-key-$label'),
          onTap: onTap,
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600)),
        ),
      );
}

/// A round 68 px touch target.
class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.child, required this.onTap, this.plain = false});
  final Widget child;
  final VoidCallback? onTap;
  final bool plain;

  @override
  Widget build(BuildContext context) => Material(
        color: plain ? Colors.transparent : Colors.white.withOpacity(0.12),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: child),
        ),
      );
}

/// A round key for the fingerprint, to pass as [PinPad.leading].
class FingerprintKey extends StatelessWidget {
  const FingerprintKey({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _RoundButton(
        key: const Key('use-fingerprint'),
        onTap: onTap,
        plain: true,
        child: const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 34),
      );
}
