import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// The customer's registered number, which mobile money deposits come from
/// and withdrawals go to: PHONE NUMBER above +252, the number and a lock.
/// Shown, never edited. Sits beside the amount field.
class OwnPhoneBox extends StatelessWidget {
  const OwnPhoneBox({super.key, required this.local});

  /// The 9 digits after 252; null when the registered number can't be read.
  final String? local;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 18,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(AppStrings.phoneNumber.toUpperCase(), maxLines: 1, style: AppTextStyles.label),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 58,
          decoration: BoxDecoration(
            color: AppColors.fieldBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.fieldBorder, width: 1.5),
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              Text('+252', style: AppTextStyles.muted.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 10), color: AppColors.fieldBorder),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    local ?? '—',
                    style: AppTextStyles.fieldValue
                        .copyWith(fontWeight: FontWeight.w800, color: AppColors.textPrimary.withOpacity(0.8)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.lock_outline_rounded, size: 20, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
