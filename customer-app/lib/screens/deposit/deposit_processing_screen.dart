import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../services/success_sound.dart';
import '../../theme/colors.dart';
import '../../utils/payment_errors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/transaction_views.dart';
import 'deposit_result_screen.dart';

/// Centered spinner while the deposit is submitted; on success replaces
/// itself with [DepositResultScreen]. On failure, shows the backend's
/// error message with a retry (reusing the same idempotency key via
/// [action]) or a way back to the deposit form.
class DepositProcessingScreen extends StatefulWidget {
  const DepositProcessingScreen({super.key, required this.action, this.method, this.amount});

  final Future<Order> Function() action;

  /// Shown while submitting: the method's icon and the amount, when known.
  final String? method;
  final String? amount;

  @override
  State<DepositProcessingScreen> createState() => _DepositProcessingScreenState();
}

class _DepositProcessingScreenState extends State<DepositProcessingScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _error = null);
    try {
      final order = await widget.action();
      SuccessSound.instance.observe([order]);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DepositResultScreen(order: order)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = PaymentErrors.handle(context.read<CustomerApi>(), e,
          isDeposit: true, method: widget.method, amount: widget.amount));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _error == null
                ? ProcessingView(method: widget.method, amount: widget.amount, deposit: true)
                : Column(mainAxisSize: MainAxisSize.min, children: _buildError(_error!)),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildError(String message) {
    return [
      Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: AppColors.statusFailed.withOpacity(0.12), shape: BoxShape.circle),
        child: const Icon(Icons.priority_high_rounded, color: AppColors.statusFailed, size: 36),
      ),
      const SizedBox(height: 24),
      Text(PaymentErrors.title, style: AppTextStyles.title, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text(message, style: AppTextStyles.muted, textAlign: TextAlign.center),
      const SizedBox(height: 28),
      PrimaryButton(label: AppStrings.tryAgain, onPressed: _run),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(AppStrings.back, style: AppTextStyles.body.copyWith(color: AppColors.textMuted)),
      ),
    ];
  }
}
