import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../models/customer_block.dart';
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
import '../l10n/tr.dart';

/// One customer: profile, wallet, totals, recent orders and recent wallet
/// transactions. The only change made here is a password reset, for
/// management, when the customer asked support for a new password.
class CustomerInfoScreen extends StatefulWidget {
  final String customerId;
  final String name;

  const CustomerInfoScreen(
      {super.key, required this.customerId, required this.name});

  @override
  State<CustomerInfoScreen> createState() => _CustomerInfoScreenState();
}

class _CustomerInfoScreenState extends State<CustomerInfoScreen> {
  CustomerDetail? _detail;
  String? _error;

  /// Managers only (the server refuses everyone else): blocked or not, why, and the history.
  CustomerBlockInfo? _block;
  bool _blocking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = context.read<Session>().api;
      final detail = await api.getCustomer(widget.customerId);
      CustomerBlockInfo? block;
      try {
        block = await api.getCustomerBlockInfo(widget.customerId);
      } catch (_) {
        block = null; // not a manager: no Block button
      }
      if (mounted) {
        setState(() {
          _detail = detail;
          _block = block;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() => _error =
            e is ApiException ? e.message : tr('Failed to load customer.'));
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
      await context
          .read<Session>()
          .api
          .resetCustomerPassword(widget.customerId, password);
      messenger.showSnackBar(const SnackBar(
          content:
              Tx('Password reset. Tell the customer their new password.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Tx(e is ApiException
              ? e.message
              : tr('Could not reset the password.'))));
    }
  }

