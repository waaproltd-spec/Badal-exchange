import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/withdrawal_verification.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';

/// Withdrawal Verification (manage_withdrawal_verifications): before a
/// customer's first withdrawal an admin approves the account. The server
/// refuses every withdrawal of an account that is not approved, from the
/// app or a direct API call. Here: the account ID and registered number,
/// balance and history, and Approve / Reject (with a reason) / Restrict
/// again (with a reason), with who decided and when.
class WithdrawalVerificationScreen extends StatefulWidget {
  const WithdrawalVerificationScreen({super.key});

  @override
  State<WithdrawalVerificationScreen> createState() => _WithdrawalVerificationScreenState();
}

class _WithdrawalVerificationScreenState extends State<WithdrawalVerificationScreen> {
  static final _when = DateFormat('MMM d, yyyy · HH:mm');

  String _status = 'pending';
  List<WithdrawalVerification>? _requests;
  Map<String, int> _counts = const {};
  String? _error;
  bool _loading = true;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _requests == null;
      _error = null;
    });
    try {
      final r = await context.read<Session>().api.getWithdrawalVerifications(status: _status);
      if (!mounted) return;
      setState(() {
        _requests = r.requests;
        _counts = r.counts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Could not load the requests.';
        _loading = false;
      });
    }
  }

  Future<void> _decide(WithdrawalVerification v, String decision) async {
    String? reason;
    if (decision != 'approve') {
      final controller = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(decision == 'reject' ? 'Reject ${v.accountId}?' : 'Restrict ${v.accountId} again?'),
          content: TextField(
            key: const Key('verify-reason'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason (shown to the customer)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
              onPressed: () => Navigator.pop(context, true),
              child: Text(decision == 'reject' ? 'Reject' : 'Restrict'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      reason = controller.text.trim();
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Approve ${v.accountId}?'),
          content: Text('${v.phone} can then withdraw under the usual rules.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Approve')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _busy = v.customerId);
    try {
      await context.read<Session>().api.decideWithdrawalVerification(v.customerId, decision, reason: reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${v.accountId}: ${_label(decision)}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not save the decision.')));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static String _label(String decision) =>
      {'approve': 'approved', 'reject': 'rejected', 'restrict': 'restricted'}[decision] ?? decision;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Withdrawal Verification')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null && _requests == null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : ListView(
                    key: const Key('verifications'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      const Text(
                        'Before a first withdrawal the account must be approved here. Until then the server '
                        'refuses every withdrawal of the account. Balances are never changed.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 12),
                      ChoiceChipsRow<String>(
                        options: [
                          for (final s in const ['pending', 'approved', 'rejected', 'restricted'])
                            (s, '${s[0].toUpperCase()}${s.substring(1)} (${_counts[s] ?? 0})'),
                          ('all', 'All'),
                        ],
                        selected: _status,
                        onSelected: (s) {
                          setState(() => _status = s);
                          _load();
                        },
                      ),
                      const SizedBox(height: 8),
                      if (_requests!.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: EmptyStateView(
                            icon: Icons.verified_user_outlined,
                            title: 'Nothing here',
                            message: 'No accounts with this status.',
                          ),
                        )
                      else
                        ..._requests!.map(_card),
                    ],
                  )),
      ),
    );
  }

  Widget _card(WithdrawalVerification v) {
    final busy = _busy == v.customerId;
    return Padding(
      key: Key('verify-${v.customerId}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: ConsoleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v.name?.isNotEmpty == true ? v.name! : v.phone, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text('${v.accountId} · +${v.phone.replaceAll('+', '')}', style: const TextStyle(color: AppColors.textSecondary)),
              ]),
            ),
            StatusPill(v.status == 'approved' ? 'completed' : (v.status == 'pending' ? 'pending' : 'failed')),
          ]),
          const SizedBox(height: 8),
          InfoRow('Status', const {'pending': 'Not approved', 'approved': 'Approved for withdrawals', 'rejected': 'Rejected', 'restricted': 'Restricted'}[v.status] ?? v.status),
          InfoRow('Balance', '\$${v.balance}'),
          InfoRow('Deposits completed', '${v.depositCount} · \$${v.depositTotal}'),
          InfoRow('Withdrawals completed', '${v.withdrawalCount} · \$${v.withdrawalTotal}'),
          if (v.requestedAt != null) InfoRow('Requested', _when.format(v.requestedAt!.toLocal())),
          if (v.decidedAt != null)
            InfoRow('Decided', '${_when.format(v.decidedAt!.toLocal())}${v.decidedBy != null ? ' · ${v.decidedBy}' : ''}'),
          if (v.reason != null && v.reason!.isNotEmpty) InfoRow('Reason', v.reason!),
          if (v.recent.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('Recent transactions', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final o in v.recent.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '${o['orderCode']} · ${o['direction']} · ${o['method']} · \$${o['amount']} · ${o['status']}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
            if (v.status != 'approved')
              FilledButton.icon(
                key: Key('approve-${v.customerId}'),
                onPressed: busy ? null : () => _decide(v, 'approve'),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Approve'),
              ),
            if (v.status == 'pending')
              OutlinedButton.icon(
                key: Key('reject-${v.customerId}'),
                onPressed: busy ? null : () => _decide(v, 'reject'),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Reject'),
              ),
            if (v.status == 'approved')
              OutlinedButton.icon(
                key: Key('restrict-${v.customerId}'),
                onPressed: busy ? null : () => _decide(v, 'restrict'),
                icon: const Icon(Icons.block_rounded),
                label: const Text('Restrict'),
              ),
          ]),
        ]),
      ),
    );
  }
}
