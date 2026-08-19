import 'package:flutter/material.dart';

import '../../api/api_exception.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/primary_button.dart';
import 'deposit_result_screen.dart';

/// Centered spinner while the deposit is submitted; on success replaces
/// itself with [DepositResultScreen]. On failure, shows the backend's
/// error message with a retry (reusing the same idempotency key via
/// [action]) or a way back to the confirm screen.
class DepositProcessingScreen extends StatefulWidget {
  const DepositProcessingScreen({super.key, required this.action});

  final Future<Order> Function() action;

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
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DepositResultScreen(order: order)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Something went wrong. Please try again.');
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _error == null ? _buildProcessing() : _buildError(_error!),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildProcessing() {
    return [
      const SizedBox(
        width: 64,
        height: 64,
        child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 4),
      ),
      const SizedBox(height: 28),
      Text(AppStrings.processing, style: AppTextStyles.headline, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      Text(AppStrings.pleaseWait, style: AppTextStyles.muted, textAlign: TextAlign.center),
    ];
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
      Text('We could not complete this', style: AppTextStyles.title, textAlign: TextAlign.center),
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
