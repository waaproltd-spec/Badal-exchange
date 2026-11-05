import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/commission.dart';
import '../models/payment_methods.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/filter_pill.dart';
import '../widgets/page_banner.dart';
import '../widgets/state_views.dart';
import '../l10n/tr.dart';
import '../l10n/date_format.dart';

/// Commission (agent_commission), its own tab: what Badal Exchange earns on completed betting-company
/// orders -- 2% of deposits, 5% of withdrawals less a 1% bonus. The bonus comes off the commission,
/// never off the customer's amount.
///
/// Filters: the period (today ... all time, or a custom range), the company and, for managers, the
/// agent; they all go to the server together, so every figure, the chart and the rankings below use the
/// same ones. An agent always sees only the orders they handled. Everything comes from the server's
/// commission entries (rates and eligibility as they always were); nothing is calculated here.
class CommissionScreen extends StatefulWidget {
  const CommissionScreen({super.key});

  @override
  State<CommissionScreen> createState() => _CommissionScreenState();
}

class _CommissionScreenState extends State<CommissionScreen> with LiveRefresh {
  static final _iso = AppDateFormat('yyyy-MM-dd');
  static final _pretty = AppDateFormat('MMM d, yyyy');
  static final _when = AppDateFormat('MMM d, yyyy · HH:mm');

