import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Full-width outlined button used for the secondary action on a screen
/// (e.g. "Withdraw" next to a primary "Deposit", or a destructive action
/// like "Log Out" with [color] overridden to [AppColors.error]).
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = AppColors.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Text(label, style: AppTextStyles.button.copyWith(color: color)),
      ),
    );
  }
}
