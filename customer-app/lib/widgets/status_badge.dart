import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/order.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// What the customer is told about an order: only "Completed" or "Failed",
/// and while the server is still confirming, "Your payment is being
/// verified…". Never "Pending" (the server still tracks it as pending or
/// processing; this is only what is shown). Cancelled and expired orders are
/// definitive failures and read "Failed", with the reason on their details.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.compact = false});

  final String status;

  /// Smaller padding and text, for dense lists like the home screen.
  final bool compact;

  static bool _final(String s) => const {'completed', 'failed', 'cancelled', 'expired'}.contains(s);

  Color get _color {
    if (status == 'completed') return AppColors.statusCompleted;
    if (!_final(status)) return AppColors.statusProcessing;
    return AppColors.statusFailed;
  }

  String get _label {
    if (status == 'completed') return AppStrings.statusCompleted;
    if (!_final(status)) return AppStrings.verifying;
    return AppStrings.statusFailed;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 3)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _label,
        style: AppTextStyles.label.copyWith(color: color, letterSpacing: 0.2, fontSize: compact ? 11.5 : null),
      ),
    );
  }
}

/// A row in the Orders list: the badge for a final order, or the temporary
/// "Your payment is being verified…" line for one still being confirmed.
class OrderStatusSlot extends StatelessWidget {
  const OrderStatusSlot({super.key, required this.order, this.compact = false});

  final Order order;
  final bool compact;

  @override
  Widget build(BuildContext context) =>
      order.isFinal ? StatusBadge(status: order.status, compact: compact) : const SizedBox.shrink();
}

/// "Your payment is being verified…" under an order that is not final yet.
class VerifyingNote extends StatelessWidget {
  const VerifyingNote({super.key, this.fontSize = 12});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('verifying-note'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hourglass_top_rounded, size: fontSize + 1, color: AppColors.statusProcessing),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            AppStrings.verifying,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.muted.copyWith(fontSize: fontSize, color: AppColors.statusProcessing, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