  /// Asks first (and for the reason when blocking), then blocks or unblocks.
  Future<void> _toggleBlock(CustomerSummary c) async {
    final block = !(_block?.blocked ?? !c.isActive);
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _BlockDialog(name: c.name, block: block),
    );
    if (reason == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _blocking = true);
    try {
      final info = await context.read<Session>().api.setCustomerBlocked(c.id,
          blocked: block, reason: reason.isEmpty ? null : reason);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content:
              Tx(block ? tr('Customer blocked.') : tr('Customer unblocked.'))));
      setState(() => _block = info);
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Tx(e is ApiException
              ? e.message
              : tr('Could not change the customer.'))));
    } finally {
      if (mounted) setState(() => _blocking = false);
    }
  }

  Future<void> _adjust(CustomerSummary c, bool add) async {
    final done =
        await Navigator.of(context).push<WalletAdjustment>(MaterialPageRoute(
      builder: (_) => WalletAdjustScreen(
          customerId: c.id,
          name: c.name,
          phone: c.phone,
          balance: c.walletBalance,
          add: add),
    ));
    if (done != null && mounted) _load();
  }

  void _openHistory(CustomerSummary c) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WalletHistoryScreen(
          customerId: c.id,
          name: c.name,
          phone: c.phone,
          balance: c.walletBalance),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Tx('Customer Info'),
        actions: [
          IconButton(
            key: const Key('wallet-history'),
            tooltip: WalletStrings.walletHistory,
            icon: const Icon(Icons.manage_history_rounded),
            onPressed:
                _detail == null ? null : () => _openHistory(_detail!.summary),
          ),
          IconButton(
            key: const Key('reset-customer-password'),
            tooltip: tr('Reset password'),
            icon: const Icon(Icons.lock_reset_rounded),
            onPressed: _detail == null ? null : _resetPassword,
          ),
        ],
      ),
      body: _detail == null
          ? (_error != null
              ? ErrorStateView(message: _error!, onRetry: _load)
              : const LoadingView())
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
              const TintedIcon(
                  icon: Icons.person_rounded,
                  color: AppColors.purple,
                  size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tx(
                      c.name,
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(c.phone,
                        style: TextStyle(color: AppColors.textSecondary)),
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
              const TintedIcon(
                  icon: Icons.account_balance_wallet_rounded,
                  color: AppColors.purple,
                  size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tx('Wallet Balance',
                        style: TextStyle(color: AppColors.textSecondary)),
                    Text(
                      '\$${c.walletBalance}',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary),
                    ),
                    if (d.pendingBalance != '0.00')
                      Text(
                        trp('\${0} held for pending withdrawals',
                            [d.pendingBalance]),
                        style:
                            TextStyle(fontSize: 12, color: AppColors.textFaint),
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
          StatCard(
              icon: Icons.shopping_bag_rounded,
              color: AppColors.purple,
              value: '${d.totalOrders}',
              label: tr('Total Orders')),
          StatCard(
              icon: Icons.south_rounded,
              color: AppColors.statusCompleted,
              value: '\$${d.totalDeposits}',
              label: tr('Total Deposits')),
          StatCard(
              icon: Icons.north_rounded,
              color: AppColors.accentOrange,
              value: '\$${d.totalWithdrawals}',
              label: tr('Total Withdrawals')),
          StatCard(
              icon: Icons.list_alt_rounded,
              color: AppColors.statusProcessing,
              value: '${d.totalTransactions}',
              label: tr('Total Transactions')),
        ]),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            children: [
              InfoRow(tr('Registration date'),
                  c.registeredAt != null ? formatDate(c.registeredAt!) : '—'),
              InfoRow(tr('Account status'),
                  c.isActive ? tr('Active') : tr('Blocked')),
            ],
          ),
        ),
        if (_block != null) ...[
          const SizedBox(height: 12),
          _BlockSection(
              info: _block!, busy: _blocking, onToggle: () => _toggleBlock(c)),
        ],
        const SizedBox(height: 8),
        SectionHeader(title: tr('Recent Orders')),
        if (d.recentOrders.isEmpty)
          ConsoleCard(
              child: Tx('No orders yet.',
                  style: TextStyle(color: AppColors.textSecondary)))
        else
          for (final o in d.recentOrders) ...[
            ActivityTile(
                item: o,
                showCustomer: false,
                onTap: () => showActivityDetails(context, o)),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 8),
        SectionHeader(
          title: tr('Recent Transactions'),
          actionLabel: tr('View all'),
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) =>
                    CustomerLedgerScreen(customerId: c.id, name: c.name)),
          ),
        ),
        if (d.recentTransactions.isEmpty)
          ConsoleCard(
              child: Tx('No wallet transactions yet.',
                  style: TextStyle(color: AppColors.textSecondary)))
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
    final (String label, IconData icon, Color color, String sign) =
        switch (entry.type) {
      'credit' when entry.description == 'Bonus moved to main wallet' => (
          tr('Bonus moved in'),
          Icons.redeem_rounded,
          AppColors.statusCompleted,
          '+'
        ),
      'credit' => (
          tr('Deposit'),
          Icons.south_rounded,
          AppColors.statusCompleted,
          '+'
        ),
      'release' => (
          tr('Released'),
          Icons.undo_rounded,
          AppColors.statusCompleted,
          '+'
        ),
      'reserve' => (
          tr('Held for withdrawal'),
          Icons.lock_clock_rounded,
          AppColors.statusPending,
          '-'
        ),
      _ => (tr('Withdrawal'), Icons.north_rounded, AppColors.accentOrange, '-'),
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
                Tx(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                Tx(
                  formatDateTime(entry.createdAt),
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$sign\$${entry.amount}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: color)),
              Text(trp('Bal. \${0}', [entry.balanceAfter]),
                  style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
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
      title: const Tx('Reset password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              trp('Only do this when {0} asked for it from their registered number. They are signed out everywhere.',
                  [widget.name]),
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('new-password'),
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('New password')),
              validator: (v) =>
                  (v ?? '').length < 8 ? tr('At least 8 characters') : null,
            ),
            TextFormField(
              key: const Key('confirm-new-password'),
              controller: _confirm,
              obscureText: true,
              decoration:
                  InputDecoration(labelText: tr('Confirm new password')),
              validator: (v) =>
                  v != _password.text ? tr('Passwords do not match') : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Tx('Cancel')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate())
              Navigator.of(context).pop(_password.text);
          },
          child: const Tx('Reset'),
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

  const _WalletButton(
      {super.key,
      required this.color,
      required this.icon,
      required this.title,
      required this.onTap});

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
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Tx(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Block / Unblock button, why the customer is blocked, and the history of blocks.
class _BlockSection extends StatelessWidget {
  const _BlockSection(
      {required this.info, required this.busy, required this.onToggle});

  final CustomerBlockInfo info;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final blocked = info.blocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blocked)
          ConsoleCard(
            key: const Key('block-notice'),
            color: AppColors.statusFailed.withOpacity(0.06),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.block_rounded, color: AppColors.statusFailed),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Tx('This customer is blocked',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.statusFailed)),
                      if ((info.reason ?? '').isNotEmpty)
                        Text(info.reason!, key: const Key('block-reason')),
                      if (info.blockedAt != null)
                        Text(formatDateTime(info.blockedAt!),
                            style: TextStyle(
                                fontSize: 12, color: AppColors.textFaint)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (blocked) const SizedBox(height: 10),
        blocked
            ? OutlinedButton.icon(
                key: const Key('unblock-customer'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: AppColors.statusCompleted,
                    side: const BorderSide(color: AppColors.statusCompleted)),
                onPressed: busy ? null : onToggle,
                icon: const Icon(Icons.lock_open_rounded),
                label: const Tx('Unblock Customer'),
              )
            : FilledButton.icon(
                key: const Key('block-customer'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: AppColors.statusFailed),
                onPressed: busy ? null : onToggle,
                icon: const Icon(Icons.block_rounded),
                label: const Tx('Block Customer'),
              ),
        if (info.history.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionHeader(title: tr('Block history')),
          for (final (i, h) in info.history.indexed) ...[
            ConsoleCard(
              key: Key('block-history-entry-$i'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TintedIcon(
                    icon: h.isBlock
                        ? Icons.block_rounded
                        : Icons.lock_open_rounded,
                    color: h.isBlock
                        ? AppColors.statusFailed
                        : AppColors.statusCompleted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tx(h.isBlock ? 'Blocked' : 'Unblocked',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        if ((h.reason ?? '').isNotEmpty) Text(h.reason!),
                        Text(
                          [
                            if ((h.by ?? '').isNotEmpty) trp('By {0}', [h.by!]),
                            if (h.at != null) formatDateTime(h.at!),
                          ].join(' • '),
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

/// Confirms a block (the reason is required) or an unblock (the reason is optional). Pops with the
/// reason (empty when none was typed), or null when cancelled.
class _BlockDialog extends StatefulWidget {
  const _BlockDialog({required this.name, required this.block});

  final String name;
  final bool block;

  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    return AlertDialog(
      title: Text(trp(block ? 'Block {0}?' : 'Unblock {0}?', [widget.name])),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(block
                    ? 'They are signed out everywhere and can not log in or use any service until you unblock them.'
                    : 'They can log in and use the services again.'),
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('block-reason-field'),
                controller: _reason,
                maxLength: 300,
                maxLines: 2,
                decoration: InputDecoration(
                    labelText: tr(
                        block ? 'Reason for blocking' : 'Reason (optional)')),
                validator: (v) => block && (v ?? '').trim().length < 3
                    ? tr('Write the reason for blocking')
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            key: const Key('block-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Tx('Cancel')),
        FilledButton(
          key: const Key('block-confirm'),
          style: FilledButton.styleFrom(
              backgroundColor:
                  block ? AppColors.statusFailed : AppColors.statusCompleted),
          onPressed: () {
            if (_formKey.currentState!.validate())
              Navigator.of(context).pop(_reason.text.trim());
          },
          child: Tx(block ? 'Block' : 'Unblock'),
        ),
      ],
    );
  }
}
