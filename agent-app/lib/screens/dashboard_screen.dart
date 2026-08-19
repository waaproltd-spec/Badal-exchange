import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/state_views.dart';

/// Dashboard: quick pending counts + shortcuts into the other sections, and
/// the control for enabling automatic EVC Plus SMS matching on this device.
class DashboardScreen extends StatefulWidget {
  final ValueChanged<int> onNavigate;

  const DashboardScreen({super.key, required this.onNavigate});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int? _pendingDepositsCount;
  int? _pendingWithdrawalsCount;
  String? _error;
  bool _loading = true;
  bool _smsBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final session = context.read<Session>();
    try {
      final results = await Future.wait([
        session.api.getPendingDeposits(),
        session.api.getPendingWithdrawals(),
      ]);
      if (!mounted) return;
      setState(() {
        _pendingDepositsCount = results[0].length;
        _pendingWithdrawalsCount = results[1].length;
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

  Future<void> _toggleSmsMatching(Session session, bool enable) async {
    setState(() => _smsBusy = true);
    if (enable) {
      final started = await session.enableSmsAutoMatching();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SMS permission is required to enable automatic matching.'),
          ),
        );
      }
    } else {
      await session.disableSmsAutoMatching();
    }
    if (mounted) setState(() => _smsBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final isAndroid = Platform.isAndroid;

    return RefreshIndicator(
      onRefresh: _load,
      child: _loading
          ? const LoadingView()
          : (_error != null
              ? ErrorStateView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Welcome, ${session.agentDisplayName}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _CountCard(
                            label: 'Pending Deposits',
                            count: _pendingDepositsCount ?? 0,
                            color: AppColors.statusPending,
                            icon: Icons.arrow_circle_down_rounded,
                            onTap: () => widget.onNavigate(1),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CountCard(
                            label: 'Pending Withdrawals',
                            count: _pendingWithdrawalsCount ?? 0,
                            color: AppColors.statusProcessing,
                            icon: Icons.arrow_circle_up_rounded,
                            onTap: () => widget.onNavigate(2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (isAndroid) _SmsMatchingCard(
                      isListening: session.smsBridge.isListening,
                      deviceRegistrationError: session.deviceRegistrationError,
                      busy: _smsBusy,
                      onToggle: (enable) => _toggleSmsMatching(session, enable),
                      onRetryDeviceRegistration: () async {
                        setState(() => _smsBusy = true);
                        await session.retryDeviceRegistration();
                        if (mounted) setState(() => _smsBusy = false);
                      },
                    ) else
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Automatic SMS matching is only available on Android agent devices.',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    const Text(
                      'Shortcuts',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    _ShortcutTile(
                      icon: Icons.sms_rounded,
                      label: 'SMS Transactions',
                      onTap: () => widget.onNavigate(3),
                    ),
                    _ShortcutTile(
                      icon: Icons.check_circle_rounded,
                      label: 'Completed orders',
                      onTap: () => widget.onNavigate(4),
                    ),
                    _ShortcutTile(
                      icon: Icons.cancel_rounded,
                      label: 'Failed orders',
                      onTap: () => widget.onNavigate(5),
                    ),
                    _ShortcutTile(
                      icon: Icons.person_rounded,
                      label: 'Profile',
                      onTap: () => widget.onNavigate(6),
                    ),
                  ],
                )),
    );
  }
}

class _CountCard extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  const _CountCard({
    required this.label,
    required this.count,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 12),
            Text(
              '$count',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ShortcutTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
        onTap: onTap,
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

  const _SmsMatchingCard({
    required this.isListening,
    required this.deviceRegistrationError,
    required this.busy,
    required this.onToggle,
    required this.onRetryDeviceRegistration,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sms_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Automatic EVC Plus SMS matching',
                    style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  ),
                ),
                if (busy)
                  const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Switch(
                    value: isListening,
                    onChanged: deviceRegistrationError == null ? onToggle : null,
                    activeTrackColor: AppColors.primary,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (deviceRegistrationError != null) ...[
              Text(
                'This device is not registered as an authorized agent device: '
                '$deviceRegistrationError',
                style: const TextStyle(fontSize: 12, color: AppColors.statusFailed),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetryDeviceRegistration, child: const Text('Retry registration')),
            ] else
              Text(
                isListening
                    ? 'Listening for authorized EVC Plus payment SMS on this device.'
                    : 'Off. Turn on to automatically submit incoming EVC Plus payment SMS for matching.',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
