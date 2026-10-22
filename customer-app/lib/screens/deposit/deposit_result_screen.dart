import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_card.dart';
import '../../widgets/transaction_views.dart';

/// The deposit as submitted: amount, status ("Deposit Confirmed" once
/// credited, otherwise waiting for the payment) and its details. For betting
/// platform deposits with a `depositCode`, the code is shown too -- except
/// 888STARZ and 1XBET, which run on the customer's own withdrawal code: there
/// is nothing to pay with ours.
class DepositResultScreen extends StatelessWidget {
  const DepositResultScreen({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: TransactionResultView(
          order: order,
          extra: order.methodInfo.isPlatform && !order.methodInfo.usesWithdrawalCode && order.depositCode != null
              ? AppCard(
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
                )
              : null,
        ),
      ),
    );
  }
}
