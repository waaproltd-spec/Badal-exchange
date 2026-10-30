import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart' show ReportDay;
import '../models/payment_methods.dart';
import '../models/report_overview.dart';
import '../state/history_filter.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/state_views.dart';

/// Reports (agent_report_overview): Today / Yesterday / Last Month (the last
/// 30 days) / All Time, or a custom range from the date line. Every section
/// comes from the same completed orders of that period, so they agree:
/// Total Overview (revenue = the completed deposits and withdrawals; fees
/// apart), Top Platforms and Payment Methods (together they make the
/// revenue), Top Users, the Largest Transactions, then orders per day and
/// each report type, which open History for the same dates. Pending,
/// failed and cancelled orders are listed apart, never in the revenue.
class ReportsScreen extends StatefulWidget {
  final ValueChanged<HistoryFilter> onOpenHistory;

  const ReportsScreen({super.key, required this.onOpenHistory});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

/// The reference look: light grey page, white rounded cards, a yellow
/// selected filter, green amounts.
class _R {
  static const page = Color(0xFFF4F4F5);
  static const card = Colors.white;
  static const yellow = Color(0xFFFFD400);
  static const yellowSoft = Color(0xFFFFF7D1);
  static const chip = Color(0xFFEFEFF1);
  static const green = Color(0xFF2E9E4F);
  static const greenSoft = Color(0xFFE6F2E8);
  static const text = Color(0xFF1C1C1E);
  static const muted = Color(0xFF6B6B70);
}

class _ReportsScreenState extends State<ReportsScreen> {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _pretty = DateFormat('MMM d, yyyy');

