import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/company_balance.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'company_detail_screen.dart';
import 'company_widgets.dart';

/// Company Balances: each company's cash register balance as the server
/// read it from the company, the total of the verified ones, and which
/// companies are low, offline or have no balance connection. Refreshes
/// every minute while open, and on demand.
class CompanyBalancesScreen extends StatefulWidget {
  /// How often the open screen asks again.
  final Duration autoRefresh;

  const CompanyBalancesScreen({super.key, this.autoRefresh = const Duration(minutes: 1)});

  @override
  State<CompanyBalancesScreen> createState() => _CompanyBalancesScreenState();
}

class _CompanyBalancesScreenState extends State<CompanyBalancesScreen> {
  CompanyBalancesOverview? _data;
  String? _error;
  bool _refreshing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.autoRefresh, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final data = await context.read<Session>().api.getCompanyBalances(refresh: refresh);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load company balances.');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _open(CompanyBalance c) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CompanyDetailScreen(company: c)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Company Balances'),
        actions: [
          IconButton(
            key: const Key('refresh-balances'),
            tooltip: 'Refresh balances',
            onPressed: _refreshing ? null : () => _load(refresh: true),
            icon: _refreshing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: data == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _LimitCard(data: data),
                  const SizedBox(height: 12),
                  TwoColumnGrid(children: [
                    StatCard(
                      icon: Icons.north_east_rounded,
                      color: AppColors.statusProcessing,
                      value: '\$${data.openWithdrawalAmount}',
                      label: 'Open withdrawals',
                    ),
                    StatCard(
                      icon: Icons.warning_amber_rounded,
                      color: AppColors.statusFailed,
                      value: '${data.lowCount}',
                      label: data.lowCount == 1 ? 'Low balance company' : 'Low balance companies',
                    ),
                    StatCard(
                      icon: Icons.wifi_off_rounded,
                      color: AppColors.statusPending,
                      value: '${data.unavailableCount}',
                      label: 'Offline / not updated',
                    ),
                    StatCard(
                      icon: Icons.link_off_rounded,
                      color: AppColors.statusDuplicate,
                      value: '${data.notConnectedCount}',
                      label: 'No balance connection',
                    ),
                  ]),
                  const SizedBox(height: 12),
                  _BalanceCard(data: data),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text('Could not refresh: $_error',
                        key: const Key('balances-error'), style: const TextStyle(color: AppColors.statusFailed)),
                  ],
                  const SizedBox(height: 8),
                  SectionHeader(title: 'Companies', actionLabel: 'Refresh', onAction: () => _load(refresh: true)),
                  for (final c in data.companies) ...[
                    CompanyCard(company: c, onTap: () => _open(c)),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    'Balance: what customers bought through the register. Limit: what it can still sell. '
                    'Read from each register (CashdeskBot) and updated with every completed sale and payout; '
                    'they can\'t be changed here. Companies without a balance connection show no amount.',
                    style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Total Limit, first and large: what the registers can still sell, added up
/// from the companies' own limits (a company that reports none is counted in
/// the note, never as zero).
class _LimitCard extends StatelessWidget {
  final CompanyBalancesOverview data;
  const _LimitCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final unknown = data.limitUnknownCount;
    return Container(
      key: const Key('total-limit-card'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [AppColors.purpleDark, AppColors.purple]),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.speed_rounded, color: Colors.white.withOpacity(0.9), size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Total Limit',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(data.totalLimit == null ? 'Not reported' : '\$${data.totalLimit}',
                key: const Key('total-limit'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 48, height: 1.1)),
          ),
          const SizedBox(height: 4),
          Text(
            data.totalLimit == null
                ? 'No company has reported a limit'
                : unknown > 0
                    ? '$unknown ${unknown == 1 ? 'company' : 'companies'} not reported (not included)'
                    : 'What the registers can still sell',
            key: const Key('total-limit-note'),
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Total Balance, below the summary cards: the verified balances added up.
class _BalanceCard extends StatelessWidget {
  final CompanyBalancesOverview data;
  const _BalanceCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final left = data.unavailableCount;
    return Container(
      key: const Key('total-balance'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [AppColors.purple, AppColors.purpleDark]),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.account_balance_wallet_rounded, color: Colors.white.withOpacity(0.9), size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Total Balance',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('\$${data.total}',
                key: const Key('total-amount'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 40, height: 1.1)),
          ),
          const SizedBox(height: 4),
          Text(
            'Verified balances of ${data.totalCompanies} '
            '${data.totalCompanies == 1 ? 'company' : 'companies'}'
            '${left > 0 ? ' · $left not included (offline or not updated)' : ''}',
            key: const Key('total-note'),
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          Text('Updated ${formatDateTime(data.generatedAt)}',
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11.5)),
        ],
      ),
    );
  }
}