  static List<(String, String)> get _ranges => [
        ('today', tr('Today')),
        ('yesterday', tr('Yesterday')),
        ('this_month', tr('This Month')),
        ('last_month', tr('Last Month')),
        ('last_3_months', tr('Last 3 Months')),
        ('all_time', tr('All Time')),
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
    // A new eligible order, or a changed one: the figures are read again.
    listenForLiveChanges(context.read<Session>().live.changes, _load);
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
        _error =
            e is ApiException ? e.message : tr('Failed to load commission.');
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
        initialDateRange: _custom ??
            DateTimeRange(
                start: now.subtract(const Duration(days: 6)), end: now),
      );
      if (picked == null) return;
      _custom = picked;
    }
    setState(() => _range = range);
    _load();
  }

  /// "Nov 1 – Nov 30, 2026" (the server's dates, so a new month needs nothing here).
  String _rangeLabel(CommissionReport r) {
    final to = DateTime.tryParse(r.to);
    if (r.from == null)
      return to == null
          ? tr('All time')
          : trp('All time, up to {0}', [_pretty.format(to)]);
    final from = DateTime.tryParse(r.from!);
    if (from == null || to == null) return '';
    return r.from == r.to
        ? _pretty.format(from)
        : '${_pretty.format(from)} – ${_pretty.format(to)}';
  }

  String _rangeName() => _range == 'custom'
      ? tr('Custom Range')
      : _ranges.firstWhere((x) => x.$1 == _range).$2;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final r = _report;
    return Column(children: [
      PageBanner(
        icon: Icons.account_balance_wallet_rounded,
        title: 'Commission',
        subtitle: 'Agent Commission & Earnings',
        art: Icons.bar_chart_rounded,
      ),
      Expanded(
        child: _loading
            ? const LoadingView()
            : (_error != null && r == null)
                ? ErrorStateView(message: _error!, onRetry: _load)
                : RefreshIndicator(
                    onRefresh: _load, child: _content(r!, bottom)),
      ),
    ]);
  }

  Widget _content(CommissionReport r, double bottom) {
    final t = r.totals;
    return ListView(
      key: const Key('commission'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottom),
      children: [
        SingleChildScrollView(
          key: const Key('range-filter'),
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in _ranges)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterPill(
                    key: Key('range-$id'),
                    label: label,
                    selected: _range == id,
                    onTap: () => _selectRange(id)),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        ConsoleCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: LayoutBuilder(builder: (context, c) {
            final label = Row(children: [
              Icon(Icons.calendar_month_rounded,
                  size: 22, color: AppColors.primaryDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  key: const Key('range-label'),
                  TextSpan(children: [
                    TextSpan(
                        text: _rangeLabel(r),
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    TextSpan(
                        text: '  (${_rangeName()})',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ]),
                ),
              ),
            ]);
            final custom = OutlinedButton(
              key: const Key('range-custom'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 42), // as wide as its text, not the theme's full width
                shape: const StadiumBorder(),
                backgroundColor: _range == 'custom'
                    ? AppColors.selected
                    : AppColors.primaryTint,
                foregroundColor: _range == 'custom'
                    ? AppColors.onPrimary
                    : AppColors.primaryDark,
                side: BorderSide(color: AppColors.primary.withOpacity(0.5)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => _selectRange('custom'),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.calendar_month_rounded, size: 18),
                const SizedBox(width: 6),
                Flexible(
                    child: Tx('Custom Range',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ]),
            );
            // A wide card: the label and the button side by side; a narrow one: the button under the label.
            if (c.maxWidth >= 420) {
              return Row(children: [
                Expanded(child: label),
                const SizedBox(width: 8),
                custom
              ]);
            }
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: custom)
                ]);
          }),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          key: const Key('company-filter'),
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterPill(
                key: const Key('company-all'),
                label: tr('All Companies'),
                icon: Icons.layers_rounded,
                selected: _method == null,
                onTap: () {
                  setState(() => _method = null);
                  _load();
                },
              ),
            ),
            for (final c in r.companies)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterPill(
                  key: Key('company-${c.method}'),
                  label: c.label,
                  leading: MethodBadge(method: c.method, size: 28),
                  selected: _method == c.method,
                  onTap: () {
                    setState(() => _method = c.method);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        if (r.canSeeAll && r.agents != null)
          DropdownButtonFormField<String?>(
            key: const Key('agent-filter'),
            value: _agent,
            isExpanded: true,
            icon: const Icon(Icons.expand_more_rounded),
            decoration: InputDecoration(
              labelText: tr('Agent'),
              prefixIcon: const Icon(Icons.groups_rounded),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
            ),
            items: [
              DropdownMenuItem<String?>(
                  value: null,
                  child: Tx('All Agents (Consolidated)',
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              DropdownMenuItem<String?>(
                  value: 'automatic', child: Tx('Automatic (no agent)')),
              for (final a in r.agents!)
                DropdownMenuItem<String?>(
                    value: a.id,
                    child: Tx(a.name.isEmpty ? (a.phone ?? a.id) : a.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              setState(() => _agent = v);
              _load();
            },
          )
        else
          Tx('Your commission: the orders you handled.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Tx(_error!,
                style: const TextStyle(color: AppColors.statusFailed)),
          ),
        const SizedBox(height: 14),
        TwoColumnGrid(children: [
          _MoneyCard(
            key: const Key('total-deposit'),
            icon: Icons.south_rounded,
            color: AppColors.statusCompleted,
            label: tr('Total Deposit'),
            value: commissionMoney(t.depositTotal),
            valueColor: AppColors.statusCompleted,
            note: _count(t.depositCount, 'deposit', 'deposits'),
            pill:
                '${percent(r.depositBp)} = ${commissionMoney(t.depositCommission)}',
          ),
          _MoneyCard(
            key: const Key('total-withdrawal'),
            icon: Icons.north_rounded,
            color: AppColors.accentOrange,
            label: tr('Total Withdrawal'),
            value: commissionMoney(t.withdrawalTotal),
            valueColor: AppColors.statusFailed,
            note: _count(t.withdrawalCount, 'withdrawal', 'withdrawals'),
            pill:
                '${percent(r.withdrawBp)} = ${commissionMoney(t.withdrawalGross)}',
          ),
          _MoneyCard(
            key: const Key('total-commission'),
            icon: Icons.payments_rounded,
            color: AppColors.purple,
            label: tr('Total Commission'),
            value: commissionMoney(t.commission),
            valueColor: AppColors.primaryDark,
            note: tr('Net, after the bonus'),
          ),
          _MoneyCard(
            key: const Key('total-bonus'),
            icon: Icons.card_giftcard_rounded,
            color: AppColors.statusProcessing,
            label: tr('Total Bonus'),
            value: commissionMoney(t.bonus),
            valueColor: AppColors.primaryDark,
            note: trp('{0} of withdrawals', [percent(r.bonusBp)]),
            footnote: tr('Taken off the commission, not off the customer'),
          ),
        ]),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, c) {
          final breakdown = _BreakdownCard(report: r);
          final trend = _TrendCard(report: r, periodName: _rangeName());
          if (c.maxWidth >= 700) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: breakdown),
              const SizedBox(width: 12),
              Expanded(child: trend),
            ]);
          }
          return Column(
              children: [breakdown, const SizedBox(height: 12), trend]);
        }),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, c) {
          final companies = _RankingCard(
            key: const Key('top-companies'),
            title: tr('Top Companies'),
            icon: Icons.layers_rounded,
            rows: r.topCompanies,
            agents: false,
            showPhone: false,
          );
          final agents = _RankingCard(
            key: const Key('top-agents'),
            title: tr('Top Agents'),
            icon: Icons.groups_rounded,
            rows: r.topAgents,
            agents: true,
            showPhone: true,
          );
          if (c.maxWidth >= 700) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: companies),
              const SizedBox(width: 12),
              Expanded(child: agents),
            ]);
          }
          return Column(
              children: [companies, const SizedBox(height: 12), agents]);
        }),
        SectionHeader(title: tr('Transactions')),
        if (r.transactions.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 24),
            child: EmptyStateView(
              icon: Icons.receipt_long_rounded,
              title: tr('No betting transactions'),
              message: tr('Nothing for these dates and this company.'),
            ),
          )
        else
          for (final x in r.transactions)
            _TransactionCard(
                row: x,
                when: x.at == null ? '' : _when.format(x.at!.toLocal())),
      ],
    );
  }

  String _count(int n, String one, String many) =>
      n == 1 ? trp('{0} $one', [n]) : trp('{0} $many', [n]);
}

