import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'sahal_account_screen.dart';
import 'sahal_forwarder_card.dart';

/// Sahal merchant sign-in: Sahal texts an access code to the merchant phone
/// at every sign-in, so a manager starts it here and types the code in.
/// The server then keeps the session and reads the merchant transactions
/// every minute, crediting the waiting deposit each merchant payment is for.
class MerchantFeedScreen extends StatefulWidget {
  /// How often the open screen checks while something is pending.
  final Duration poll;

  const MerchantFeedScreen({super.key, this.poll = const Duration(seconds: 4)});

  @override
  State<MerchantFeedScreen> createState() => _MerchantFeedScreenState();
}

class _MerchantFeedScreenState extends State<MerchantFeedScreen> {
  final _code = TextEditingController();
  MerchantFeedStatus? _status;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.poll, (_) {
      final s = _status?.state;
      if (s == 'ready' || s == 'code_entered' || s == 'needs_code') _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Session>().api.getMerchantFeedStatus();
      if (mounted) setState(() {
        _status = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load the Sahal status.');
    }
  }

  Future<void> _do(Future<MerchantFeedStatus> Function() action) async {
    setState(() => _busy = true);
    try {
      final s = await action();
      if (mounted) setState(() {
        _status = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signIn() => _do(() => context.read<Session>().api.merchantFeedSignIn());

  void _sendCode() {
    final code = _code.text.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(code)) {
      setState(() => _error = 'Enter the code from the SMS (numbers only).');
      return;
    }
    _code.clear();
    _do(() => context.read<Session>().api.merchantFeedCode(code));
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Sahal Merchant Sign-in')),
      body: s == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(status: s),
                const SizedBox(height: 10),
                ConsoleCard(
                  key: const Key('feed-open-account'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SahalAccountScreen())),
                  child: const Row(
                    children: [
                      Icon(Icons.manage_accounts_rounded),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('Sahal account & session: login, change account, test connection, reconnect',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
                if (s.needsCode) ...[
                  const GroupLabel('Access code'),
                  ConsoleCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Sahal sent an SMS to the merchant phone (252905999914): '
                            '"-SAHAL SERVICES- Access code is ……". The Agent App on that phone enters it by '
                            'itself when SMS permission is allowed. If it does not, type it here within 10 minutes.',
                            key: Key('feed-auto-hint')),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('feed-code'),
                          controller: _code,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Access code', prefixIcon: Icon(Icons.key_rounded)),
                          onSubmitted: (_) => _sendCode(),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          key: const Key('feed-send-code'),
                          onPressed: _busy ? null : _sendCode,
                          child: const Text('Authenticate'),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, key: const Key('feed-error'), style: const TextStyle(color: AppColors.statusFailed)),
                ],
                if (!s.needsCode && s.state != 'code_entered' && s.state != 'not_configured') ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('feed-sign-in'),
                    onPressed: _busy || s.state == 'ready' ? null : _signIn,
                    icon: const Icon(Icons.login_rounded),
                    label: Text(s.working ? 'Sign in again (new code)' : 'Sign in to Sahal'),
                  ),
                ],
                const GroupLabel('Deposits'),
                ConsoleCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SwitchListTile(
                    key: const Key('feed-credit'),
                    title: const Text('Credit deposits automatically', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Credited (24 h): ${s.creditedToday} · Not matched: ${s.unmatchedToday}'),
                    value: s.creditOn,
                    onChanged: _busy ? null : (v) => _do(() => context.read<Session>().api.merchantFeedCredit(v)),
                  ),
                ),
                const GroupLabel('Withdrawals'),
                ConsoleCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SwitchListTile(
                    key: const Key('feed-payouts'),
                    title: const Text('Complete withdrawals sent from Sahal', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Send each withdrawal in Sahal (Customer Fund Transfer): it is marked completed '
                        'when the transfer shows in Sahal. Completed (24 h): ${s.payoutsCompletedToday}'),
                    value: s.payoutsOn,
                    onChanged: _busy ? null : (v) => _do(() => context.read<Session>().api.merchantFeedPayouts(v)),
                  ),
                ),
                const SahalForwarderCard(),
                const SizedBox(height: 16),
                const Text(
                  'Each sign-in makes Sahal text a new code, so sign in only when needed: the server keeps the '
                  'session open by reading every minute. A merchant payment credits a waiting deposit only when it '
                  'comes from the customer\'s own number with the same amount, once. Payments with no matching '
                  'deposit are not credited; check them in the merchant portal.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final MerchantFeedStatus status;
  const _StatusCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status.state) {
      'ok' => ('Signed in · reading', AppColors.statusCompleted, Icons.check_circle_rounded),
      'needs_code' => ('Code needed', AppColors.statusPending, Icons.sms_rounded),
      'code_entered' => ('Checking the code…', AppColors.statusProcessing, Icons.hourglass_top_rounded),
      'ready' => ('Signing in…', AppColors.statusProcessing, Icons.hourglass_top_rounded),
      'not_configured' => ('Login not set up', AppColors.statusFailed, Icons.settings_rounded),
      _ => ('Stopped', AppColors.statusFailed, Icons.pause_circle_rounded),
    };
    return ConsoleCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, key: const Key('feed-state'), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                if ((status.message ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(status.message!, style: const TextStyle(color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 6),
                Text(
                  'Payments read: ${status.rowsSeen}'
                  '${status.lastOkAt != null ? ' · last read ${formatDateTime(status.lastOkAt!)}' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
