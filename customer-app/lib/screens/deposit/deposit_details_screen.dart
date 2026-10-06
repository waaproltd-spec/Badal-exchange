import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/deposit_numbers_card.dart';
import '../../widgets/primary_button.dart';
import 'deposit_confirm_screen.dart';

/// Collects the phone number (mobile money) or account ID (betting platform)
/// + amount, then fetches a quote before moving to confirmation. The app never computes the
/// rate/fee itself -- it always asks the backend via /customer/quotes.
class DepositDetailsScreen extends StatefulWidget {
  const DepositDetailsScreen({super.key, required this.option});

  /// The chosen method, with the numbers customers send payments to.
  final PaymentMethodOption option;

  @override
  State<DepositDetailsScreen> createState() => _DepositDetailsScreenState();
}

class _DepositDetailsScreenState extends State<DepositDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _amountController = TextEditingController();
  bool _submitting = false;
  String? _error;

  PaymentMethodInfo get _info => widget.option.info;

  @override
  void dispose() {
    _identifierController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final quote = await context.read<CustomerApi>().createQuote(
            direction: 'deposit',
            method: _info.id,
            amount: _amountController.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DepositConfirmScreen(
            quote: quote,
            phoneNumber: _info.isPlatform ? null : _identifierController.text.trim(),
            accountId: _info.isPlatform ? _identifierController.text.trim() : null,
          ),
        ),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
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
              Text('Deposit details', style: AppTextStyles.headline),
              const SizedBox(height: 8),
              Text(
                _info.isPlatform
                    ? 'Enter your ${_info.label} account ID and the amount to deposit.'
                    : 'Enter the ${_info.label} number you will pay from.',
                style: AppTextStyles.muted,
              ),
              if (widget.option.depositNumbers.isNotEmpty) ...[
                const SizedBox(height: 20),
                DepositNumbersCard(numbers: widget.option.depositNumbers),
              ],
              const SizedBox(height: 28),
              AppTextField(
                label: _info.identifierLabel,
                controller: _identifierController,
                keyboardType: _info.isPlatform ? TextInputType.text : TextInputType.phone,
                hint: _info.identifierHint,
                textInputAction: TextInputAction.next,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return _info.isPlatform ? 'Enter your account ID' : 'Enter a phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              AppTextField(
                label: AppStrings.amount,
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                hint: '0.00',
                textInputAction: TextInputAction.done,
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return 'Enter a valid amount';
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
