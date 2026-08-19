import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../models/quote.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/summary_row.dart';
import 'withdraw_processing_screen.dart';

/// Shows exactly what the backend quoted -- phone/WinWin ID, amount, fee,
/// total deducted from the wallet, and amount to receive -- and submits
/// the withdrawal on confirm.
class WithdrawConfirmScreen extends StatefulWidget {
  const WithdrawConfirmScreen({
    super.key,
    required this.quote,
    this.phoneNumber,
    this.winwinId,
  });

  final Quote quote;
  final String? phoneNumber;
  final String? winwinId;

  @override
  State<WithdrawConfirmScreen> createState() => _WithdrawConfirmScreenState();
}

class _WithdrawConfirmScreenState extends State<WithdrawConfirmScreen> {
  /// Generated once per submit attempt and reused across retries of the
  /// same logical request, so a network retry can never double-submit.
  late final String _idempotencyKey;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = Uuid().v4();
  }

  Future<Order> _submit(CustomerApi api) {
    if (widget.quote.method == 'evc_plus') {
      return api.withdrawEvc(
        phoneNumber: widget.phoneNumber!,
        amount: widget.quote.amount,
        idempotencyKey: _idempotencyKey,
      );
    }
    return api.withdrawWinwin(
      winwinId: widget.winwinId!,
      amount: widget.quote.amount,
      idempotencyKey: _idempotencyKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final isEvc = quote.method == 'evc_plus';

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text('Confirm Withdrawal', style: AppTextStyles.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(child: MethodIcon(method: quote.method, size: 56)),
            const SizedBox(height: 16),
            Center(
              child: Text(isEvc ? AppStrings.evcPlus : AppStrings.winwin, style: AppTextStyles.title),
            ),
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                children: [
                  SummaryRow(
                    label: isEvc ? 'Phone Number' : 'WinWin ID',
                    value: (isEvc ? widget.phoneNumber : widget.winwinId) ?? '',
                  ),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.amount, value: Formatters.money(quote.amount)),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.fee, value: Formatters.money(quote.fee)),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.totalDeducted, value: Formatters.money(quote.walletDelta)),
                  const SummaryDivider(),
                  SummaryRow(
                    label: AppStrings.netAmount,
                    value: Formatters.money(quote.netAmount),
                    emphasize: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            PrimaryButton(
              label: AppStrings.confirm,
              onPressed: () {
                final api = context.read<CustomerApi>();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WithdrawProcessingScreen(action: () => _submit(api)),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
