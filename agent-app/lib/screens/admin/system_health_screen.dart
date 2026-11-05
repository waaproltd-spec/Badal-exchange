import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../l10n/tr.dart';
import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'broadcast_screens.dart' show mogadishu;

/// System Health: what the platform's monitor found (it scans every minute), what it repaired by itself,
/// and what needs a person. The owner gets the same problems on Telegram.
class SystemHealthScreen extends StatefulWidget {
  const SystemHealthScreen({super.key, this.poll = const Duration(seconds: 30)});

  final Duration poll;

  @override
  State<SystemHealthScreen> createState() => _SystemHealthScreenState();
}

class _SystemHealthScreenState extends State<SystemHealthScreen> {
  SystemHealth? _health;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.poll, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final h = await context.read<Session>().api.getSystemHealth();
      if (mounted) setState(() {
        _health = h;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : tr('Failed to load'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _health;
    return Scaffold(
      appBar: AppBar(title: Tx('System Health')),
      body: h == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                SystemHealthSummary(health: h),
                if (!h.ownerChatLinked) ...[
                  const SizedBox(height: 12),
                  _Notice(key: const Key('health-owner-chat'), text: tr('The owner\'s Telegram chat is not linked: alerts cannot be sent. Send /start to the support bot from the admin account.')),
                ],
                const SizedBox(height: 12),
                GroupLabel(tr('Open problems')),
                if (h.open.isEmpty)
                  Padding(padding: const EdgeInsets.all(8), child: Tx('No open problems.', key: const Key('health-none')))
                else
                  for (final i in h.open) _IncidentCard(i),
                if (h.resolved.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  GroupLabel(tr('Solved in the last 2 days')),
                  for (final i in h.resolved) _IncidentCard(i, resolved: true),
                ],
              ]),
            ),
    );
  }
}

/// The one-line status: Healthy / N problems / the scan has stopped.
class SystemHealthSummary extends StatelessWidget {
  const SystemHealthSummary({super.key, required this.health, this.onTap});

  final SystemHealth health;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final h = health;
    final (color, icon, text) = h.stale
        ? (AppColors.statusFailed, Icons.warning_amber_rounded, tr('The monitor has not scanned for 5 minutes'))
        : h.critical > 0
            ? (AppColors.statusFailed, Icons.error_rounded, trp('{0} critical problem(s)', [h.critical]))
            : h.problems > 0
                ? (AppColors.statusPending, Icons.warning_amber_rounded, trp('{0} problem(s) to watch', [h.problems]))
                : (AppColors.statusCompleted, Icons.check_circle_rounded, tr('Everything is healthy'));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('system-health-summary'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Row(children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text, key: const Key('system-health-title'), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16)),
                if (h.scannedAt != null)
                  Text(trp('Last scan {0} · {1} checks', [mogadishu(h.scannedAt!), h.checks]), style: const TextStyle(fontSize: 12)),
              ]),
            ),
            if (onTap != null) const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.statusPending.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
        child: Text(text),
      );
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard(this.i, {this.resolved = false});

  final HealthIncident i;
  final bool resolved;

  @override
  Widget build(BuildContext context) {
    final color = resolved
        ? AppColors.statusCompleted
        : i.critical
            ? AppColors.statusFailed
            : i.severity == 'info'
                ? AppColors.statusProcessing
                : AppColors.statusPending;
    Widget line(String label, String? value) => value == null || value.isEmpty
        ? const SizedBox.shrink()
        : Padding(padding: const EdgeInsets.only(top: 2), child: Text('$label: $value', style: const TextStyle(fontSize: 13)));
    return Card(
      key: Key('health-${i.key}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(resolved ? Icons.check_circle_rounded : (i.critical ? Icons.error_rounded : Icons.warning_amber_rounded), color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(i.title, style: const TextStyle(fontWeight: FontWeight.w800))),
          ]),
          if (!resolved && i.firstSeen != null) line(tr('Since'), mogadishu(i.firstSeen!)),
          if (resolved && i.resolvedAt != null) line(tr('Solved'), mogadishu(i.resolvedAt!)),
          line(tr('Cause'), i.cause),
          line(tr('Repair'), i.repair),
          line(tr('Result'), i.repairResult),
          if (i.financial) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('Money may be affected: do not change balances by hand'), style: TextStyle(color: AppColors.statusFailed, fontWeight: FontWeight.w700, fontSize: 13))),
          if (i.customers && !resolved) line(tr('Customers'), tr('affected')),
          if (i.developer && !resolved) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('A developer is needed'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        ]),
      ),
    );
  }
}
