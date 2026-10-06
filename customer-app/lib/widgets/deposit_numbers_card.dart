import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// "Send your payment to" card listing the numbers/accounts set up for a
/// method in the Agent App, each with a copy button.
class DepositNumbersCard extends StatelessWidget {
  const DepositNumbersCard({super.key, required this.numbers});

  final List<({String number, String? label})> numbers;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.goldTint,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.lightGold, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.sendPaymentTo.toUpperCase(), style: AppTextStyles.label),
          const SizedBox(height: 6),
          for (final n in numbers)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.number, style: AppTextStyles.fieldValue),
                      if ((n.label ?? '').isNotEmpty) Text(n.label!, style: AppTextStyles.muted.copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_rounded, size: 20, color: AppColors.primaryDark),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: n.number));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${n.number} copied')));
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
