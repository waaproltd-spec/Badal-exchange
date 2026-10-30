import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/payment_numbers.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';

String _err(Object e, String fallback) => e is ApiException ? e.message : fallback;

String _networks(List<String> methods) => methods.map(paymentNumberNetworkLabel).join(', ');

/// Customer Payment Numbers: which customers an admin has authorized to use
/// another phone number (not the registered one) to send money and to receive
/// withdrawals, on EVC Plus, Golis, ZAAD and eDahab. Everyone else keeps the
/// registered-number rule; the server enforces it on every deposit and
/// withdrawal.
class PaymentNumbersScreen extends StatefulWidget {
  const PaymentNumbersScreen({super.key});

  @override
  State<PaymentNumbersScreen> createState() => _PaymentNumbersScreenState();
}

class _PaymentNumbersScreenState extends State<PaymentNumbersScreen> {
  static const _filters = [('all', 'All'), ('authorized', 'Authorized'), ('revoked', 'Revoked')];

  String _filter = 'all';
  final _search = TextEditingController();
  List<PaymentNumberCustomer>? _customers;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _customers == null;
      _error = null;
    });
    try {
      final r = await context.read<Session>().api.getPaymentNumberCustomers(query: _search.text.trim(), filter: _filter);
      if (!mounted) return;
      setState(() {
        _customers = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e, 'Could not load the customers.');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Payment Numbers')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null && _customers == null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : ListView(
                    key: const Key('payment-numbers-list'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      const ConsoleCard(
                        child: Text(
                          'An authorized customer can send money from, and receive withdrawals to, a new phone number on EVC Plus, '
                          'Golis, ZAAD and eDahab. Everyone else keeps using their registered number.',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ChoiceChipsRow<String>(
                        options: [for (final f in _filters) (f.$1, f.$2)],
                        selected: _filter,
                        onSelected: (f) {
                          setState(() => _filter = f);
                          _load();
                        },
                      ),
                      const SizedBox(height: 10),
                      SearchField(hint: 'Search by name, phone or account ID…', controller: _search, onSubmitted: (_) => _load()),
                      const SizedBox(height: 10),
                      if (_customers!.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: EmptyStateView(icon: Icons.phone_in_talk_rounded, title: 'No customers', message: 'Nobody matches this filter.'),
                        )
                      else
                        for (final c in _customers!)
                          Padding(
                            key: Key('payment-number-row-${c.id}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ConsoleCard(
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerPaymentNumbersScreen(customerId: c.id)));
                                if (mounted) _load();
                              },
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Expanded(child: Text(c.name.isEmpty ? '+${c.phone}' : c.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                                  _Pill(c.enabled ? 'Authorized' : 'Not authorized', c.enabled ? AppColors.statusCompleted : AppColors.textSecondary),
                                ]),
                                Text('+${c.phone} · ${c.accountId}', style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                                if (c.enabled) Text(_networks(c.methods), style: const TextStyle(fontSize: 12.5)),
                                if (c.numberCount > 0)
                                  Text('${c.numberCount} number${c.numberCount == 1 ? '' : 's'} on file',
                                      style: const TextStyle(fontSize: 12.5, color: AppColors.textFaint)),
                              ]),
                            ),
                          ),
                    ],
                  )),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );
}

