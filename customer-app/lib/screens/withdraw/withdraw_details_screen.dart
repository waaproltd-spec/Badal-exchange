import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import 'withdraw_confirm_screen.dart';

/// Collects the amount (plus the account ID for betting platforms), then
/// fetches a quote (which also enforces min/max withdrawal limits
/// server-side) before moving to confirmation. Mobile money is always paid
/// out to the customer's registered login number (the backend enforces
/// it), so there is no phone field.
class WithdrawDetailsScreen extends StatefulWidget {
  const WithdrawDetailsScreen({super.key, required this.method, this.ownPhone});

  /// Payment method id (see payment_method.dart).
  final String method;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        title: Text(_info.label, style: AppTextStyles.appBarTitle),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(AppStrings.withdrawalDetails, style: AppTextStyles.headline),
              const SizedBox(height: 8),
              Text(
                _info.isPlatform
                    ? AppStrings.withdrawPlatformHint(_info.label)
                    : AppStrings.withdrawPhoneHint(_info.label),
                style: AppTextStyles.muted,
              ),
              const SizedBox(height: 28),
              if (_info.isPlatform) ...[
                AppTextField(
                  label: _info.identifierLabel,
                  controller: _identifierController,
                  keyboardType: TextInputType.text,
                  hint: _info.identifierHint,
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v == null || v.trim().isEmpty) ? AppStrings.enterAccountId : null,
                ),
                const SizedBox(height: 20),
              ] else ...[
                Container(
                  key: const Key('withdraw-own-number'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primaryTint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.verified_user_outlined, color: AppColors.primary),
                      const SizedBox(width: 12),
                      Expanded(child: Text(AppStrings.receiveToOwnNumber, style: AppTextStyles.muted)),
                      Text(_ownLocal == null ? '—' : '+252 $_ownLocal',
                          style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              AppTextField(
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
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 32),
              PrimaryButton(
                label: AppStrings.continueLabel,
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
