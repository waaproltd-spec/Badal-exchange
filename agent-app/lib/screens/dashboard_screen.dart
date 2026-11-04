import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/company_balance.dart';
import '../models/console.dart';
import '../models/management.dart' show PaymentSource;
import '../state/history_filter.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/page_banner.dart';
import '../models/report_overview.dart' show usd;
import '../widgets/state_views.dart';
import 'company/company_balances_screen.dart';
import 'pending_deposits_screen.dart';
import 'pending_withdrawals_screen.dart';
import 'sms_transactions_screen.dart';
import '../l10n/tr.dart';

/// Dashboard: the agent's overview. Pending counts open the screens where
/// those orders are actioned; the other counts open History filtered. Also
/// the money behind each count, customers, a 7-day chart, the status ring,
/// top services and deposit methods for a chosen day (its 7 days), the
/// automatic EVC Plus SMS matching control and recent activity.
class DashboardScreen extends StatefulWidget {
  final ValueChanged<HistoryFilter> onOpenHistory;
  final VoidCallback? onOpenUsers;

  const DashboardScreen({super.key, required this.onOpenHistory, this.onOpenUsers});

  /// Pending deposits + withdrawals, for the bell in the app bar.
  static final ValueNotifier<int> pending = ValueNotifier(0);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with LiveRefresh {
  DashboardSummary? _summary;
  String? _error;
  bool _loading = true;
  bool _smsBusy = false;
  CompanyBalancesOverview? _companies;
  PaymentSource? _source;
  DashboardStats? _stats;

  /// The day the chart and top lists end on; null is today.
  DateTime? _day;

  @override
  void initState() {
    super.initState();
    _load();
    listenForLiveChanges(context.read<Session>().live.changes, _load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = _summary == null;
      _error = null;
    });
    try {
      final session = context.read<Session>();
      final summary = await session.api.getDashboard();
      if (session.canViewCompanyBalances) {
        _loadCompanies(session);
        _loadSource(session);
      }
      _loadStats(session);
      if (!mounted) return;
      DashboardScreen.pending.value = summary.pendingDeposits + summary.pendingWithdrawals;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : tr('Failed to load dashboard data.');
        _loading = false;
      });
    }
  }

  /// Company Balances summary; its failure never hides the dashboard.
  Future<void> _loadCompanies(Session session) async {
    try {
      final c = await session.api.getCompanyBalances();
      if (mounted) setState(() => _companies = c);
    } catch (_) {}
  }

  /// Which payment source is active; its failure (or an older server) never hides the dashboard.
  Future<void> _loadSource(Session session) async {
    try {
      final c = await session.api.getPaymentSource();
      if (mounted) setState(() => _source = c);
    } catch (_) {}
  }

  /// The extra figures; their failure (or an older server) never hides the dashboard.
  Future<void> _loadStats(Session session) async {
    try {
      final s = await session.api.getDashboardStats(day: _day);
      if (mounted) setState(() => _stats = s);
    } catch (_) {}
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day ?? now,
      firstDate: DateTime(2026, 1, 1),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() => _day = picked);
    _loadStats(context.read<Session>());
  }

  Future<void> _openCompanies() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompanyBalancesScreen()));
    if (mounted) _load();
  }

  Future<void> _push(String title, Widget body) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: Tx(title)), body: body),
    ));
    if (mounted) _load();
  }

  Future<void> _toggleSmsMatching(Session session, bool enable) async {
    setState(() => _smsBusy = true);
    if (enable) {
      final started = await session.enableSmsAutoMatching();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Tx('SMS permission is required to enable automatic matching.')),
        );
      }
    } else {
      await session.disableSmsAutoMatching();
    }
    if (mounted) setState(() => _smsBusy = false);
  }

  /// "\$30.00" under a status count, once the figures are in.
  String? _money(String key) => _stats == null ? null : '\$${_stats!.amount(key)}';

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _summary == null) return ErrorStateView(message: _error!, onRetry: _load);

    final session = context.watch<Session>();
    final s = _summary!;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('dashboard-list'),
        padding: EdgeInsets.zero,
        children: [
          PageBanner(
            topInset: false,
            leading: Container(
              width: 62,
              height: 62,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: AppColors.onHeader, borderRadius: BorderRadius.circular(18)),
              child: Image.asset('assets/brand/logo.png', key: const Key('banner-logo')),
            ),
            title: trp('Welcome, {0}', [session.agentDisplayName]),
            subtitle: 'Manage your transactions and company balances',
            titleSize: 22,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('dashboard-day'),
                onPressed: _pickDay,
                icon: const Icon(Icons.calendar_today_rounded, size: 18),
                label: Tx(longDay(_stats?.day ?? _day ?? DateTime.now())),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(tooltip: tr('Refresh'), onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
          ]),
          const SizedBox(height: 12),
          if (session.canViewCompanyBalances) ...[
            _CompanyBalancesCard(data: _companies, onTap: _openCompanies),
            const SizedBox(height: 12),
            if (_source != null) ...[
              PaymentSourceCard(data: _source!),
              const SizedBox(height: 12),
            ],
          ],
          if (_stats != null) ...[
            CustomersCard(
              total: _stats!.totalCustomers,
              newThisMonth: _stats!.newCustomersThisMonth,
              onTap: widget.onOpenUsers,
            ),
            const SizedBox(height: 12),
          ],
          TwoColumnGrid(children: [
            StatCard(
              icon: Icons.south_rounded,
              color: AppColors.statusPending,
              value: '${s.pendingDeposits}',
              label: tr('Pending Deposits'),
              caption: _money('pendingDeposits'),
              onTap: () => _push(tr('Pending Deposits'), const PendingDepositsScreen()),
            ),
            StatCard(
              icon: Icons.north_rounded,
              color: AppColors.statusProcessing,
              value: '${s.pendingWithdrawals}',
              label: tr('Pending Withdrawals'),
              caption: _money('pendingWithdrawals'),
              onTap: () => _push(tr('Pending Withdrawals'), const PendingWithdrawalsScreen()),
            ),
            StatCard(
              icon: Icons.autorenew_rounded,
              color: AppColors.purple,
              value: '${s.processing}',
              label: tr('Processing'),
              caption: _money('processing'),
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'processing')),
            ),
            StatCard(
              icon: Icons.check_rounded,
              color: AppColors.statusCompleted,
              value: '${s.completed}',
              label: tr('Completed'),
              caption: _money('completed'),
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'completed')),
            ),
            StatCard(
              icon: Icons.close_rounded,
              color: AppColors.statusFailed,
              value: '${s.failed}',
              label: tr('Failed'),
              caption: _money('failed'),
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'failed')),
            ),
            StatCard(
              icon: Icons.receipt_long_rounded,
              color: AppColors.textSecondary,
              value: '${s.totalTransactions}',
              label: tr('Total Transactions'),
              onTap: () => widget.onOpenHistory(const HistoryFilter(type: 'order')),
            ),
          ]),
          const SizedBox(height: 16),
          if (_stats != null) ...[
            TransactionsOverviewCard(days: _stats!.days),
            const SizedBox(height: 12),
            TransactionStatusCard(
              completed: s.completed,
              pending: s.pendingDeposits + s.pendingWithdrawals,
              processing: s.processing,
              failed: s.failed,
            ),
            const SizedBox(height: 12),
            TopListCard(
              key: const Key('dashboard-top-services'),
              title: tr('Top Services / Orders'),
              countLabel: tr('orders'),
              rows: _stats!.topServices,
              emptyText: tr('No completed orders in these 7 days.'),
              onViewAll: () => widget.onOpenHistory(const HistoryFilter(type: 'order')),
            ),
            const SizedBox(height: 12),
            TopListCard(
              key: const Key('dashboard-top-deposits'),
              title: tr('Top Deposit Methods'),
              countLabel: tr('txns'),
              rows: _stats!.topDepositMethods,
              emptyText: tr('No completed deposits in these 7 days.'),
              onViewAll: () => widget.onOpenHistory(const HistoryFilter(type: 'deposit')),
            ),
            const SizedBox(height: 16),
          ],
          if (Platform.isAndroid)
            _SmsMatchingCard(
              isListening: session.smsBridge.isListening,
              deviceRegistrationError: session.deviceRegistrationError,
              busy: _smsBusy,
              onToggle: (enable) => _toggleSmsMatching(session, enable),
              onRetryDeviceRegistration: () async {
                setState(() => _smsBusy = true);
                await session.retryDeviceRegistration();
                if (mounted) setState(() => _smsBusy = false);
              },
              onOpenLog: () => _push(tr('SMS Transactions'), const SmsTransactionsScreen()),
            )
          else
            ConsoleCard(
              child: Tx(
                'Automatic EVC Plus SMS matching is only available on Android agent devices.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: AppColors.header, borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.history_rounded, color: AppColors.onHeader, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Tx('Recent Activity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  Tx('Latest transactions', style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary)),
                ]),
              ),
              OutlinedButton(
                key: const Key('activity-see-all'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 42), // as wide as its text, not the theme's full width
                  shape: const StadiumBorder(),
                  side: BorderSide(color: AppColors.primary.withOpacity(0.5)),
                  backgroundColor: AppColors.primaryTint,
                  foregroundColor: AppColors.primaryDark,
                ),
                onPressed: () => widget.onOpenHistory(const HistoryFilter()),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Tx('See all', style: TextStyle(fontWeight: FontWeight.w800)),
                  const Icon(Icons.chevron_right_rounded, size: 18),
                ]),
              ),
            ]),
          ),
          if (s.recentActivity.isEmpty)
            ConsoleCard(
              child: Tx('No activity yet.', style: TextStyle(color: AppColors.textSecondary)),
            )
          else
            for (final item in s.recentActivity) ...[
              ActivityTile(item: item, onTap: () => showActivityDetails(context, item)),
              const SizedBox(height: 8),
            ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashboard entry to Company Balances: the verified total and any warnings, on a dark card.
class _CompanyBalancesCard extends StatelessWidget {
  final CompanyBalancesOverview? data;
  final VoidCallback onTap;

  const _CompanyBalancesCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = data;
    Widget chip(IconData icon, String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withOpacity(0.18), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13))),
          ]),
        );
    return Material(
      key: const Key('company-balances-entry'),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.header, Color.lerp(AppColors.header, AppColors.primary, 0.45)!],
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: AppColors.onHeader.withOpacity(0.14), borderRadius: BorderRadius.circular(18)),
                  child: Icon(Icons.account_balance_wallet_rounded, size: 30, color: AppColors.lightGold),
                ),
                const SizedBox(width: 12),
                VerticalDivider(width: 1, color: AppColors.onHeader.withOpacity(0.25)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Tx('Company Balances', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.onHeader)),
                      ),
                      if (d == null)
                        Tx('Cash register balances', style: TextStyle(color: AppColors.onHeader.withOpacity(0.75)))
                      else ...[
                        Tx('Total Limit', style: TextStyle(color: AppColors.onHeader.withOpacity(0.75))),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(d.totalLimit == null ? tr('Not reported') : usd(d.totalLimit!),
                              key: const Key('company-total-limit'),
                              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppColors.onHeader)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Tx('Total Balance', style: TextStyle(fontSize: 13, color: AppColors.onHeader.withOpacity(0.75))),
                            Text(': ', style: TextStyle(fontSize: 13, color: AppColors.onHeader.withOpacity(0.75))),
                            Flexible(
                              child: Text(usd(d.total),
                                  key: const Key('company-total'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.onHeader.withOpacity(0.9))),
                            ),
                          ]),
                        ),
                        if (d.lowCount > 0 || d.unavailableCount > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(spacing: 8, runSpacing: 6, children: [
                              if (d.lowCount > 0) chip(Icons.warning_amber_rounded, trp('{0} Low', [d.lowCount]), const Color(0xFFFF8A7A)),
                              if (d.unavailableCount > 0)
                                chip(Icons.check_circle_rounded, trp('{0} Offline', [d.unavailableCount]), const Color(0xFF5BE08F)),
                            ]),
                          ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.onHeader.withOpacity(0.85)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmsMatchingCard extends StatelessWidget {
  final bool isListening;
  final String? deviceRegistrationError;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRetryDeviceRegistration;
  final VoidCallback onOpenLog;

  const _SmsMatchingCard({
    required this.isListening,
    required this.deviceRegistrationError,
    required this.busy,
    required this.onToggle,
    required this.onRetryDeviceRegistration,
    required this.onOpenLog,
  });

  @override
  Widget build(BuildContext context) {
    final online = isListening && deviceRegistrationError == null;
    return ConsoleCard(
      onTap: onOpenLog,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TintedIcon(
                icon: Icons.sensors_rounded,
                color: online ? AppColors.statusCompleted : AppColors.textFaint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Tx(
                  'EVC Plus SMS Matching',
                  style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
              ),
              if (busy)
                const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Switch(
                  value: isListening,
                  onChanged: deviceRegistrationError == null ? onToggle : null,
                  activeTrackColor: AppColors.statusCompleted,
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (deviceRegistrationError != null) ...[
            Text(
              trp('This device is not registered as an authorized agent device: {0}', [deviceRegistrationError]),
              style: const TextStyle(fontSize: 12, color: AppColors.statusFailed),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetryDeviceRegistration, child: const Tx('Retry registration')),
          ] else
            Tx(
              isListening
                  ? tr('Online — listening for authorized EVC Plus payment SMS on this device. Tap to see submissions.')
                  : tr('Off — turn on to automatically match incoming EVC Plus payment SMS. Tap to see submissions.'),
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// Which source is carrying deposit payments: Sahal (primary), the Agent SIM reading SMS 898, or neither.
class PaymentSourceCard extends StatelessWidget {
  final PaymentSource data;

  const PaymentSourceCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final (color, icon, title, note) = switch (data.source) {
      'sahal' => (
          AppColors.statusCompleted,
          Icons.check_circle_rounded,
          tr('Sahal Active'),
          tr('Payments are read from Sahal. The Agent SIM takes over by itself if Sahal stops.')
        ),
      'agent_sim' => (
          AppColors.statusPending,
          Icons.sim_card_rounded,
          tr('Agent SIM Fallback Active'),
          tr('Sahal is not answering: payments are read from SMS 898 on the Agent SIM. Sahal takes over again by itself.')
        ),
      _ => (
          AppColors.statusFailed,
          Icons.error_rounded,
          tr('Both Sources Unavailable'),
          tr('Sahal is not answering and no Agent phone is reading SMS. Open the Agent App on the phone with the Sahal SIM.')
        ),
    };
    return Container(
      key: const Key('payment-source'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, key: const Key('payment-source-title'), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(note, style: const TextStyle(fontSize: 13)),
            if (data.creditedBySmsToday > 0 || data.waitingToday > 0) ...[
              const SizedBox(height: 6),
              Text(
                trp('Credited from SMS today: {0} · waiting: {1}', ['${data.creditedBySmsToday}', '${data.waitingToday}']),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
