import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/bonus.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/formatters.dart';

/// One line of bonus history: earned on an order (with the percentage it was
/// worked out with), or transferred to the main wallet.
class BonusEntryTile extends StatelessWidget {
  const BonusEntryTile({super.key, required this.entry});

  final BonusEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = e.earned ? AppColors.success : AppColors.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder, width: 1.5),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: color.withOpacity(0.12),
          child: Icon(e.earned ? Icons.redeem_rounded : Icons.account_balance_wallet_rounded, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.earned ? '${AppStrings.bonusEarned} (${e.rate ?? ''})' : AppStrings.bonusMovedTitle,
                style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
            if (e.earned && e.orderAmount != null)
              Text(AppStrings.bonusOnOrder(e.orderAmount!, e.direction ?? 'withdraw', e.methodLabel ?? ''),
                  style: AppTextStyles.muted),
            Text(Formatters.dateTime(e.createdAt), style: AppTextStyles.muted.copyWith(fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 8),
        Text('${e.earned ? '+' : '−'}${Formatters.money(e.amount)}',
            style: AppTextStyles.fieldValue.copyWith(color: color, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
