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
import '../../l10n/tr.dart';

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
        child: Tx(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

String _methodLabel(String m) => m == 'edahab' ? 'eDahab' : (m == 'evc_plus' ? 'EVC Plus' : m);

(String, Color) _payoutState(PayoutOrder o) {
  if (o.payoutReview) return (tr('Needs review'), AppColors.statusFailed);
  return switch (o.status) {
    'pending' => (tr('Waiting'), AppColors.statusPending),
    'processing' => (tr('Sending'), AppColors.statusProcessing),
    'completed' => (tr('Paid'), AppColors.statusCompleted),
    'failed' => (tr('Failed, refunded'), AppColors.statusDuplicate),
    _ => (o.status, AppColors.statusDuplicate),
  };
}

Future<bool> _confirm(BuildContext context, String title, String message, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Tx(title),
        content: Tx(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Tx(action)),
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
      tr('Was the money sent?'),
      trp('An automatic payout may have reached the carrier. Check the payout wallet\'s history for \${0} to {1}. Continue only if it was NOT sent.', [amount, phone]),
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
      appBar: AppBar(title: const Tx('Automatic Payouts')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ChoiceChipsRow<bool>(
            options: [(true, tr('Needs review')), (false, tr('All recent'))],
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
                        title: _reviewOnly ? 'Nothing needs review' : tr('No automatic payouts yet')),
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
                                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                                if (o.failureReason != null)
                                  Tx(o.failureReason!, style: const TextStyle(color: AppColors.statusFailed, fontSize: 12)),
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
      if (mounted) setState(() => _error = errorText(e, tr('Failed to load.')));
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
      if (mounted) showSnack(context, errorText(e, tr('Something went wrong.')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _load();
    }
  }

  Future<void> _retry() => _guarded(
        () => _session.api.retryPayout(widget.orderId),
        () => _session.api.retryPayout(widget.orderId, confirmedNotPaid: true),
        tr('Queued for another automatic payout.'),
        tr('It was not sent — retry'),
      );

  Future<void> _fail() async {
    if (!await _confirm(context, tr('Fail and refund?'), tr('The reserved amount goes back to the customer\'s Badal Exchange wallet.'), tr('Fail & refund'))) {
      return;
    }
    await _guarded(
      () => _session.api.failWithdrawal(widget.orderId, reason: tr('Payout not sent (checked by agent)')),
      () => _session.api.failWithdrawal(widget.orderId, reason: tr('Payout not sent (checked by agent)'), confirmedNotPaid: true),
      tr('Withdrawal failed; the customer was refunded.'),
      tr('It was not sent — refund'),
    );
  }

  Future<void> _complete() async {
    final ref = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Tx('Mark as paid'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(trp('Only if the payout wallet\'s history shows \${0} sent to {1}.', [_order!.payoutAmount, _order!.phoneNumber])),
          TextField(controller: ref, decoration: InputDecoration(labelText: tr('Carrier reference'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('It was paid')),
        ],
      ),
    );
    if (ok != true || ref.text.trim().length < 3) return;
    await _guarded(() => _session.api.completeWithdrawal(widget.orderId, transactionRef: ref.text.trim()), () async {},
        tr('Withdrawal completed.'), '');
  }

  Future<void> _payNow() async {
    final deviceId = _session.deviceId;
    final o = _order!;
    if (deviceId == null) return;
    if (!await _confirm(context, tr('Send payout now?'),
        trp('This phone dials \${0} {1} to {2} and enters the wallet PIN.', [o.payoutAmount, o.methodLabel, o.phoneNumber]), tr('Send'))) {
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
      appBar: AppBar(title: Tx(o?.orderCode ?? tr('Payout'))),
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
                          child: Text(trp('Withdrawal {0}', [o.methodLabel]), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                        _Pill(_payoutState(o).$1, _payoutState(o).$2),
                      ]),
                      const SizedBox(height: 8),
                      InfoRow(tr('Customer'), '${o.customerName ?? '—'} ${o.customerPhone ?? ''}'),
                      InfoRow(tr('Amount'), '\$${o.amount}'),
                      InfoRow(tr('Payout'), trp('\${0} to {1}', [o.payoutAmount, o.phoneNumber])),
                      InfoRow(tr('Paid from'), o.payoutWalletPhone ?? tr('No payout wallet set')),
                      InfoRow(tr('Reference'), o.transactionRef ?? '—'),
                      if (o.failureReason != null) InfoRow(tr('Problem'), o.failureReason!),
                      InfoRow(tr('Created'), formatDateTime(o.createdAt)),
                      if (o.completedAt != null) InfoRow(tr('Completed'), formatDateTime(o.completedAt!)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  if (_busy) const LinearProgressIndicator(),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (o.status == 'processing' && o.payoutReview) ...[
                      FilledButton.icon(
                          onPressed: _busy ? null : _retry, icon: const Icon(Icons.replay_rounded), label: const Tx('Retry payout')),
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _complete, icon: const Icon(Icons.verified_rounded), label: const Tx('It was paid')),
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _fail, icon: const Icon(Icons.undo_rounded), label: const Tx('Fail & refund')),
                    ],
                    if ((o.status == 'pending' || (o.status == 'processing' && o.payoutRequested)) && !o.payoutReview)
                      FilledButton.icon(
                          onPressed: _busy ? null : _payNow,
                          icon: const Icon(Icons.send_rounded),
                          label: const Tx('Send payout from this phone')),
                  ]),
                  if (o.dialAttempts.isNotEmpty) ...[
                    GroupLabel(tr('Payout attempts')),
                    for (final a in o.dialAttempts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConsoleCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(trp('Attempt {0}', [a.attemptNumber]), style: const TextStyle(fontWeight: FontWeight.w700))),
                              _Pill(a.status, a.status == 'success' ? AppColors.statusCompleted : AppColors.statusDuplicate),
                            ]),
                            if (a.step1Response != null) Text(trp('Carrier, step 1: {0}', [a.step1Response])),
                            if (a.step2Response != null) Text(trp('Carrier, after PIN: {0}', [a.step2Response])),
                            if (a.createdAt != null)
                              Tx(formatDateTime(a.createdAt!), style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
                          ]),
                        ),
                      ),
                  ],
                  if (o.history.isNotEmpty) ...[
                    GroupLabel(tr('History')),
                    for (final h in o.history)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${formatDateTime(DateTime.tryParse('${h['createdAt']}') ?? DateTime.now())}  ${h['action']}',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
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
        title: const Tx('Assign to a deposit'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(trp('Only when you are sure which pending deposit this \${0} payment belongs to. That customer\'s wallet is credited.', [s.amount])),
          const SizedBox(height: 12),
          TextField(controller: code, decoration: InputDecoration(labelText: tr('Deposit order code'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Assign')),
        ],
      ),
    );
    if (ok == true && code.text.trim().isNotEmpty) {
      await run(() => api.resolvePaymentSms(s.id, code.text.trim()), success: tr('Deposit credited.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Payment SMS')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ChoiceChipsRow<String>(
            options: [
              ('ambiguous', tr('Needs decision')),
              ('unmatched', tr('Unmatched')),
              ('matched', tr('Matched')),
              ('ignored', tr('Unreadable')),
              ('', tr('All')),
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
                ? ListView(children: [SizedBox(height: 80), EmptyStateView(icon: Icons.sms_outlined, title: tr('Nothing here'))])
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
                                child: Tx(
                                  s.amount != null ? '\$${s.amount} from ${s.phone ?? '?'} (${s.provider ?? s.sender})' : s.sender,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              StatusPill(s.matchStatus),
                            ]),
                            const SizedBox(height: 6),
                            Tx(s.body, style: const TextStyle(fontSize: 13)),
                            if (s.reason != null) ...[
                              const SizedBox(height: 4),
                              Tx(s.reason!, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            ],
                            if (s.orderCode != null)
                              Text(trp('Deposit: {0}', [s.orderCode]), style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            if (s.receivedAt != null)
                              Tx(formatDateTime(s.receivedAt!), style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
                            if (open && s.amount != null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(onPressed: () => _assign(s), child: const Tx('Assign to deposit')),
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
  List<AutoPayoutSettings> _safeguards = const [];
  SahalPayoutSettings? _sahal;
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
      final g = await _session.api.getAutoPayouts();
      final d = await _session.payouts.device.status();
      final auto = await PayoutRunner.autoPayoutEnabled();
      // An older server has no Sahal payouts: the rest still shows.
      final sahal = await _session.api.getSahalPayouts().then<SahalPayoutSettings?>((v) => v).catchError((_) => null);
      if (mounted) {
        setState(() {
          _wallets = w;
          _safeguards = g;
          _sahal = sahal;
          _device = d;
          _auto = auto;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Failed to load.')));
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Something went wrong.')));
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
          title: Tx(w == null ? 'Add wallet' : tr('Edit wallet')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButtonFormField<String>(
                value: method,
                decoration: InputDecoration(labelText: tr('Wallet')),
                items: const [
                  DropdownMenuItem(value: 'evc_plus', child: Tx('EVC Plus')),
                  DropdownMenuItem(value: 'edahab', child: Tx('eDahab')),
                ],
                onChanged: (v) => set(() => method = v ?? method),
              ),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: tr('Wallet number (9 digits)')),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Tx('SIM is in this phone'),
                subtitle: const Tx('Its payment SMS are read here and its payouts are sent from here'),
                value: onThisPhone,
                onChanged: (v) => set(() => onThisPhone = v),
              ),
              if (onThisPhone)
                DropdownButtonFormField<int?>(
                  value: slot,
                  decoration: InputDecoration(labelText: tr('SIM slot')),
                  items: const [
                    DropdownMenuItem(value: 1, child: Tx('SIM 1')),
                    DropdownMenuItem(value: 2, child: Tx('SIM 2')),
                  ],
                  onChanged: (v) => set(() => slot = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save')),
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
      tr('Wallet saved.'),
    );
  }

  Future<void> _delete(PayoutWallet w) async {
    if (!await _confirm(context, tr('Remove wallet?'), trp('{0} {1} and its PIN are removed.', [w.methodLabel, w.phoneNumber]), tr('Remove'))) return;
    await _run(() => _session.api.deletePayoutWallet(w.id), tr('Wallet removed.'));
  }

  Future<void> _setPin(PayoutWallet w) async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('PIN for {0} {1}', [w.methodLabel, w.phoneNumber])),
        content: TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: tr('Wallet PIN'), helperText: tr('Stored encrypted; it is never shown again.')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save PIN')),
        ],
      ),
    );
    if (ok == true) await _run(() => _session.api.setPayoutWalletPin(w.id, pin.text.trim()), tr('PIN saved.'));
  }

  Future<void> _setCode(PayoutWallet w) async {
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('*736 code for {0} {1}', [w.methodLabel, w.phoneNumber])),
        content: TextField(
          controller: code,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: tr('*736 code'),
            helperText: tr('The last number in *736*number*amount*CODE#. The PIN is typed after it.\nStored encrypted; it is never shown again.'),
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save code')),
        ],
      ),
    );
    if (ok == true) await _run(() => _session.api.setPayoutWalletUssdCode(w.id, code.text.trim()), tr('*736 code saved.'));
  }

  Future<void> _setMode(AutoPayoutSettings g, String mode) async {
    if (mode == g.mode) return;
    if (mode == 'test' &&
        !await _confirm(
          context,
          trp('Test {0} payouts', [g.methodLabel]),
          trp('Only a \${0} withdrawal is paid automatically in Test mode.\n\n1. Set the {1} minimum withdrawal to \${2} (Payment methods).\n2. From a customer account, withdraw \${3} to your own {4} number.\n3. Keep this phone on with automatic payouts on. It sends the payout; the withdrawal completes when {5} confirms it, and the test passes when its "you transferred" SMS arrives.\n\nThen switch to Live.', [g.testAmount, g.methodLabel, g.testAmount, g.testAmount, g.methodLabel, g.methodLabel]),
          tr('Start test'),
        )) {
      return;
    }
    if (mode == 'live' &&
        !await _confirm(
          context,
          tr('Go live?'),
          trp('Every {0} withdrawal will be sent automatically from {1}, up to \${2} a day, keeping at least \${3} in the wallet.', [g.methodLabel, g.walletPhone ?? 'the payout wallet', g.dailyLimit, g.minBalance]),
          tr('Go live'),
        )) {
      return;
    }
    await _run(() => _session.api.setAutoPayout(g.method, mode: mode),
        mode == 'off' ? 'Automatic ${g.methodLabel} payouts off.' : (mode == 'test' ? 'Test mode on.' : tr('Live.')));
  }

  Future<void> _editLimits(AutoPayoutSettings g) async {
    final daily = TextEditingController(text: g.dailyLimit);
    final min = TextEditingController(text: g.minBalance);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('{0} limits', [g.methodLabel])),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('auto-daily'),
            controller: daily,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: tr('Daily limit (\$)'), helperText: tr('Paid automatically per day')),
          ),
          TextField(
            key: const Key('auto-min'),
            controller: min,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: tr('Minimum balance (\$)'), helperText: tr('Always left in the wallet')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final d = double.tryParse(daily.text.trim());
    final m = double.tryParse(min.text.trim());
    if (d == null || m == null) {
      if (mounted) showSnack(context, tr('Enter amounts in dollars.'));
      return;
    }
    await _run(() => _session.api.setAutoPayout(g.method, dailyLimit: d, minBalance: m), tr('Limits saved.'));
  }

  Future<void> _enterBalance(AutoPayoutSettings g) async {
    final bal = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('{0} wallet balance', [g.methodLabel])),
        content: TextField(
          key: const Key('auto-balance'),
          controller: bal,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: tr('Balance now (\$)'),
            helperText: tr('As the wallet shows it. Its SMS update it after that.'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final b = double.tryParse(bal.text.trim());
    if (b == null) {
      if (mounted) showSnack(context, tr('Enter the balance in dollars.'));
      return;
    }
    await _run(() => _session.api.setPayoutBalance(g.method, b), tr('Balance saved.'));
  }

  Widget _safeguardCard(AutoPayoutSettings g) {
    final help = switch (g.mode) {
      'live' => tr('Every withdrawal is sent automatically within the limits below.'),
      'test' => trp('Only a \${0} test withdrawal is sent automatically.', [g.testAmount]),
      _ => tr('Nothing is sent automatically. Withdrawals wait to be paid by hand.'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        key: Key('auto-${g.method}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Tx(g.methodLabel, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            key: Key('auto-mode-${g.method}'),
            segments: const [
              ButtonSegment(value: 'off', label: Tx('Off')),
              ButtonSegment(value: 'test', label: Tx('Test')),
              ButtonSegment(value: 'live', label: Tx('Live')),
            ],
            selected: {g.mode},
            onSelectionChanged: g.hasWallet || g.mode != 'off' ? (v) => _setMode(g, v.first) : null,
          ),
          const SizedBox(height: 6),
          Tx(g.hasWallet ? help : tr('Add a wallet with a phone and PIN first.'),
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
          InfoRow(tr('Paid today'), trp('\${0} of \${1}', [g.paidToday, g.dailyLimit])),
          InfoRow(tr('Minimum balance'), '\$${g.minBalance}'),
          InfoRow(
            tr('Wallet balance'),
            g.balance == null
                ? tr('Not known yet')
                : '\$${g.balance}${g.balanceSeenAt != null ? ' (${formatDateTime(g.balanceSeenAt!)})' : ''}',
          ),
          InfoRow(trp('\${0} test', [g.testAmount]), g.testPassed ? 'Passed${g.testOrderCode != null ? ' (${g.testOrderCode})' : ''}' : tr('Not passed yet')),
          if (g.liveNeedsRetest)
            const Tx('The payout wallet or phone changed: switch to Test and send a new test.',
                style: TextStyle(color: AppColors.statusFailed)),
          if (g.waiting > 0 && g.heldReason != null)
            Text(trp('{0} waiting · {1}', [g.waiting, g.heldReason]),
                key: Key('auto-held-${g.method}'), style: const TextStyle(color: AppColors.statusPending)),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: () => _editLimits(g), child: const Tx('Limits')),
            if (g.hasWallet) TextButton(onPressed: () => _enterBalance(g), child: const Tx('Enter balance')),
          ]),
        ]),
      ),
    );
  }

  Future<void> _setSahalMode(SahalPayoutSettings g, String mode) async {
    if (mode == g.mode) return;
    if (mode == 'test' &&
        !await _confirm(
          context,
          tr('Test Sahal payouts'),
          trp('Only a \${0} Golis, ZAAD or EVC Plus withdrawal is sent automatically from Sahal in Test mode. While Sahal is on, the phone does not pay EVC Plus withdrawals.\n\n1. Set that method\'s minimum withdrawal to \${1} (Payment methods).\n2. From a customer account, withdraw \${2} by Golis, ZAAD or EVC Plus.\n3. The server sends it from Sahal within a minute and completes the withdrawal.\n\nThen switch to Live. Stop paying these withdrawals by hand from then on.', [g.testAmount, g.testAmount, g.testAmount]),
          tr('Start test'),
        )) {
      return;
    }
    if (mode == 'live' &&
        !await _confirm(
          context,
          tr('Go live?'),
          trp('Every Golis, ZAAD and EVC Plus withdrawal will be sent automatically from Sahal, up to \${0} a day. Do not also pay them by hand.', [g.dailyLimit]),
          tr('Go live'),
        )) {
      return;
    }
    await _run(() => _session.api.setSahalPayouts(mode: mode),
        mode == 'off' ? 'Sahal payouts off.' : (mode == 'test' ? 'Test mode on.' : tr('Live.')));
  }

  Future<void> _editSahalLimit(SahalPayoutSettings g) async {
    final daily = TextEditingController(text: g.dailyLimit);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Tx('Sahal daily limit'),
        content: TextField(
          key: const Key('sahal-daily'),
          controller: daily,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('Daily limit (\$)'), helperText: tr('Sent from Sahal per day')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Tx('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Tx('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final d = double.tryParse(daily.text.trim());
    if (d == null) {
      if (mounted) showSnack(context, tr('Enter the amount in dollars.'));
      return;
    }
    await _run(() => _session.api.setSahalPayouts(dailyLimit: d), tr('Limit saved.'));
  }

  Widget _sahalCard(SahalPayoutSettings g) {
    final help = switch (g.mode) {
      'live' => tr('Every Golis, ZAAD and EVC Plus withdrawal is sent from Sahal by the server, within the daily limit.'),
      'test' => trp('Only a \${0} Golis, ZAAD or EVC Plus withdrawal is sent from Sahal.', [g.testAmount]),
      _ => tr('Nothing is sent from Sahal automatically.'),
    };
    String label(String s) => switch (s) {
          'success' => 'sent',
          'failed' => 'refused',
          'ambiguous' => 'unclear: check Sahal',
          _ => 'sending',
        };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        key: const Key('auto-sahal'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Tx('Golis, ZAAD & EVC Plus (from Sahal)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            key: const Key('auto-mode-sahal'),
            segments: const [
              ButtonSegment(value: 'off', label: Tx('Off')),
              ButtonSegment(value: 'test', label: Tx('Test')),
              ButtonSegment(value: 'live', label: Tx('Live')),
            ],
            selected: {g.mode},
            onSelectionChanged: (v) => _setSahalMode(g, v.first),
          ),
          const SizedBox(height: 6),
          Tx(help, style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
          InfoRow(tr('Sent today'), trp('\${0} of \${1}', [g.paidToday, g.dailyLimit])),
          InfoRow(
            tr('Sahal balance'),
            g.balance == null
                ? tr('Not read yet')
                : '\$${g.balance}${g.balanceSeenAt != null ? ' (${formatDateTime(g.balanceSeenAt!)})' : ''}',
          ),
          if (g.needsBalance > 0)
            Text(trp('{0} waiting for more Sahal balance: top up Sahal and they go out.', [g.needsBalance]),
                key: const Key('sahal-needs-balance'), style: const TextStyle(color: AppColors.statusPending)),
          InfoRow(trp('\${0} test', [g.testAmount]), g.testPassed ? 'Passed' : tr('Not passed yet')),
          if (g.waiting > 0) InfoRow(tr('Waiting'), '${g.waiting}'),
          if (g.unclear > 0)
            Text(trp('{0} transfer(s) without a clear answer: check them in Sahal before paying again.', [g.unclear]),
                style: const TextStyle(color: AppColors.statusFailed)),
          for (final a in g.recent.take(5)) ...[
            Text(
              '${a.orderCode} · \$${a.amount} → ${a.receiver}${a.receiverName != null ? ' (${a.receiverName})' : ''} · '
              '${label(a.status)}${a.transferId != null ? ' · ${a.transferId}' : ''}'
              '${a.status == 'failed' && a.reply != null ? ' · ${a.reply}' : ''}',
              style: const TextStyle(fontSize: 12.5),
            ),
            if (a.canRetry)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: Key('sahal-retry-${a.orderCode}'),
                  onPressed: () => _run(() => _session.api.retrySahalPayout(a.orderId!), trp('{0} will be sent again.', [a.orderCode])),
                  child: const Tx('Try again'),
                ),
              ),
          ],
          Wrap(spacing: 8, children: [
            TextButton(onPressed: () => _editSahalLimit(g), child: const Tx('Limit')),
          ]),
        ]),
      ),
    );
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
      appBar: AppBar(title: const Tx('Wallets & Auto Payout')),
      body: wallets == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  GroupLabel(tr('This phone')),
                  ConsoleCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Tx('Automatic withdrawal payouts'),
                        subtitle: const Tx('Pays EVC Plus / eDahab withdrawals whose payout wallet is on this phone, one at a time'),
                        value: _auto,
                        onChanged: _setAuto,
                      ),
                      InfoRow(tr('Accessibility ("Badal Exchange payouts")'), d?.accessibilityEnabled == true ? 'On' : tr('Off')),
                      InfoRow(tr('Phone & call permission'), d?.permissionsGranted == true ? 'Granted' : tr('Not granted')),
                      Wrap(spacing: 8, children: [
                        if (d?.accessibilityEnabled != true)
                          OutlinedButton(
                            onPressed: () => _session.payouts.device.openAccessibilitySettings(),
                            child: const Tx('Open Accessibility'),
                          ),
                        if (d?.permissionsGranted != true)
                          OutlinedButton(
                            onPressed: () async {
                              await Permission.phone.request();
                              _load();
                            },
                            child: const Tx('Grant permission'),
                          ),
                      ]),
                    ]),
                  ),
                  GroupLabel(tr('Automatic payout safeguards')),
                  for (final g in _safeguards) _safeguardCard(g),
                  if (_sahal != null) _sahalCard(_sahal!),
                  Row(children: [
                    Expanded(child: GroupLabel(tr('Badal Exchange wallets'))),
                    TextButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Tx('Add')),
                  ]),
                  Tx(
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
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${_methodLabel(w.method)} ${w.phoneNumber}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              Tx(
                                [
                                  w.deviceId == null
                                      ? tr('No phone set')
                                      : '${w.deviceId == _session.deviceId ? 'This phone' : 'Another phone'}'
                                          '${w.simSlot != null ? ', SIM ${w.simSlot}' : ''}',
                                  if (w.paysWithdrawals) 'pays withdrawals',
                                ].join(' • '),
                                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                              ),
                              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                                TextButton(onPressed: () => _setPin(w), child: Tx(w.hasPin ? 'Change PIN' : tr('Set PIN'))),
                                if (w.method == 'evc_plus')
                                  TextButton(
                                      onPressed: () => _setCode(w), child: Tx(w.hasCode ? 'Change *736 code' : tr('Set *736 code'))),
                                IconButton(
                                    tooltip: tr('Remove'),
                                    onPressed: () => _delete(w),
                                    icon: const Icon(Icons.delete_outline_rounded)),
                              ]),
                            ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
