import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../state/orders_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/status_badge.dart';
import 'order_detail_screen.dart';

class OrdersListScreen extends StatefulWidget {
  const OrdersListScreen({super.key});

  @override
  State<OrdersListScreen> createState() => _OrdersListScreenState();
}

class _OrdersListScreenState extends State<OrdersListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<OrdersProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ordersState = context.watch<OrdersProvider>();

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.orders, style: AppTextStyles.title)),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: () => context.read<OrdersProvider>().load(),
          child: _buildBody(ordersState),
        ),
      ),
    );
  }

  Widget _buildBody(OrdersProvider state) {
    if (state.loading && state.orders.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 160),
          Center(child: CircularProgressIndicator(color: AppColors.primary)),
        ],
      );
    }
    if (state.error != null && state.orders.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(child: Text(state.error!, style: AppTextStyles.muted, textAlign: TextAlign.center)),
        ],
      );
    }
    if (state.orders.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(child: Text(AppStrings.noOrders, style: AppTextStyles.muted)),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: state.orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _OrderTile(order: state.orders[index]),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final isDeposit = order.isDeposit;
    final methodLabel = order.isEvc ? AppStrings.evcPlus : AppStrings.winwin;
    final typeLabel = isDeposit ? AppStrings.deposit : AppStrings.withdraw;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: order.id)),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.cardBorder, width: 1.5),
        ),
        child: Row(
          children: [
            MethodIcon(method: order.method, size: 44),
            const SizedBox(width: 14),
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
    );
  }
}
