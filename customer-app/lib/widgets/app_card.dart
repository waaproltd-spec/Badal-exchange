import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// White card with a soft rounded border, matching the mockup (20-24px
/// radius, 1-1.5px light purple-gray border, no heavy shadow).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color = Colors.white,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.cardBorder, width: 1.5),
      ),
      child: child,
    );
  }
}
