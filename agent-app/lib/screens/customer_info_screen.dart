import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/customer_bonus_card.dart';
import '../widgets/state_views.dart';
import '../l10n/wallet_strings.dart';
import '../models/wallet_adjustment.dart';
import 'admin/system_screens.dart';
import 'wallet/wallet_adjust_screen.dart';
import 'wallet/wallet_history_screen.dart';

/// One customer: profile, wallet, totals, recent orders and recent wallet
/// transactions. The only change made here is a password reset, for
/// management, when the customer asked support for a new password.
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

  Future<void> _resetPassword() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _ResetPasswordDialog(name: widget.name),
    );
    if (password == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<Session>().api.resetCustomerPassword(widget.customerId, password);
      messenger.showSnackBar(const SnackBar(content: Text('Password reset. Tell the customer their new password.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not reset the password.')));
    }
  }

  Future<void> _adjust(CustomerSummary c, bool add) async {
    final done = await Navigator.of(context).push<WalletAdjustment>(MaterialPageRoute(
      builder: (_) => WalletAdjustScreen(customerId: c.id, name: c.name, phone: c.phone, balance: c.walletBalance, add: add),
    ));
    if (done != null && mounted) _load();
  }

  void _openHistory(CustomerSummary c) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WalletHistoryScreen(customerId: c.id, name: c.name, phone: c.phone, balance: c.walletBalance),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Info'),
        actions: [
          IconButton(
            key: const Key('wallet-history'),
            tooltip: WalletStrings.walletHistory,
            icon: const Icon(Icons.manage_history_rounded),
            onPressed: _detail == null ? null : () => _openHistory(_detail!.summary),
          ),
          IconButton(
            key: const Key('reset-customer-password'),
            tooltip: 'Reset password',
            icon: const Icon(Icons.lock_reset_rounded),
            onPressed: _detail == null ? null : _resetPassword,
          ),
        ],
      ),
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
        Row(
          children: [
            Expanded(
              child: _WalletButton(
                key: const Key('add-money'),
                color: AppColors.statusCompleted,
                icon: Icons.add_rounded,
                title: WalletStrings.addMoney,
                onTap: () => _adjust(c, true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _WalletButton(
                key: const Key('deduct-money'),
                color: AppColors.statusFailed,
                icon: Icons.remove_rounded,
                title: WalletStrings.deductMoney,
                onTap: () => _adjust(c, false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        CustomerBonusCard(api: context.read<Session>().api, customerId: c.id),
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
        SectionHeader(
          title: 'Recent Transactions',
          actionLabel: 'View all',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CustomerLedgerScreen(customerId: c.id, name: c.name)),
          ),
        ),
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
      'credit' when entry.description == 'Bonus moved to main wallet' =>
        ('Bonus moved in', Icons.redeem_rounded, AppColors.statusCompleted, '+'),
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

/// Asks for the new password twice; returns it, or null when cancelled.
class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.name});

  final String name;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Only do this when ${widget.name} asked for it from their registered number. '
              'They are signed out everywhere.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('new-password'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
              validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
            ),
            TextFormField(
              key: const Key('confirm-new-password'),
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
              validator: (v) => v != _password.text ? 'Passwords do not match' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) Navigator.of(context).pop(_password.text);
          },
          child: const Text('Reset'),
        ),
      ],
    );
  }
}

/// Add Money / Deduct Money on Customer Info.
class _WalletButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _WalletButton({super.key, required this.color, required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
