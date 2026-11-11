import '../../widgets/network_problem_view.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
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
  final ScrollController _scroll = ScrollController();

  /// Orders read beyond the newest ones the provider holds (further pages of the tab being scrolled), by tab.
  final Map<_Filter, List<Order>> _extra = {for (final f in _Filter.values) f: <Order>[]};
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<OrdersProvider>().load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static String? _direction(_Filter f) => switch (f) { _Filter.all => null, _Filter.deposits => 'deposit', _Filter.withdrawals => 'withdraw' };

  /// What the tab shows: the newest orders the app already holds, then the pages read since; each order once, newest first.
  List<Order> _shown(OrdersProvider state, _Filter f) {
    final base = switch (f) {
      _Filter.all => state.orders,
      _Filter.deposits => state.orders.where((o) => o.isDeposit).toList(),
      _Filter.withdrawals => state.orders.where((o) => !o.isDeposit).toList(),
    };
    final seen = <String>{};
    final all = [...base, ..._extra[f]!].where((o) => seen.add(o.id)).toList();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  }

  /// The tab's total as the database counts it; until then (or if it cannot be read) what the app holds.
  int _countFor(OrdersProvider state, _Filter f) {
    final c = state.counts;
    if (c != null) return switch (f) { _Filter.all => c.total, _Filter.deposits => c.deposits, _Filter.withdrawals => c.withdrawals };
    final held = state.orders;
    return switch (f) {
      _Filter.all => held.length,
      _Filter.deposits => held.where((o) => o.isDeposit).length,
      _Filter.withdrawals => held.where((o) => !o.isDeposit).length,
    };
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loadingMore) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 300) return;
    _loadMore();
  }

  Future<void> _loadMore() async {
    final state = context.read<OrdersProvider>();
    final f = _filter;
    final have = _shown(state, f).length;
    if (_loadingMore || have >= _countFor(state, f)) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<CustomerApi>().getOrdersPage(direction: _direction(f), offset: have, limit: 30);
      if (mounted) setState(() => _extra[f]!.addAll(page));
    } catch (_) {
      // Offline or a hiccup: the next scroll tries again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
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
          onRefresh: () async {
            for (final l in _extra.values) {
              l.clear();
            }
            await context.read<OrdersProvider>().load();
          },
          child: Column(
            children: [
              _SummaryCards(
                all: _countFor(ordersState, _Filter.all),
                deposits: _countFor(ordersState, _Filter.deposits),
                withdrawals: _countFor(ordersState, _Filter.withdrawals),
                onPick: (f) => setState(() => _filter = f),
              ),
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
        children: [
          const SizedBox(height: 160),
          Center(child: CircularProgressIndicator(color: AppColors.primary)),
        ],
      );
    }
    if (state.networkProblem && state.orders.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 20),
        children: [NetworkProblemView(onRetry: () => context.read<OrdersProvider>().load())],
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
    final orders = _shown(state, _filter);
    if (orders.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(child: Text(AppStrings.noOrders, style: AppTextStyles.muted)),
        ],
      );
    }
    final more = orders.length < _countFor(state, _filter);
    return ListView.separated(
      key: const Key('orders-list'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: orders.length + (more ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index >= orders.length) {
          // Reached the end of what is held and there are more: read the next page.
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary))),
          );
        }
        return _OrderTile(order: orders[index]);
      },
    );
  }
}

