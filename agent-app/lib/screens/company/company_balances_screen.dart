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
                  _TotalCard(data: data),
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
                  const Text(
                    'Balances are read from each company\'s cash register (CashdeskBot) and can\'t be changed here. '
                    'Companies without a balance connection show no amount.',
                    style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                  ),
                ],
              ),
            ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final CompanyBalancesOverview data;
  const _TotalCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final left = data.unavailableCount;
    return Container(
      key: const Key('total-balance'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [AppColors.purpleDark, AppColors.purple]),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), shape: BoxShape.circle),
            child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Total Company Balance',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('\$${data.total}',
                      key: const Key('total-amount'),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 32)),
                ),
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
          ),
        ],
      ),
    );
  }
}
