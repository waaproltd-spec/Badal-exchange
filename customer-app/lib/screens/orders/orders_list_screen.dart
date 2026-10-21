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
import '../../widgets/transaction_views.dart';

class OrdersListScreen extends StatefulWidget {
  const OrdersListScreen({super.key});

  @override
  State<OrdersListScreen> createState() => _OrdersListScreenState();
}

enum _Filter { all, deposits, withdrawals }

class _OrdersListScreenState extends State<OrdersListScreen> {
  _Filter _filter = _Filter.all;

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
      appBar: AppBar(title: Text(AppStrings.orders, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: () => context.read<OrdersProvider>().load(),
          child: Column(
            children: [
              _FilterBar(value: _filter, onChanged: (f) => setState(() => _filter = f)),
              Expanded(child: _buildBody(ordersState)),
            ],
          ),
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
    final orders = switch (_filter) {
      _Filter.all => state.orders,
      _Filter.deposits => state.orders.where((o) => o.isDeposit).toList(),
      _Filter.withdrawals => state.orders.where((o) => !o.isDeposit).toList(),
    };
    if (orders.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(child: Text(AppStrings.noOrders, style: AppTextStyles.muted)),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _OrderTile(order: orders[index]),
    );
  }
}

/// All / Deposits / Withdrawals.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});

  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = {
      _Filter.all: AppStrings.allHistory,
      _Filter.deposits: AppStrings.depositsTab,
      _Filter.withdrawals: AppStrings.withdrawalsTab,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          for (final f in _Filter.values) ...[
            ChoiceChip(
              key: Key('filter-${f.name}'),
              label: Text(labels[f]!),
              selected: value == f,
              onSelected: (_) => onChanged(f),
              showCheckmark: false,
              selectedColor: AppColors.purpleDark,
              backgroundColor: Colors.white,
              side: BorderSide(color: value == f ? AppColors.purpleDark : AppColors.cardBorder),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              labelStyle: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: value == f ? Colors.white : AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final isDeposit = order.isDeposit;
    final methodLabel = order.methodLabel;
    final typeLabel = isDeposit ? AppStrings.deposit : AppStrings.withdraw;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showTransactionDetails(context, order),
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
                  order.amountPending ? AppStrings.amountPending : '${isDeposit ? '+' : '-'}${Formatters.money(order.amount)}',
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
