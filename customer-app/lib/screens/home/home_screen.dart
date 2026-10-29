import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/app_content.dart';
import '../../models/order.dart';
import '../../state/auth_provider.dart';
import '../../state/orders_provider.dart';
import '../../state/wallet_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/support_button.dart';
import '../../widgets/brand/baari_logo.dart';
import '../../widgets/home_ads_strip.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/transaction_views.dart';
import '../../widgets/wallet_card.dart';
import '../bonus/bonus_screen.dart';
import '../deposit/deposit_details_screen.dart';
import '../notifications/notifications_screen.dart';
import '../withdraw/withdraw_details_screen.dart';

/// Wallet home, kept compact so two recent orders fit on a phone screen:
/// branded header, wallet card, Deposit + Withdraw, then recent orders.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onViewAllOrders});

  /// Switches the shell to the Orders tab.
  final VoidCallback? onViewAllOrders;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _recentOrdersCount = 3;
  List<HomeAd> _ads = const [];


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
        _loadAds(),
      ]);

  Future<void> _openBonus() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BonusScreen()));
    if (mounted) _refresh();
  }

  /// Ads are optional decoration: a failure just leaves the section hidden.
  Future<void> _loadAds() async {
    try {
      final ads = await context.read<CustomerApi>().getHomeAds();
      if (mounted) setState(() => _ads = ads);
    } catch (_) {}
  }

  void _openNotifications() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
  }

  /// Deposit and Withdraw both pick a method in the bottom sheet, then open
  /// that method's form.
  Future<void> _goDeposit() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.deposit,
        ownPhone: context.read<AuthProvider>().user?.phone);
    if (option == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DepositDetailsScreen(option: option, ownPhone: context.read<AuthProvider>().user?.phone),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _goWithdraw() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.withdraw,
        ownPhone: context.read<AuthProvider>().user?.phone);
    if (option == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WithdrawDetailsScreen(
          method: option.info.id,
          option: option,
          ownPhone: context.read<AuthProvider>().user?.phone,
          availableBalance: context.read<WalletProvider>().wallet?.availableBalance,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final walletState = context.watch<WalletProvider>();
    final ordersState = context.watch<OrdersProvider>();
    final topInset = MediaQuery.of(context).padding.top;

    // Light status-bar icons over the dark purple header.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.appBackground,
        body: SupportButton(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refresh,
            child: ListView(
              // Room at the end so the Support button never hides the last order.
              padding: const EdgeInsets.only(bottom: supportButtonClearance),
              children: [
                _WalletHeader(
                  topInset: topInset,
                  walletState: walletState,
                  onDeposit: _goDeposit,
                  onWithdraw: _goWithdraw,
                  onNotifications: _openNotifications,
                  onBonus: _openBonus,
                ),
                if (_ads.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: HomeAdsStrip(ads: _ads),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(AppStrings.recentOrders,
                                  maxLines: 1, style: AppTextStyles.title.copyWith(fontSize: 18)),
                            ),
                          ),
                          if (widget.onViewAllOrders != null)
                            TextButton(
                              key: const Key('view-all-orders'),
                              onPressed: widget.onViewAllOrders,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                minimumSize: const Size(0, 36),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    AppStrings.viewAll,
                                    style: AppTextStyles.body.copyWith(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.primary),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
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
    required this.onNotifications,
    required this.onBonus,
  });

  final double topInset;
  final WalletProvider walletState;
  final VoidCallback onDeposit;
  final VoidCallback onWithdraw;
  final VoidCallback onNotifications;
  final VoidCallback onBonus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, topInset + 10, 16, 16),
      decoration: const BoxDecoration(
        gradient: AppColors.headerGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
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
                  colors: [AppColors.accentOrange.withOpacity(0.18), AppColors.accentOrange.withOpacity(0)],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: BaariLogo(markSize: 38, onDark: true)),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: AppStrings.notifications,
                    onPressed: onNotifications,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.12),
                      side: BorderSide(color: Colors.white.withOpacity(0.25)),
                    ),
                    icon: const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              WalletCard(
                wallet: walletState.wallet,
                loading: walletState.loading,
                error: walletState.error,
                onBonusTap: onBonus,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _ActionTile(
                      key: const Key('home-deposit'),
                      label: AppStrings.deposit,
                      icon: Icons.south_west_rounded,
                      background: AppColors.lightGold,
                      iconBackground: AppColors.purpleDark,
                      iconColor: AppColors.lightGold,
                      onTap: onDeposit,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionTile(
                      key: const Key('home-withdraw'),
                      label: AppStrings.withdraw,
                      icon: Icons.north_east_rounded,
                      background: AppColors.accentOrange,
                      iconBackground: AppColors.purpleDark,
                      iconColor: AppColors.accentOrange,
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

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.background,
    required this.iconBackground,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color iconBackground;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 6, 0),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                const SizedBox(width: 10),
                // Scale down rather than truncate on narrow phones.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppColors.purpleDark,
                      ),
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.purpleDark, size: 20),
              ],
            ),
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
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    if (orders.isEmpty) {
      return _EmptyOrders(message: state.error);
    }
    return Column(
      children: [
        for (final order in orders) ...[
          _RecentOrderTile(key: Key('recent-order-${order.id}'), order: order),
          const SizedBox(height: 8),
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
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
            child: Icon(Icons.receipt_long_rounded, color: AppColors.primary, size: 34),
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
  const _RecentOrderTile({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    // As the customer sees it (an unpaid deposit reads Failed after a
    // minute); the details sheet gets the server's order.
    final real = this.order;
    final order = real.shown;
    final isDeposit = order.isDeposit;
    final methodLabel = order.methodLabel;
    final typeLabel = isDeposit ? AppStrings.deposit : AppStrings.withdraw;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showTransactionDetails(context, real),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder, width: 1.2),
          ),
          child: Row(
            children: [
              MethodIcon(method: order.method, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$typeLabel · $methodLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Formatters.dateTime(order.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.muted.copyWith(fontSize: 12),
                    ),
                    if (!order.isFinal) ...[const SizedBox(height: 2), const VerifyingNote(fontSize: 11.5)],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    order.amountPending
                        ? AppStrings.amountPending
                        : '${isDeposit ? '+' : '-'}${Formatters.money(order.amount)}',
                    style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isDeposit ? AppColors.statusCompleted : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  OrderStatusSlot(order: order, compact: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
