import 'package:flutter/material.dart';

import '../models/payment_method.dart';

/// Methods with a logo in assets/methods/<id>.png; others show initials.
const _logos = {
  'evc_plus', 'golis', 'telesom', 'edahab', 'onexbet', 'melbet', 'winwin', 'dbbet', 'betwinner', 'betjam', 'betongame',
  '888starz',
};

/// A payment method's mark: its logo on a rounded tile, or (for a method
/// without one) its initials on a tile in the method's color.
class MethodIcon extends StatelessWidget {
  const MethodIcon({super.key, required this.method, this.size = 48});

  final String method;
  final double size;

  @override
  Widget build(BuildContext context) {
    // A logo a manager gave the platform replaces the one built into the app.
    if (_logos.contains(method) && methodInfo(method).logo == null) {
      return Container(
        key: Key('logo-$method'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.24),
          border: Border.all(color: Colors.black.withOpacity(0.08)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.24),
          child: Image.asset('assets/methods/$method.png', fit: BoxFit.cover, filterQuality: FilterQuality.medium),
        ),
      );
    }
    final info = methodInfo(method);
    if (info.logo != null) {
      // A platform added in the Agent App, with the logo a manager gave it.
      return Container(
        key: Key('logo-$method'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size * 0.24),
          border: Border.all(color: Colors.black.withOpacity(0.08)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.24),
          child: Image.memory(
            info.logo!,
            // The whole logo, on white: a wide or square logo is never cropped.
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            // An unreadable picture falls back to the initials, never an error box.
            errorBuilder: (_, __, ___) => _InitialsIcon(info: info, size: size),
          ),
        ),
      );
    }
    return _InitialsIcon(info: info, size: size);
  }
}

/// The method's initials on a tile in its color.
class _InitialsIcon extends StatelessWidget {
  const _InitialsIcon({required this.info, required this.size});

  final PaymentMethodInfo info;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: info.color,
        shape: info.isPlatform ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: info.isPlatform ? null : BorderRadius.circular(size * 0.28),
      ),
      child: Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: FittedBox(
          child: Text(
            info.initials,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.34),
          ),
        ),
      ),
    );
  }
}

/// A method's full logo on a wide white (or the logo's own dark) rounded
/// tile, 2.4 : 1, never cropped or stretched. Methods without a logo show
/// their [MethodIcon] instead.
class MethodLogo extends StatelessWidget {
  const MethodLogo({super.key, required this.method, this.radius = 12});

  final String method;
  final double radius;

  static const aspect = 2.4;

  @override
  Widget build(BuildContext context) {
    if (!_logos.contains(method) || methodInfo(method).logo != null) {
      final info = methodInfo(method);
      if (info.logo != null) {
        // A platform added in the Agent App: its logo in the same wide tile
        // as the built-in ones, whole (never cropped or stretched).
        return AspectRatio(
          aspectRatio: aspect,
          child: DecoratedBox(
            key: Key('wide-logo-$method'),
            // No fill of its own: the logo's tile is opaque and covers it, and a
            // white layer underneath would show as a thin light outline round a
            // dark tile (the built-in dark logos have none).
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Image.memory(
                info.logo!,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                // An unreadable picture falls back to the initials, never an error box.
                errorBuilder: (_, __, ___) => LayoutBuilder(
                  builder: (context, box) => Center(child: _InitialsIcon(info: info, size: box.maxHeight)),
                ),
              ),
            ),
          ),
        );
      }
      return LayoutBuilder(
        builder: (context, box) => Center(child: MethodIcon(method: method, size: box.maxHeight)),
      );
    }
    return AspectRatio(
      aspectRatio: aspect,
      child: DecoratedBox(
        key: Key('wide-logo-$method'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.asset('assets/methods/wide/$method.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
        ),
      ),
    );
  }
}