/// One of the four figures: icon, title, the amount, a note and (deposit / withdrawal) the commission pill.
class _MoneyCard extends StatelessWidget {
  const _MoneyCard({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.valueColor,
    required this.note,
    this.pill,
    this.footnote,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final Color valueColor;
  final String note;
  final String? pill;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      color: Color.alphaBlend(color.withOpacity(0.08), AppColors.surface),
      borderColor: color.withOpacity(0.3),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TintedIcon(icon: icon, color: color, size: 40),
          const SizedBox(width: 10),
          Expanded(
              child: Tx(label,
                  maxLines: 2,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary))),
        ]),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: valueColor)),
        ),
        const SizedBox(height: 6),
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(note,
                  style:
                      TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              if (pill != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                      color: color.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(10)),
                  child: Text(pill!,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: valueColor)),
                ),
            ]),
        if (footnote != null) ...[
          const SizedBox(height: 4),
          Text(footnote!,
              style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
        ],
      ]),
    );
  }
}

/// The calculation, line by line: deposit commission + withdrawal commission - bonus = net.
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.report});

  final CommissionReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final t = r.totals;
    return ConsoleCard(
      key: const Key('commission-breakdown'),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.calculate_rounded, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          Expanded(
              child: Tx('Commission Breakdown',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary))),
        ]),
        const SizedBox(height: 8),
        _Line(trp('Deposit commission ({0})', [percent(r.depositBp)]),
            commissionMoney(t.depositCommission)),
        _Line(trp('Withdrawal commission ({0})', [percent(r.withdrawBp)]),
            commissionMoney(t.withdrawalGross)),
        _Line(trp('Bonus ({0} of withdrawals)', [percent(r.bonusBp)]),
            '- ${commissionMoney(t.bonus)}'),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
              color: AppColors.primaryTint,
              borderRadius: BorderRadius.circular(12)),
          child: _Line(tr('Net Commission'), commissionMoney(t.commission),
              strong: true),
        ),
        const SizedBox(height: 6),
        Tx('Net = deposit commission + withdrawal commission - bonus. Only completed orders count.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
      ]),
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
            child: Tx(label,
                style: TextStyle(
                    color: strong
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          Tx(value,
              style: TextStyle(
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  fontSize: strong ? 18 : null,
                  color: strong
                      ? AppColors.statusCompleted
                      : AppColors.textPrimary)),
        ]),
      );
}

