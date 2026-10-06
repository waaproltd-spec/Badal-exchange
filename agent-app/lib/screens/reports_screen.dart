import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/history_filter.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';

/// Reports: totals and counts for a period (daily / weekly / monthly /
/// custom range), a per-day chart, and report types that open History with
/// the same range applied.
class ReportsScreen extends StatefulWidget {
  final ValueChanged<HistoryFilter> onOpenHistory;

  const ReportsScreen({super.key, required this.onOpenHistory});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _pretty = DateFormat('MMM d, yyyy');

  String _period = 'daily';
  DateTimeRange? _customRange;
  ReportSummary? _report;
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
      final report = await context.read<Session>().api.getReport(
            period: _period,
            from: _period == 'custom' ? _iso.format(_customRange!.start) : null,
            to: _period == 'custom' ? _iso.format(_customRange!.end) : null,
          );
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load report.';
        _loading = false;
      });
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _customRange ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
    );
    if (picked == null) return;
    setState(() {
      _customRange = picked;
      _period = 'custom';
    });
    _load();
  }

  void _selectPeriod(String period) {
    if (period == 'custom') {
      _pickRange();
      return;
    }
    setState(() => _period = period);
    _load();
  }

  void _open({String type = 'all', String? status}) {
    final r = _report;
    widget.onOpenHistory(HistoryFilter(type: type, status: status, from: r?.from, to: r?.to));
  }

  String _rangeLabel(ReportSummary r) {
    final from = DateTime.tryParse(r.from);
    final to = DateTime.tryParse(r.to);
    if (from == null || to == null) return '';
    return r.from == r.to ? _pretty.format(from) : '${_pretty.format(from)} – ${_pretty.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _report == null) return ErrorStateView(message: _error!, onRetry: _load);
    final r = _report!;
    final txCount = r.deposits.count + r.withdrawals.count;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          ConsoleCard(
            onTap: _pickRange,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.calendar_month_rounded, color: AppColors.purple),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_rangeLabel(r), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                const Icon(Icons.expand_more_rounded, color: AppColors.textSecondary),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ChoiceChipsRow<String>(
            options: const [('daily', 'Daily'), ('weekly', 'Weekly'), ('monthly', 'Monthly'), ('custom', 'Custom')],
            selected: _period,
            onSelected: _selectPeriod,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.statusFailed)),
            ),
          const SizedBox(height: 12),
          TwoColumnGrid(children: [
            StatCard(
              icon: Icons.south_rounded,
              color: AppColors.statusCompleted,
              value: '\$${r.deposits.total}',
              label: 'Total Deposits',
              caption: '${r.deposits.count} transactions',
              onTap: () => _open(type: 'deposit'),
            ),
            StatCard(
              icon: Icons.north_rounded,
              color: AppColors.accentOrange,
              value: '\$${r.withdrawals.total}',
              label: 'Total Withdrawals',
              caption: '${r.withdrawals.count} transactions',
              onTap: () => _open(type: 'withdraw'),
            ),
            StatCard(
              icon: Icons.shopping_bag_rounded,
              color: AppColors.purple,
              value: '\$${r.orders.total}',
              label: 'Total Orders',
              caption: '${r.orders.count} orders',
              onTap: () => _open(type: 'order'),
            ),
            StatCard(
              icon: Icons.receipt_long_rounded,
              color: AppColors.statusProcessing,
              value: '$txCount',
              label: 'Transaction Count',
              caption: '${r.completed.count} completed • ${r.failed.count} failed',
              onTap: () => _open(),
            ),
          ]),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transactions Overview',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                SizedBox(height: 170, child: _BarChart(series: r.series)),
                const SizedBox(height: 10),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Legend(color: AppColors.statusCompleted, label: 'Deposits'),
                    SizedBox(width: 14),
                    _Legend(color: AppColors.accentOrange, label: 'Withdrawals'),
                    SizedBox(width: 14),
                    _Legend(color: AppColors.purple, label: 'Orders'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const SectionHeader(title: 'Report Types'),
          _ReportType(
            icon: Icons.south_rounded,
            color: AppColors.statusCompleted,
            label: 'Deposit Reports',
            figure: r.deposits,
            onTap: () => _open(type: 'deposit'),
          ),
          _ReportType(
            icon: Icons.north_rounded,
            color: AppColors.accentOrange,
            label: 'Withdrawal Reports',
            figure: r.withdrawals,
            onTap: () => _open(type: 'withdraw'),
          ),
          _ReportType(
            icon: Icons.shopping_bag_rounded,
            color: AppColors.purple,
            label: 'Order Reports',
            figure: r.orders,
            onTap: () => _open(type: 'order'),
          ),
          _ReportType(
            icon: Icons.check_rounded,
            color: AppColors.statusCompleted,
            label: 'Completed Transactions',
            figure: r.completed,
            onTap: () => _open(type: 'order', status: 'completed'),
          ),
          _ReportType(
            icon: Icons.close_rounded,
            color: AppColors.statusFailed,
            label: 'Failed Transactions',
            figure: r.failed,
            onTap: () => _open(type: 'order', status: 'failed'),
          ),
        ],
      ),
    );
  }
}

class _ReportType extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final ReportFigure figure;
  final VoidCallback onTap;

  const _ReportType({
    required this.icon,
    required this.color,
    required this.label,
    required this.figure,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            TintedIcon(icon: icon, color: color, size: 34),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(
              '\$${figure.total}  ·  ${figure.count}',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
          ],
        ),
      ),
    );
  }
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
