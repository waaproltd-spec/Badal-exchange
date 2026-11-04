import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'sahal_forwarder_card.dart';
import '../../l10n/tr.dart';
import '../../l10n/language.dart';

/// Sahal merchant account, from the Admin Dashboard: the connection and its
/// session, and a new login that is saved, tested in its own session and only
/// then activated -- the working account carries on until that moment.
///
/// The server keeps the password and PIN encrypted and never sends them back:
/// this screen can only send them. The fields are masked, emptied once saved,
/// and nothing is kept on this phone.
class SahalAccountScreen extends StatefulWidget {
  /// How often the open screen checks while a test or a code is pending.
  final Duration poll;

  const SahalAccountScreen({super.key, this.poll = const Duration(seconds: 4)});

  @override
  State<SahalAccountScreen> createState() => _SahalAccountScreenState();
}

class _SahalAccountScreenState extends State<SahalAccountScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();
  final _code = TextEditingController();
  SahalAccountStatus? _status;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.poll, (_) {
      if (_status?.pending?.busy == true || _status?.connection != 'connected') _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _username.dispose();
    _password.dispose();
    _pin.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Session>().api.getSahalAccount();
      if (mounted) {
        setState(() {
          _status = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : tr('Could not load the Sahal account.'));
    }
  }

  Future<void> _do(Future<SahalAccountStatus> Function() action) async {
    setState(() => _busy = true);
    try {
      final s = await action();
      if (mounted) {
        setState(() {
          _status = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : tr('Something went wrong. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final user = _username.text.trim();
    final pass = _password.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = tr('Enter the Sahal merchant login and password.'));
      return;
    }
    final pin = _pin.text.trim();
    // The password and PIN leave this screen at once.
    _password.clear();
    _pin.clear();
    await _do(() => context.read<Session>().api.saveSahalAccount(username: user, password: pass, pin: pin));
    if (_error == null) _username.clear();
  }

  void _sendCode() {
    final code = _code.text.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(code)) {
      setState(() => _error = tr('Enter the code from the SMS (numbers only).'));
      return;
    }
    _code.clear();
    _do(() => context.read<Session>().api.sahalAccountCode(code));
  }

  /// Activating switches the live account. It asks, says what is open, and
  /// for a different merchant account asks to confirm the deposit codes.
  Future<void> _activate(SahalAccountStatus s) async {
    final p = s.pending!;
    final different = p.username != s.activeUsername;
    var confirmed = !different;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          key: const Key('activate-dialog'),
          title: const Tx('Switch to the new Sahal account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(trp('Account {0} was signed in and its transactions read. It replaces {1} now; its session is used as it is, with no new SMS code.', [p.username, s.activeUsername ?? 'the account set on the server'])),
              const SizedBox(height: 10),
              Text(trp('Open now: {0} deposit(s) waiting for payment, {1} withdrawal(s) waiting, {2} transfer(s) held for a check.', [s.openDeposits, s.openWithdrawals, s.transfersHeld]),
                  key: const Key('activate-open')),
              if (s.openDeposits > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Tx('A deposit paid to the old account after the switch is not read. Switch when none is waiting.',
                      style: TextStyle(color: AppColors.statusPending)),
                ),
              if (different)
                CheckboxListTile(
                  key: const Key('activate-confirm-codes'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: confirmed,
                  onChanged: (v) => setLocal(() => confirmed = v ?? false),
                  title: const Tx('Customers\' deposit codes (merchant USSD) point to the new account.'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Tx('Cancel')),
            ElevatedButton(
              key: const Key('activate-go'),
              onPressed: confirmed ? () => Navigator.of(ctx).pop(true) : null,
              child: const Tx('Switch now'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await _do(() => context.read<Session>().api.activateSahalAccount(depositCodesUpdated: different));
    }
  }

  static String _time(DateTime? t) => t == null ? '—' : SahalForwarderCard.somaliTime(t.toUtc().toIso8601String());

  static String _age(int? seconds) {
    if (seconds == null) return '—';
    final m = seconds ~/ 60;
    if (AppLanguage.isSomali) return m >= 60 ? '${m ~/ 60} saac ${m % 60} daqiiqo' : '$m daqiiqo';
    return m >= 60 ? '${m ~/ 60} h ${m % 60} min' : '$m min';
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Tx('Sahal Merchant Account')),
      body: s == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _connection(s),
                GroupLabel(tr('Session')),
                _session(s),
                GroupLabel(tr('Account')),
                _account(s),
                if (s.pending != null) ...[
                  GroupLabel(tr('New account')),
                  _pending(s),
                ],
                GroupLabel(tr('Change or connect an account')),
                _form(s),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, key: const Key('account-error'), style: const TextStyle(color: AppColors.statusFailed)),
                ],
                const SizedBox(height: 16),
                Tx(
                  'A new login is never used until it has signed in and read Sahal\'s transactions, and you switch to it. '
                  'The working account, its session and the automatic deposits and withdrawals carry on until then. '
                  'The password and PIN are kept encrypted on the server and are never shown again.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
    );
  }

  Widget _connection(SahalAccountStatus s) {
    final (label, color, icon) = switch (s.connection) {
      'connected' => (tr('Connected'), AppColors.statusCompleted, Icons.check_circle_rounded),
      'authentication_required' => (tr('Authentication required'), AppColors.statusPending, Icons.sms_rounded),
      _ => (tr('Disconnected'), AppColors.statusFailed, Icons.link_off_rounded),
    };
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, key: const Key('account-connection'),
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                    if ((s.feedMessage ?? '').isNotEmpty)
                      Tx(s.feedMessage!, style: TextStyle(color: AppColors.textSecondary)),
                    Text(trp('Last read: {0}', [_time(s.lastReadAt)]),
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('account-check'),
                  onPressed: _busy ? null : () => _do(() => context.read<Session>().api.checkSahalConnection()),
                  icon: const Icon(Icons.wifi_tethering_rounded),
                  label: const Tx('Test connection'),
                ),
              ),
              if (!s.connected) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('account-reconnect'),
                    onPressed: _busy ? null : () => _do(() async {
                      await context.read<Session>().api.merchantFeedSignIn();
                      return context.read<Session>().api.getSahalAccount();
                    }),
                    icon: const Icon(Icons.login_rounded),
                    label: const Tx('Reconnect'),
                  ),
                ),
              ],
            ],
          ),
          if (s.connection == 'authentication_required')
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Tx('Sahal asked for its SMS code. The phone with the SMS forwarder or this app enters it by '
                  'itself; if it does not, type it in Sahal Merchant Sign-in.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }

  Widget _session(SahalAccountStatus s) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.sessionActive ? tr('Session open') : tr('No session open'),
              key: const Key('account-session'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(trp('Last successful login: {0}', [_time(s.lastLoginAt ?? s.sessionStartedAt)]), key: const Key('account-login-time')),
          Text(trp('Last renewal: {0}', [_time(s.lastRenewalAt)]), key: const Key('account-renewal-time')),
          Text(trp('This session is {0} old', [_age(s.sessionAgeSeconds)])),
          const SizedBox(height: 6),
          Tx('Sahal ends a session about every hour and texts a new code each time. The SMS forwarder enters '
              'it by itself when it can.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          SwitchListTile(
            key: const Key('account-renew-idle'),
            contentPadding: EdgeInsets.zero,
            title: const Tx('Renew an idle session by itself'),
            subtitle: const Tx('Off: a new code is asked only when a withdrawal needs the session (fewer SMS codes; '
                'the first withdrawal after an expiry waits a few seconds longer).'),
            value: s.renewIdle,
            onChanged: _busy
                ? null
                : (v) => _do(() async {
                      await context.read<Session>().api.setSahalRenewIdle(v);
                      return context.read<Session>().api.getSahalAccount();
                    }),
          ),
        ],
      ),
    );
  }

  Widget _account(SahalAccountStatus s) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.source == 'database' ? trp('Account: {0}', [s.activeUsername]) : tr('Account: set on the server'),
              key: const Key('account-active'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Tx(s.source == 'database'
              ? trp('Activated here{0}. Password: saved (hidden).', [s.activatedAt != null ? ' ${_time(s.activatedAt)}' : ''])
              : tr('The login is in the server\'s settings. Connect a new account below to manage it from here.'),
              style: TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _pending(SahalAccountStatus s) {
    final p = s.pending!;
    final (label, color) = switch (p.status) {
      'verified' => (tr('Verified: ready to switch to'), AppColors.statusCompleted),
      'failed' => (tr('Test failed'), AppColors.statusFailed),
      'needs_code' => (tr('Code needed'), AppColors.statusPending),
      'testing' || 'logging_in' || 'code_entered' => (tr('Testing…'), AppColors.statusProcessing),
      _ => (tr('Saved: not tested yet'), AppColors.textSecondary),
    };
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(p.username, key: const Key('pending-username'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(label, key: const Key('pending-status'), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          if ((p.message ?? '').isNotEmpty) Tx(p.message!, style: TextStyle(color: AppColors.textSecondary)),
          Text(trp('Password: saved (hidden){0}', [p.hasPin ? tr(' · PIN: saved (hidden)') : tr(' · no PIN (transfers stay off for this account)')]),
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          if (p.needsCode) ...[
            const SizedBox(height: 10),
            TextField(
              key: const Key('pending-code'),
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('SMS code sent to the new account\'s phone'), prefixIcon: Icon(Icons.key_rounded)),
              onSubmitted: (_) => _sendCode(),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const Key('pending-send-code'),
              onPressed: _busy ? null : _sendCode,
              child: const Tx('Authenticate'),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('pending-test'),
                  onPressed: _busy || p.busy ? null : () => _do(() => context.read<Session>().api.testSahalAccount()),
                  child: Tx(p.verified ? tr('Test again') : tr('Test new account')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  key: const Key('pending-activate'),
                  onPressed: _busy || !p.verified ? null : () => _activate(s),
                  child: const Tx('Activate'),
                ),
              ),
            ],
          ),
          TextButton(
            key: const Key('pending-discard'),
            onPressed: _busy ? null : () => _do(() => context.read<Session>().api.discardSahalAccount()),
            child: const Tx('Discard the new login'),
          ),
        ],
      ),
    );
  }

  Widget _form(SahalAccountStatus s) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('account-username'),
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: tr('Sahal merchant login (username or account)'), prefixIcon: Icon(Icons.person_rounded)),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('account-password'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [],
            decoration: InputDecoration(labelText: tr('Password'), prefixIcon: Icon(Icons.lock_rounded)),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('account-pin'),
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: tr('Merchant PIN (needed to send withdrawals)'), prefixIcon: Icon(Icons.pin_rounded)),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('account-save'),
            onPressed: _busy ? null : _save,
            child: const Tx('Save settings'),
          ),
          const SizedBox(height: 6),
          Tx('Saving does not change the working account. Test the new login, then activate it.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
