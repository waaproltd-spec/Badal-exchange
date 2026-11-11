import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/bonus.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/formatters.dart';

/// One line of bonus history: earned on an order (green; the percentage, the order's amount, the platform, the bonus, the date),
/// transferred to the main wallet (purple), or taken back (red). Amounts are shown exactly as the database holds them.
class BonusEntryTile extends StatelessWidget {
  const BonusEntryTile({super.key, required this.entry});

  final BonusEntry entry;

  static const _purple = Color(0xFFB57BFF);

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = e.reversed ? AppColors.error : e.earned ? AppColors.success : _purple;
    final sign = e.earned ? '+' : '−';
    final title = e.reversed ? AppStrings.bonusReversedTitle : e.earned ? '${AppStrings.bonusEarned} (${e.rate ?? ''})' : AppStrings.bonusMovedTitle;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _purple.withOpacity(0.45), width: 1.3),
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: color.withOpacity(0.22), borderRadius: BorderRadius.circular(14)),
            child: Icon(e.earned ? Icons.card_giftcard_rounded : e.reversed ? Icons.undo_rounded : Icons.account_balance_wallet_rounded, color: color, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 16)),
              if (e.earned && e.orderAmount != null) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.sports_esports_rounded, size: 18, color: _purple.withOpacity(0.9)),
                  const SizedBox(width: 6),
                  Flexible(child: Text(AppStrings.bonusOrderLine(e.orderAmount!, e.direction ?? 'withdraw'), style: AppTextStyles.muted)),
                ]),
                if ((e.methodLabel ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    key: const Key('bonus-platform'),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: _purple.withOpacity(0.18), borderRadius: BorderRadius.circular(14)),
                    child: Text(e.methodLabel!, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ],
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: color, width: 1.4),
            ),
            child: Text('$sign${Formatters.money(e.amount)}',
                style: AppTextStyles.fieldValue.copyWith(color: color, fontWeight: FontWeight.w900, fontSize: 17)),
          ),
        ]),
        const SizedBox(height: 10),
        Divider(height: 1, color: Colors.white.withOpacity(0.1)),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.calendar_month_rounded, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Flexible(child: Text(Formatters.dateTime(e.createdAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.muted.copyWith(fontSize: 13))),
        ]),
      ]),
    );
  }
}
