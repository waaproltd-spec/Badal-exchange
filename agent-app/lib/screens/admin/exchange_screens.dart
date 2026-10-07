import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/exchange.dart';
import '../../payout/exchange_payout_runner.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Exchange (EVC Plus <-> eDahab) management: orders, payment SMS review,
/// and settings (payout wallets, PINs, rates, this phone's automation).

String exchangeStatusLabel(String s) => switch (s) {
      'pending' => 'Waiting for payment',
      'in_progress' => 'Paid, payout pending',
      'completed' => 'Completed',
      'failed' => 'Payout failed',
      'cancelled' => 'Cancelled',
      _ => s,
    };

Color _statusColor(String s) => switch (s) {
      'pending' => AppColors.statusPending,
      'in_progress' => AppColors.statusProcessing,
      'completed' => AppColors.statusCompleted,
      'failed' => AppColors.statusFailed,
      _ => AppColors.statusDuplicate,
    };

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

String _method(String m) => m == 'edahab' ? 'eDahab' : (m == 'evc_plus' ? 'EVC Plus' : m);

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------

class ExchangeOrdersScreen extends StatefulWidget {
  const ExchangeOrdersScreen({super.key});

  @override
  State<ExchangeOrdersScreen> createState() => _ExchangeOrdersScreenState();
}

class _ExchangeOrdersScreenState extends ListScreenState<ExchangeOrdersScreen, ExchangeOrder> {
  String _status = '';
  final _search = TextEditingController();

