import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';

/// Read-only view of one customer: profile, wallet, totals, recent orders and
/// recent wallet transactions. Agents cannot change customer data here.
class CustomerInfoScreen extends StatefulWidget {
  final String customerId;
  final String name;

  const CustomerInfoScreen({super.key, required this.customerId, required this.name});

  @override
  State<CustomerInfoScreen> createState() => _CustomerInfoScreenState();
}

class _CustomerInfoScreenState extends State<CustomerInfoScreen> {
  CustomerDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await context.read<Session>().api.getCustomer(widget.customerId);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Failed to load customer.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Info')),
      body: _detail == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(onRefresh: _load, child: _body(_detail!)),
    );
  }

  Widget _body(CustomerDetail d) {
    final c = d.summary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ConsoleCard(
          child: Row(
            children: [
              const TintedIcon(icon: Icons.person_rounded, color: AppColors.purple, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(c.phone, style: const TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    StatusPill(c.status),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Row(
            children: [
              const TintedIcon(icon: Icons.account_balance_wallet_rounded, color: AppColors.purple, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Wallet Balance', style: TextStyle(color: AppColors.textSecondary)),
                    Text(
                      '\$${c.walletBalance}',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                    ),
                    if (d.pendingBalance != '0.00')
                      Text(
                        '\$${d.pendingBalance} held for pending withdrawals',
                        style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TwoColumnGrid(children: [
          StatCard(icon: Icons.shopping_bag_rounded, color: AppColors.purple, value: '${d.totalOrders}', label: 'Total Orders'),
          StatCard(icon: Icons.south_rounded, color: AppColors.statusCompleted, value: '\$${d.totalDeposits}', label: 'Total Deposits'),
          StatCard(icon: Icons.north_rounded, color: AppColors.accentOrange, value: '\$${d.totalWithdrawals}', label: 'Total Withdrawals'),
          StatCard(icon: Icons.list_alt_rounded, color: AppColors.statusProcessing, value: '${d.totalTransactions}', label: 'Total Transactions'),
        ]),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            children: [
              InfoRow('Registration date', c.registeredAt != null ? formatDate(c.registeredAt!) : '—'),
              InfoRow('Account status', c.isActive ? 'Active' : 'Blocked'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const SectionHeader(title: 'Recent Orders'),
        if (d.recentOrders.isEmpty)
          const ConsoleCard(child: Text('No orders yet.', style: TextStyle(color: AppColors.textSecondary)))
        else
          for (final o in d.recentOrders) ...[
            ActivityTile(item: o, showCustomer: false, onTap: () => showActivityDetails(context, o)),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 8),
        const SectionHeader(title: 'Recent Transactions'),
        if (d.recentTransactions.isEmpty)
          const ConsoleCard(child: Text('No wallet transactions yet.', style: TextStyle(color: AppColors.textSecondary)))
        else
          for (final t in d.recentTransactions) ...[
            _LedgerTile(entry: t),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _LedgerTile extends StatelessWidget {
  final LedgerEntry entry;
  const _LedgerTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    // credit adds to the balance; debit/reserve take from it; release returns it.
    final (String label, IconData icon, Color color, String sign) = switch (entry.type) {
      'credit' => ('Deposit', Icons.south_rounded, AppColors.statusCompleted, '+'),
      'release' => ('Released', Icons.undo_rounded, AppColors.statusCompleted, '+'),
      'reserve' => ('Held for withdrawal', Icons.lock_clock_rounded, AppColors.statusPending, '-'),
      _ => ('Withdrawal', Icons.north_rounded, AppColors.accentOrange, '-'),
    };
    return ConsoleCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          TintedIcon(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                Text(
                  formatDateTime(entry.createdAt),
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$sign\$${entry.amount}', style: TextStyle(fontWeight: FontWeight.w800, color: color)),
              Text('Bal. \$${entry.balanceAfter}', style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
            ],
          ),
        ],
      ),
    );
  }
}
