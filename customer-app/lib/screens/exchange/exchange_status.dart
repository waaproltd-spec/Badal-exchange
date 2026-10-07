import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

/// Status pill for exchange orders (their statuses differ from wallet orders).
class ExchangeStatusBadge extends StatelessWidget {
  const ExchangeStatusBadge({super.key, required this.status});

  final String status;

  static (String, Color) describe(String status) {
    switch (status) {
      case 'pending':
        return ('Waiting for payment', AppColors.statusPending);
      case 'in_progress':
        return ('Sending', AppColors.statusProcessing);
      case 'completed':
        return ('Completed', AppColors.statusCompleted);
      case 'failed':
        return ('Being checked', AppColors.statusFailed);
      case 'cancelled':
        return ('Cancelled', AppColors.statusCancelled);
      default:
        return (status, AppColors.statusCancelled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = describe(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: AppTextStyles.label.copyWith(color: color)),
    );
  }
}
