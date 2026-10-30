import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/kyc.dart';
import '../../models/withdraw_limits.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'kyc_screens.dart';

String _err(Object e, String fallback) => e is ApiException ? e.message : fallback;

String _kyc(String status) => kycStatusLabels[status] ?? (status == 'not_submitted' ? 'No KYC' : status);

/// Customer Withdrawal Limits: the four default limits (verified / unverified,
/// daily / monthly), and every customer with KYC status, what they withdrew
/// today and this month, and what is left. Only management can change them;
/// the server enforces them on every withdrawal.
class WithdrawLimitsScreen extends StatefulWidget {
  const WithdrawLimitsScreen({super.key});

  @override
  State<WithdrawLimitsScreen> createState() => _WithdrawLimitsScreenState();
}

class _WithdrawLimitsScreenState extends State<WithdrawLimitsScreen> {
  static const _filters = [
    ('all', 'All'),
    ('unverified', 'Unverified'),
    ('verified', 'Verified'),
    ('near', 'Near limit'),
    ('reached', 'Limit reached'),
    ('custom', 'Custom limits'),
  ];

  String _filter = 'all';
  final _search = TextEditingController();
  WithdrawLimitDefaults? _defaults;
  List<LimitCustomer>? _customers;
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
      final r = await context.read<Session>().api.getWithdrawLimitCustomers(query: _search.text.trim(), filter: _filter);
      if (!mounted) return;
      setState(() {
        _defaults = r.defaults;
        _customers = r.customers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e, 'Could not load the withdrawal limits.');
        _loading = false;
      });
    }
  }

  Future<void> _editDefaults() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DefaultsSheet(current: _defaults!),
    );
    if (saved == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _defaults;
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Withdrawal Limits')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null && _customers == null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : ListView(
                    key: const Key('limits-list'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      if (d != null)
                        ConsoleCard(
                          key: const Key('limit-defaults'),
                          onTap: _editDefaults,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              const Expanded(child: Text('Default limits (withdrawals only)', style: TextStyle(fontWeight: FontWeight.w800))),
                              const Icon(Icons.edit_rounded, size: 18, color: AppColors.purple),
                            ]),
                            const SizedBox(height: 8),
                            Text('Not verified: \$${d.unverifiedDaily} a day · \$${d.unverifiedMonthly} a month'),
                            Text('KYC approved: \$${d.verifiedDaily} a day · \$${d.verifiedMonthly} a month'),
                            const SizedBox(height: 4),
                            const Text('The day starts at 00:00 Somalia time, the month on the 1st.',
                                style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
                          ]),
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
                          child: EmptyStateView(icon: Icons.speed_rounded, title: 'No customers', message: 'Nobody matches this filter.'),
                        )
                      else
                        for (final c in _customers!)
                          Padding(
                            key: Key('limit-row-${c.id}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ConsoleCard(
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerLimitsScreen(customerId: c.id)));
                                if (mounted) _load();
                              },
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Expanded(child: Text(c.name.isEmpty ? '+${c.phone}' : c.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                                  _Pill(c.verified ? 'KYC approved' : _kyc(c.kycStatus), c.verified ? AppColors.statusCompleted : AppColors.textSecondary),
                                ]),
                                Text('+${c.phone}${c.custom ? ' · custom limits' : ''}',
                                    style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                                const SizedBox(height: 6),
                                Text('Today \$${c.dailyUsed} of \$${c.dailyLimit} · left \$${c.dailyRemaining}'),
                                Text('Month \$${c.monthlyUsed} of \$${c.monthlyLimit} · left \$${c.monthlyRemaining}'),
                                if (c.warning != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      c.warning!.endsWith('reached') ? 'Limit reached' : 'Close to the limit',
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: c.warning!.endsWith('reached') ? AppColors.statusFailed : AppColors.statusProcessing),
                                    ),
                                  ),
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
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      );
}

/// The four default limits.
class _DefaultsSheet extends StatefulWidget {
  const _DefaultsSheet({required this.current});
  final WithdrawLimitDefaults current;

  @override
  State<_DefaultsSheet> createState() => _DefaultsSheetState();
}

class _DefaultsSheetState extends State<_DefaultsSheet> {
  late final _ud = TextEditingController(text: widget.current.unverifiedDaily);
  late final _um = TextEditingController(text: widget.current.unverifiedMonthly);
  late final _vd = TextEditingController(text: widget.current.verifiedDaily);
  late final _vm = TextEditingController(text: widget.current.verifiedMonthly);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_ud, _um, _vd, _vm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<Session>().api.setWithdrawLimitDefaults(
            unverifiedDaily: _ud.text.trim(),
            unverifiedMonthly: _um.text.trim(),
            verifiedDaily: _vd.text.trim(),
            verifiedMonthly: _vm.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not save the limits.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, TextEditingController c, Key key) => Expanded(
        child: TextField(
          key: key,
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, prefixText: '\$'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const Text('Default withdrawal limits', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Withdrawals only. Deposits are never limited.', style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          const Text('Not verified (no approved KYC)', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(children: [_field('Daily', _ud, const Key('unverified-daily')), const SizedBox(width: 10), _field('Monthly', _um, const Key('unverified-monthly'))]),
          const SizedBox(height: 14),
          const Text('KYC approved', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(children: [_field('Daily', _vd, const Key('verified-daily')), const SizedBox(width: 10), _field('Monthly', _vm, const Key('verified-monthly'))]),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, key: const Key('limits-error'), style: const TextStyle(color: AppColors.statusFailed)),
          ],
          const SizedBox(height: 16),
          ElevatedButton(key: const Key('save-defaults'), onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ]),
      ),
    );
  }
}

