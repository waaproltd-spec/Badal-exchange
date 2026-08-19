import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/match_result.dart';
import '../models/sms_transaction_log.dart';
import '../services/sms_log_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/state_views.dart';

/// A log of SMS-derived (and manual WinWin) submissions this device has
/// made, with the match status the backend returned for each. There is no
/// dedicated "list my sms transactions" endpoint, so this is a simple local
/// history — see lib/services/sms_log_store.dart.
class SmsTransactionsScreen extends StatefulWidget {
  const SmsTransactionsScreen({super.key});

  @override
  State<SmsTransactionsScreen> createState() => _SmsTransactionsScreenState();
}

class _SmsTransactionsScreenState extends State<SmsTransactionsScreen> {
  List<SmsTransactionLog> _entries = [];
  bool _loading = true;
  StreamSubscription<SmsTransactionLog>? _subscription;

  @override
  void initState() {
    super.initState();
    _load();
    // Live-update the log as the background SMS bridge submits new
    // transactions, without requiring a manual pull-to-refresh.
    final session = context.read<Session>();
    _subscription = session.smsBridge.onLogEntry.listen((_) => _load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await SmsLogStore.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();

    return RefreshIndicator(
      onRefresh: _load,
      child: _entries.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                EmptyStateView(
                  icon: Icons.sms_rounded,
                  title: 'No SMS submissions yet',
                  message: 'Matched, unmatched, and duplicate submissions from this device will appear here.',
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _entries.length,
              itemBuilder: (context, index) => _SmsLogTile(entry: _entries[index]),
            ),
    );
  }
}

class _SmsLogTile extends StatelessWidget {
  final SmsTransactionLog entry;

  const _SmsLogTile({required this.entry});

  static final _dateFormat = DateFormat('MMM d, HH:mm:ss');

  String get _statusLabel {
    switch (entry.status) {
      case MatchStatus.matched:
        return 'matched';
      case MatchStatus.unmatched:
        return 'unmatched';
      case MatchStatus.duplicate:
        return 'duplicate';
      case MatchStatus.error:
        return 'failed';
    }
  }

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
                Icon(
                  entry.isManualWinwin ? Icons.edit_note_rounded : Icons.sms_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.isManualWinwin ? 'Manual WinWin confirmation' : 'EVC Plus SMS (${entry.provider})',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
                  ),
                ),
                StatusBadge(status: _statusLabel),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (entry.sender != null)
                        Text(entry.sender!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      Text('Ref: ${entry.transactionRef}', style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                    ],
                  ),
                ),
                Text(
                  '\$${entry.amount}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Submitted ${_dateFormat.format(entry.submittedAt.toLocal())}',
              style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
            if (entry.status == MatchStatus.error && entry.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                entry.errorMessage!,
                style: const TextStyle(fontSize: 12, color: AppColors.statusFailed),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
