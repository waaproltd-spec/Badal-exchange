import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Full-width, ~58px tall, solid BAARI-purple call-to-action. This is the
/// dominant, obvious action on every screen it appears on.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.trailingIcon,
    this.gradient,
    this.leadingIcon,
  });

  /// Optional purple gradient fill instead of the solid color.
  final Gradient? gradient;

  final String label;

  /// Optional icon before the label (e.g. a paper plane).
  final IconData? leadingIcon;

  /// Optional icon after the label (e.g. an arrow).
  final IconData? trailingIcon;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final isDisabled = loading || onPressed == null;
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: isDisabled ? null : gradient,
          boxShadow: isDisabled
              ? const []
              : [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.28),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
        ),
        child: ElevatedButton(
          onPressed: isDisabled ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: gradient != null ? Colors.transparent : AppColors.primary,
            disabledBackgroundColor: AppColors.primary.withOpacity(0.45),
            foregroundColor: Colors.white,
            elevation: 0,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : (trailingIcon == null && leadingIcon == null)
                  ? Text(label, style: AppTextStyles.button)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (leadingIcon != null) ...[Icon(leadingIcon, size: 24), const SizedBox(width: 12)],
                        Flexible(child: Text(label, style: AppTextStyles.button, overflow: TextOverflow.ellipsis)),
                        if (trailingIcon != null) ...[const SizedBox(width: 10), Icon(trailingIcon, size: 22)],
                      ],
                    ),
        ),
      ),
    );
  }
}
