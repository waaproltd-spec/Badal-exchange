import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/order.dart';
import '../theme/app_theme.dart';

/// A single order (deposit or withdrawal) rendered as a card: order code,
/// method + counterparty, amount/fee/net, status badge, timestamp, and an
/// optional row of action buttons supplied by the screen that owns the
/// available actions for that order's status.
class OrderCard extends StatelessWidget {
  final Order order;
  final List<Widget> actions;

  const OrderCard({super.key, required this.order, this.actions = const []});

  static final _dateFormat = DateFormat('MMM d, HH:mm');

  @override
  Widget build(BuildContext context) {
    final methodLabel = order.isEvcPlus ? 'EVC Plus' : (order.isWinwin ? 'WinWin' : order.method);
    final directionLabel = order.isDeposit ? 'Deposit' : 'Withdrawal';
    final directionIcon = order.isDeposit ? Icons.south_west_rounded : Icons.north_east_rounded;
    final directionColor = order.isDeposit ? AppColors.statusCompleted : AppColors.statusProcessing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(directionIcon, size: 18, color: directionColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$directionLabel · $methodLabel',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                StatusBadge(status: order.status),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.counterpartyLabel,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        order.orderCode.isNotEmpty ? order.orderCode : order.id,
                        style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '\$${order.amount}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (order.fee != '0.00')
                      Text(
                        'Fee \$${order.fee}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: AppColors.textFaint),
                const SizedBox(width: 4),
                Text(
                  _dateFormat.format(order.createdAt.toLocal()),
                  style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
                if (order.depositCode != null) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.tag, size: 14, color: AppColors.textFaint),
                  const SizedBox(width: 4),
                  Text(
                    order.depositCode!,
                    style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                  ),
                ],
              ],
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 10, runSpacing: 10, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
