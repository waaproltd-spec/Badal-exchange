import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/commission.dart';
import '../models/payment_methods.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';

/// Commission (agent_commission), its own tab (Reports is unchanged):
/// what Badal Exchange earns on completed betting-company orders -- 2% of
/// deposits, 5% of withdrawals less a 1% bonus (4% net). The bonus comes
/// off the commission, never off the customer's amount.
///
/// Four totals (deposit, withdrawal, commission, bonus), filtered by date
/// and company; managers can also look at one agent or the orders done
/// automatically. An agent always sees only the orders they handled.
/// Below: the orders of the period with their commission (only completed
/// ones earn; failed, cancelled and pending show with nothing earned).
class CommissionScreen extends StatefulWidget {
  const CommissionScreen({super.key});

  @override
  State<CommissionScreen> createState() => _CommissionScreenState();
}

class _CommissionScreenState extends State<CommissionScreen> {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _pretty = DateFormat('MMM d, yyyy');
  static final _when = DateFormat('MMM d, yyyy · HH:mm');

  static const _ranges = [
    ('today', 'Today'),
    ('yesterday', 'Yesterday'),
    ('this_month', 'This Month'),
    ('last_3_months', 'Last 3 Months'),
    ('last_6_months', 'Last 6 Months'),
    ('last_1_year', 'Last 1 Year'),
    ('all_time', 'All Time'),
    ('custom', 'Custom'),
  ];

  String _range = 'today';
  DateTimeRange? _custom;
  String? _method; // null: all companies
  String? _agent; // managers: null everyone, 'automatic', or an agent id
  CommissionReport? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _report == null;
      _error = null;
    });
    try {
      final report = await context.read<Session>().api.getCommission(
            range: _range,
            from: _range == 'custom' ? _iso.format(_custom!.start) : null,
            to: _range == 'custom' ? _iso.format(_custom!.end) : null,
            method: _method,
            agent: _agent,
          );
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load commission.';
        _loading = false;
      });
    }
  }

  Future<void> _selectRange(String range) async {
    if (range == 'custom') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        initialDateRange: _custom ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
      );
      if (picked == null) return;
      _custom = picked;
    }
    setState(() => _range = range);
    _load();
  }

  String _rangeLabel(CommissionReport r) {
    final to = DateTime.tryParse(r.to);
    if (r.from == null) return to == null ? 'All time' : 'All time, up to ${_pretty.format(to)}';
    final from = DateTime.tryParse(r.from!);
    if (from == null || to == null) return '';
    return r.from == r.to ? _pretty.format(from) : '${_pretty.format(from)} – ${_pretty.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _report == null) return ErrorStateView(message: _error!, onRetry: _load);
    final r = _report!;
    final t = r.totals;
    final bottom = MediaQuery.of(context).padding.bottom;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('commission'),
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottom),
        children: [
          ChoiceChipsRow<String>(options: _ranges, selected: _range, onSelected: _selectRange),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.calendar_month_rounded, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Expanded(child: Text(_rangeLabel(r), style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 12),
          ChoiceChipsRow<String?>(
            key: const Key('company-filter'),
            options: [(null, 'All Companies'), for (final c in r.companies) (c.method, c.label)],
            selected: _method,
            onSelected: (m) {
              setState(() => _method = m);
              _load();
            },
          ),
          const SizedBox(height: 10),
          if (r.canSeeAll && r.agents != null)
            DropdownButtonFormField<String?>(
              key: const Key('agent-filter'),
              value: _agent,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Agent', isDense: true),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All agents (consolidated)')),
                const DropdownMenuItem<String?>(value: 'automatic', child: Text('Automatic (no agent)')),
                for (final a in r.agents!)
                  DropdownMenuItem<String?>(value: a.id, child: Text(a.name.isEmpty ? (a.phone ?? a.id) : a.name)),
              ],
              onChanged: (v) {
                setState(() => _agent = v);
                _load();
              },
            )
          else
            const Text('Your commission: the orders you handled.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.statusFailed)),
            ),
          const SizedBox(height: 12),
          TwoColumnGrid(children: [
            StatCard(
              key: const Key('total-deposit'),
              icon: Icons.south_rounded,
              color: AppColors.statusCompleted,
              value: commissionMoney(t.depositTotal),
              label: 'Total Deposit',
              caption: '${t.depositCount} · ${percent(r.depositBp)} = ${commissionMoney(t.depositCommission)}',
            ),
            StatCard(
              key: const Key('total-withdrawal'),
              icon: Icons.north_rounded,
              color: AppColors.accentOrange,
              value: commissionMoney(t.withdrawalTotal),
              label: 'Total Withdrawal',
              caption: '${t.withdrawalCount} · ${percent(r.withdrawBp)} = ${commissionMoney(t.withdrawalGross)}',
            ),
            StatCard(
              key: const Key('total-commission'),
              icon: Icons.payments_rounded,
              color: AppColors.purple,
              value: commissionMoney(t.commission),
              label: 'Total Commission',
              caption: 'Net, after the bonus',
            ),
            StatCard(
              key: const Key('total-bonus'),
              icon: Icons.card_giftcard_rounded,
              color: AppColors.statusProcessing,
              value: commissionMoney(t.bonus),
              label: 'Total Bonus',
              caption: '${percent(r.bonusBp)} of withdrawals, off the commission',
            ),
          ]),
          const SizedBox(height: 8),
          ConsoleCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Line('Deposit commission (${percent(r.depositBp)})', commissionMoney(t.depositCommission)),
              _Line('Withdrawal commission (${percent(r.withdrawBp)})', commissionMoney(t.withdrawalGross)),
              _Line('Bonus (${percent(r.bonusBp)} of withdrawals)', '- ${commissionMoney(t.bonus)}'),
              const Divider(height: 14),
              _Line('Net commission', commissionMoney(t.commission), strong: true),
            ]),
          ),
          const SectionHeader(title: 'Transactions'),
          if (r.transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: EmptyStateView(
                icon: Icons.receipt_long_rounded,
                title: 'No betting transactions',
                message: 'Nothing for these dates and this company.',
              ),
            )
          else
            for (final x in r.transactions) _TransactionCard(row: x, when: x.at == null ? '' : _when.format(x.at!.toLocal())),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.strong = false});
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: strong ? AppColors.textPrimary : AppColors.textSecondary,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  color: strong ? AppColors.statusCompleted : AppColors.textPrimary)),
        ]),
      );
}

class _TransactionCard extends StatelessWidget {
  const _TransactionCard({required this.row, required this.when});
  final CommissionRow row;
  final String when;

  @override
  Widget build(BuildContext context) {
    final type = row.direction == 'deposit' ? 'Deposit' : 'Withdrawal';
    return Padding(
      key: Key('tx-${row.orderCode}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            MethodBadge(method: row.method, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${row.label} · $type',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('$when · ${row.orderCode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ]),
            ),
            const SizedBox(width: 8),
            StatusPill(row.status),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _Figure('Amount', row.amount == null ? '—' : commissionMoney(row.amount!)),
            _Figure('Commission', row.commission == null ? '—' : commissionMoney(row.commission!)),
            _Figure('Bonus', row.bonus == null ? '—' : '- ${commissionMoney(row.bonus!)}'),
            _Figure('Net', row.netCommission == null ? 'Not earned' : commissionMoney(row.netCommission!),
                color: row.earns ? AppColors.statusCompleted : AppColors.textFaint),
          ]),
        ]),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color ?? AppColors.textPrimary)),
      ]);
}
