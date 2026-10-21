import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/wallet.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/formatters.dart';

/// The home screen's wallet card: available balance, then the promo code
/// and Wallet ID side by side, then the bonus balance. Every value comes
/// from the backend (customer_wallet); nothing is made up on the device.
class WalletCard extends StatelessWidget {
  const WalletCard({super.key, required this.wallet, this.loading = false, this.error});

  final Wallet? wallet;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final wallet = this.wallet;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: AppColors.purpleDark.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_rounded, size: 18, color: Colors.white.withOpacity(0.85)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  AppStrings.availableBalance,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(color: Colors.white.withOpacity(0.85)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loading && wallet == null)
            const SizedBox(
              height: 48,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                ),
              ),
            )
          else if (error != null && wallet == null)
            Text(error!, style: AppTextStyles.muted.copyWith(color: Colors.white70))
          else
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                Formatters.money(wallet?.availableBalance ?? '0.00'),
                key: const Key('available-balance'),
                style: AppTextStyles.amountLarge.copyWith(color: Colors.white, fontSize: 42),
              ),
            ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _CodeTile(
                  key: const Key('promo-code'),
                  icon: Icons.card_giftcard_rounded,
                  label: AppStrings.promoCode,
                  value: wallet?.promoCode,
                  valueColor: AppColors.gold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CodeTile(
                  key: const Key('wallet-id'),
                  icon: Icons.account_balance_wallet_rounded,
                  label: AppStrings.walletId,
                  value: wallet?.walletId,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _BonusTile(value: Formatters.money(wallet?.bonusBalance ?? '0.00')),
        ],
      ),
    );
  }
}

/// A compact label + code tile with a copy button. Without a value it shows
/// a dash and nothing to copy. Narrow screens drop the icon and shrink the
/// code rather than clip it.
class _CodeTile extends StatelessWidget {
  const _CodeTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return LayoutBuilder(
      builder: (context, box) {
        final roomy = box.maxWidth >= 150;
        return Container(
          height: 64,
          padding: EdgeInsets.fromLTRB(roomy ? 12 : 10, 8, 2, 8),
          decoration: BoxDecoration(
            color: AppColors.primaryDeep.withOpacity(0.35),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              if (roomy) ...[
                Icon(icon, size: 24, color: Colors.white),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.8), fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value ?? '—',
                        style: AppTextStyles.fieldValue.copyWith(
                          color: value == null ? Colors.white54 : valueColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (value != null)
                IconButton(
                  tooltip: AppStrings.copy,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: Icon(Icons.copy_rounded, size: 20, color: valueColor),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.maybeOf(context)
                        ?.showSnackBar(SnackBar(content: Text(AppStrings.copied(value))));
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BonusTile extends StatelessWidget {
  const _BonusTile({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('bonus'),
      padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.primaryDeep.withOpacity(0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.bonus, style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.8))),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: AppTextStyles.fieldValue.copyWith(color: AppColors.gold, fontSize: 22)),
                ),
              ],
            ),
          ),
          Icon(Icons.redeem_rounded, size: 24, color: Colors.white.withOpacity(0.7)),
        ],
      ),
    );
  }
}
