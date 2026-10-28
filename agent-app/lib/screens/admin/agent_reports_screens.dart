import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Each agent's completed deposits and withdrawals, failures and wallet
/// adjustments over a period.
class AgentPerformanceScreen extends StatefulWidget {
  const AgentPerformanceScreen({super.key});

  @override
  State<AgentPerformanceScreen> createState() => _AgentPerformanceScreenState();
}

class _AgentPerformanceScreenState extends State<AgentPerformanceScreen> {
  static const _periods = [(0, 'Today'), (6, '7 days'), (29, '30 days'), (89, '3 months')];
  int _days = 0;
  List<AgentPerformance>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final to = DateTime.now();
    try {
      final rows = await context.read<Session>().api.getAgentPerformance(from: to.subtract(Duration(days: _days)), to: to);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Could not load the report.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Agent performance')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ChoiceChipsRow<int>(
              key: const Key('performance-period'),
              options: _periods,
              selected: _days,
              onSelected: (d) {
                setState(() {
                  _days = d;
                  _rows = null;
                });
                _load();
              },
            ),
            const SizedBox(height: 12),
            if (_error != null)
              ErrorStateView(message: _error!, onRetry: _load)
            else if (rows == null)
              const LoadingView()
            else if (rows.isEmpty)
              const ConsoleCard(child: Text('No agents.', style: TextStyle(color: AppColors.textSecondary)))
            else
              for (final r in rows) ...[
                ConsoleCard(
                  key: Key('performance-${r.id}'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w800))),
                      StatusPill(r.status == 'active' ? 'active' : 'blocked'),
                    ]),
                    const SizedBox(height: 6),
                    InfoRow('Deposits completed', '${r.deposits} · \$${r.depositAmount}'),
                    InfoRow('Withdrawals completed', '${r.withdrawals} · \$${r.withdrawalAmount}'),
                    InfoRow('Failed', '${r.failed}'),
                    InfoRow('Wallet adjustments', '${r.adjustments}'),
                  ]),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

/// Logins and security changes of every agent account, newest first.
class LoginHistoryScreen extends StatefulWidget {
  const LoginHistoryScreen({super.key});

  @override
  State<LoginHistoryScreen> createState() => _LoginHistoryScreenState();
}

class _LoginHistoryScreenState extends State<LoginHistoryScreen> {
  List<LoginEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final events = await context.read<Session>().api.getLoginHistory();
      if (mounted) setState(() => _events = events);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Could not load the login history.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      appBar: AppBar(title: const Text('Login history')),
      body: _error != null
          ? ErrorStateView(message: _error!, onRetry: _load)
          : events == null
              ? const LoadingView()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (events.isEmpty)
                        const ConsoleCard(child: Text('Nothing recorded yet.', style: TextStyle(color: AppColors.textSecondary))),
                      for (final e in events) ...[
                        ConsoleCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(children: [
                            TintedIcon(
                              icon: e.action == 'user.login' ? Icons.login_rounded : Icons.shield_rounded,
                              color: e.action == 'user.login' ? AppColors.statusCompleted : AppColors.accentOrange,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${e.userName ?? e.actorName ?? '—'} · ${e.label}',
                                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                Text(
                                  [
                                    formatDateTime(e.createdAt),
                                    if (e.action != 'user.login' && e.actorName != null && e.actorName != e.userName)
                                      'by ${e.actorName}',
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                ),
                              ]),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
    );
  }
}
