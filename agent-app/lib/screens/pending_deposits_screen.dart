import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/deposit_board.dart';
import '../models/match_result.dart';
import '../models/payment_methods.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/payment_confirm_sheet.dart';
import '../widgets/state_views.dart';
import 'customer_info_screen.dart';

/// Lacagaha Sugaya Xaqiijinta: every deposit customers sent that is not
/// confirmed yet (agent_deposit_board). At the top: customers waiting, their
/// total, deposits that expired unpaid in the period, new ones in 24 hours.
/// Then the deposits, filtered by method, a search (number, name or ID) and
/// the period, each with how long it has waited and Xaqiiji (confirm the
/// payment, lib/widgets/payment_confirm_sheet.dart), Diid (reject, with a
/// reason; nothing was credited) and the customer. A table on a wide
/// screen, cards on a phone.
///
/// EVC Plus deposits still match automatically from the payment SMS (see
/// lib/sms/sms_bridge.dart): a matched one leaves this list by itself.
class PendingDepositsScreen extends StatefulWidget {
  const PendingDepositsScreen({super.key});

  @override
  State<PendingDepositsScreen> createState() => _PendingDepositsScreenState();
}

class _PendingDepositsScreenState extends State<PendingDepositsScreen> with LiveRefresh {
  static final _day = DateFormat('d MMM yyyy');
  static final _when = DateFormat('d MMM yyyy\nHH:mm');

