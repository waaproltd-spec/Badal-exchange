import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../models/quote.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../utils/ussd.dart';
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
/// "Create first, dial second": the order is created before the phone's
/// dialer is launched, so returning from a dropped/cancelled dial still
/// lands on a real status screen rather than nothing. The wallet is only
/// ever credited later, once the agent app's real SMS verification confirms
/// the payment actually happened -- the dial itself never credits anything.
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
  String? _ussdTemplate;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = const Uuid().v4();
    // Best-effort: if this hasn't loaded by the time the customer taps
    // Confirm, the order still gets created -- it's just skipped.
    context.read<CustomerApi>().getEvcUssdTemplate().then((template) {
      if (mounted) setState(() => _ussdTemplate = template);
    }).catchError((_) {});
  }

  Future<Order> _submit(CustomerApi api) async {
    final order = await api.depositEvc(
      phoneNumber: widget.phoneNumber,
      amount: widget.quote.amount,
      idempotencyKey: _idempotencyKey,
    );
    final dialUri = buildUssdDialUri(_ussdTemplate, widget.quote.amount);
    if (dialUri != null) {
      await launchUrl(Uri.parse(dialUri)).catchError((_) => false);
    }
    return order;
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