/// One customer: grant or revoke the permission (and which networks), and see,
/// add, block or remove their numbers.
class CustomerPaymentNumbersScreen extends StatefulWidget {
  const CustomerPaymentNumbersScreen({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerPaymentNumbersScreen> createState() => _CustomerPaymentNumbersScreenState();
}

class _CustomerPaymentNumbersScreenState extends State<CustomerPaymentNumbersScreen> {
  CustomerPaymentNumbers? _data;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _actionError;
  final _networksPicked = <String>{};
  final _phone = TextEditingController();
  final _label = TextEditingController();
  String _newMethod = 'evc_plus';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Session>().api.getCustomerPaymentNumbers(widget.customerId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _networksPicked
          ..clear()
          ..addAll(d.access.enabled ? d.access.methods : [for (final n in paymentNumberNetworks) n.$1]);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e, 'Could not load this customer.');
        _loading = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String fallback) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = _err(e, fallback));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            TextButton(key: const Key('confirm-action'), onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final api = context.read<Session>().api;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment numbers')),
      body: _loading
          ? const LoadingView()
          : (d == null
              ? ErrorStateView(message: _error ?? 'Could not load this customer.', onRetry: _load)
              : ListView(
                  key: const Key('customer-payment-numbers'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    ConsoleCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d.name.isEmpty ? '+${d.phone}' : d.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text('Registered number: +${d.phone} · ${d.accountId}', style: const TextStyle(color: AppColors.textSecondary)),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    ConsoleCard(
                      key: const Key('payment-number-access'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          const Expanded(child: Text('Can use another number', style: TextStyle(fontWeight: FontWeight.w800))),
                          _Pill(d.access.enabled ? 'Authorized' : 'Not authorized', d.access.enabled ? AppColors.statusCompleted : AppColors.textSecondary),
                        ]),
                        const SizedBox(height: 4),
                        Text(
                          d.access.enabled
                              ? 'The customer can send money from, and receive withdrawals to, a new number on the networks below.'
                              : 'The customer must use the registered number.',
                          style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, children: [
                          for (final n in paymentNumberNetworks)
                            FilterChip(
                              key: Key('network-${n.$1}'),
                              label: Text(n.$2),
                              selected: _networksPicked.contains(n.$1),
                              onSelected: _busy
                                  ? null
                                  : (v) => setState(() => v ? _networksPicked.add(n.$1) : _networksPicked.remove(n.$1)),
                            ),
                        ]),
                        if (_actionError != null) ...[
                          const SizedBox(height: 8),
                          Text(_actionError!, key: const Key('payment-number-error'), style: const TextStyle(color: AppColors.statusFailed)),
                        ],
                        const SizedBox(height: 12),
                        ElevatedButton(
                          key: const Key('grant-access'),
                          onPressed: _busy || _networksPicked.isEmpty
                              ? null
                              : () => _run(
                                  () => api.setPaymentNumberAccess(d.id, enabled: true, methods: _networksPicked.toList()),
                                  'Could not save.'),
                          child: Text(d.access.enabled ? 'Save networks' : 'Authorize this customer'),
                        ),
                        if (d.access.enabled)
                          TextButton(
                            key: const Key('revoke-access'),
                            onPressed: _busy
                                ? null
                                : () async {
                                    if (await _confirm('Revoke permission?', 'From now on this customer must use their registered number again. Their numbers stay on file.', 'Revoke')) {
                                      await _run(() => api.setPaymentNumberAccess(d.id, enabled: false), 'Could not revoke.');
                                    }
                                  },
                            child: const Text('Revoke permission', style: TextStyle(color: AppColors.statusFailed)),
                          ),
                        if (!d.access.enabled && d.access.revokedAt != null)
                          Text('Revoked ${formatDateTime(d.access.revokedAt!)}${d.access.revokedBy == null ? '' : ' by ${d.access.revokedBy}'}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                        if (d.access.enabled && d.access.grantedAt != null)
                          Text('Authorized ${formatDateTime(d.access.grantedAt!)}${d.access.grantedBy == null ? '' : ' by ${d.access.grantedBy}'}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    const Text('Numbers on file', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    if (d.numbers.isEmpty)
                      const Text('No numbers yet.', key: Key('no-numbers'), style: TextStyle(color: AppColors.textSecondary))
                    else
                      for (final n in d.numbers)
                        Padding(
                          key: Key('number-${n.id}'),
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ConsoleCard(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('+${n.phone} · ${paymentNumberNetworkLabel(n.method)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text(
                                    '${n.label == null ? '' : '${n.label} · '}added by the ${n.addedBy} · used ${n.uses} time${n.uses == 1 ? '' : 's'}'
                                    '${n.lastUsedAt == null ? '' : ' · last ${formatDateTime(n.lastUsedAt!)}'}',
                                    style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                                  ),
                                  if (n.blocked) const Text('Blocked', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.statusFailed)),
                                ]),
                              ),
                              TextButton(
                                key: Key('block-${n.id}'),
                                onPressed: _busy ? null : () => _run(() => api.setPaymentNumberBlocked(n.id, !n.blocked), 'Could not change the number.'),
                                child: Text(n.blocked ? 'Unblock' : 'Block'),
                              ),
                              IconButton(
                                key: Key('remove-${n.id}'),
                                tooltip: 'Remove',
                                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.statusFailed),
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        if (await _confirm('Remove number?', '+${n.phone} is taken off this customer\'s list.', 'Remove')) {
                                          await _run(() => api.removePaymentNumber(n.id), 'Could not remove the number.');
                                        }
                                      },
                              ),
                            ]),
                          ),
                        ),
                    const SizedBox(height: 10),
                    ConsoleCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('Add a number', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          key: const Key('new-number-network'),
                          value: _newMethod,
                          decoration: const InputDecoration(labelText: 'Network'),
                          items: [for (final n in paymentNumberNetworks) DropdownMenuItem(value: n.$1, child: Text(n.$2))],
                          onChanged: (v) => setState(() => _newMethod = v ?? _newMethod),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('new-number-phone'),
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone number', hintText: '61xxxxxxx or 252…'),
                        ),
                        const SizedBox(height: 8),
                        TextField(key: const Key('new-number-label'), controller: _label, decoration: const InputDecoration(labelText: 'Label (optional)')),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          key: const Key('add-number'),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                    await api.addPaymentNumber(d.id,
                                        method: _newMethod, phone: _phone.text.trim(), label: _label.text.trim().isEmpty ? null : _label.text.trim());
                                    _phone.clear();
                                    _label.clear();
                                  }, 'Could not add the number.'),
                          child: const Text('Add number'),
                        ),
                      ]),
                    ),
                  ],
                )),
    );
  }
}