  DepositBoard? _board;
  String? _error;
  bool _loading = true;
  String? _method; // null: all
  String _query = '';
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _range = DateTimeRange(start: today, end: today);
    _load();
    listenForLiveChanges(context.read<Session>().live.changes, _load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = _board == null;
      _error = null;
    });
    try {
      final board = await context.read<Session>().api.getDepositBoard(
            from: _range.start,
            to: _range.end.add(const Duration(days: 1)),
          );
      if (!mounted) return;
      setState(() {
        _board = board;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Lacagaha lama soo rarin karin.';
        _loading = false;
      });
    }
  }

  List<BoardDeposit> get _shown {
    final q = _query.trim().toLowerCase();
    return (_board?.deposits ?? const <BoardDeposit>[]).where((d) {
      if (_method != null && d.order.method != _method) return false;
      if (q.isEmpty) return true;
      return [d.order.phoneNumber, d.order.accountId, d.customerName, d.customerPhone, d.order.orderCode, d.order.depositCode]
          .any((v) => v != null && v.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _confirm({BoardDeposit? deposit}) async {
    final result = await showPaymentConfirmSheet(context, order: deposit?.order);
    if (result == null || !mounted) return;
    showMatchResultSnackBar(context, result);
    if (result.status == MatchStatus.matched) _load();
  }

  Future<void> _reject(BoardDeposit d) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Diid ${d.order.orderCode}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('\$${d.order.amount} · ${d.order.methodLabel} · ${d.order.phoneNumber ?? d.order.accountId ?? ''}\n'
                'Lacag lama siin macmiilka; dalabka waa la xirayaa.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reject-reason'),
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Sababta', hintText: 'Tusaale: lacag lama helin'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Ka noqo')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Diid'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Session>().api.rejectDeposit(d.order.id, reason: reason.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${d.order.orderCode} waa la diiday.')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Lama diidi karin.')));
    }
  }

  void _view(BoardDeposit d) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomerInfoScreen(customerId: d.order.customerId, name: d.customerName ?? d.customerPhone ?? ''),
    ));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : LayoutBuilder(builder: (context, box) => _content(box.maxWidth >= 900))),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _confirm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Xaqiiji lacag'),
      ),
    );
  }

  Widget _content(bool wide) {
    final board = _board!;
    final shown = _shown;
    return ListView(
      key: const Key('deposit-board'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Lacagaha Sugaya Xaqiijinta',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        const Text('Liiska dhammaan lacagaha ay macmiishu soo direen ee aan weli la xaqiijin.',
            style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        _summary(board, wide),
        const SizedBox(height: 16),
        _filters(wide),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyStateView(
              icon: Icons.arrow_circle_down_rounded,
              title: 'Lacag sugaysa ma jirto',
              message: 'EVC Plus si toos ah ayuu u xaqiijismaa marka SMS-ka lacagta yimaado. '
                  'Lacagaha kale ku xaqiiji badhanka hoose.',
            ),
          )
        else if (wide)
          _table(shown)
        else
          ...shown.map(_card),
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Waxaa la muujinayaa ${shown.length} ka mid ah ${board.deposits.length}',
                style: const TextStyle(color: AppColors.textSecondary)),
          ),
      ],
    );
  }

  Widget _summary(DepositBoard b, bool wide) {
    final cards = [
      _SummaryCard(key: const Key('sum-customers'), icon: Icons.schedule_rounded, color: AppColors.statusPending,
          title: 'Tirada Macmiisha', value: '${b.pendingCustomers}', note: 'Sugaya Xaqiijin'),
      _SummaryCard(key: const Key('sum-total'), icon: Icons.payments_rounded, color: AppColors.statusProcessing,
          title: 'Wadarta Lacagaha', value: '\$${b.pendingTotal}', note: 'Sugaya Xaqiijin'),
      _SummaryCard(key: const Key('sum-expired'), icon: Icons.error_outline_rounded, color: AppColors.statusFailed,
          title: 'Waqtiga Dhammaaday', value: '${b.expiredCount}', note: 'Muddada la doortay'),
      _SummaryCard(key: const Key('sum-new'), icon: Icons.check_circle_rounded, color: AppColors.statusCompleted,
          title: 'Maanta Cusub', value: '${b.newCount}', note: '24 saac gudahood'),
    ];
    if (wide) {
      return Row(children: [for (final c in cards) Expanded(child: Padding(padding: const EdgeInsets.all(4), child: c))]);
    }
    return Column(children: [
      Row(children: [Expanded(child: cards[0]), const SizedBox(width: 8), Expanded(child: cards[1])]),
      const SizedBox(height: 8),
      Row(children: [Expanded(child: cards[2]), const SizedBox(width: 8), Expanded(child: cards[3])]),
    ]);
  }

  Widget _filters(bool wide) {
    final methods = {for (final d in _board!.deposits) d.order.method}.toList()..sort();
    final method = DropdownButtonFormField<String?>(
      key: const Key('method-filter'),
      value: methods.contains(_method) ? _method : null,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Dhammaan Hababka')),
        for (final m in methods) DropdownMenuItem<String?>(value: m, child: Text(methodInfo(m).label)),
      ],
      onChanged: (v) => setState(() => _method = v),
    );
    final search = TextField(
      key: const Key('deposit-search'),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.search_rounded),
        hintText: 'Raadi lambarka macmiilka, magaca ama ID...',
      ),
      onChanged: (v) => setState(() => _query = v),
    );
    final range = OutlinedButton.icon(
      onPressed: _pickRange,
      icon: const Icon(Icons.calendar_month_rounded, size: 18),
      label: Text('${_day.format(_range.start)} - ${_day.format(_range.end)}'),
    );
    final refresh = OutlinedButton.icon(
      onPressed: _load,
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text('Cusboonaysii'),
    );
    if (wide) {
      return Row(children: [
        SizedBox(width: 220, child: method),
        const SizedBox(width: 12),
        Expanded(child: search),
        const SizedBox(width: 12),
        range,
        const SizedBox(width: 12),
        refresh,
      ]);
    }
    return Column(children: [
      search,
      const SizedBox(height: 8),
      Row(children: [Expanded(child: method), const SizedBox(width: 8), refresh]),
      const SizedBox(height: 8),
      SizedBox(width: double.infinity, child: range),
    ]);
  }

  Color _waitColor(BoardDeposit d) => !d.isPending
      ? AppColors.statusFailed
      : (d.waitingSeconds < 600 ? AppColors.statusCompleted : AppColors.statusPending);

  Widget _status(BoardDeposit d) {
    final color = d.isPending ? AppColors.statusPending : AppColors.statusFailed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.18), borderRadius: BorderRadius.circular(8)),
      child: Text(d.isPending ? 'Sugaya Xaqiijin' : 'Waqtigii Dhammaaday',
          textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
    );
  }

  List<Widget> _actions(BoardDeposit d) => [
        if (d.isPending) ...[
          FilledButton(
            key: Key('confirm-${d.order.id}'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.statusCompleted),
            onPressed: () => _confirm(deposit: d),
            child: const Text('Xaqiiji'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: Key('reject-${d.order.id}'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
            onPressed: () => _reject(d),
            child: const Text('Diid'),
          ),
          const SizedBox(width: 4),
        ],
        IconButton(
          key: Key('view-${d.order.id}'),
          tooltip: 'Macmiilka',
          onPressed: () => _view(d),
          icon: const Icon(Icons.visibility_rounded),
        ),
      ];

  String _number(BoardDeposit d) => d.order.phoneNumber ?? d.order.accountId ?? '—';

  Widget _table(List<BoardDeposit> rows) {
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          dataRowMinHeight: 56,
          dataRowMaxHeight: 64,
          columns: const [
            DataColumn(label: Text('#')),
            DataColumn(label: Text('Deposit ID')),
            DataColumn(label: Text('Macmiilka')),
            DataColumn(label: Text('Lambarka')),
            DataColumn(label: Text('Lacagta'), numeric: true),
            DataColumn(label: Text('Habka')),
            DataColumn(label: Text('Taariikhda')),
            DataColumn(label: Text('Waqtiga\nSugaysa')),
            DataColumn(label: Text('Xaaladda')),
            DataColumn(label: Text('Ficil')),
          ],
          rows: [
            for (var i = 0; i < rows.length; i++)
              DataRow(cells: [
                DataCell(Text('${i + 1}')),
                DataCell(Text(rows[i].order.orderCode)),
                DataCell(Text(rows[i].customerName ?? '—')),
                DataCell(Text(_number(rows[i]))),
                DataCell(Text('\$${rows[i].order.amount}', style: const TextStyle(fontWeight: FontWeight.w700))),
                DataCell(Text(rows[i].order.methodLabel)),
                DataCell(Text(_when.format(rows[i].order.createdAt.toLocal()))),
                DataCell(Text(waitedText(rows[i].waitingSeconds),
                    style: TextStyle(fontWeight: FontWeight.w700, color: _waitColor(rows[i])))),
                DataCell(_status(rows[i])),
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: _actions(rows[i]))),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _card(BoardDeposit d) {
    return Card(
      key: Key('deposit-${d.order.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              MethodBadge(method: d.order.method, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.customerName ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text('${d.order.orderCode} · ${d.order.methodLabel} · ${_number(d)}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                ]),
              ),
              Text('\$${d.order.amount}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.timer_outlined, size: 16, color: _waitColor(d)),
              const SizedBox(width: 4),
              Text(waitedText(d.waitingSeconds), style: TextStyle(fontWeight: FontWeight.w700, color: _waitColor(d))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(DateFormat('d MMM, HH:mm').format(d.order.createdAt.toLocal()),
                    style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
              ),
              _status(d),
            ]),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: _actions(d)),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({super.key, required this.icon, required this.color, required this.title, required this.value, required this.note});

  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(children: [
        CircleAvatar(radius: 20, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 22)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            ),
            Text(note, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }
}
