import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/wallet.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/formatters.dart';

/// Show / hide the balances (a privacy switch only: nothing is changed or stored in the wallet). One switch for the wallet balance and the
/// bonus balance; it is kept while the app stays open, and starts shown.
class BalancePrivacy {
  BalancePrivacy._();

  /// true: the amounts are hidden ("••••••").
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);
  static void toggle() => hidden.value = !hidden.value;
  static const String mask = '••••••';
}

/// The home screen's wallet card, compact: available balance with the bonus
/// beside it, then the promo code and Wallet ID side by side. Every value comes
/// from the backend (customer_wallet); nothing is made up on the device.
class WalletCard extends StatelessWidget {
  const WalletCard({super.key, required this.wallet, this.loading = false, this.error, this.onBonusTap, this.onSendTap});

  final Wallet? wallet;
  final bool loading;
  final String? error;

  /// Opens the Bonus wallet.
  final VoidCallback? onBonusTap;

  /// Opens Send Money (free wallet to wallet transfer), inside the wallet card.
  final VoidCallback? onSendTap;

  @override
  Widget build(BuildContext context) {
    final wallet = this.wallet;
    return ValueListenableBuilder<bool>(
      valueListenable: BalancePrivacy.hidden,
      builder: (context, hidden, _) => _card(context, wallet, hidden),
    );
  }

  Widget _card(BuildContext context, Wallet? wallet, bool hidden) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        gradient: AppColors.cardGradient,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: AppColors.purpleDark.withOpacity(0.3),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Balance on the left, the bonus beside it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_balance_wallet_rounded, size: 16, color: Colors.white.withOpacity(0.85)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            AppStrings.availableBalance,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.85), fontSize: 13),
                          ),
                        ),
                        // One eye for both balances, right beside the wallet balance.
                        IconButton(
                          key: const Key('balance-eye'),
                          tooltip: hidden ? AppStrings.showBalance : AppStrings.hideBalance,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                          icon: Icon(hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                              size: 20, color: Colors.white.withOpacity(0.9)),
                          onPressed: BalancePrivacy.toggle,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (loading && wallet == null)
                      const SizedBox(
                        height: 38,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          ),
                        ),
                      )
                    else if (error != null && wallet == null)
                      Text(error!, style: AppTextStyles.muted.copyWith(color: Colors.white70, fontSize: 12))
                    else
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          hidden ? BalancePrivacy.mask : Formatters.money(wallet?.availableBalance ?? '0.00'),
                          key: const Key('available-balance'),
                          style: AppTextStyles.amountLarge.copyWith(color: Colors.white, fontSize: 32, height: 1.15),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: Colors.white.withOpacity(0.18),
              ),
              _BonusTile(value: hidden ? BalancePrivacy.mask : Formatters.money(wallet?.bonusBalance ?? '0.00'), onTap: onBonusTap),
            ],
          ),
          const SizedBox(height: 6),
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
          if (onSendTap != null) ...[
            const SizedBox(height: 6),
            // Send Money lives in the wallet itself: a slim button, not a new card or menu item.
            SizedBox(
              width: double.infinity,
              height: 34,
              child: OutlinedButton.icon(
                key: const Key('wallet-send-money'),
                onPressed: onSendTap,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(AppStrings.sendMoney, style: const TextStyle(fontWeight: FontWeight.w800)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
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
        final roomy = box.maxWidth >= 190;
        return Container(
          height: 48,
          padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
          decoration: BoxDecoration(
            color: AppColors.primaryDeep.withOpacity(0.35),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              if (roomy) ...[
                Icon(icon, size: 20, color: Colors.white),
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
                        style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.8), fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(height: 1),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value ?? '—',
                        style: AppTextStyles.fieldValue.copyWith(
                          color: value == null ? Colors.white54 : valueColor,
                          fontSize: 16,
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
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(AppStrings.copied(value))));
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The bonus balance, compact, beside the available balance.
class _BonusTile extends StatelessWidget {
  const _BonusTile({required this.value, this.onTap});

  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('bonus'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.redeem_rounded, size: 22, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.bonus,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.8), fontSize: 12),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: AppTextStyles.fieldValue.copyWith(color: AppColors.gold, fontSize: 17)),
                ),
              ],
            ),
          ),
          if (onTap != null) Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white.withOpacity(0.7)),
        ],
      ),
      ),
    );
  }
}
