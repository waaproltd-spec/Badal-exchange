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
import 'deposit_processing_screen.dart';

/// EVC Plus only -- 888STARZ deposits redeem a CashdeskBot payout code
/// directly from [DepositDetailsScreen] and never see a quote preview,
/// since the amount is only known once CashdeskBot confirms the code.
///
/// Shows exactly what the backend quoted -- phone number, amount, rate,
/// fee, net amount to be credited -- and submits the deposit on confirm.
class DepositConfirmScreen extends StatefulWidget {
  const DepositConfirmScreen({
    super.key,
    required this.quote,
    required this.phoneNumber,
  });

  final Quote quote;
  final String phoneNumber;

  @override
  State<DepositConfirmScreen> createState() => _DepositConfirmScreenState();
}

class _DepositConfirmScreenState extends State<DepositConfirmScreen> {
  /// Generated once per submit attempt and reused across retries of the
  /// same logical request, so a network retry can never double-submit.
  late final String _idempotencyKey;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = const Uuid().v4();
  }

  Future<Order> _submit(CustomerApi api) {
    return api.depositEvc(
      phoneNumber: widget.phoneNumber,
      amount: widget.quote.amount,
      idempotencyKey: _idempotencyKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text('Confirm Deposit', style: AppTextStyles.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(child: MethodIcon(method: quote.method, size: 56)),
            const SizedBox(height: 16),
            Center(
              child: Text(AppStrings.evcPlus, style: AppTextStyles.title),
            ),
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                children: [
                  SummaryRow(label: 'Phone Number', value: widget.phoneNumber),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.amount, value: Formatters.money(quote.amount)),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.rate, value: '${quote.rate}'),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.fee, value: Formatters.money(quote.fee)),
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
                    builder: (_) => DepositProcessingScreen(action: () => _submit(api)),
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
