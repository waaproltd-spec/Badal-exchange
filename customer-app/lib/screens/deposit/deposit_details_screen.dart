import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import 'deposit_confirm_screen.dart';
import 'deposit_processing_screen.dart';

/// EVC Plus: collects the phone number + amount, fetches a quote, then moves
/// to confirmation -- the app never computes the rate/fee itself, it always
/// asks the backend via /customer/quotes.
///
/// 888STARZ: collects the Player ID + the 4-digit withdrawal code 888STARZ
/// generated for the customer. There's no amount to type and nothing to
/// preview -- CashdeskBot's Payout confirmation is the only source of the
/// credited amount, so this submits straight to the backend and shows
/// whatever order comes back.
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
  final _codeController = TextEditingController();
  bool _submitting = false;
  String? _error;

  bool get _isEvc => widget.method == 'evc_plus';

  @override
  void dispose() {
    _identifierController.dispose();
    _amountController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (_isEvc) {
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
              phoneNumber: _identifierController.text.trim(),
            ),
          ),
        );
        return;
      }

      final winwinId = _identifierController.text.trim();
      final code = _codeController.text.trim();
      final idempotencyKey = const Uuid().v4();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DepositProcessingScreen(
            action: () => context.read<CustomerApi>().depositWinwin(
                  winwinId: winwinId,
                  code: code,
                  idempotencyKey: idempotencyKey,
                ),
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
                    : 'Enter your 888STARZ Player ID and the withdrawal code 888STARZ gave you.',
                style: AppTextStyles.muted,
              ),
              const SizedBox(height: 28),
              AppTextField(
                label: _isEvc ? 'EVC Plus Phone Number' : '888STARZ Player ID',
                controller: _identifierController,
                keyboardType: _isEvc ? TextInputType.phone : TextInputType.text,
                hint: _isEvc ? 'e.g. 2526XXXXXXX' : 'e.g. 7841228',
                textInputAction: TextInputAction.next,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return _isEvc ? 'Enter a phone number' : 'Enter your 888STARZ Player ID';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              if (_isEvc)
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
                )
              else
                AppTextField(
                  label: '888STARZ Withdrawal Code',
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  hint: '0000',
                  textInputAction: TextInputAction.done,
                  validator: (v) {
                    final trimmed = (v ?? '').trim();
                    if (!RegExp(r'^\d{4}$').hasMatch(trimmed)) {
                      return 'Enter the 4-digit code from 888STARZ';
                    }
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