/// One customer: KYC status (and the application to approve / reject),
/// limits, what was withdrawn and what is left, own limits, withdrawals.
class CustomerLimitsScreen extends StatefulWidget {
  const CustomerLimitsScreen({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerLimitsScreen> createState() => _CustomerLimitsScreenState();
}

class _CustomerLimitsScreenState extends State<CustomerLimitsScreen> {
  CustomerWithdrawLimits? _data;
  String? _error;
  bool _loading = true;
  final _daily = TextEditingController();
  final _monthly = TextEditingController();
  final _note = TextEditingController();
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _daily.dispose();
    _monthly.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Session>().api.getCustomerWithdrawLimits(widget.customerId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _daily.text = d.customDaily ? d.dailyLimit : '';
        _monthly.text = d.customMonthly ? d.monthlyLimit : '';
        _note.text = d.note ?? '';
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

  Future<void> _save({bool reset = false}) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final d = reset ? '' : _daily.text.trim();
      final m = reset ? '' : _monthly.text.trim();
      await context.read<Session>().api.setCustomerWithdrawLimits(
            widget.customerId,
            daily: d.isEmpty ? null : d,
            monthly: m.isEmpty ? null : m,
            note: reset ? null : _note.text.trim(),
          );
      await _load();
    } catch (e) {
      if (mounted) setState(() => _saveError = _err(e, 'Could not save.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Withdrawal limits')),
      body: _loading
          ? const LoadingView()
          : (d == null
              ? ErrorStateView(message: _error ?? 'Could not load this customer.', onRetry: _load)
              : ListView(
                  key: const Key('customer-limits'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    ConsoleCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d.name.isEmpty ? '+${d.phone}' : d.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text('+${d.phone} · ${d.accountId}', style: const TextStyle(color: AppColors.textSecondary)),
                        const SizedBox(height: 10),
                        Row(children: [
                          const Text('KYC: ', style: TextStyle(fontWeight: FontWeight.w700)),
                          _Pill(d.verified ? 'Approved' : _kyc(d.kycStatus), d.verified ? AppColors.statusCompleted : AppColors.statusProcessing),
                        ]),
                        if (d.kycApplicationId != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const Key('review-kyc'),
                              onPressed: () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => KycReviewScreen(id: d.kycApplicationId!)));
                                if (mounted) _load();
                              },
                              icon: const Icon(Icons.badge_rounded, size: 18),
                              label: const Text('Review KYC (approve / reject)'),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    ConsoleCard(
                      key: const Key('customer-limit-numbers'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Withdrawn and remaining', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text('Today: \$${d.dailyUsed} of \$${d.dailyLimit} · left \$${d.dailyRemaining}${d.customDaily ? ' (custom)' : ''}'),
                        Text('This month: \$${d.monthlyUsed} of \$${d.monthlyLimit} · left \$${d.monthlyRemaining}${d.customMonthly ? ' (custom)' : ''}'),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    ConsoleCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text("This customer's own limits", style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text('Leave a box empty to use the default (\$${d.verified ? d.defaults.verifiedDaily : d.defaults.unverifiedDaily} a day, '
                            '\$${d.verified ? d.defaults.verifiedMonthly : d.defaults.unverifiedMonthly} a month).',
                            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              key: const Key('custom-daily'),
                              controller: _daily,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(labelText: 'Daily', prefixText: '\$'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              key: const Key('custom-monthly'),
                              controller: _monthly,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(labelText: 'Monthly', prefixText: '\$'),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        TextField(key: const Key('custom-note'), controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
                        if (_saveError != null) ...[
                          const SizedBox(height: 8),
                          Text(_saveError!, key: const Key('limits-error'), style: const TextStyle(color: AppColors.statusFailed)),
                        ],
                        const SizedBox(height: 12),
                        ElevatedButton(key: const Key('save-custom'), onPressed: _saving ? null : () => _save(), child: const Text('Save limits')),
                        if (d.hasCustom)
                          TextButton(key: const Key('reset-custom'), onPressed: _saving ? null : () => _save(reset: true), child: const Text('Back to the default limits')),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    const Text('Recent withdrawals', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    if (d.history.isEmpty)
                      const Text('No withdrawals yet.', style: TextStyle(color: AppColors.textSecondary))
                    else
                      for (final h in d.history)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ConsoleCard(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('\$${h.amount} · ${h.method}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text('${h.orderCode}${h.createdAt == null ? '' : ' · ${formatDateTime(h.createdAt!)}'}',
                                      style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                                ]),
                              ),
                              _Pill(h.counted ? h.status : '${h.status} (not counted)', h.counted ? AppColors.purple : AppColors.textSecondary),
                            ]),
                          ),
                        ),
                  ],
                )),
    );
  }
}
