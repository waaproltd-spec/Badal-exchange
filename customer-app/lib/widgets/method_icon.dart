import 'package:flutter/material.dart';

import '../models/payment_method.dart';

/// Methods with a logo in assets/methods/<id>.png; others show initials.
const _logos = {
  'evc_plus', 'golis', 'telesom', 'edahab', 'onexbet', 'melbet', 'winwin', 'dbbet', 'betwinner', '888starz',
};

/// A payment method's mark: its logo on a rounded tile, or (for a method
/// without one) its initials on a tile in the method's color.
class MethodIcon extends StatelessWidget {
  const MethodIcon({super.key, required this.method, this.size = 48});

  final String method;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (_logos.contains(method)) {
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
