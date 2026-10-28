import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/theme_mode.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_card.dart';
import '../../widgets/secondary_button.dart';
import '../../widgets/summary_row.dart';
import '../auth/login_screen.dart';
import 'change_password_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.logout),
        content: Text(AppStrings.logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.cancel),
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
      appBar: AppBar(title: Text(AppStrings.profile, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
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
            const SizedBox(height: 16),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(AppStrings.language, style: AppTextStyles.body),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: AppLanguage.somali, label: FittedBox(child: Text(AppStrings.somaliName))),
                      ButtonSegment(
                          value: AppLanguage.english, label: FittedBox(child: Text(AppStrings.englishName))),
                    ],
                    selected: {AppLanguage.current.value},
                    onSelectionChanged: (s) => AppLanguage.set(s.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(AppStrings.appearance, style: AppTextStyles.body),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    key: const Key('theme-mode'),
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                          value: ThemeMode.light,
                          icon: const Icon(Icons.light_mode_rounded, size: 18),
                          label: FittedBox(child: Text(AppStrings.themeLight))),
                      ButtonSegment(
                          value: ThemeMode.dark,
                          icon: const Icon(Icons.dark_mode_rounded, size: 18),
                          label: FittedBox(child: Text(AppStrings.themeDark))),
                      ButtonSegment(
                          value: ThemeMode.system,
                          icon: const Icon(Icons.phone_android_rounded, size: 18),
                          label: FittedBox(child: Text(AppStrings.themeSystem))),
                    ],
                    selected: {AppThemeMode.current.value},
                    onSelectionChanged: (s) => AppThemeMode.set(s.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AppCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                key: const Key('change-password'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                leading: Icon(Icons.lock_reset_rounded, color: AppColors.primary),
                title: Text(AppStrings.changePassword, style: AppTextStyles.body),
                trailing: Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
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
