import 'package:flutter/material.dart';

import '../../api/api_exception.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/transaction_views.dart';
import 'withdraw_result_screen.dart';

/// Centered spinner while the withdrawal is submitted; on success replaces
/// itself with [WithdrawResultScreen]. On failure -- INSUFFICIENT_BALANCE,
/// BELOW_MIN_WITHDRAWAL, ABOVE_MAX_WITHDRAWAL, DUPLICATE_WITHDRAWAL, etc --
/// shows the backend's message with a retry (same idempotency key) or a
/// way back to the confirm screen.
class WithdrawProcessingScreen extends StatefulWidget {
  const WithdrawProcessingScreen({super.key, required this.action, this.method, this.amount});

  final Future<Order> Function() action;

  /// Shown while submitting: the method's icon and the amount, when known.
  final String? method;
  final String? amount;

  @override
  State<WithdrawProcessingScreen> createState() => _WithdrawProcessingScreenState();
}

class _WithdrawProcessingScreenState extends State<WithdrawProcessingScreen> {
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
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => WithdrawResultScreen(order: order)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppStrings.somethingWentWrong);
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
                ? ProcessingView(method: widget.method, amount: widget.amount, deposit: false)
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
      Text(AppStrings.couldNotComplete, style: AppTextStyles.title, textAlign: TextAlign.center),
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
