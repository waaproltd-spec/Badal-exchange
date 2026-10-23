import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/payment_method.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import 'method_icon.dart';

/// Round white back button of the Complete Deposit / Withdrawal pages.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: AppColors.textPrimary)),
      ),
    );
  }
}

/// The chosen method with a Change button.
class FlowMethodCard extends StatelessWidget {
  const FlowMethodCard({super.key, required this.info, required this.onChange, this.subtitle});

  final PaymentMethodInfo info;
  final VoidCallback onChange;

  /// Defaults to the method's kind (mobile transfer, betting account...).
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: Row(
        children: [
          MethodIcon(method: info.id, size: 50),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.label.toUpperCase(), style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  subtitle ??
                      (info.usesWithdrawalCode
                          ? AppStrings.bettingCashierDeposit
                          : info.isPlatform
                              ? AppStrings.bettingAccount
                              : AppStrings.instantMobileTransfer),
                  style: AppTextStyles.muted,
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('change-method'),
            onPressed: onChange,
            child: Text(AppStrings.change,
                style: AppTextStyles.body.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