  String _range = 'today';
  DateTimeRange? _custom;
  ReportOverview? _report;
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
      final report = await context.read<Session>().api.getReportOverview(
            range: _range,
            from: _range == 'custom' ? _iso.format(_custom!.start) : null,
            to: _range == 'custom' ? _iso.format(_custom!.end) : null,
          );
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load the report.';
        _loading = false;
      });
    }
  }

  void _select(String range) {
    if (range == _range) return;
    setState(() => _range = range);
    _load();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _custom ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
    );
    if (picked == null) return;
    setState(() {
      _custom = picked;
      _range = 'custom';
    });
    _load();
  }

  void _open({String type = 'all', String? status}) {
    final r = _report;
    widget.onOpenHistory(HistoryFilter(type: type, status: status, from: r?.from, to: r?.from == null ? null : r?.to));
  }

  String _rangeLabel(ReportOverview r) {
    final to = DateTime.tryParse(r.to);
    if (r.from == null) return to == null ? 'All time' : 'All time, up to ${_pretty.format(to)}';
    final from = DateTime.tryParse(r.from!);
    if (from == null || to == null) return '';
    return r.from == r.to ? _pretty.format(from) : '${_pretty.format(from)} – ${_pretty.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _R.page,
      child: _loading
          ? const LoadingView()
          : (_error != null && _report == null
              ? ErrorStateView(message: _error!, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: _content(_report!))),
    );
  }

  Widget _content(ReportOverview r) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final failed = r.status('failed');
    final cancelled = r.status('cancelled');
    final expired = r.status('expired');
    final open = ReportTotal(r.status('pending').count + r.status('processing').count, '0');
    return ListView(
      key: const Key('reports'),
      padding: EdgeInsets.fromLTRB(16, 4, 16, 32 + bottom),
      children: [
        const Text('Analytics & Insights', style: TextStyle(fontSize: 15, color: _R.muted)),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in const [
              ('today', 'Today'),
              ('yesterday', 'Yesterday'),
              ('last_month', 'Last Month'),
              ('all_time', 'All Time'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _FilterPill(key: Key('range-$id'), label: label, selected: _range == id, onTap: () => _select(id)),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        InkWell(
          key: const Key('range-custom'),
          onTap: _pickRange,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(Icons.calendar_month_rounded, size: 18, color: _range == 'custom' ? _R.text : _R.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_rangeLabel(r),
                    style: TextStyle(color: _R.text, fontWeight: _range == 'custom' ? FontWeight.w700 : FontWeight.w500)),
              ),
              const Text('Custom', style: TextStyle(color: _R.muted, fontSize: 13)),
              const Icon(Icons.expand_more_rounded, color: _R.muted, size: 18),
            ]),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error!, style: const TextStyle(color: AppColors.statusFailed)),
          ),
        const SizedBox(height: 10),
        const _Heading('Total Overview'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _OverviewCard(
              key: const Key('overview-revenue'),
              color: _R.greenSoft,
              icon: Icons.trending_up_rounded,
              iconColor: _R.green,
              value: usd(r.revenue),
              valueColor: _R.green,
              label: 'Revenue',
              caption: 'Completed only · fees ${usd(r.fees)}',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _OverviewCard(
              key: const Key('overview-transactions'),
              color: _R.yellowSoft,
              icon: Icons.shopping_cart_rounded,
              iconColor: const Color(0xFFF2B600),
              value: '${r.transactions}',
              valueColor: _R.text,
              label: 'Transactions',
              caption: '${r.deposits.count} deposits · ${r.withdrawals.count} withdrawals',
            ),
          ),
        ]),
        const SizedBox(height: 8),
        _ListCard(children: [
          _SplitRow(label: 'Deposits', figure: r.deposits, onTap: () => _open(type: 'deposit', status: 'completed')),
          _SplitRow(label: 'Withdrawals', figure: r.withdrawals, onTap: () => _open(type: 'withdraw', status: 'completed')),
        ]),
        const _Heading('Top Platforms'),
        if (r.platforms.isEmpty)
          const _Empty('No completed platform transactions in this period.')
        else
          for (var i = 0; i < r.platforms.length; i++)
            _RankCard(key: Key('platform-${r.platforms[i].key}'), rank: i + 1, row: r.platforms[i], method: r.platforms[i].key),
        const _Heading('Payment Methods'),
        if (r.methods.isEmpty)
          const _Empty('No completed mobile money transactions in this period.')
        else
          for (var i = 0; i < r.methods.length; i++)
            _RankCard(key: Key('method-${r.methods[i].key}'), rank: i + 1, row: r.methods[i], method: r.methods[i].key),
        const _Heading('Top Users'),
        if (r.users.isEmpty)
          const _Empty('No customer transactions in this period.')
        else ...[
          for (var i = 0; i < r.users.length; i++)
            _RankCard(key: Key('user-${r.users[i].key}'), rank: i + 1, row: r.users[i], trophy: i == 0),
          if (r.usersCount > r.users.length)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text('Top ${r.users.length} of ${r.usersCount} customers',
                  style: const TextStyle(color: _R.muted, fontSize: 12.5)),
            ),
        ],
        const _Heading('Largest Transactions'),
        if (r.topTransactions.isEmpty)
          const _Empty('No completed transactions in this period.')
        else
          _ListCard(children: [for (final t in r.topTransactions) _TransactionRow(t: t)]),
        if (r.series != null && r.series!.isNotEmpty) ...[
          const _Heading('Transactions per Day'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: _R.card, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              SizedBox(height: 170, child: _BarChart(series: r.series!)),
              const SizedBox(height: 10),
              const Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 4, children: [
                _Legend(color: AppColors.statusCompleted, label: 'Deposits paid'),
                _Legend(color: AppColors.accentOrange, label: 'Withdrawals paid'),
                _Legend(color: AppColors.purple, label: 'All orders'),
              ]),
            ]),
          ),
        ],
        const _Heading('Not in the revenue'),
        _ListCard(children: [
          _SplitRow(label: 'Waiting (pending / processing)', figure: open, countOnly: true, onTap: () => _open(type: 'order', status: 'pending')),
          _SplitRow(label: 'Failed', figure: failed, onTap: () => _open(type: 'order', status: 'failed')),
          _SplitRow(label: 'Cancelled / rejected', figure: cancelled, onTap: () => _open(type: 'order', status: 'cancelled')),
          _SplitRow(label: 'Expired unpaid', figure: expired, onTap: () => _open(type: 'order', status: 'expired')),
        ]),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Text(text, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _R.text)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _R.card, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: const TextStyle(color: _R.muted)),
      );
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _R.yellow : _R.chip,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Text(label,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : const Color(0xFF55555A))),
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    super.key,
    required this.color,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.valueColor,
    required this.label,
    required this.caption,
  });
  final Color color;
  final IconData icon;
  final Color iconColor;
  final String value;
  final Color valueColor;
  final String label;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(18)),
      child: Column(children: [
        Icon(icon, color: iconColor, size: 26),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: valueColor)),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 15, color: _R.muted)),
        const SizedBox(height: 4),
        Text(caption, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: _R.muted)),
      ]),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: _R.card, borderRadius: BorderRadius.circular(18)),
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ]),
      );
}

class _SplitRow extends StatelessWidget {
  const _SplitRow({required this.label, required this.figure, required this.onTap, this.countOnly = false});
  final String label;
  final ReportTotal figure;
  final VoidCallback onTap;
  final bool countOnly;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: _R.text))),
            Text(countOnly ? '${figure.count}' : '${usd(figure.total)}  ·  ${figure.count}',
                style: const TextStyle(color: _R.muted, fontSize: 13.5)),
            const Icon(Icons.chevron_right_rounded, color: _R.muted, size: 20),
          ]),
        ),
      );
}

