import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/summary_row.dart';

/// Circular checkmark + restated amount for a normal outcome. For betting
/// platform deposits, prominently surfaces the `depositCode` the customer
/// must reference when paying. Where to send the payment is shown on the
/// deposit page itself.
class DepositResultScreen extends StatelessWidget {
  const DepositResultScreen({super.key, required this.order});

  final Order order;

  bool get _isSuccessLike =>
      order.status != 'failed' && order.status != 'cancelled' && order.status != 'expired';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 16),
            Center(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: _isSuccessLike ? AppColors.primaryTint : AppColors.statusFailed.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isSuccessLike ? Icons.check_circle_rounded : Icons.error_rounded,
                  color: _isSuccessLike ? AppColors.primary : AppColors.statusFailed,
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(AppStrings.depositSubmitted, style: AppTextStyles.headline, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(order.statusMessage, style: AppTextStyles.muted, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 28),
            if (order.methodInfo.isPlatform && order.depositCode != null) ...[
              AppCard(
                color: AppColors.primaryTint,
                child: Column(
                  children: [
                    Text(
                      AppStrings.depositCodeLabel.toUpperCase(),
                      style: AppTextStyles.label.copyWith(color: AppColors.primaryDark),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      order.depositCode!,
                      style: AppTextStyles.amountLarge.copyWith(color: AppColors.primaryDark, letterSpacing: 4),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppStrings.depositCodeUse(order.methodLabel),
                      style: AppTextStyles.muted,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            AppCard(
              child: Column(
                children: [
                  SummaryRow(label: AppStrings.orderCode, value: order.orderCode),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.amount, value: order.amountPending ? AppStrings.amountPending : Formatters.money(order.amount)),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.netAmount, value: order.amountPending ? '—' : Formatters.money(order.netAmount)),
                  const SummaryDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(AppStrings.status, style: AppTextStyles.muted),
                        StatusBadge(status: order.status),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            PrimaryButton(
              label: AppStrings.done,
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ],
        ),
      ),
    );
  }
}
