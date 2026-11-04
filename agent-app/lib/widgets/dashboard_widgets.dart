import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/console.dart';
import '../models/payment_methods.dart';
import '../theme/app_theme.dart';
import 'console_widgets.dart';
import '../l10n/tr.dart';

const _depositColor = AppColors.statusCompleted;
const _withdrawColor = AppColors.accentOrange;
const _orderColor = Color(0xFF8B5CF6);

List<String> get _weekdays => [tr('Mon'), tr('Tue'), tr('Wed'), tr('Thu'), tr('Fri'), tr('Sat'), tr('Sun')];
List<String> get _months => [tr('Jan'), tr('Feb'), tr('Mar'), tr('Apr'), tr('May'), tr('Jun'), tr('Jul'), tr('Aug'), tr('Sep'), tr('Oct'), tr('Nov'), tr('Dec')];

/// "Oct 28" for a chart axis.
String shortDay(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// "Tue, Oct 28, 2026" for the date button.
String longDay(DateTime d) => '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}';

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String? value;

  const _Legend(this.color, this.label, [this.value]);

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Tx(label, style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
      if (value != null) ...[
        const SizedBox(width: 10),
        Tx(value!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
      ],
    ]);
  }
}

/// Total Customers, with how many joined this month.
class CustomersCard extends StatelessWidget {
  final int total;
  final int newThisMonth;
  final VoidCallback? onTap;

  const CustomersCard({super.key, required this.total, required this.newThisMonth, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      key: const Key('dashboard-customers'),
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(children: [
          const TintedIcon(icon: Icons.groups_rounded, color: AppColors.purple, size: 56),
          const SizedBox(width: 12),
          VerticalDivider(width: 1, color: AppColors.border),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Tx('Total Customers', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.textPrimary)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('$total', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.statusCompleted.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.arrow_upward_rounded, size: 16, color: AppColors.statusCompleted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(trp('+{0} new this month', [newThisMonth]),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.statusCompleted)),
                  ),
                ]),
              ),
            ]),
          ),
          if (onTap != null) Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
        ]),
      ),
    );
  }
}

/// Deposits, withdrawals and orders per day, as grouped bars.
class TransactionsOverviewCard extends StatelessWidget {
  final List<DashboardDay> days;

  const TransactionsOverviewCard({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    final top = days.fold<int>(0, (m, d) => math.max(m, math.max(d.deposits, math.max(d.withdrawals, d.orders))));
    final scale = top == 0 ? 1 : top;
    const barHeight = 120.0;
    Widget bar(int n, Color c) => Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: n == 0 ? 2 : math.max(4, barHeight * n / scale),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: n == 0 ? AppColors.border : c,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
              ),
            ),
          ),
        );
    return ConsoleCard(
      key: const Key('dashboard-overview'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tx('Transactions Overview',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        Wrap(spacing: 12, runSpacing: 4, children: [
          _Legend(_depositColor, tr('Deposits')),
          _Legend(_withdrawColor, tr('Withdrawals')),
          _Legend(_orderColor, tr('Orders')),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: barHeight,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final d in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    bar(d.deposits, _depositColor),
                    bar(d.withdrawals, _withdrawColor),
                    bar(d.orders, _orderColor),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        Row(children: [
          for (final d in days)
            Expanded(
              child: Tx(shortDay(d.day),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
            ),
        ]),
      ]),
    );
  }
}

/// Completed, pending, processing and failed as a ring, with the total inside.
class TransactionStatusCard extends StatelessWidget {
  final int completed;
  final int pending;
  final int processing;
  final int failed;

  const TransactionStatusCard(
      {super.key, required this.completed, required this.pending, required this.processing, required this.failed});

  @override
  Widget build(BuildContext context) {
    final parts = [
      (completed, AppColors.statusCompleted, tr('Completed')),
      (pending, AppColors.statusPending, tr('Pending')),
      (processing, AppColors.statusProcessing, tr('Processing')),
      (failed, AppColors.statusFailed, tr('Failed')),
    ];
    final total = completed + pending + processing + failed;
    return ConsoleCard(
      key: const Key('dashboard-status'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tx('Transaction Status',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        const SizedBox(height: 12),
        Row(children: [
          SizedBox(
            width: 120,
            height: 120,
            child: CustomPaint(
              painter: _RingPainter([for (final p in parts) (p.$1.toDouble(), p.$2)]),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$total', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  Tx('Total', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final p in parts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: _Legend(p.$2, p.$3)),
                    Text('${p.$1}', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  ]),
                ),
            ]),
          ),
        ]),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<(double, Color)> parts;

  _RingPainter(this.parts);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    final total = parts.fold<double>(0, (s, p) => s + p.$1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    if (total <= 0) {
      canvas.drawArc(arc, 0, 2 * math.pi, false, paint..color = AppColors.border);
      return;
    }
    var start = -math.pi / 2;
    for (final (value, color) in parts) {
      if (value <= 0) continue;
      final sweep = 2 * math.pi * value / total;
      canvas.drawArc(arc, start, sweep, false, paint..color = color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.parts != parts;
}

/// A top list: each method's badge, name, a bar for its share, how many and how much.
class TopListCard extends StatelessWidget {
  final String title;
  final String countLabel;
  final List<DashboardTop> rows;
  final String emptyText;
  final VoidCallback? onViewAll;

  const TopListCard({
    super.key,
    required this.title,
    required this.countLabel,
    required this.rows,
    required this.emptyText,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final most = rows.fold<double>(0, (m, r) => math.max(m, double.tryParse(r.amount) ?? 0));
    return ConsoleCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Tx(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          ),
          if (onViewAll != null)
            TextButton(onPressed: onViewAll, child: const Tx('View All')),
        ]),
        Tx('Last 7 days, completed', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Tx(emptyText, style: TextStyle(color: AppColors.textSecondary))
        else
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                MethodBadge(method: r.method, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Tx(r.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      ),
                      Text('\$${r.amount}',
                          style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: most <= 0 ? 0 : (double.tryParse(r.amount) ?? 0) / most,
                            minHeight: 5,
                            color: methodInfo(r.method).color,
                            backgroundColor: AppColors.border,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${r.count} $countLabel', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ]),
                  ]),
                ),
              ]),
            ),
      ]),
    );
  }
}
