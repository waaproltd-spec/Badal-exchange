import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/wallet_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';
import '../deposit/deposit_method_screen.dart';
import '../withdraw/withdraw_method_screen.dart';

/// Deliberately minimal: balance + the two actions. No extra cards.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<WalletProvider>().load();
    });
  }

  Future<void> _refreshWallet() => context.read<WalletProvider>().load();

  Future<void> _goDeposit() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DepositMethodScreen()),
    );
    if (mounted) _refreshWallet();
  }

  Future<void> _goWithdraw() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WithdrawMethodScreen()),
    );
    if (mounted) _refreshWallet();
  }

  @override
  Widget build(BuildContext context) {
    final walletState = context.watch<WalletProvider>();
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _refreshWallet,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            children: [
              Text(AppStrings.appName, style: AppTextStyles.title),
              const SizedBox(height: 28),
              _BalanceCard(walletState: walletState),
              const SizedBox(height: 32),
              PrimaryButton(label: AppStrings.deposit, onPressed: _goDeposit),
              const SizedBox(height: 16),
              SecondaryButton(label: AppStrings.withdraw, onPressed: _goWithdraw),
            ],
          ),
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.walletState});

  final WalletProvider walletState;

  @override
  Widget build(BuildContext context) {
    final wallet = walletState.wallet;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.primaryTint,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.cardBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.availableBalance.toUpperCase(), style: AppTextStyles.label),
          const SizedBox(height: 14),
          if (walletState.loading && wallet == null)
            const SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
                ),
              ),
            )
          else if (walletState.error != null && wallet == null)
            Text(walletState.error!, style: AppTextStyles.muted)
          else
            Text(
              Formatters.money(wallet?.availableBalance ?? '0.00'),
              style: AppTextStyles.amountLarge.copyWith(color: AppColors.primaryDark),
            ),
        ],
      ),
    );
  }
}
