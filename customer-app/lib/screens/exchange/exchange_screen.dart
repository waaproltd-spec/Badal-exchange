import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../models/exchange.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/summary_row.dart';
import 'exchange_order_screen.dart';
import 'exchange_status.dart';

/// Exchange money between EVC Plus and eDahab: pick the direction, enter the
/// amount and both numbers, see the quote from the backend, then create the
/// order. Paying and the payout happen on the order screen.
class ExchangeScreen extends StatefulWidget {
  const ExchangeScreen({super.key});

  @override
  State<ExchangeScreen> createState() => _ExchangeScreenState();
}

class _ExchangeScreenState extends State<ExchangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _sender = TextEditingController();
  final _receiver = TextEditingController();

  List<ExchangeOption>? _options;
  List<ExchangeOrder> _recent = const [];
  ExchangeOption? _selected;
  ExchangeQuote? _quote;
  String? _error;
  bool _busy = false;

  /// One id per filled-in form, so a double tap or a retry after a dropped
  /// response returns the same order instead of a second one.
  String _requestId = const Uuid().v4();

  String _signature = '';

  @override
  void initState() {
    super.initState();
    for (final c in [_amount, _sender, _receiver]) {
      c.addListener(_formChanged);
    }
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _sender.dispose();
    _receiver.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<CustomerApi>();
    try {
      final options = await api.exchangeOptions();
      final recent = await api.exchangeOrders();
      if (!mounted) return;
      setState(() {
        _options = options;
        _recent = recent;
        _selected ??= options.isEmpty ? null : options.first;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// A new request id and a fresh quote whenever what was typed changes
  /// (cursor moves don't count).
  void _formChanged() {
    final sig = '${_selected?.id}|${_amount.text.trim()}|${_sender.text.trim()}|${_receiver.text.trim()}';
    if (sig == _signature) return;
    _signature = sig;
    _requestId = const Uuid().v4();
    if (_quote != null) setState(() => _quote = null);
  }

  Future<void> _submit() async {
    final option = _selected;
    if (option == null || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<CustomerApi>();
    try {
      if (_quote == null) {
        final quote = await api.exchangeQuote(optionId: option.id, amount: _amount.text.trim());
        if (mounted) setState(() => _quote = quote);
        return;
      }
      final order = await api.createExchangeOrder(
        optionId: option.id,
        amount: _amount.text.trim(),
        senderPhone: _sender.text.trim(),
        receiverPhone: _receiver.text.trim(),
        clientRequestId: _requestId,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExchangeOrderScreen(initial: order)));
      _amount.clear();
      _formChanged();
      _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _phone(String? v) {
    final d = (v ?? '').replaceAll(RegExp(r'\D'), '');
    if (d.length < 9) return 'Enter the full number, e.g. 610000000';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text('Exchange', style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: options == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error))
                    : const CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text('EVC Plus ⇄ eDahab', style: AppTextStyles.headline),
                      const SizedBox(height: 6),
                      Text('Send money from one wallet and receive it in the other.', style: AppTextStyles.muted),
                      const SizedBox(height: 20),
                      if (options.isEmpty)
                        AppCard(child: Text('Exchange is not available right now.', style: AppTextStyles.body))
                      else ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final o in options)
                              ChoiceChip(
                                label: Text('${o.fromLabel} → ${o.toLabel}'),
                                selected: _selected?.id == o.id,
                                onSelected: (_) {
                                  setState(() => _selected = o);
                                  _formChanged();
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_selected != null)
                          Text(
                            'Fee ${_selected!.feeText}'
                            '${_selected!.minAmount != null ? ' · min \$${_selected!.minAmount}' : ''}'
                            '${_selected!.maxAmount != null ? ' · max \$${_selected!.maxAmount}' : ''}',
                            style: AppTextStyles.muted,
                          ),
                        const SizedBox(height: 20),
                        _field(
                          label: 'Amount you send (\$)',
                          controller: _amount,
                          hint: '0.00',
                          keyboard: const TextInputType.numberWithOptions(decimal: true),
                          validator: (v) {
                            final n = double.tryParse((v ?? '').trim());
                            return n == null || n <= 0 ? 'Enter a valid amount' : null;
                          },
                        ),
                        const SizedBox(height: 16),
                        _field(
                          label: 'Your ${_selected?.fromLabel ?? ''} number (you pay from)',
                          controller: _sender,
                          hint: _selected?.fromMethod == 'edahab' ? '62xxxxxxx' : '61xxxxxxx',
                          keyboard: TextInputType.phone,
                          validator: _phone,
                        ),
                        const SizedBox(height: 16),
                        _field(
                          label: '${_selected?.toLabel ?? ''} number to receive',
                          controller: _receiver,
                          hint: _selected?.toMethod == 'edahab' ? '62xxxxxxx' : '61xxxxxxx',
                          keyboard: TextInputType.phone,
                          validator: _phone,
                        ),
                        if (_quote != null) ...[
                          const SizedBox(height: 20),
                          AppCard(
                            child: Column(
                              children: [
                                SummaryRow(label: 'You send', value: Formatters.money(_quote!.amountSent)),
                                SummaryRow(label: 'Fee', value: Formatters.money(_quote!.fee)),
                                SummaryRow(
                                    label: 'You receive',
                                    value: '${Formatters.money(_quote!.amountReceived)} on ${_selected!.toLabel}',
                                    emphasize: true),
                              ],
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
                        ],
                        const SizedBox(height: 24),
                        PrimaryButton(
                          label: _quote == null ? 'See how much I get' : 'Confirm exchange',
                          onPressed: _busy ? null : _submit,
                          loading: _busy,
                        ),
                      ],
                      if (_recent.isNotEmpty) ...[
                        const SizedBox(height: 32),
                        Text('My exchanges', style: AppTextStyles.title),
                        const SizedBox(height: 8),
                        for (final o in _recent.take(20))
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              title: Text('${Formatters.money(o.amountSent)} ${o.fromLabel} → ${o.toLabel}'),
                              subtitle: Text('${o.id} · ${Formatters.dateTime(o.createdAt)}'),
                              trailing: ExchangeStatusBadge(status: o.status),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ExchangeOrderScreen(initial: o)));
                                _load();
                              },
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) =>
      AppTextField(label: label, controller: controller, hint: hint, keyboardType: keyboard, validator: validator);
}
