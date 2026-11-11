import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart' show ReportDay;
import '../models/payment_methods.dart';
import '../models/report_overview.dart';
import '../state/history_filter.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/theme_mode.dart';
import '../widgets/filter_pill.dart';
import '../widgets/page_banner.dart';
import '../widgets/state_views.dart';
import '../l10n/tr.dart';
import '../l10n/date_format.dart';

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
  static bool get _dark => AppThemeMode.isDark;
  static Color get page => _dark ? const Color(0xFF0C0A10) : const Color(0xFFF4F4F5);
  static Color get card => _dark ? const Color(0xFF16131D) : Colors.white;
  static const yellow = Color(0xFFFFD400);
  static Color get yellowSoft => _dark ? const Color(0xFF3A3320) : const Color(0xFFFFF7D1);
  static Color get chip => _dark ? const Color(0xFF26212F) : const Color(0xFFEFEFF1);
  static const green = Color(0xFF2E9E4F);
  static Color get greenSoft => _dark ? const Color(0xFF16301F) : const Color(0xFFE6F2E8);
  static Color get text => _dark ? const Color(0xFFF3EEF8) : const Color(0xFF1C1C1E);
  static Color get muted => _dark ? const Color(0xFFB9AEC6) : const Color(0xFF6B6B70);
}

