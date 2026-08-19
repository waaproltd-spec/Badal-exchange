import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Small pill showing an order's status with the palette's semantic
/// colors: pending=amber, processing=blue, completed=green,
/// failed=red, cancelled/expired=gray.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final String status;

  Color get _color {
    switch (status) {
      case 'pending':
        return AppColors.statusPending;
      case 'processing':
        return AppColors.statusProcessing;
      case 'completed':
        return AppColors.statusCompleted;
      case 'failed':
        return AppColors.statusFailed;
      case 'cancelled':
      case 'expired':
      default:
        return AppColors.statusCancelled;
    }
  }

  String get _label {
    switch (status) {
      case 'pending':
        return 'Pending';
      case 'processing':
        return 'Processing';
      case 'completed':
        return 'Completed';
      case 'failed':
        return 'Failed';
      case 'cancelled':
        return 'Cancelled';
      case 'expired':
        return 'Expired';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _label,
        style: AppTextStyles.label.copyWith(color: color, letterSpacing: 0.2),
      ),
    );
  }
}
