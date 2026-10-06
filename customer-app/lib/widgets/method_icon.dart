import 'package:flutter/material.dart';

import '../models/payment_method.dart';

/// A payment method's mark: its short initials on a tile in the method's
/// color. Mobile money is a rounded square, betting platforms a circle.
class MethodIcon extends StatelessWidget {
  const MethodIcon({super.key, required this.method, this.size = 48});

  final String method;
  final double size;

  @override
  Widget build(BuildContext context) {
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