  @override
  Future<List<ExchangeOrder>> fetch() =>
      api.getExchangeOrders(status: _status.isEmpty ? null : _status, query: _search.text.trim().isEmpty ? null : _search.text.trim());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exchange Orders')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SearchField(hint: 'Order ID or phone', controller: _search, onSubmitted: (_) => load()),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ChoiceChipsRow<String>(
              options: const [
                ('', 'All'),
                ('pending', 'Waiting payment'),
                ('in_progress', 'Payout pending'),
                ('failed', 'Failed'),
                ('completed', 'Completed'),
                ('cancelled', 'Cancelled'),
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
              builder: (orders) => orders.isEmpty
                  ? ListView(children: const [SizedBox(height: 80), EmptyStateView(icon: Icons.swap_horiz_rounded, title: 'No exchange orders')])
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: orders.length,
                      itemBuilder: (_, i) {
                        final o = orders[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ConsoleCard(
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExchangeOrderDetailScreen(id: o.id)));
                              load();
                            },
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('\$${o.amountSent} ${o.fromLabel} → \$${o.amountReceived} ${o.toLabel}',
                                      style: const TextStyle(fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  Text('${o.id} • ${o.senderPhone} → ${o.receiverPhone}',
                                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                                  Text(formatDateTime(o.createdAt), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                                ]),
                              ),
                              _Pill(exchangeStatusLabel(o.status), _statusColor(o.status)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class ExchangeOrderDetailScreen extends StatefulWidget {
  const ExchangeOrderDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<ExchangeOrderDetailScreen> createState() => _ExchangeOrderDetailScreenState();
}

class _ExchangeOrderDetailScreenState extends State<ExchangeOrderDetailScreen> {
  ExchangeOrder? _order;
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
      final o = await _session.api.getExchangeOrder(widget.id);
      if (mounted) setState(() => _order = o);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Failed to load.'));
    }
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
    } finally {
      if (mounted) setState(() => _busy = false);
      _load();
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
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

  Future<void> _verify(ExchangeOrder o) async {
    final ref = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Verify payment by hand'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Only if you can see \$${o.amountSent} from ${o.senderPhone} in the ${o.fromLabel} wallet. '
              'The payout then goes out.'),
          const SizedBox(height: 12),
          TextField(controller: ref, decoration: const InputDecoration(labelText: 'Carrier reference (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Payment received')),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => _session.api.verifyExchangeOrder(o.id, reference: ref.text.trim().isEmpty ? null : ref.text.trim()),
        'Payment verified.');
  }

  Future<void> _retry(ExchangeOrder o) async {
    try {
      setState(() => _busy = true);
      await _session.api.retryExchangePayout(o.id);
      if (mounted) showSnack(context, 'Payout queued again.');
    } on ApiException catch (e) {
      if (e.code != 'CONFIRM_NOT_PAID') {
        if (mounted) showSnack(context, e.message);
      } else if (mounted) {
        final sure = await _confirm(
          'Was the money sent?',
          'The last attempt may have reached the carrier. Check the payout wallet\'s history for '
              '\$${o.amountReceived} to ${o.receiverPhone}. Retry only if it was NOT sent.',
          'It was not sent — retry',
        );
        if (sure) {
          await _act(() => _session.api.retryExchangePayout(o.id, confirmedNotPaid: true), 'Payout queued again.');
          return;
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _load();
    }
  }

  Future<void> _payNow(ExchangeOrder o) async {
    final deviceId = _session.deviceId;
    if (deviceId == null) return;
    if (!await _confirm('Send payout now?',
        'This phone dials \$${o.amountReceived} ${o.toLabel} to ${o.receiverPhone} and enters the wallet PIN.', 'Send')) {
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

  Future<void> _cancel(ExchangeOrder o) async {
    final ok = await _confirm('Cancel this order?',
        o.status == 'pending'
            ? 'The customer has not paid (or it was not matched). The order is closed.'
            : 'The customer\'s payment was received and no payout went out. Refund the customer by hand.',
        'Cancel order');
    if (ok) await _act(() => _session.api.reverseExchangeOrder(o.id, reason: 'Cancelled by agent'), 'Order cancelled.');
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text(widget.id)),
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
                          child: Text('${o.fromLabel} → ${o.toLabel}',
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                        _Pill(exchangeStatusLabel(o.status), _statusColor(o.status)),
                      ]),
                      const SizedBox(height: 8),
                      InfoRow('Customer pays', '\$${o.amountSent} from ${o.senderPhone}'),
                      InfoRow('Fee', '\$${o.fee}'),
                      InfoRow('Payout', '\$${o.amountReceived} to ${o.receiverPhone}'),
                      InfoRow('Paid into', o.collectionPhoneNumber ?? '—'),
                      InfoRow('Payment reference', o.paymentReference ?? '—'),
                      InfoRow('Payment verified', o.paymentVerifiedAt == null ? '—' : formatDateTime(o.paymentVerifiedAt!)),
                      InfoRow('Payout reference', o.payoutReference ?? '—'),
                      if (o.failureReason != null) InfoRow('Problem', o.failureReason!),
                      InfoRow('Created', formatDateTime(o.createdAt)),
                      if (o.completedAt != null) InfoRow('Completed', formatDateTime(o.completedAt!)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  if (_busy) const LinearProgressIndicator(),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (o.status == 'pending')
                      FilledButton.icon(
                          onPressed: _busy ? null : () => _verify(o),
                          icon: const Icon(Icons.verified_rounded),
                          label: const Text('Verify payment')),
                    if (o.status == 'in_progress')
                      FilledButton.icon(
                          onPressed: _busy ? null : () => _payNow(o),
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Send payout from this phone')),
                    if (o.status == 'failed')
                      FilledButton.icon(
                          onPressed: _busy ? null : () => _retry(o),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('Retry payout')),
                    if (o.status == 'pending' || o.status == 'in_progress' || o.status == 'failed')
                      OutlinedButton.icon(
                          onPressed: _busy ? null : () => _cancel(o),
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel order')),
                  ]),
                  if (o.paymentSms != null) ...[
                    const GroupLabel('Payment SMS'),
                    ConsoleCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${o.paymentSms!['sender']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('${o.paymentSms!['body']}'),
                      ]),
                    ),
                  ],
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
                            if (a.step1Response != null) Text('Step 1: ${a.step1Response}'),
                            if (a.step2Response != null) Text('Step 2: ${a.step2Response}'),
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
    final id = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Assign to an order'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Only when you are sure which waiting order this payment belongs to. '
              'That order is then verified and its payout goes out.'),
          const SizedBox(height: 12),
          TextField(controller: id, decoration: const InputDecoration(labelText: 'Exchange order ID (DEX...)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Assign')),
        ],
      ),
    );
    if (ok == true && id.text.trim().isNotEmpty) {
      await run(() => api.resolvePaymentSms(s.id, id.text.trim().toUpperCase()), success: 'Payment assigned.');
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
                            if (s.exchangeOrderId != null || s.orderId != null)
                              Text('Order: ${s.exchangeOrderId ?? s.orderId}',
                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            if (s.receivedAt != null)
                              Text(formatDateTime(s.receivedAt!), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                            if (open && s.amount != null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(onPressed: () => _assign(s), child: const Text('Assign to order')),
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
// Settings: payout wallets, rates, this phone
// ---------------------------------------------------------------------------

class ExchangeSettingsScreen extends StatefulWidget {
  const ExchangeSettingsScreen({super.key});

  @override
  State<ExchangeSettingsScreen> createState() => _ExchangeSettingsScreenState();
}

class _ExchangeSettingsScreenState extends State<ExchangeSettingsScreen> {
  ExchangeSettings? _settings;
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
      final s = await _session.api.getExchangeSettings();
      final d = await _session.payouts.device.status();
      final auto = await ExchangePayoutRunner.autoPayoutEnabled();
      if (mounted) {
        setState(() {
          _settings = s;
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

  Future<void> _editWallet([ExchangePayoutWallet? w]) async {
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
                subtitle: const Text('Payment SMS and payouts for this wallet are handled here'),
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

  Future<void> _setPin(ExchangePayoutWallet w) async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('PIN for ${_method(w.method)} ${w.phoneNumber}'),
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

  Future<void> _editCorridor(ExchangeCorridor c, List<ExchangePayoutWallet> wallets) async {
    final rate = TextEditingController(text: c.rate.toString());
    final fee = TextEditingController(text: c.feeValue);
    final min = TextEditingController(text: c.minAmount ?? '');
    final max = TextEditingController(text: c.maxAmount ?? '');
    var feeType = c.feeType;
    var enabled = c.enabled;
    final options = wallets.where((w) => w.method == c.toMethod).toList();
    String? walletId = options.any((w) => w.id == c.payoutWalletId) ? c.payoutWalletId : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('${_method(c.fromMethod)} → ${_method(c.toMethod)}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Available to customers'),
                value: enabled,
                onChanged: (v) => set(() => enabled = v),
              ),
              TextField(
                  controller: rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Rate (1 = same amount)')),
              DropdownButtonFormField<String>(
                value: feeType,
                decoration: const InputDecoration(labelText: 'Fee type'),
                items: const [
                  DropdownMenuItem(value: 'percentage', child: Text('Percentage')),
                  DropdownMenuItem(value: 'fixed', child: Text('Fixed \$')),
                ],
                onChanged: (v) => set(() => feeType = v ?? feeType),
              ),
              TextField(
                  controller: fee,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Fee')),
              TextField(
                  controller: min,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Minimum \$ (optional)')),
              TextField(
                  controller: max,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Maximum \$ (optional)')),
              DropdownButtonFormField<String?>(
                value: walletId,
                decoration: InputDecoration(labelText: 'Pays out from (${_method(c.toMethod)} wallet)'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— none —')),
                  for (final w in options) DropdownMenuItem(value: w.id, child: Text(w.phoneNumber)),
                ],
                onChanged: (v) => set(() => walletId = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(
      () => _session.api.saveExchangeCorridor(
        c,
        rate: double.tryParse(rate.text.trim()) ?? c.rate,
        feeType: feeType,
        feeValue: double.tryParse(fee.text.trim()) ?? 0,
        minAmount: double.tryParse(min.text.trim()),
        maxAmount: double.tryParse(max.text.trim()),
        payoutWalletId: walletId,
        enabled: enabled,
      ),
      'Exchange saved.',
    );
  }

  Future<void> _setAuto(bool on) async {
    await ExchangePayoutRunner.setAutoPayoutEnabled(on);
    final deviceId = _session.deviceId;
    if (on && deviceId != null) _session.payouts.start(deviceId: deviceId);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final d = _device;
    return Scaffold(
      appBar: AppBar(title: const Text('Exchange Settings')),
      body: s == null
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
                        title: const Text('Automatic payouts'),
                        subtitle: const Text('Pays verified orders whose payout wallet is on this phone, one at a time'),
                        value: _auto,
                        onChanged: _setAuto,
                      ),
                      InfoRow('Accessibility ("Baari exchange payouts")', d?.accessibilityEnabled == true ? 'On' : 'Off'),
                      InfoRow('Phone & call permission', d?.permissionsGranted == true ? 'Granted' : 'Not granted'),
                      Wrap(spacing: 8, children: [
                        if (d?.accessibilityEnabled != true)
                          OutlinedButton(
                            onPressed: () async {
                              await _session.payouts.device.openAccessibilitySettings();
                            },
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
                    const Expanded(child: GroupLabel('Wallets')),
                    TextButton.icon(onPressed: () => _editWallet(), icon: const Icon(Icons.add), label: const Text('Add')),
                  ]),
                  const Text(
                    'The oldest wallet of each kind is the number customers pay into. '
                    'Each exchange pays out from the wallet chosen for it below.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  for (final w in s.payoutWallets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ConsoleCard(
                        onTap: () => _editWallet(w),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${_method(w.method)} ${w.phoneNumber}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                w.deviceId == null
                                    ? 'No phone set'
                                    : '${w.deviceId == _session.deviceId ? 'This phone' : 'Another phone'}'
                                        '${w.simSlot != null ? ', SIM ${w.simSlot}' : ''}',
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                              ),
                            ]),
                          ),
                          TextButton(onPressed: () => _setPin(w), child: Text(w.hasPin ? 'Change PIN' : 'Set PIN')),
                        ]),
                      ),
                    ),
                  const GroupLabel('Exchanges'),
                  for (final c in s.corridors)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ConsoleCard(
                        onTap: () => _editCorridor(c, s.payoutWallets),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${_method(c.fromMethod)} → ${_method(c.toMethod)}',
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                'Rate ${c.rate} • fee ${c.feeType == 'percentage' ? '${c.feeValue}%' : '\$${c.feeValue}'}'
                                '${c.payoutWalletId == null ? ' • no payout wallet' : ''}',
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                              ),
                            ]),
                          ),
                          _Pill(c.enabled ? 'ON' : 'OFF', c.enabled ? AppColors.statusCompleted : AppColors.statusDuplicate),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