/// Transactions over the period: deposits and withdrawals as two lines (counts).
class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.report, required this.periodName});

  final CommissionReport report;
  final String periodName;

  @override
  Widget build(BuildContext context) {
    final points = report.trend;
    final any = points.any((p) => p.transactions > 0);
    return ConsoleCard(
      key: const Key('commission-trend'),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.bar_chart_rounded, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: tr('Transaction Trend'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              TextSpan(
                  text: '  ($periodName)',
                  style:
                      TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ])),
          ),
        ]),
        const SizedBox(height: 10),
        if (!any)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Center(
                child: Tx('No transactions in this period',
                    style: TextStyle(color: AppColors.textSecondary))),
          )
        else ...[
          SizedBox(
            height: 170,
            child: CustomPaint(
              key: const Key('trend-chart'),
              painter: _TrendPainter(
                points: points,
                granularity: report.granularity,
                depositColor: AppColors.statusCompleted,
                withdrawalColor: AppColors.accentOrange,
                gridColor: AppColors.border,
                textColor: AppColors.textSecondary,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 4,
              children: [
                _Dot(AppColors.statusCompleted, tr('Deposits')),
                _Dot(AppColors.accentOrange, tr('Withdrawals')),
                Tx(
                    report.granularity == 'day'
                        ? tr('per day')
                        : (report.granularity == 'week'
                            ? tr('per week')
                            : tr('per month')),
                    style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
              ]),
        ],
      ]),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, this.label);
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Tx(label,
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
      ]);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.granularity,
    required this.depositColor,
    required this.withdrawalColor,
    required this.gridColor,
    required this.textColor,
  });

  final List<TrendPoint> points;
  final String granularity;
  final Color depositColor, withdrawalColor, gridColor, textColor;

  static final _day = AppDateFormat('MMM d');
  static final _month = AppDateFormat('MMM yyyy');

  /// A round top for the axis: 4 -> 4, 7 -> 8, 33 -> 40.
  static int niceMax(int v) {
    if (v <= 4) return 4;
    final step =
        v <= 10 ? 2 : (v <= 20 ? 5 : (v <= 50 ? 10 : (v <= 100 ? 20 : 50)));
    return ((v + step - 1) ~/ step) * step;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const left = 30.0, bottom = 22.0, top = 6.0, right = 8.0;
    final w = size.width - left - right;
    final h = size.height - bottom - top;
    final peak = niceMax(points.fold<int>(
        0, (m, p) => math.max(m, math.max(p.deposits, p.withdrawals))));
    TextPainter label(String s) => TextPainter(
          text: TextSpan(
              text: s, style: TextStyle(fontSize: 10.5, color: textColor)),
          textDirection: TextDirection.ltr,
        )..layout();
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + h - h * i / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      final tp = label('${(peak * i / 4).round()}');
      tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
    }
    double x(int i) =>
        points.length == 1 ? left + w / 2 : left + w * i / (points.length - 1);
    double y(int v) => top + h - h * v / peak;

    void line(int Function(TrendPoint) value, Color color) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final o = Offset(x(i), y(value(points[i])));
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      final fill = Path.from(path)
        ..lineTo(x(points.length - 1), top + h)
        ..lineTo(x(0), top + h)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withOpacity(0.10));
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round);
      if (points.length <= 40) {
        for (var i = 0; i < points.length; i++) {
          canvas.drawCircle(
              Offset(x(i), y(value(points[i]))), 3, Paint()..color = color);
        }
      }
    }

    line((p) => p.withdrawals, withdrawalColor);
    line((p) => p.deposits, depositColor);

    final labels = math.min(5, points.length);
    for (var k = 0; k < labels; k++) {
      final i =
          labels == 1 ? 0 : (k * (points.length - 1) / (labels - 1)).round();
      final d = points[i].start;
      final tp =
          label(granularity == 'month' ? _month.format(d) : _day.format(d));
      final dx = (x(i) - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx, top + h + 5));
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points || old.granularity != granularity;
}

/// The first three of a ranking by net commission; View All shows the whole list.
class _RankingCard extends StatelessWidget {
  const _RankingCard(
      {super.key,
      required this.title,
      required this.icon,
      required this.rows,
      required this.agents,
      required this.showPhone});