/// "#3", the logo or initial, the name with the count, and the amount.
class _RankCard extends StatelessWidget {
  const _RankCard({super.key, required this.rank, required this.row, this.method, this.trophy = false});
  final int rank;
  final RankedRow row;
  final String? method;
  final bool trophy;

  @override
  Widget build(BuildContext context) {
    final initial = row.label.trim().isEmpty ? '?' : row.label.trim()[0].toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(color: _R.card, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: trophy
              ? Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(color: _R.yellowSoft, shape: BoxShape.circle),
                  child: const Icon(Icons.emoji_events_rounded, color: Color(0xFFF2B600), size: 18),
                )
              : Text('#$rank', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _R.muted)),
        ),
        const SizedBox(width: 6),
        if (method != null)
          MethodBadge(method: method!, size: 48)
        else
          CircleAvatar(
            radius: 24,
            backgroundColor: _R.yellow,
            child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(row.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _R.text)),
            const SizedBox(height: 2),
            Text(row.phone != null ? '+${row.phone!.replaceAll('+', '')}' : '${row.count} transactions',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: _R.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(usd(row.total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _R.green)),
            ),
          ),
          if (row.phone != null)
            Text('${row.count} txns', style: const TextStyle(fontSize: 12.5, color: _R.muted)),
        ]),
      ]),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.t});
  final TopTransaction t;
  static final _when = DateFormat('MMM d, HH:mm');

  @override
  Widget build(BuildContext context) => Padding(
        key: Key('tx-${t.orderCode}'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          MethodBadge(method: t.method, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t.label} · ${t.direction == 'deposit' ? 'Deposit' : 'Withdrawal'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: _R.text)),
              Text(
                [t.orderCode, t.customerName ?? t.customerPhone, if (t.completedAt != null) _when.format(t.completedAt!.toLocal())]
                    .whereType<String>()
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: _R.muted),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Text(usd(t.amount), style: const TextStyle(fontWeight: FontWeight.w800, color: _R.green, fontSize: 16)),
        ]),
      );
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }
}

/// Grouped bars per day (deposits / withdrawals / orders), with a y-axis.
class _BarChart extends StatelessWidget {
  final List<ReportDay> series;
  const _BarChart({required this.series});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BarChartPainter(series), size: Size.infinite);
  }
}

class _BarChartPainter extends CustomPainter {
  final List<ReportDay> series;
  _BarChartPainter(this.series);

  static final _dayLabel = DateFormat('MMM d');

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxis = 28.0;
    const bottomAxis = 18.0;
    final chartW = size.width - leftAxis;
    final chartH = size.height - bottomAxis;
    final maxValue = series.fold<int>(0, (m, d) => math.max(m, math.max(d.orders, math.max(d.deposits, d.withdrawals))));
    final top = math.max(4, ((maxValue + 3) ~/ 4) * 4); // round up to a multiple of 4

    final gridPaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final textStyle = const TextStyle(fontSize: 10, color: AppColors.textFaint);

    for (var i = 0; i <= 4; i++) {
      final y = chartH - chartH * i / 4;
      canvas.drawLine(Offset(leftAxis, y), Offset(size.width, y), gridPaint);
      _text(canvas, '${(top * i / 4).round()}', Offset(0, y - 6), textStyle, width: leftAxis - 4, alignRight: true);
    }
    if (series.isEmpty) return;

    final groupW = chartW / series.length;
    final barW = math.max(1.5, math.min(10.0, groupW / 4.5));
    const colors = [AppColors.statusCompleted, AppColors.accentOrange, AppColors.purple];
    final labelEvery = (series.length / 6).ceil();

    for (var i = 0; i < series.length; i++) {
      final d = series[i];
      final values = [d.deposits, d.withdrawals, d.orders];
      final groupLeft = leftAxis + groupW * i + (groupW - barW * 3) / 2;
      for (var k = 0; k < 3; k++) {
        final h = chartH * values[k] / top;
        if (h <= 0) continue;
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(groupLeft + barW * k, chartH - h, barW * 0.85, h),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        );
        canvas.drawRRect(rect, Paint()..color = colors[k]);
      }
      if (i % labelEvery == 0) {
        final date = DateTime.tryParse(d.date);
        if (date != null) {
          _text(canvas, _dayLabel.format(date), Offset(leftAxis + groupW * i, chartH + 4), textStyle,
              width: math.max(groupW * labelEvery, 40));
        }
      }
    }
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style, {required double width, bool alignRight = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      maxLines: 1,
    )..layout(minWidth: alignRight ? width : 0, maxWidth: width);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) => old.series != series;
}
