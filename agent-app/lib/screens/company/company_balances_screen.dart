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
import '../../l10n/tr.dart';

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
      if (mounted) setState(() => _error = e is ApiException ? e.message : tr('Could not load company balances.'));
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
        title: const Tx('Company Balances'),
        actions: [
          IconButton(
            key: const Key('refresh-balances'),
            tooltip: tr('Refresh balances'),
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
                      label: tr('Open withdrawals'),
                    ),
                    StatCard(
                      icon: Icons.warning_amber_rounded,
                      color: AppColors.statusFailed,
                      value: '${data.lowCount}',
                      label: data.lowCount == 1 ? tr('Low balance company') : tr('Low balance companies'),
                    ),
                    StatCard(
                      icon: Icons.wifi_off_rounded,
                      color: AppColors.statusPending,
                      value: '${data.unavailableCount}',
                      label: tr('Offline / not updated'),
                    ),
                    StatCard(
                      icon: Icons.link_off_rounded,
                      color: AppColors.statusDuplicate,
                      value: '${data.notConnectedCount}',
                      label: tr('No balance connection'),
                    ),
                  ]),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(trp('Could not refresh: {0}', [_error]),
                        key: const Key('balances-error'), style: const TextStyle(color: AppColors.statusFailed)),
                  ],
                  const SizedBox(height: 8),
                  SectionHeader(title: tr('Companies'), actionLabel: tr('Refresh'), onAction: () => _load(refresh: true)),
                  for (final c in data.companies) ...[
                    CompanyCard(company: c, onTap: () => _open(c)),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 4),
                  Tx(
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
              child: Tx('Total Limit',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(data.totalLimit == null ? tr('Not reported') : '\$${data.totalLimit}',
                key: const Key('total-limit'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 48, height: 1.1)),
          ),
          const SizedBox(height: 4),
          Text(
            data.totalLimit == null
                ? tr('No company has reported a limit')
                : unknown > 0
                    ? trp('{0} {1} not reported (not included)', [unknown, unknown == 1 ? tr('company') : tr('companies')])
                    : tr('What the registers can still sell'),
            key: const Key('total-limit-note'),
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(trp('Updated {0}', [formatDateTime(data.generatedAt)]),
              key: const Key('updated-at'), style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11.5)),
        ],
      ),
    );
  }
}
