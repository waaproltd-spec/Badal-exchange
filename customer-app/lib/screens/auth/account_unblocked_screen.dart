import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/brand/baari_logo.dart';

/// "Account Unblocked": shown once when a customer whose account was blocked logs in again and the server
/// accepts the login (the administrator unblocked the account). Wallet, orders and history were never touched.
/// [onLogin] continues into the app.
class AccountUnblockedScreen extends StatelessWidget {
  const AccountUnblockedScreen({super.key, required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('account-unblocked'),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppColors.headerGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const BaariLogoMark(size: 70, onDark: true),
                      const SizedBox(height: 8),
                      const FittedBox(
                          fit: BoxFit.scaleDown,
                          child:
                              BaariWordmark(fontSize: 28, color: Colors.white)),
                      const SizedBox(height: 28),
                      Container(
                        padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
                        decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(28)),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: Container(
                                width: 104,
                                height: 104,
                                decoration: BoxDecoration(
                                    color: AppColors.success.withOpacity(0.14),
                                    shape: BoxShape.circle),
                                alignment: Alignment.center,
                                child: Container(
                                  width: 76,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    color: AppColors.success,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                          color: AppColors.success
                                              .withOpacity(0.45),
                                          blurRadius: 18,
                                          spreadRadius: 1)
                                    ],
                                  ),
                                  child: const Icon(Icons.check_rounded,
                                      size: 48, color: Colors.white),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(AppStrings.accountUnblockedTitle,
                                key: const Key('unblocked-title'),
                                textAlign: TextAlign.center,
                                style: AppTextStyles.headline
                                    .copyWith(fontSize: 28)),
                            const SizedBox(height: 12),
                            Text(AppStrings.accountUnblockedMessage,
                                key: const Key('unblocked-message'),
                                textAlign: TextAlign.center,
                                style: AppTextStyles.body
                                    .copyWith(fontSize: 16, height: 1.45)),
                            const SizedBox(height: 22),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                  gradient: AppColors.headerGradient,
                                  borderRadius: BorderRadius.circular(18)),
                              child: TextButton.icon(
                                key: const Key('unblocked-login'),
                                style: TextButton.styleFrom(
                                  minimumSize: const Size.fromHeight(56),
                                  foregroundColor: AppColors.textOnPrimary,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18)),
                                ),
                                onPressed: onLogin,
                                icon: const Icon(Icons.login_rounded),
                                label: Text(AppStrings.unblockedLogin,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 17)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
