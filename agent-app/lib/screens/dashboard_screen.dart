import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/history_filter.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'pending_deposits_screen.dart';
import 'pending_withdrawals_screen.dart';
import 'sms_transactions_screen.dart';

/// Dashboard: the agent's overview. Pending counts open the screens where
/// those orders are actioned; the other counts open History filtered. Also
/// hosts the automatic EVC Plus SMS matching control and recent activity.
class DashboardScreen extends StatefulWidget {
  final ValueChanged<HistoryFilter> onOpenHistory;

  const DashboardScreen({super.key, required this.onOpenHistory});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with LiveRefresh {
  DashboardSummary? _summary;
  String? _error;
  bool _loading = true;
  bool _smsBusy = false;

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
      final summary = await context.read<Session>().api.getDashboard();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load dashboard data.';
        _loading = false;
      });
    }
  }

  Future<void> _push(String title, Widget body) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body),
    ));
    if (mounted) _load();
  }

  Future<void> _toggleSmsMatching(Session session, bool enable) async {
    setState(() => _smsBusy = true);
    if (enable) {
      final started = await session.enableSmsAutoMatching();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS permission is required to enable automatic matching.')),
        );
      }
    } else {
      await session.disableSmsAutoMatching();
    }
    if (mounted) setState(() => _smsBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _summary == null) return ErrorStateView(message: _error!, onRetry: _load);

    final session = context.watch<Session>();
    final s = _summary!;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(
            'Welcome, ${session.agentDisplayName}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 2),
          const Text('Manage your transactions', style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          TwoColumnGrid(children: [
            StatCard(
              icon: Icons.south_rounded,
              color: AppColors.statusPending,
              value: '${s.pendingDeposits}',
              label: 'Pending Deposits',
              onTap: () => _push('Pending Deposits', const PendingDepositsScreen()),
            ),
            StatCard(
              icon: Icons.north_rounded,
              color: AppColors.statusProcessing,
              value: '${s.pendingWithdrawals}',
              label: 'Pending Withdrawals',
              onTap: () => _push('Pending Withdrawals', const PendingWithdrawalsScreen()),
            ),
            StatCard(
              icon: Icons.autorenew_rounded,
              color: AppColors.purple,
              value: '${s.processing}',
              label: 'Processing',
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'processing')),
            ),
            StatCard(
              icon: Icons.check_rounded,
              color: AppColors.statusCompleted,
              value: '${s.completed}',
              label: 'Completed',
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'completed')),
            ),
            StatCard(
              icon: Icons.close_rounded,
              color: AppColors.statusFailed,
              value: '${s.failed}',
              label: 'Failed',
              onTap: () => widget.onOpenHistory(const HistoryFilter(status: 'failed')),
            ),
            StatCard(
              icon: Icons.receipt_long_rounded,
              color: AppColors.textSecondary,
              value: '${s.totalTransactions}',
              label: 'Total Transactions',
              onTap: () => widget.onOpenHistory(const HistoryFilter(type: 'order')),
            ),
          ]),
          const SizedBox(height: 16),
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
              onOpenLog: () => _push('SMS Transactions', const SmsTransactionsScreen()),
            )
          else
            const ConsoleCard(
              child: Text(
                'Automatic EVC Plus SMS matching is only available on Android agent devices.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: 8),
          SectionHeader(
            title: 'Recent Activity',
            actionLabel: 'See all',
            onAction: () => widget.onOpenHistory(const HistoryFilter()),
          ),
          if (s.recentActivity.isEmpty)
            const ConsoleCard(
              child: Text('No activity yet.', style: TextStyle(color: AppColors.textSecondary)),
            )
          else
            for (final item in s.recentActivity) ...[
              ActivityTile(item: item, onTap: () => showActivityDetails(context, item)),
              const SizedBox(height: 8),
            ],
        ],
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
              const Expanded(
                child: Text(
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
              'This device is not registered as an authorized agent device: $deviceRegistrationError',
              style: const TextStyle(fontSize: 12, color: AppColors.statusFailed),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetryDeviceRegistration, child: const Text('Retry registration')),
          ] else
            Text(
              isListening
                  ? 'Online — listening for authorized EVC Plus payment SMS on this device. Tap to see submissions.'
                  : 'Off — turn on to automatically match incoming EVC Plus payment SMS. Tap to see submissions.',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}