class _ReportsScreenState extends State<ReportsScreen> {
  static final _iso = AppDateFormat('yyyy-MM-dd');
  static final _pretty = AppDateFormat('MMM d, yyyy');

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
        _error = e is ApiException ? e.message : tr('Failed to load the report.');
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
    if (r.from == null) return to == null ? tr('All time') : trp('All time, up to {0}', [_pretty.format(to)]);
    final from = DateTime.tryParse(r.from!);
    if (from == null || to == null) return '';
    return r.from == r.to ? _pretty.format(from) : '${_pretty.format(from)} – ${_pretty.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _R.page,
      child: Column(children: [
        const PageBanner(icon: Icons.bar_chart_rounded, title: 'Reports', subtitle: 'Analytics & Insights', art: Icons.trending_up_rounded),
        Expanded(
          child: _loading
              ? const LoadingView()
              : (_error != null && _report == null
                  ? ErrorStateView(message: _error!, onRetry: _load)
                  : RefreshIndicator(onRefresh: _load, child: _content(_report!))),
        ),
      ]),
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
      padding: EdgeInsets.fromLTRB(0, 0, 0, 32 + bottom),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in [
              ('today', tr('Today')),
              ('yesterday', tr('Yesterday')),
              ('last_month', tr('Last Month')),
              ('all_time', tr('All Time')),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterPill(key: Key('range-$id'), label: label, selected: _range == id, onTap: () => _select(id)),
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
                child: Tx(_rangeLabel(r),
                    style: TextStyle(color: _R.text, fontWeight: _range == 'custom' ? FontWeight.w700 : FontWeight.w500)),
              ),
              Tx('Custom', style: TextStyle(color: _R.muted, fontSize: 13)),
              Icon(Icons.expand_more_rounded, color: _R.muted, size: 18),
            ]),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Tx(_error!, style: const TextStyle(color: AppColors.statusFailed)),
          ),
        const SizedBox(height: 10),
        _Heading(tr('Total Overview')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _OverviewCard(
              key: const Key('overview-revenue'),
              color: _R.greenSoft,
              icon: Icons.trending_up_rounded,
              iconColor: _R.green,
              value: usd(r.revenue),
              valueColor: _R.green,
              label: tr('Revenue'),
              caption: trp('Completed only · fees {0}', [usd(r.fees)]),
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
              label: tr('Transactions'),
              caption: trp('{0} deposits · {1} withdrawals', [r.deposits.count, r.withdrawals.count]),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        _ListCard(children: [
          _SplitRow(label: tr('Deposits'), figure: r.deposits, onTap: () => _open(type: 'deposit', status: 'completed')),
          _SplitRow(label: tr('Withdrawals'), figure: r.withdrawals, onTap: () => _open(type: 'withdraw', status: 'completed')),
        ]),
        _Heading(tr('Top Platforms')),
        if (r.platforms.isEmpty)
          _Empty(tr('No completed platform transactions in this period.'))
        else
          for (var i = 0; i < r.platforms.length; i++)
            _RankCard(key: Key('platform-${r.platforms[i].key}'), rank: i + 1, row: r.platforms[i], method: r.platforms[i].key),
        _Heading(tr('Payment Methods')),
        if (r.methods.isEmpty)
          _Empty(tr('No completed mobile money transactions in this period.'))
        else
          for (var i = 0; i < r.methods.length; i++)
            _RankCard(key: Key('method-${r.methods[i].key}'), rank: i + 1, row: r.methods[i], method: r.methods[i].key),
        _Heading(tr('Top Users')),
        if (r.users.isEmpty)
          _Empty(tr('No customer transactions in this period.'))
        else ...[
          for (var i = 0; i < r.users.length; i++)
            _RankCard(key: Key('user-${r.users[i].key}'), rank: i + 1, row: r.users[i], trophy: i == 0),
          if (r.usersCount > r.users.length)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(trp('Top {0} of {1} customers', [r.users.length, r.usersCount]),
                  style: TextStyle(color: _R.muted, fontSize: 12.5)),
            ),
        ],
        _Heading(tr('Largest Transactions')),
        if (r.topTransactions.isEmpty)
          _Empty(tr('No completed transactions in this period.'))
        else
          _ListCard(children: [for (final t in r.topTransactions) _TransactionRow(t: t)]),
        if (r.series != null && r.series!.isNotEmpty) ...[
          _Heading(tr('Transactions per Day')),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: _R.card, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              SizedBox(height: 170, child: _BarChart(series: r.series!)),
              const SizedBox(height: 10),
              Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 4, children: [
                _Legend(color: AppColors.statusCompleted, label: tr('Deposits paid')),
                _Legend(color: AppColors.accentOrange, label: tr('Withdrawals paid')),
                _Legend(color: AppColors.purple, label: tr('All orders')),
              ]),
            ]),
          ),
        ],
        _Heading(tr('Not in the revenue')),
        _ListCard(children: [
          _SplitRow(label: tr('Waiting (pending / processing)'), figure: open, countOnly: true, onTap: () => _open(type: 'order', status: 'pending')),
          _SplitRow(label: tr('Failed'), figure: failed, onTap: () => _open(type: 'order', status: 'failed')),
          _SplitRow(label: tr('Cancelled / rejected'), figure: cancelled, onTap: () => _open(type: 'order', status: 'cancelled')),
          _SplitRow(label: tr('Expired unpaid'), figure: expired, onTap: () => _open(type: 'order', status: 'expired')),
        ]),
          ]),
        ),
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
        child: Tx(text, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _R.text)),
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
        child: Tx(text, style: TextStyle(color: _R.muted)),
      );
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
          child: Tx(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: valueColor)),
        ),
        const SizedBox(height: 6),
        Tx(label, style: TextStyle(fontSize: 15, color: _R.muted)),
        const SizedBox(height: 4),
        Tx(caption, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: _R.muted)),
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
            Expanded(child: Tx(label, style: TextStyle(fontWeight: FontWeight.w600, color: _R.text))),
            Tx(countOnly ? '${figure.count}' : '${usd(figure.total)}  ·  ${figure.count}',
                style: TextStyle(color: _R.muted, fontSize: 13.5)),
            Icon(Icons.chevron_right_rounded, color: _R.muted, size: 20),
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
                  decoration: BoxDecoration(color: _R.yellowSoft, shape: BoxShape.circle),
                  child: const Icon(Icons.emoji_events_rounded, color: Color(0xFFF2B600), size: 18),
                )
              : Text('#$rank', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _R.muted)),
        ),
        const SizedBox(width: 6),
        if (method != null)
          MethodBadge(method: method!, size: 48)
        else
          CircleAvatar(
            radius: 24,
            backgroundColor: _R.yellow,
            child: Tx(initial, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Tx(row.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _R.text)),
            const SizedBox(height: 2),
            Tx(row.phone != null ? '+${row.phone!.replaceAll('+', '')}' : '${row.count} transactions',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: _R.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Tx(usd(row.total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _R.green)),
            ),
          ),
          if (row.phone != null)
            Text(trp('{0} txns', [row.count]),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: _R.muted)),
        ]),
          ),
        ),
      ]),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.t});
  final TopTransaction t;
  static final _when = AppDateFormat('MMM d, HH:mm');

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
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: _R.text)),
              Tx(
                [t.orderCode, t.customerName ?? t.customerPhone, if (t.completedAt != null) _when.format(t.completedAt!.toLocal())]
                    .whereType<String>()
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: _R.muted),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Tx(usd(t.amount), style: const TextStyle(fontWeight: FontWeight.w800, color: _R.green, fontSize: 16)),
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
        Flexible(child: Tx(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
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

  static final _dayLabel = AppDateFormat('MMM d');

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
    final textStyle = TextStyle(fontSize: 10, color: AppColors.textFaint);

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
