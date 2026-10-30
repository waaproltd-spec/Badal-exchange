import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/console.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../customer_info_screen.dart';

const _rates = [(50, '0.5%'), (100, '1%'), (150, '1.5%'), (200, '2%')];

/// The groups of transaction types, in the order they are listed.
const _groups = [
  ('withdraw', 'mobile_money', 'Mobile money withdrawals'),
  ('deposit', 'mobile_money', 'Mobile money deposits'),
  ('withdraw', 'platform', 'Betting withdrawals'),
  ('deposit', 'platform', 'Betting deposits'),
];

/// Managers: the Bonus system. On/off for everyone, the rate (0.5–2%), which
/// transaction types earn a bonus, each customer's bonus balance and the
/// history (earned and transferred). A completed order earns only when its
/// type is switched on here.
class BonusSettingsScreen extends StatefulWidget {
  const BonusSettingsScreen({super.key});

  @override
  State<BonusSettingsScreen> createState() => _BonusSettingsScreenState();
}

class _BonusSettingsScreenState extends State<BonusSettingsScreen> {
  BonusSettings? _settings;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await context.read<Session>().api.getBonusSettings();
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load the bonus settings.');
    }
  }

  Future<void> _save({bool? enabled, int? defaultRateBp, List<String>? eligible}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final s = await context
          .read<Session>()
          .api
          .setBonusSettings(enabled: enabled, defaultRateBp: defaultRateBp, eligible: eligible);
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not save.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editLimits(BonusSettings s) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _LimitsDialog(daily: s.dailyLimit ?? '', monthly: s.monthlyLimit ?? ''),
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final updated = await context.read<Session>().api.setBonusLimits(daily: result.$1, monthly: result.$2);
      if (mounted) setState(() => _settings = updated);
      messenger.showSnackBar(const SnackBar(content: Text('Bonus limits saved.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not save.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toggleType(BonusSettings s, BonusType t, bool on) {
    final keys = s.eligibleKeys.toSet();
    on ? keys.add(t.key) : keys.remove(t.key);
    _save(eligible: keys.toList()..sort());
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Bonus')),
      body: s == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(onRefresh: _load, child: _body(s)),
    );
  }

  Widget _body(BonusSettings s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ConsoleCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const TintedIcon(icon: Icons.redeem_rounded, color: AppColors.accentOrange, size: 44),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Bonus system',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ),
              Switch(
                key: const Key('bonus-system'),
                value: s.enabled,
                onChanged: _saving ? null : (v) => _save(enabled: v),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              s.enabled
                  ? 'Customers earn the bonus on completed transactions of the types switched on below.'
                  : 'Off: nobody earns a bonus. Bonuses already earned stay in the customers\' bonus wallets.',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            const Text('Bonus rate', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            IgnorePointer(
              ignoring: _saving,
              child: ChoiceChipsRow<int>(
                key: const Key('bonus-default-rate'),
                options: _rates,
                selected: s.defaultRateBp,
                onSelected: (bp) {
                  if (bp != s.defaultRateBp) _save(defaultRateBp: bp);
                },
              ),
            ),
            const SizedBox(height: 4),
            const Text('For every customer without a rate of their own (set on Customer Info).',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
          ]),
        ),
        const SizedBox(height: 12),
        ConsoleCard(
          key: const Key('bonus-limits'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                child: Text('Limits per customer',
                    style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ),
              TextButton(
                key: const Key('bonus-limits-edit'),
                onPressed: _saving ? null : () => _editLimits(s),
                child: const Text('Change'),
              ),
            ]),
            InfoRow('Per day', s.dailyLimit == null ? 'No limit' : '\$${s.dailyLimit}'),
            InfoRow('Per month', s.monthlyLimit == null ? 'No limit' : '\$${s.monthlyLimit}'),
            const Text('Over a limit, the rest of a bonus is not credited; the history says so.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
          ]),
        ),
        const SizedBox(height: 12),
        TwoColumnGrid(children: [
          StatCard(
              icon: Icons.account_balance_wallet_rounded,
              color: AppColors.purple,
              value: '\$${s.totalBalance}',
              label: 'In bonus wallets'),
          StatCard(
              icon: Icons.trending_up_rounded,
              color: AppColors.statusCompleted,
              value: '\$${s.totalEarned}',
              label: 'Earned in total'),
          StatCard(
              icon: Icons.account_balance_wallet_outlined,
              color: AppColors.accentOrange,
              value: '\$${s.totalMoved}',
              label: 'Moved to main wallets'),
        ]),
        const SizedBox(height: 8),
        const SectionHeader(title: 'Transactions that earn a bonus'),
        for (final (direction, kind, title) in _groups) ...[
          GroupLabel(title),
          ConsoleCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final t in s.types.where((t) => t.direction == direction && t.kind == kind))
                SwitchListTile(
                  key: Key('bonus-type-${t.key}'),
                  dense: true,
                  title: Text(t.label),
                  value: t.eligible,
                  onChanged: _saving ? null : (v) => _toggleType(s, t, v),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        const SectionHeader(title: 'Customers'),
        if (s.customers.isEmpty)
          const ConsoleCard(child: Text('No customer has a bonus yet.', style: TextStyle(color: AppColors.textSecondary)))
        else
          for (final c in s.customers) ...[
            ConsoleCard(
              key: Key('bonus-customer-${c.id}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => CustomerInfoScreen(customerId: c.id, name: c.name)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    Text('${c.phone} · ${c.rate}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('\$${c.balance}', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  Text('Earned \$${c.totalEarned}', style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                ]),
              ]),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 4),
        const SectionHeader(title: 'History'),
        if (s.history.isEmpty)
          const ConsoleCard(child: Text('Nothing yet.', style: TextStyle(color: AppColors.textSecondary)))
        else
          for (final e in s.history) ...[
            _HistoryTile(entry: e),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final CustomerBonusEntry entry;
  const _HistoryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = e.earned ? AppColors.statusCompleted : AppColors.purple;
    final what = e.earned
        ? '${e.rate ?? ''} of \$${e.withdrawal ?? ''} ${e.methodLabel ?? ''} ${e.direction == 'deposit' ? 'deposit' : 'withdrawal'}'
            ' · ${e.orderCode ?? ''}'
        : 'Transferred to main wallet (\$${e.movedToMain ?? e.amount})';
    return ConsoleCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        TintedIcon(icon: e.earned ? Icons.redeem_rounded : Icons.account_balance_wallet_rounded, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.customerName ?? '', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            Text(what, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
            if (e.note != null) Text(e.note!, style: const TextStyle(fontSize: 12, color: AppColors.statusPending)),
            Text(formatDateTime(e.createdAt), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
          ]),
        ),
        Text('${e.earned ? '+' : '-'}\$${e.amount}', style: TextStyle(fontWeight: FontWeight.w800, color: color)),
      ]),
    );
  }
}

/// Daily and monthly bonus limits per customer, in dollars; empty: no limit.
class _LimitsDialog extends StatefulWidget {
  final String daily;
  final String monthly;
  const _LimitsDialog({required this.daily, required this.monthly});

  @override
  State<_LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<_LimitsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _daily = TextEditingController(text: widget.daily);
  late final _monthly = TextEditingController(text: widget.monthly);

  @override
  void dispose() {
    _daily.dispose();
    _monthly.dispose();
    super.dispose();
  }

  String? _check(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = double.tryParse(t);
    return n == null || n <= 0 ? 'Enter an amount, or leave empty' : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bonus limits'),
      content: Form(
        key: _formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            key: const Key('bonus-daily-limit'),
            controller: _daily,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Per customer per day (\$)', helperText: 'Empty: no limit'),
            validator: _check,
          ),
          TextFormField(
            key: const Key('bonus-monthly-limit'),
            controller: _monthly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Per customer per month (\$)', helperText: 'Empty: no limit'),
            validator: _check,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) Navigator.of(context).pop((_daily.text.trim(), _monthly.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
