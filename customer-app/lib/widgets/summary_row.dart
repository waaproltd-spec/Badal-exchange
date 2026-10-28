import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// A "label ... value" line used inside [AppCard]s on confirmation,
/// result, and order-detail screens.
class SummaryRow extends StatelessWidget {
  const SummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
    this.valueKey,
  });

  final String label;
  final String value;
  final bool emphasize;

  /// For a value that is a note rather than data (e.g. "Checking...").
  final Color? valueColor;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Both sides wrap, so long labels (e.g. in Somali) never overflow.
          Flexible(child: Text(label, style: AppTextStyles.muted)),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.end,
              style: emphasize
                  ? AppTextStyles.title.copyWith(color: valueColor ?? AppColors.primaryDark)
                  : AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin divider matching the field/card border tone, for separating
/// [SummaryRow]s inside an [AppCard].
class SummaryDivider extends StatelessWidget {
  const SummaryDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(color: AppColors.fieldBorder, height: 1);
  }
}
