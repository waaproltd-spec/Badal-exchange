import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../l10n/wallet_strings.dart';
import '../../models/wallet_adjustment.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';

/// Add Money or Deduct Money on one customer's wallet: amount (with quick
/// amounts), reason, current and new balance, then a confirmation. The
/// server does the change; this screen only shows what it will be. Pops with
/// the [WalletAdjustment] once done.
class WalletAdjustScreen extends StatefulWidget {
  final String customerId;
  final String name;
  final String phone;

  /// The customer's available balance, e.g. "6.00".
  final String balance;
  final bool add;

  const WalletAdjustScreen({
    super.key,
    required this.customerId,
    required this.name,
    required this.phone,
    required this.balance,
    required this.add,
  });

  @override
  State<WalletAdjustScreen> createState() => _WalletAdjustScreenState();
}

class _WalletAdjustScreenState extends State<WalletAdjustScreen> {
  static const _quick = [1, 5, 10, 20, 50, 100];

  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _submitting = false;
  String? _error;

  /// One key per intended adjustment: a retry after a lost reply is applied
  /// once; editing the amount or reason starts a new one.
  String _key = const Uuid().v4();

  Color get _color => widget.add ? AppColors.statusCompleted : AppColors.statusFailed;
  int get _balanceCents => _cents(widget.balance) ?? 0;

  static int? _cents(String text) {
    final n = double.tryParse(text.trim());
    if (n == null || n.isNaN || n.isInfinite) return null;
    return (n * 100).round();
  }

  static String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  int? get _amountCents {
    final c = _cents(_amount.text);
    return c != null && c > 0 ? c : null;
  }

  String? get _problem {
    final amount = _amountCents;
    if (amount == null) return WalletStrings.enterAmount;
    if (!widget.add && amount > _balanceCents) return WalletStrings.moreThanBalance;
    if (_reason.text.trim().length < 3) return WalletStrings.enterReason;
    return null;
  }

  @override
  void initState() {
    super.initState();
    for (final c in [_amount, _reason]) {
      c.addListener(() => setState(() => _key = const Uuid().v4()));
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = _amountCents;
    if (_submitting || _problem != null || amount == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.add ? WalletStrings.addMoney : WalletStrings.deductMoney),
        content: Text(WalletStrings.confirmQuestion(widget.add, _money(amount), widget.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(WalletStrings.cancel)),
          FilledButton(
            key: const Key('confirm-adjust'),
            style: FilledButton.styleFrom(backgroundColor: _color),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(widget.add ? WalletStrings.confirmAdd : WalletStrings.confirmDeduct),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await context.read<Session>().api.adjustWallet(
            customerId: widget.customerId,
            add: widget.add,
            amount: (amount / 100).toStringAsFixed(2),
            reason: _reason.text.trim(),
            idempotencyKey: _key,
          );
      if (!mounted) return;
      setState(() => _submitting = false);
      await showDialog<void>(
        context: context,
        builder: (context) => _ResultDialog(adjustment: result),
      );
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = WalletStrings.failed);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount = _amountCents;
    final after = amount == null ? null : _balanceCents + (widget.add ? amount : -amount);
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: Text(widget.add ? WalletStrings.addMoney : WalletStrings.deductMoney)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleCard(
              child: Row(
                children: [
                  const TintedIcon(icon: Icons.person_rounded, color: AppColors.purple, size: 54),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.name,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                        Text(widget.phone, style: const TextStyle(color: AppColors.textSecondary)),
                        const SizedBox(height: 6),
                        Text(WalletStrings.walletBalance,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        Text(_money(_balanceCents),
                            key: const Key('adjust-balance'),
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ConsoleCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(WalletStrings.amountUsd, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('adjust-amount'),
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}(\.\d{0,2})?'))],
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(prefixText: '\$ ', hintText: '0.00'),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, box) {
                      final width = (box.maxWidth - 16) / 3;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final q in _quick)
                            SizedBox(
                              width: width,
                              child: OutlinedButton(
                                key: Key('quick-$q'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  backgroundColor: _amountCents == q * 100 ? AppColors.purple.withOpacity(0.12) : null,
                                  side: BorderSide(
                                      color: _amountCents == q * 100 ? AppColors.purpleDark : AppColors.border),
                                ),
                                onPressed: () => _amount.text = '$q.00',
                                child: Text('\$$q', style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(widget.add ? WalletStrings.reasonAdd : WalletStrings.reasonDeduct,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('adjust-reason'),
                    controller: _reason,
                    maxLength: 200,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.chat_bubble_outline_rounded),
                      hintText: widget.add ? WalletStrings.reasonHintAdd : WalletStrings.reasonHintDeduct,
                      counterText: '',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ConsoleCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(WalletStrings.details, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  InfoRow(WalletStrings.currentBalance, _money(_balanceCents)),
                  InfoRow(
                    widget.add ? WalletStrings.amountAdded : WalletStrings.amountDeducted,
                    amount == null ? '—' : '${widget.add ? '+' : '-'} ${_money(amount)}',
                  ),
                  InfoRow(WalletStrings.newBalance, after == null ? '—' : _money(after)),
                ],
              ),
            ),
            if (_error != null || (problem != null && _amount.text.isNotEmpty)) ...[
              const SizedBox(height: 12),
              Text(_error ?? problem!,
                  key: const Key('adjust-error'), style: const TextStyle(color: AppColors.statusFailed)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                key: const Key('adjust-submit'),
                style: FilledButton.styleFrom(
                  backgroundColor: widget.add ? AppColors.purpleDark : AppColors.statusFailed,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: problem == null && !_submitting ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Icon(widget.add ? Icons.send_rounded : Icons.remove_circle_outline_rounded),
                label: Text(widget.add ? WalletStrings.confirmAdd : WalletStrings.confirmDeduct,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultDialog extends StatelessWidget {
  final WalletAdjustment adjustment;

  const _ResultDialog({required this.adjustment});

  @override
  Widget build(BuildContext context) {
    final a = adjustment;
    return AlertDialog(
      key: const Key('adjust-result'),
      icon: const Icon(Icons.check_circle_rounded, color: AppColors.statusCompleted, size: 48),
      title: Text(a.isAdd ? WalletStrings.added : WalletStrings.deducted),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InfoRow(WalletStrings.reference, a.reference),
          InfoRow(a.isAdd ? WalletStrings.amountAdded : WalletStrings.amountDeducted, '\$${a.amount}'),
          InfoRow(WalletStrings.balanceBefore, '\$${a.balanceBefore}'),
          InfoRow(WalletStrings.balanceAfter, '\$${a.balanceAfter}'),
        ],
      ),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(WalletStrings.done))],
    );
  }
}