  final String title;
  final IconData icon;
  final List<RankedRow> rows;
  final bool agents;
  final bool showPhone;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary))),
          if (rows.length > 3)
            TextButton(
              key: Key('${agents ? 'agents' : 'companies'}-view-all'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RankingScreen(
                    title: title,
                    rows: rows,
                    agents: agents,
                    showPhone: showPhone),
              )),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Tx('View All'),
                const Icon(Icons.chevron_right_rounded, size: 18)
              ]),
            ),
        ]),
        Tx('Ranked by net commission',
            style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
        const SizedBox(height: 4),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
                child: Tx('Nothing for these filters yet.',
                    style: TextStyle(color: AppColors.textSecondary))),
          )
        else
          for (final (i, row) in rows.take(3).indexed)
            RankRow(rank: i + 1, row: row, agent: agents, showPhone: showPhone),
      ]),
    );
  }
}

/// One line of a ranking: position, logo or initial, name, transactions, net commission.
class RankRow extends StatelessWidget {
  const RankRow(
      {super.key,
      required this.rank,
      required this.row,
      required this.agent,
      required this.showPhone});

  final int rank;
  final RankedRow row;
  final bool agent;
  final bool showPhone;

  @override
  Widget build(BuildContext context) {
    final name = row.automatic
        ? tr('Automatic (no agent)')
        : (row.name.isEmpty ? (row.phone ?? '—') : row.name);
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Padding(
      key: Key('rank-${agent ? 'agent' : 'company'}-${row.key}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        SizedBox(
          width: 30,
          child: rank == 1 && agent
              ? const Icon(Icons.emoji_events_rounded,
                  color: AppColors.accentOrange, size: 22)
              : Text('#$rank',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
        ),
        if (agent)
          CircleAvatar(
            radius: 20,
            backgroundColor:
                row.automatic ? AppColors.primaryTint : const Color(0xFFF5C518),
            child: row.automatic
                ? Icon(Icons.bolt_rounded, color: AppColors.primaryDark)
                : Text(initial,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, color: Colors.white)),
          )
        else
          MethodBadge(method: row.method ?? '', size: 40),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (agent && showPhone && (row.phone ?? '').isNotEmpty)
              Text(row.phone!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            Text(trp('{0} txns', [row.transactions]),
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(commissionMoney(row.commission),
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.statusCompleted)),
          ),
        ),
      ]),
    );
  }
}

/// View All: the whole ranking.
class RankingScreen extends StatelessWidget {
  const RankingScreen(
      {super.key,
      required this.title,
      required this.rows,
      required this.agents,
      required this.showPhone});

  final String title;
  final List<RankedRow> rows;
  final bool agents;
  final bool showPhone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        key: const Key('ranking-list'),
        padding: const EdgeInsets.all(16),
        children: [
          Tx('Ranked by net commission',
              style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          ConsoleCard(
            child: Column(children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, color: AppColors.border),
                RankRow(
                    rank: i + 1, row: row, agent: agents, showPhone: showPhone),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}

class _TransactionCard extends StatelessWidget {
  const _TransactionCard({required this.row, required this.when});
  final CommissionRow row;
  final String when;

  @override
  Widget build(BuildContext context) {
    final type = row.direction == 'deposit' ? tr('Deposit') : tr('Withdrawal');
    return Padding(
      key: Key('tx-${row.orderCode}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        padding: const EdgeInsets.all(14),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            MethodBadge(method: row.method, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${row.label} · $type',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('$when · ${row.orderCode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ]),
            ),
            const SizedBox(width: 8),
            StatusPill(row.status),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _Figure(tr('Amount'),
                row.amount == null ? '—' : commissionMoney(row.amount!)),
            _Figure(
                tr('Commission'),
                row.commission == null
                    ? '—'
                    : commissionMoney(row.commission!)),
            _Figure(tr('Bonus'),
                row.bonus == null ? '—' : '- ${commissionMoney(row.bonus!)}'),
            _Figure(
                tr('Net'),
                row.netCommission == null
                    ? tr('Not earned')
                    : commissionMoney(row.netCommission!),
                color: row.earns
                    ? AppColors.statusCompleted
                    : AppColors.textFaint),
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
  Widget build(BuildContext context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Tx(label,
                style: TextStyle(fontSize: 11, color: AppColors.textFaint)),
            Tx(value,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color ?? AppColors.textPrimary)),
          ]);
}
