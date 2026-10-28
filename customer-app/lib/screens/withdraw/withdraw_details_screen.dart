import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/flow_header.dart';
import '../../widgets/own_phone_box.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/primary_button.dart';
import 'withdraw_confirm_screen.dart';

/// Collects the amount (plus the account ID for betting platforms), then
/// fetches a quote (which also enforces min/max withdrawal limits
/// server-side) before moving to confirmation. Mobile money is always paid
/// out to the customer's registered login number (the backend enforces
/// it), so there is no phone field.
class WithdrawDetailsScreen extends StatefulWidget {
  const WithdrawDetailsScreen({super.key, required this.method, this.ownPhone, this.option, this.availableBalance});

  /// Payment method id (see payment_method.dart).
  final String method;

  /// The method as the backend offers it (withdrawal limits), when known.
  final PaymentMethodOption? option;

  /// The wallet's available balance, shown at the top when known.
  final String? availableBalance;

  /// The customer's registered login phone: where mobile money is paid out.
  final String? ownPhone;

  @override
  State<WithdrawDetailsScreen> createState() => _WithdrawDetailsScreenState();
}

class _WithdrawDetailsScreenState extends State<WithdrawDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _amountController = TextEditingController();
  bool _submitting = false;
  String? _error;

  PaymentMethodInfo get _info => methodInfo(widget.method);

  /// Last 9 digits of the registered number.
  String? get _ownLocal {
    final digits = (widget.ownPhone ?? '').replaceAll(RegExp(r'\D'), '');
    return digits.length >= 9 ? digits.substring(digits.length - 9) : null;
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_info.isPlatform && _ownLocal == null) {
      setState(() => _error = AppStrings.noRegisteredNumber);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final quote = await context.read<CustomerApi>().createQuote(
            direction: 'withdraw',
            method: widget.method,
            amount: _amountController.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WithdrawConfirmScreen(
            quote: quote,
            phoneNumber: _info.isPlatform ? null : '252$_ownLocal',
            accountId: _info.isPlatform ? _identifierController.text.trim() : null,
          ),
        ),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _change() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.withdraw, ownPhone: widget.ownPhone);
    if (option == null || !mounted || option.info.id == widget.method) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => WithdrawDetailsScreen(
        method: option.info.id,
        option: option,
        ownPhone: widget.ownPhone,
        availableBalance: widget.availableBalance,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final min = widget.option?.minWithdraw;
    final max = widget.option?.maxWithdraw;
    final account = AppTextField(
      label: _info.identifierLabel,
      controller: _identifierController,
      keyboardType: TextInputType.text,
      hint: _info.identifierHint,
      textInputAction: TextInputAction.next,
      validator: (v) => (v == null || v.trim().isEmpty) ? AppStrings.enterAccountId : null,
    );
    final amount = AppTextField(
      label: AppStrings.amount,
      controller: _amountController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      hint: '0.00',
      textInputAction: TextInputAction.done,
      validator: (v) {
        final n = double.tryParse((v ?? '').trim());
        if (n == null || n <= 0) return AppStrings.enterValidAmount;
        return null;
      },
    );
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Row(
                children: [
                  RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 14),
                  Expanded(child: Text(AppStrings.completeWithdrawal, style: AppTextStyles.title)),
                ],
              ),
              const SizedBox(height: 20),
              if (widget.availableBalance != null) ...[
                Container(
                  key: const Key('withdraw-available'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.cardBorder, width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.availableBalance.toUpperCase(), style: AppTextStyles.label),
                      const SizedBox(height: 4),
                      Text(Formatters.money(widget.availableBalance!),
                          style: AppTextStyles.title.copyWith(fontSize: 24, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              FlowMethodCard(
                info: _info,
                onChange: _change,
                subtitle: _info.isPlatform ? AppStrings.bettingAccount : AppStrings.instantMobileTransfer,
              ),
              const SizedBox(height: 20),
              if (_info.isPlatform)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: account),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: amount),
                  ],
                )
              else
                // The registered number (locked) beside the amount, as on Deposit.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: OwnPhoneBox(key: const Key('withdraw-own-number'), local: _ownLocal)),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: amount),
                  ],
                ),
              if (min != null && max != null) ...[
                const SizedBox(height: 8),
                Text(
                  AppStrings.withdrawLimits(Formatters.money(min), Formatters.money(max)),
                  key: const Key('withdraw-limits'),
                  style: AppTextStyles.muted.copyWith(fontSize: 12.5),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                label: AppStrings.continueLabel,
                trailingIcon: Icons.arrow_forward_rounded,
                onPressed: _continue,
                loading: _submitting,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
