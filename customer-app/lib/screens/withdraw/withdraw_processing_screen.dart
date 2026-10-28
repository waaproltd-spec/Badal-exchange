import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/transaction_views.dart';
import 'withdraw_result_screen.dart';

/// The withdrawal's three steps while it is submitted and sent: checking the
/// balance, sending the money, confirming it went through. It follows the
/// order until it is completed or failed (at most [maxWait]), then replaces
/// itself with [WithdrawResultScreen], which then shows the transfer number;
/// a withdrawal paid later by hand shows there as in progress. On failure -- INSUFFICIENT_BALANCE,
/// BELOW_MIN_WITHDRAWAL, ABOVE_MAX_WITHDRAWAL, DUPLICATE_WITHDRAWAL, etc --
/// shows the backend's message with a retry (same idempotency key) or a
/// way back to the confirm screen.
class WithdrawProcessingScreen extends StatefulWidget {
  const WithdrawProcessingScreen({super.key, required this.action, this.method, this.amount});

  /// How long the screen follows the order before showing it as it is.
  static const maxWait = Duration(minutes: 2);
  static const pollEvery = Duration(seconds: 3);

  final Future<Order> Function() action;

  /// Shown while submitting: the method's icon and the amount, when known.
  final String? method;
  final String? amount;

  @override
  State<WithdrawProcessingScreen> createState() => _WithdrawProcessingScreenState();
}

class _WithdrawProcessingScreenState extends State<WithdrawProcessingScreen> {
  String? _error;

  /// The step in progress (see [ProcessingView.step]).
  int _step = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _step = 0;
    });
    final Order order;
    try {
      order = await widget.action();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppStrings.somethingWentWrong);
      return;
    }
    if (!mounted) return;
    setState(() => _step = 1);
    final done = await _follow(order);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => WithdrawResultScreen(order: done)),
    );
  }

  /// The order as it is once completed or failed, or when [maxWait] is up
  /// (or it can't be read): the result shows it as it then is.
  Future<Order> _follow(Order order) async {
    final api = context.read<CustomerApi>();
    final until = DateTime.now().add(WithdrawProcessingScreen.maxWait);
    var latest = order;
    while (mounted) {
      if (latest.status == 'processing' && _step < 2) setState(() => _step = 2);
      if (latest.status == 'completed') {
        setState(() => _step = 3);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        return latest;
      }
      if (const {'failed', 'cancelled', 'expired'}.contains(latest.status) || DateTime.now().isAfter(until)) {
        return latest;
      }
      try {
        latest = await api.getOrder(order.id);
      } catch (_) {
        return latest;
      }
      if (latest.status == 'pending' || latest.status == 'processing') {
        await Future<void>.delayed(WithdrawProcessingScreen.pollEvery);
      }
    }
    return latest;
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
                ? ProcessingView(method: widget.method, amount: widget.amount, deposit: false, step: _step)
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
