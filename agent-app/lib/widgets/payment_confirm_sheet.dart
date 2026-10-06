import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../api/api_exception.dart';
import '../models/match_result.dart';
import '../models/order.dart';
import '../models/payment_methods.dart';
import '../models/sms_transaction_log.dart';
import '../services/sms_log_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';

/// Lets an agent confirm a deposit payment they personally verified as real
/// and completed: a mobile-money payment that arrived (EVC Plus, Golis,
/// Telesom, eDahab), or a top-up done in a betting platform's cashier tools
/// (WinWin, 1XBET, MELBET, Betwinner, DBbet, 888STARZ).
///
/// The backend matches it against the customer's pending order and dedupes
/// by the transaction reference, so the same payment can never credit a
/// wallet twice. Pass [order] to prefill from a pending deposit.
///
/// Returns the match result, or null if the agent cancelled.
Future<MatchResult?> showPaymentConfirmSheet(BuildContext context, {Order? order}) {
  return showModalBottomSheet<MatchResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _PaymentConfirmForm(order: order),
  );
}

/// Shows the standard snack bar for a confirmation result.
void showMatchResultSnackBar(BuildContext context, MatchResult result) {
  final (String text, Color color) = switch (result.status) {
    MatchStatus.matched => ('Matched — the deposit order has been completed.', AppColors.statusCompleted),
    MatchStatus.unmatched => ('No pending order matched these details. Double-check and try again.', AppColors.statusUnmatched),
    MatchStatus.duplicate => ('This transaction was already submitted.', AppColors.statusDuplicate),
    MatchStatus.error => (result.errorMessage ?? 'Something went wrong.', AppColors.statusFailed),
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
}

class _PaymentConfirmForm extends StatefulWidget {
  final Order? order;
  const _PaymentConfirmForm({this.order});

  @override
  State<_PaymentConfirmForm> createState() => _PaymentConfirmFormState();
}

class _PaymentConfirmFormState extends State<_PaymentConfirmForm> {
  final _formKey = GlobalKey<FormState>();
  late String _method;
  late final TextEditingController _counterparty;
  late final TextEditingController _depositCode;
  late final TextEditingController _amount;
  final _reference = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final order = widget.order;
    _method = order?.method ?? 'evc_plus';
    _counterparty = TextEditingController(text: order?.counterpartyLabel == '—' ? '' : order?.counterpartyLabel);
    _depositCode = TextEditingController(text: order?.depositCode ?? '');
    _amount = TextEditingController(text: order?.amount ?? '');
  }

  @override
  void dispose() {
    _counterparty.dispose();
    _depositCode.dispose();
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  PaymentMethodInfo get _info => methodInfo(_method);

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final api = context.read<Session>().api;
    final occurredAt = DateTime.now();
    final counterparty = _counterparty.text.trim();
    final amount = _amount.text.trim();
    final reference = _reference.text.trim();

    MatchResult result;
    try {
      result = _info.isPlatform
          ? await api.submitPlatformTransaction(
              method: _method,
              accountId: counterparty,
              depositCode: _depositCode.text.trim(),
              amount: amount,
              reference: reference,
              occurredAt: occurredAt,
            )
          : await api.submitMobileMoneyTransaction(
              method: _method,
              senderPhone: counterparty,
              amount: amount,
              transactionRef: reference,
              occurredAt: occurredAt,
            );
    } catch (e) {
      result = MatchResult.error(e is ApiException ? e.message : 'Failed to submit confirmation.');
    }

    // Keep this device's local submission log (SMS Transactions screen).
    await SmsLogStore.instance.add(SmsTransactionLog(
      id: const Uuid().v4(),
      provider: _method,
      sender: counterparty,
      amount: amount,
      transactionRef: reference,
      occurredAt: occurredAt,
      submittedAt: DateTime.now(),
      status: result.status,
      orderId: result.orderId,
      errorMessage: result.errorMessage,
      isManualWinwin: true,
    ));

    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final isPlatform = _info.isPlatform;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Confirm payment',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                isPlatform
                    ? 'Only enter a top-up you personally confirmed as completed in the ${_info.label} cashier tools.'
                    : 'Only enter a ${_info.label} payment you personally saw arrive.',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _method,
                decoration: const InputDecoration(labelText: 'Payment method'),
                items: [
                  for (final m in paymentMethods)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text('${m.label}${m.isPlatform ? '  ·  betting' : '  ·  mobile money'}'),
                    ),
                ],
                onChanged: widget.order != null ? null : (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _counterparty,
                decoration: InputDecoration(labelText: isPlatform ? '${_info.label} account ID' : 'Sender phone number'),
                keyboardType: isPlatform ? TextInputType.text : TextInputType.phone,
                textInputAction: TextInputAction.next,
                validator: (v) => (v == null || v.trim().length < (isPlatform ? 3 : 4)) ? 'Required' : null,
              ),
              if (isPlatform) ...[
                const SizedBox(height: 14),
                TextFormField(
                  controller: _depositCode,
                  decoration: const InputDecoration(labelText: 'Deposit code (optional)'),
                  textInputAction: TextInputAction.next,
                ),
              ],
              const SizedBox(height: 14),
              TextFormField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Amount'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.next,
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  return (n == null || n <= 0) ? 'Enter a valid amount' : null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _reference,
                decoration: InputDecoration(labelText: isPlatform ? '${_info.label} reference' : 'Transaction ID'),
                textInputAction: TextInputAction.done,
                validator: (v) => (v == null || v.trim().length < 3) ? 'At least 3 characters' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Submit confirmation'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
