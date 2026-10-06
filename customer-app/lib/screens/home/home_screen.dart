import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../state/orders_provider.dart';
import '../../state/wallet_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/brand/baari_logo.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/status_badge.dart';
import '../deposit/deposit_method_screen.dart';
import '../orders/order_detail_screen.dart';
import '../withdraw/withdraw_method_screen.dart';

/// Wallet home: branded header, balance card (Balance / Xiran / Bonus),
/// Deposit + Withdraw, and the most recent orders.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onViewAllOrders});

  /// Switches the shell to the Orders tab.
  final VoidCallback? onViewAllOrders;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _recentOrdersCount = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() => Future.wait([
        context.read<WalletProvider>().load(),
        context.read<OrdersProvider>().load(),
      ]);

  Future<void> _goDeposit() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DepositMethodScreen()),
    );
    if (mounted) _refresh();
  }

  Future<void> _goWithdraw() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WithdrawMethodScreen()),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final walletState = context.watch<WalletProvider>();
    final ordersState = context.watch<OrdersProvider>();
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _WalletHeader(
              topInset: topInset,
              walletState: walletState,
              onDeposit: _goDeposit,
              onWithdraw: _goWithdraw,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(AppStrings.recentOrders, style: AppTextStyles.title)),
                      if (widget.onViewAllOrders != null)
                        TextButton(
                          onPressed: widget.onViewAllOrders,
                          child: Text(
                            AppStrings.viewAll,
                            style: AppTextStyles.body.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _RecentOrders(
                    state: ordersState,
                    orders: ordersState.orders.take(_recentOrdersCount).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletHeader extends StatelessWidget {
  const _WalletHeader({
    required this.topInset,
    required this.walletState,
    required this.onDeposit,
    required this.onWithdraw,
  });

  final double topInset;
  final WalletProvider walletState;
  final VoidCallback onDeposit;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, topInset + 20, 20, 24),
      decoration: const BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Stack(
        children: [
          // Soft gold glow, purely decorative.
          Positioned(
            right: -60,
            top: 40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [AppColors.gold.withOpacity(0.22), AppColors.gold.withOpacity(0)],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BaariLogo(markSize: 46, onDark: true),
              ),
              const SizedBox(height: 28),
              _BalanceCard(walletState: walletState),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ActionTile(
                      label: AppStrings.deposit,
                      icon: Icons.south_west_rounded,
                      iconBackground: AppColors.primary,
                      onTap: onDeposit,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionTile(
                      label: AppStrings.withdraw,
                      icon: Icons.north_east_rounded,
                      iconBackground: AppColors.gold,
                      iconColor: AppColors.primaryDeep,
                      onTap: onWithdraw,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_rounded,
                  size: 18, color: Colors.white.withOpacity(0.85)),
              const SizedBox(width: 8),
              Text(
                AppStrings.availableBalance,
                style: AppTextStyles.body.copyWith(color: Colors.white.withOpacity(0.85)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (walletState.loading && wallet == null)
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
          else if (walletState.error != null && wallet == null)
            Text(walletState.error!, style: AppTextStyles.muted.copyWith(color: Colors.white70))
          else
            Text(
              Formatters.money(wallet?.availableBalance ?? '0.00'),
              style: AppTextStyles.amountLarge.copyWith(color: Colors.white, fontSize: 42),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _SubBalance(
                  label: AppStrings.xiran,
                  value: Formatters.money(wallet?.pendingBalance ?? '0.00'),
                  icon: Icons.lock_clock_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SubBalance(
                  label: AppStrings.bonus,
                  value: Formatters.money(wallet?.bonusBalance ?? '0.00'),
                  icon: Icons.card_giftcard_rounded,
                  valueColor: AppColors.gold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubBalance extends StatelessWidget {
  const _SubBalance({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor = Colors.white,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
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
                Text(
                  label,
                  style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.8)),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AppTextStyles.fieldValue.copyWith(color: valueColor, fontSize: 20),
                  ),
                ),
              ],
            ),
          ),
          Icon(icon, size: 20, color: Colors.white.withOpacity(0.7)),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.label,
    required this.icon,
    required this.iconBackground,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  final String label;
  final IconData icon;
  final Color iconBackground;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentOrders extends StatelessWidget {
  const _RecentOrders({required this.state, required this.orders});

  final OrdersProvider state;
  final List<Order> orders;

  @override
  Widget build(BuildContext context) {
    if (state.loading && orders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    if (orders.isEmpty) {
      return _EmptyOrders(message: state.error);
    }
    return Column(
      children: [
        for (final order in orders) ...[
          _RecentOrderTile(order: order),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
            child: const Icon(Icons.receipt_long_rounded, color: AppColors.primary, size: 34),
          ),
          const SizedBox(height: 16),
          Text(
            AppStrings.noOrders,
            style: AppTextStyles.title.copyWith(fontSize: 18),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            message ?? AppStrings.noOrdersHint,
            style: AppTextStyles.muted,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _RecentOrderTile extends StatelessWidget {
  const _RecentOrderTile({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final isDeposit = order.isDeposit;
    final methodLabel = order.isEvc ? AppStrings.evcPlus : AppStrings.winwin;
    final typeLabel = isDeposit ? AppStrings.deposit : AppStrings.withdraw;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: order.id)),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.cardBorder, width: 1.2),
          ),
          child: Row(
            children: [
              MethodIcon(method: order.method, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$typeLabel · $methodLabel',
                      style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      Formatters.dateTime(order.createdAt),
                      style: AppTextStyles.muted.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${isDeposit ? '+' : '-'}${Formatters.money(order.amount)}',
                    style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isDeposit ? AppColors.statusCompleted : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  StatusBadge(status: order.status),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
