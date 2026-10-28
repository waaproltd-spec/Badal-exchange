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

/// Home screen: the bonus wallet at a glance -- what is available, what was
/// earned in total, the rate and the last few lines -- and a way to all of it.
class HomeBonusCard extends StatelessWidget {
  const HomeBonusCard({super.key, required this.info, required this.onOpen});

  final BonusInfo info;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value, Key key) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.muted.copyWith(fontSize: 12.5)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(Formatters.money(value),
                  key: key, style: AppTextStyles.title.copyWith(fontSize: 20, color: AppColors.primaryDark)),
            ),
          ]),
        );
    return Container(
      key: const Key('home-bonus'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.redeem_rounded, color: AppColors.goldDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(AppStrings.bonusWallet,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.title.copyWith(fontSize: 17)),
          ),
          if (info.rate != '0%')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppColors.goldTint, borderRadius: BorderRadius.circular(10)),
              child: Text(info.rate, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          TextButton(
            key: const Key('home-bonus-open'),
            onPressed: onOpen,
            child: Text(AppStrings.viewAll),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: Row(children: [
            stat(AppStrings.availableBonus, info.balance, const Key('home-bonus-balance')),
            const SizedBox(width: 12),
            stat(AppStrings.totalEarned, info.totalEarned, const Key('home-bonus-total')),
          ]),
        ),
        if (info.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(AppStrings.noBonusYet, style: AppTextStyles.muted),
          )
        else
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(children: [for (final e in info.entries.take(3)) BonusEntryTile(entry: e)]),
          ),
      ]),
    );
  }
}
