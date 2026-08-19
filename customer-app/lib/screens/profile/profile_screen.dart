import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_card.dart';
import '../../widgets/secondary_button.dart';
import '../../widgets/summary_row.dart';
import '../auth/login_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppStrings.logout, style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    await context.read<AuthProvider>().logout();
    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final displayName = (user?.name.isNotEmpty ?? false) ? user!.name : '-';
    final initial = (user?.name.isNotEmpty ?? false) ? user!.name[0].toUpperCase() : '?';

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.profile, style: AppTextStyles.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: const BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
                child: Center(
                  child: Text(
                    initial,
                    style: AppTextStyles.headline.copyWith(color: AppColors.primaryDark),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                children: [
                  SummaryRow(label: AppStrings.name, value: displayName),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.phoneNumber, value: user?.phone ?? '-'),
                ],
              ),
            ),
            const SizedBox(height: 32),
            SecondaryButton(
              label: AppStrings.logout,
              color: AppColors.error,
              onPressed: () => _confirmLogout(context),
            ),
          ],
        ),
      ),
    );
  }
}
