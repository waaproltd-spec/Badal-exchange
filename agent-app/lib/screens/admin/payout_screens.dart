import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/payout.dart';
import '../../payout/payout_runner.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Dalab-Reseller-style payments: automatic withdrawal payouts from the agent
/// phone, payment SMS review for deposits, and Baari's wallets on the phone.

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.13), borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

String _methodLabel(String m) => m == 'edahab' ? 'eDahab' : (m == 'evc_plus' ? 'EVC Plus' : m);

(String, Color) _payoutState(PayoutOrder o) {
  if (o.payoutReview) return ('Needs review', AppColors.statusFailed);
  return switch (o.status) {
    'pending' => ('Waiting', AppColors.statusPending),
    'processing' => ('Sending', AppColors.statusProcessing),
    'completed' => ('Paid', AppColors.statusCompleted),
    'failed' => ('Failed, refunded', AppColors.statusDuplicate),
    _ => (o.status, AppColors.statusDuplicate),
  };
}

Future<bool> _confirm(BuildContext context, String title, String message, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

/// Asks the agent to confirm the money did NOT go out (after checking the
/// payout wallet's history), for actions that would otherwise risk paying
/// twice or refunding money that was sent.
Future<bool> confirmNotPaid(BuildContext context, {required String amount, required String phone, required String action}) =>
    _confirm(
      context,
      'Was the money sent?',
      'An automatic payout may have reached the carrier. Check the payout wallet\'s history for '
          '\$$amount to $phone. Continue only if it was NOT sent.',
      action,
    );

// ---------------------------------------------------------------------------
// Payouts
// ---------------------------------------------------------------------------

class PayoutsScreen extends StatefulWidget {
  const PayoutsScreen({super.key});

  @override
  State<PayoutsScreen> createState() => _PayoutsScreenState();
}

class _PayoutsScreenState extends ListScreenState<PayoutsScreen, PayoutOrder> {
  bool _reviewOnly = true;

  @override
  Future<List<PayoutOrder>> fetch() => api.getPayouts(reviewOnly: _reviewOnly);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Automatic Payouts')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ChoiceChipsRow<bool>(
            options: const [(true, 'Needs review'), (false, 'All recent')],
            selected: _reviewOnly,
            onSelected: (v) {
              setState(() => _reviewOnly = v);
              load();
            },
          ),
        ),
        Expanded(
          child: body(
            builder: (list) => list.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    EmptyStateView(
                        icon: Icons.check_circle_outline_rounded,
                        title: _reviewOnly ? 'Nothing needs review' : 'No automatic payouts yet'),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final o = list[i];
                      final (label, color) = _payoutState(o);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConsoleCard(
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayoutDetailScreen(orderId: o.id)));
                            load();
                          },
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('\$${o.payoutAmount} ${o.methodLabel} → ${o.phoneNumber}',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Text('${o.orderCode} • ${o.customerName ?? ''}',
                                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                                if (o.failureReason != null)
                                  Text(o.failureReason!, style: const TextStyle(color: AppColors.statusFailed, fontSize: 12)),
                              ]),
                            ),
                            _Pill(label, color),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class PayoutDetailScreen extends StatefulWidget {
  const PayoutDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<PayoutDetailScreen> createState() => _PayoutDetailScreenState();
}

class _PayoutDetailScreenState extends State<PayoutDetailScreen> {
  PayoutOrder? _order;
  String? _error;
  bool _busy = false;