/// Dhammaan / Dhigashooyin (green) / Bixinno (red): counted by the database; tapping one opens that tab.
class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.all, required this.deposits, required this.withdrawals, required this.onPick});

  final int all;
  final int deposits;
  final int withdrawals;
  final ValueChanged<_Filter> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(children: [
        Expanded(child: _SummaryCard(
          key: const Key('orders-count-all'),
          label: AppStrings.allHistory, value: all, icon: Icons.layers_rounded,
          color: const Color(0xFF9B5DE5), onTap: () => onPick(_Filter.all))),
        const SizedBox(width: 10),
        Expanded(child: _SummaryCard(
          key: const Key('orders-count-deposits'),
          label: AppStrings.depositsTab, value: deposits, icon: Icons.arrow_downward_rounded,
          color: AppColors.statusCompleted, onTap: () => onPick(_Filter.deposits))),
        const SizedBox(width: 10),
        Expanded(child: _SummaryCard(
          key: const Key('orders-count-withdrawals'),
          label: AppStrings.withdrawalsTab, value: withdrawals, icon: Icons.arrow_upward_rounded,
          color: AppColors.statusFailed, onTap: () => onPick(_Filter.withdrawals))),
      ]),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({super.key, required this.label, required this.value, required this.icon, required this.color, required this.onTap});

  final String label;
  final int value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final compact = box.maxWidth < 112; // 320 px phones: a smaller icon and tighter padding, the numbers scale down
      final icon = compact ? 26.0 : 34.0;
      return InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(compact ? 7 : 10, 12, compact ? 5 : 10, 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: color.withOpacity(0.7), width: 1.4),
          ),
          child: Row(children: [
            Container(
              width: icon,
              height: icon,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(this.icon, color: Colors.white, size: compact ? 16 : 20),
            ),
            SizedBox(width: compact ? 5 : 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(label, maxLines: 1, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('$value', maxLines: 1, style: AppTextStyles.title.copyWith(fontSize: 28, fontWeight: FontWeight.w900, color: color == const Color(0xFF9B5DE5) ? null : color)),
                ),
              ]),
            ),
          ]),
        ),
      );
    });
  }
}

/// Dhammaan / Dhigashooyin / Bixinno: three equal tabs.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          for (final f in _Filter.values) ...[
            Expanded(
              child: GestureDetector(
                key: Key('filter-${f.name}'),
                onTap: () => onChanged(f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: value == f ? const LinearGradient(colors: [Color(0xFF7B2CBF), Color(0xFF9D4EDD)]) : null,
                    color: value == f ? null : AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: value == f ? const Color(0xFFC77DFF) : AppColors.cardBorder, width: 1.3),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(labels[f]!,
                        maxLines: 1,
                        style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 14.5, color: value == f ? Colors.white : AppColors.textMuted)),
                  ),
                ),
              ),
            ),
            if (f != _Filter.withdrawals) const SizedBox(width: 8),
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
    // What the customer sees (an unpaid deposit reads Failed after 30 seconds);
    // the details sheet gets the server's order and keeps it up to date.
    final real = this.order;
    final order = real.shown;
    final isDeposit = order.isDeposit;
    final methodLabel = order.methodLabel;
    final typeLabel = isDeposit ? AppStrings.deposit : AppStrings.withdraw;
    final ref = (order.transactionRef ?? '').trim();

    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => showTransactionDetails(context, real),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.cardBorder, width: 1.4),
        ),
        child: Row(
          children: [
            MethodIcon(method: order.method, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$typeLabel · $methodLabel',
                    style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 15.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Formatters.dateTime(order.createdAt),
                    style: AppTextStyles.muted.copyWith(fontSize: 12.5),
                  ),
                  if (ref.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('ID: $ref', key: Key('order-ref-${order.id}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.muted.copyWith(fontSize: 11.5)),
                  ],
                  if (!order.isFinal) ...[const SizedBox(height: 4), const VerifyingNote()],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // The amount and the status take at most 40% of the card, so the provider name and the date keep their room on 320 px phones.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: (MediaQuery.of(context).size.width * 0.4).clamp(110.0, 170.0)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      order.amountPending ? AppStrings.amountPending : '${isDeposit ? '+' : '-'}${Formatters.money(order.amount)}',
                      maxLines: 1,
                      style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 16.5,
                        color: isDeposit ? AppColors.statusCompleted : AppColors.statusFailed,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  OrderStatusSlot(order: order),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
