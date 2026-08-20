import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/method_icon.dart';
import 'deposit_details_screen.dart';

class DepositMethodScreen extends StatelessWidget {
  const DepositMethodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.deposit, style: AppTextStyles.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.chooseMethod, style: AppTextStyles.headline),
              const SizedBox(height: 24),
              _MethodTile(
                method: 'evc_plus',
                title: AppStrings.evcPlus,
                subtitle: 'Deposit using your EVC Plus mobile money',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DepositDetailsScreen(method: 'evc_plus'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _MethodTile(
                method: 'winwin',
                title: AppStrings.winwin,
                subtitle: 'Deposit using your 888STARZ withdrawal code',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DepositDetailsScreen(method: 'winwin'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.method,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String method;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.cardBorder, width: 1.5),
        ),
        child: Row(
          children: [
            MethodIcon(method: method),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.title),
                  const SizedBox(height: 4),
                  Text(subtitle, style: AppTextStyles.muted),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