  Session get _session => context.read<Session>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await _session.api.getPayout(widget.orderId);
      if (mounted) setState(() => _order = o);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Failed to load.'));
    }
  }

  /// Runs [action]; on CONFIRM_NOT_PAID asks the agent and runs
  /// [confirmed] instead.
  Future<void> _guarded(Future<void> Function() action, Future<void> Function() confirmed, String success, String confirmLabel) async {
    final o = _order!;
    setState(() => _busy = true);
    try {
      try {
        await action();
      } on ApiException catch (e) {
        if (e.code != 'CONFIRM_NOT_PAID' || !mounted) rethrow;
        if (!await confirmNotPaid(context, amount: o.payoutAmount, phone: o.phoneNumber, action: confirmLabel)) return;
        await confirmed();
      }
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
    } finally {
      if (mounted) setState(() => _busy = false);
      _load();
    }
  }

  Future<void> _retry() => _guarded(
        () => _session.api.retryPayout(widget.orderId),
        () => _session.api.retryPayout(widget.orderId, confirmedNotPaid: true),
        'Queued for another automatic payout.',
        'It was not sent — retry',
      );

  Future<void> _fail() async {
    if (!await _confirm(context, 'Fail and refund?', 'The reserved amount goes back to the customer\'s Baari wallet.', 'Fail & refund')) {
      return;
    }
    await _guarded(
      () => _session.api.failWithdrawal(widget.orderId, reason: 'Payout not sent (checked by agent)'),
      () => _session.api.failWithdrawal(widget.orderId, reason: 'Payout not sent (checked by agent)', confirmedNotPaid: true),
      'Withdrawal failed; the customer was refunded.',
      'It was not sent — refund',
    );
  }

  Future<void> _complete() async {
    final ref = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark as paid'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Only if the payout wallet\'s history shows \$${_order!.payoutAmount} sent to ${_order!.phoneNumber}.'),
          TextField(controller: ref, decoration: const InputDecoration(labelText: 'Carrier reference')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('It was paid')),
        ],
      ),
    );
    if (ok != true || ref.text.trim().length < 3) return;
    await _guarded(() => _session.api.completeWithdrawal(widget.orderId, transactionRef: ref.text.trim()), () async {},
        'Withdrawal completed.', '');
  }

  Future<void> _payNow() async {
    final deviceId = _session.deviceId;
    final o = _order!;
    if (deviceId == null) return;
    if (!await _confirm(context, 'Send payout now?',
        'This phone dials \$${o.payoutAmount} ${o.methodLabel} to ${o.phoneNumber} and enters the wallet PIN.', 'Send')) {
      return;
    }
    setState(() => _busy = true);
    final result = await _session.payouts.payOrder(o, deviceId: deviceId);
    if (mounted) {
      setState(() => _busy = false);
      showSnack(context, result.message);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text(o?.orderCode ?? 'Payout')),
      body: o == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ConsoleCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('Withdrawal ${o.methodLabel}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                        _Pill(_payoutState(o).$1, _payoutState(o).$2),
                      ]),
                      const SizedBox(height: 8),
                      InfoRow('Customer', '${o.customerName ?? '—'} ${o.customerPhone ?? ''}'),
                      InfoRow('Amount', '\$${o.amount}'),
                      InfoRow('Payout', '\$${o.payoutAmount} to ${o.phoneNumber}'),
                      InfoRow('Paid from', o.payoutWalletPhone ?? 'No payout wallet set'),
                      InfoRow('Reference', o.transactionRef ?? '—'),
                      if (o.failureReason != null) InfoRow('Problem', o.failureReason!),
                      InfoRow('Created', formatDateTime(o.createdAt)),
                      if (o.completedAt != null) InfoRow('Completed', formatDateTime(o.completedAt!)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  if (_busy) const LinearProgressIndicator(),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (o.status == 'processing' && o.payoutReview) ...[
                      FilledButton.icon(
                          onPressed: _busy ? null : _retry, icon: const Icon(Icons.replay_rounded), label: const Text('Retry payout')),
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _complete, icon: const Icon(Icons.verified_rounded), label: const Text('It was paid')),
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _fail, icon: const Icon(Icons.undo_rounded), label: const Text('Fail & refund')),
                    ],
                    if ((o.status == 'pending' || (o.status == 'processing' && o.payoutRequested)) && !o.payoutReview)
                      FilledButton.icon(
                          onPressed: _busy ? null : _payNow,
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Send payout from this phone')),
                  ]),
                  if (o.dialAttempts.isNotEmpty) ...[
                    const GroupLabel('Payout attempts'),
                    for (final a in o.dialAttempts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConsoleCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text('Attempt ${a.attemptNumber}', style: const TextStyle(fontWeight: FontWeight.w700))),
                              _Pill(a.status, a.status == 'success' ? AppColors.statusCompleted : AppColors.statusDuplicate),
                            ]),
                            if (a.step1Response != null) Text('Carrier, step 1: ${a.step1Response}'),
                            if (a.step2Response != null) Text('Carrier, after PIN: ${a.step2Response}'),
                            if (a.createdAt != null)
                              Text(formatDateTime(a.createdAt!), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                          ]),
                        ),
                      ),
                  ],
                  if (o.history.isNotEmpty) ...[
                    const GroupLabel('History'),
                    for (final h in o.history)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${formatDateTime(DateTime.tryParse('${h['createdAt']}') ?? DateTime.now())}  ${h['action']}',
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Payment SMS review
// ---------------------------------------------------------------------------

class PaymentSmsReviewScreen extends StatefulWidget {
  const PaymentSmsReviewScreen({super.key});

  @override
  State<PaymentSmsReviewScreen> createState() => _PaymentSmsReviewScreenState();
}

class _PaymentSmsReviewScreenState extends ListScreenState<PaymentSmsReviewScreen, PaymentSmsLog> {
  String _status = 'ambiguous';

  @override
  Future<List<PaymentSmsLog>> fetch() => api.getPaymentSms(status: _status.isEmpty ? null : _status);

  Future<void> _assign(PaymentSmsLog s) async {
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Assign to a deposit'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Only when you are sure which pending deposit this \$${s.amount} payment belongs to. '
              'That customer\'s wallet is credited.'),
          const SizedBox(height: 12),
          TextField(controller: code, decoration: const InputDecoration(labelText: 'Deposit order code')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Assign')),
        ],
      ),
    );
    if (ok == true && code.text.trim().isNotEmpty) {
      await run(() => api.resolvePaymentSms(s.id, code.text.trim()), success: 'Deposit credited.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment SMS')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ChoiceChipsRow<String>(
            options: const [
              ('ambiguous', 'Needs decision'),
              ('unmatched', 'Unmatched'),
              ('matched', 'Matched'),
              ('ignored', 'Unreadable'),
              ('', 'All'),
            ],
            selected: _status,
            onSelected: (v) {
              setState(() => _status = v);
              load();
            },
          ),
        ),
        Expanded(
          child: body(
            builder: (list) => list.isEmpty
                ? ListView(children: const [SizedBox(height: 80), EmptyStateView(icon: Icons.sms_outlined, title: 'Nothing here')])
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final s = list[i];
                      final open = s.matchStatus == 'ambiguous' || s.matchStatus == 'unmatched';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConsoleCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(
                                child: Text(
                                  s.amount != null ? '\$${s.amount} from ${s.phone ?? '?'} (${s.provider ?? s.sender})' : s.sender,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              StatusPill(s.matchStatus),
                            ]),
                            const SizedBox(height: 6),
                            Text(s.body, style: const TextStyle(fontSize: 13)),
                            if (s.reason != null) ...[
                              const SizedBox(height: 4),
                              Text(s.reason!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            ],
                            if (s.orderCode != null)
                              Text('Deposit: ${s.orderCode}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            if (s.receivedAt != null)
                              Text(formatDateTime(s.receivedAt!), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                            if (open && s.amount != null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(onPressed: () => _assign(s), child: const Text('Assign to deposit')),
                              ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Wallets on the agent phone + this phone's automation
// ---------------------------------------------------------------------------

class PayoutSettingsScreen extends StatefulWidget {
  const PayoutSettingsScreen({super.key});

  @override
  State<PayoutSettingsScreen> createState() => _PayoutSettingsScreenState();
}

class _PayoutSettingsScreenState extends State<PayoutSettingsScreen> {
  List<PayoutWallet>? _wallets;
  String? _error;
  PayoutDeviceStatus? _device;
  bool _auto = false;

  Session get _session => context.read<Session>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final w = await _session.api.getPayoutWallets();
      final d = await _session.payouts.device.status();
      final auto = await PayoutRunner.autoPayoutEnabled();
      if (mounted) {
        setState(() {
          _wallets = w;
          _device = d;
          _auto = auto;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Failed to load.'));
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
    }
    _load();
  }

  Future<void> _edit([PayoutWallet? w]) async {
    final phone = TextEditingController(text: w?.phoneNumber ?? '');
    var method = w?.method ?? 'evc_plus';
    var onThisPhone = w == null || (w.deviceId != null && w.deviceId == _session.deviceId);
    int? slot = w?.simSlot ?? 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(w == null ? 'Add wallet' : 'Edit wallet'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(labelText: 'Wallet'),
                items: const [
                  DropdownMenuItem(value: 'evc_plus', child: Text('EVC Plus')),
                  DropdownMenuItem(value: 'edahab', child: Text('eDahab')),
                ],
                onChanged: (v) => set(() => method = v ?? method),
              ),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Wallet number (9 digits)'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('SIM is in this phone'),
                subtitle: const Text('Its payment SMS are read here and its payouts are sent from here'),
                value: onThisPhone,
                onChanged: (v) => set(() => onThisPhone = v),
              ),
              if (onThisPhone)
                DropdownButtonFormField<int?>(
                  value: slot,
                  decoration: const InputDecoration(labelText: 'SIM slot'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('SIM 1')),
                    DropdownMenuItem(value: 2, child: Text('SIM 2')),
                  ],
                  onChanged: (v) => set(() => slot = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(
      () => _session.api.savePayoutWallet(
        id: w?.id,
        method: method,
        phoneNumber: phone.text.trim(),
        deviceId: onThisPhone ? _session.deviceId : null,
        simSlot: onThisPhone ? slot : null,
      ),
      'Wallet saved.',
    );
  }

  Future<void> _delete(PayoutWallet w) async {
    if (!await _confirm(context, 'Remove wallet?', '${w.methodLabel} ${w.phoneNumber} and its PIN are removed.', 'Remove')) return;
    await _run(() => _session.api.deletePayoutWallet(w.id), 'Wallet removed.');
  }

  Future<void> _setPin(PayoutWallet w) async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('PIN for ${w.methodLabel} ${w.phoneNumber}'),
        content: TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Wallet PIN', helperText: 'Stored encrypted; it is never shown again.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save PIN')),
        ],
      ),
    );
    if (ok == true) await _run(() => _session.api.setPayoutWalletPin(w.id, pin.text.trim()), 'PIN saved.');
  }

  Future<void> _setAuto(bool on) async {
    await PayoutRunner.setAutoPayoutEnabled(on);
    final deviceId = _session.deviceId;
    if (on && deviceId != null) _session.payouts.start(deviceId: deviceId);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final wallets = _wallets;
    final d = _device;
    return Scaffold(
      appBar: AppBar(title: const Text('Wallets & Auto Payout')),
      body: wallets == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  const GroupLabel('This phone'),
                  ConsoleCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Automatic withdrawal payouts'),
                        subtitle: const Text('Pays EVC Plus / eDahab withdrawals whose payout wallet is on this phone, one at a time'),
                        value: _auto,
                        onChanged: _setAuto,
                      ),
                      InfoRow('Accessibility ("Baari payouts")', d?.accessibilityEnabled == true ? 'On' : 'Off'),
                      InfoRow('Phone & call permission', d?.permissionsGranted == true ? 'Granted' : 'Not granted'),
                      Wrap(spacing: 8, children: [
                        if (d?.accessibilityEnabled != true)
                          OutlinedButton(
                            onPressed: () => _session.payouts.device.openAccessibilitySettings(),
                            child: const Text('Open Accessibility'),
                          ),
                        if (d?.permissionsGranted != true)
                          OutlinedButton(
                            onPressed: () async {
                              await Permission.phone.request();
                              _load();
                            },
                            child: const Text('Grant permission'),
                          ),
                      ]),
                    ]),
                  ),
                  Row(children: [
                    const Expanded(child: GroupLabel('Baari wallets')),
                    TextButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Add')),
                  ]),
                  const Text(
                    'Deposit SMS for a wallet only count when they arrive on its phone and SIM. '
                    'Withdrawals are paid from the oldest wallet of each kind that has a phone and a PIN.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  for (final w in wallets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ConsoleCard(
                        onTap: () => _edit(w),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${_methodLabel(w.method)} ${w.phoneNumber}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                [
                                  w.deviceId == null
                                      ? 'No phone set'
                                      : '${w.deviceId == _session.deviceId ? 'This phone' : 'Another phone'}'
                                          '${w.simSlot != null ? ', SIM ${w.simSlot}' : ''}',
                                  if (w.paysWithdrawals) 'pays withdrawals',
                                ].join(' • '),
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                              ),
                            ]),
                          ),
                          TextButton(onPressed: () => _setPin(w), child: Text(w.hasPin ? 'Change PIN' : 'Set PIN')),
                          IconButton(
                              tooltip: 'Remove', onPressed: () => _delete(w), icon: const Icon(Icons.delete_outline_rounded)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
