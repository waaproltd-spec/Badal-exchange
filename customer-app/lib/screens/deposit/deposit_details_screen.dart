import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import 'deposit_confirm_screen.dart';

/// Collects the phone number (EVC Plus) or WinWin ID + amount, then fetches
/// a quote before moving to confirmation. The app never computes the
/// rate/fee itself -- it always asks the backend via /customer/quotes.
class DepositDetailsScreen extends StatefulWidget {
  const DepositDetailsScreen({super.key, required this.method});

  /// 'evc_plus' | 'winwin'
  final String method;

  @override
  State<DepositDetailsScreen> createState() => _DepositDetailsScreenState();
}

class _DepositDetailsScreenState extends State<DepositDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _amountController = TextEditingController();
  bool _submitting = false;
  String? _error;

  bool get _isEvc => widget.method == 'evc_plus';

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
            method: widget.method,
            amount: _amountController.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DepositConfirmScreen(
            quote: quote,
            phoneNumber: _isEvc ? _identifierController.text.trim() : null,
            winwinId: _isEvc ? null : _identifierController.text.trim(),
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
        title: Text(_isEvc ? AppStrings.evcPlus : AppStrings.winwin, style: AppTextStyles.title),
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
                _isEvc
                    ? 'Enter the EVC Plus number you will pay from.'
                    : 'Enter your WinWin ID and the amount to deposit.',
                style: AppTextStyles.muted,
              ),
              const SizedBox(height: 28),
              AppTextField(
                label: _isEvc ? 'EVC Plus Phone Number' : 'WinWin ID',
                controller: _identifierController,
                keyboardType: _isEvc ? TextInputType.phone : TextInputType.text,
                hint: _isEvc ? 'e.g. 2526XXXXXXX' : 'e.g. 7841228',
                textInputAction: TextInputAction.next,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return _isEvc ? 'Enter a phone number' : 'Enter your WinWin ID';
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
