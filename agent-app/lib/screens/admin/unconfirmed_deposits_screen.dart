import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/deposit_board.dart';
import '../../models/payment_methods.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/state_views.dart';

/// Unconfirmed Deposits (manage_unconfirmed_deposits): customers who started
/// a deposit, apart from confirmed payments.
///
///  * "Customer has not confirmed the deposit yet." -- the deposit form was
///    filled in (recorded by the Customer App) but Confirm Deposit was never
///    pressed: no order exists.
///  * "Pending Admin Verification." -- Confirm Deposit was pressed: the order
///    waits for the payment to be verified. Pressing it proves no money came.
///
/// Neither is ever credited to a wallet. Each shows how long it has waited;
/// past 48 hours it is marked overdue and stays listed, as do deposits that
/// expired unpaid or were rejected. Only what the server stored is shown.
class UnconfirmedDepositsScreen extends StatefulWidget {
  const UnconfirmedDepositsScreen({super.key});

  @override
  State<UnconfirmedDepositsScreen> createState() => _UnconfirmedDepositsScreenState();
}

enum _Show { all, notConfirmed, pendingVerification, overdue, closed }

class _UnconfirmedDepositsScreenState extends State<UnconfirmedDepositsScreen> {
  static final _when = DateFormat('d MMM yyyy, HH:mm');
  static final _day = DateFormat('d MMM yyyy');

  UnconfirmedDeposits? _data;
  String? _error;
  bool _loading = true;
  _Show _show = _Show.all;
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _range = DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final data = await context.read<Session>().api.getUnconfirmedDeposits(
            from: _range.start,
            to: _range.end.add(const Duration(days: 1)),
          );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Could not load unconfirmed deposits.';
        _loading = false;
      });
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
    );
    if (picked == null) return;
    setState(() => _range = picked);
    _load();
  }

  bool _matches(UnconfirmedDeposit d) => switch (_show) {
        _Show.all => true,
        _Show.notConfirmed => d.status == 'not_confirmed',
        _Show.pendingVerification => d.status == 'pending_verification',
        _Show.overdue => d.overdue,
        _Show.closed => d.status == 'expired' || d.status == 'cancelled',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unconfirmed Deposits')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : _content()),
      ),
    );
  }

  Widget _content() {
    final data = _data!;
    final shown = data.deposits.where(_matches).toList();
    return ListView(
      key: const Key('unconfirmed-deposits'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Text(
          'Customers who started a deposit. Nothing here has been credited: a wallet is credited only '
          'when the payment itself is verified.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _Count(key: const Key('count-not-confirmed'), label: 'Not confirmed by customer',
              value: data.notConfirmed, color: AppColors.statusUnmatched)),
          const SizedBox(width: 8),
          Expanded(child: _Count(key: const Key('count-pending'), label: 'Pending admin verification',
              value: data.pendingVerification, color: AppColors.statusPending)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _Count(key: const Key('count-overdue'), label: 'Overdue (over 48 hours)',
              value: data.overdue, color: AppColors.statusFailed)),
          const SizedBox(width: 8),
          Expanded(child: _Count(key: const Key('count-closed'), label: 'Expired / rejected (not credited)',
              value: data.expired, color: AppColors.statusDuplicate)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.calendar_month_rounded, size: 18),
              label: Text('${_day.format(_range.start)} - ${_day.format(_range.end)}'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final (s, label) in const [
            (_Show.all, 'All'),
            (_Show.notConfirmed, 'Not confirmed'),
            (_Show.pendingVerification, 'Pending verification'),
            (_Show.overdue, 'Overdue'),
            (_Show.closed, 'Expired / rejected'),
          ])
            ChoiceChip(label: Text(label), selected: _show == s, onSelected: (_) => setState(() => _show = s)),
        ]),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyStateView(
              icon: Icons.hourglass_empty_rounded,
              title: 'Nothing here',
              message: 'No deposits in this period match.',
            ),
          )
        else
          ...shown.map(_card),
      ],
    );
  }

  Color _statusColor(UnconfirmedDeposit d) => switch (d.status) {
        'not_confirmed' => AppColors.statusUnmatched,
        'pending_verification' => AppColors.statusPending,
        _ => AppColors.statusDuplicate,
      };

  Widget _card(UnconfirmedDeposit d) {
    final color = _statusColor(d);
    return Card(
      key: Key('row-${d.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              MethodBadge(method: d.method, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.customerPhone, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text(
                    [d.customerName, methodInfo(d.method).label, if (d.accountId != null) 'ID ${d.accountId}', d.orderCode]
                        .whereType<String>()
                        .join(' · '),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                ]),
              ),
              Text(d.amount != null ? '\$${d.amount}' : 'No amount',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
            const SizedBox(height: 10),
            Container(
              key: Key('status-${d.id}'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(8)),
              child: Text(d.statusText, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.timer_outlined, size: 16, color: d.overdue ? AppColors.statusFailed : AppColors.textSecondary),
              const SizedBox(width: 4),
              Text('Waiting ${waitedEnglish(d.waitingSeconds)}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: d.overdue ? AppColors.statusFailed : AppColors.textPrimary)),
              if (d.overdue) ...[
                const SizedBox(width: 8),
                Container(
                  key: Key('overdue-${d.id}'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.statusFailed, borderRadius: BorderRadius.circular(6)),
                  child: const Text('OVERDUE 48h', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
            const SizedBox(height: 4),
            Text('Started ${_when.format(d.startedAt.toLocal())}'
                '${d.submittedAt != null ? '  ·  Confirmed by customer ${_when.format(d.submittedAt!.toLocal())}' : ''}',
                style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// "45 sec", "12 min", "5 h 20 min", "2 days 3 h".
String waitedEnglish(int seconds) {
  if (seconds < 60) return '$seconds sec';
  if (seconds < 3600) return '${seconds ~/ 60} min';
  if (seconds < 86400) return '${seconds ~/ 3600} h ${(seconds % 3600) ~/ 60} min';
  return '${seconds ~/ 86400} days ${(seconds % 86400) ~/ 3600} h';
}

class _Count extends StatelessWidget {
  const _Count({super.key, required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$value', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ]),
    );
  }
}
