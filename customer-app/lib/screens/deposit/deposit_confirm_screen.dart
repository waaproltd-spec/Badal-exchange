import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../models/payment_method.dart';
import '../../models/quote.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/summary_row.dart';
import 'deposit_processing_screen.dart';

/// Shows exactly what the backend quoted -- phone/account ID, amount, rate,
/// fee, net amount to be credited -- and submits the deposit on confirm.
class DepositConfirmScreen extends StatefulWidget {
  const DepositConfirmScreen({
    super.key,
    required this.quote,
    this.phoneNumber,
    this.accountId,
    this.platformCode,
  });

  final Quote quote;
  final String? phoneNumber;
  final String? accountId;

  /// The platform's withdrawal code, for deposits collected automatically.
  final String? platformCode;

  @override
  State<DepositConfirmScreen> createState() => _DepositConfirmScreenState();
}

class _DepositConfirmScreenState extends State<DepositConfirmScreen> {
  /// Generated once per submit attempt and reused across retries of the
  /// same logical request, so a network retry can never double-submit.
  late final String _idempotencyKey;

  /// One tap submits once: the button stays off until the processing screen
  /// is closed.
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = Uuid().v4();
  }

  Future<Order> _submit(CustomerApi api) {
    return api.deposit(
      method: widget.quote.method,
      phoneNumber: widget.phoneNumber,
      accountId: widget.accountId,
      amount: widget.quote.amount,
      idempotencyKey: _idempotencyKey,
      platformCode: widget.platformCode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final info = methodInfo(quote.method);

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.confirmDeposit, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(child: MethodIcon(method: quote.method, size: 56)),
            const SizedBox(height: 16),
            Center(
              child: Text(info.label, style: AppTextStyles.title),
            ),
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                children: [
                  SummaryRow(
                    label: info.isPlatform ? AppStrings.accountId : AppStrings.phoneNumber,
                    value: (info.isPlatform ? widget.accountId : widget.phoneNumber) ?? '',
                  ),
                  if (widget.platformCode != null) ...[
                    const SummaryDivider(),
                    SummaryRow(label: AppStrings.withdrawalCode, value: widget.platformCode!),
                  ],
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.amount, value: Formatters.money(quote.amount)),
                  if (quote.rate != 1) ...[
                    const SummaryDivider(),
                    SummaryRow(label: AppStrings.rate, value: quote.rate.toString()),
                  ],
                  if ((num.tryParse(quote.fee) ?? 0) != 0) ...[
                    const SummaryDivider(),
                    SummaryRow(label: AppStrings.fee, value: Formatters.money(quote.fee)),
                  ],
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
              onPressed: _submitting
                  ? null
                  : () async {
                      final api = context.read<CustomerApi>();
                      setState(() => _submitting = true);
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DepositProcessingScreen(action: () => _submit(api)),
                        ),
                      );
                      if (mounted) setState(() => _submitting = false);
                    },
            ),
          ],
        ),
      ),
    );
  }
}
