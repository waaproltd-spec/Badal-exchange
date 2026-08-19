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
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.muted),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: emphasize
                  ? AppTextStyles.title.copyWith(color: AppColors.primaryDark)
                  : AppTextStyles.body.copyWith(fontWeight: FontWeight.w700),
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
    return const Divider(color: AppColors.fieldBorder, height: 1);
  }
}
