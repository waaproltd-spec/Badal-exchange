import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../l10n/strings.dart';
import '../models/payment_method.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import 'method_icon.dart';

enum PaymentDirection { deposit, withdraw }

/// Opens the Deposit or Withdraw method picker as a bottom sheet over the
/// (dimmed) wallet dashboard. Returns the chosen method, or null when the
/// sheet is closed.
Future<PaymentMethodOption?> showPaymentMethodSheet(BuildContext context, PaymentDirection direction) {
  return showModalBottomSheet<PaymentMethodOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (_) => PaymentMethodSheet(direction: direction),
  );
}

/// Every payment method the backend currently offers (methods switched OFF
/// in the Agent App don't appear), in the backend's order, as a 3-column
/// grid. Three rows show at once; further methods scroll into view.
class PaymentMethodSheet extends StatefulWidget {
  const PaymentMethodSheet({super.key, required this.direction});

  final PaymentDirection direction;

  @override
  State<PaymentMethodSheet> createState() => _PaymentMethodSheetState();
}

class _PaymentMethodSheetState extends State<PaymentMethodSheet> {
  static const _columns = 3;
  static const _visibleRows = 3;
  static const _spacing = 12.0;
  static const _sidePadding = 20.0;
  static const _cardAspect = 1.12; // width / height

  late Future<List<PaymentMethodOption>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<CustomerApi>().getPaymentMethods();
  }

  void _retry() => setState(() => _future = context.read<CustomerApi>().getPaymentMethods());

  bool get _isDeposit => widget.direction == PaymentDirection.deposit;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final cardWidth = (media.size.width - 2 * _sidePadding - (_columns - 1) * _spacing) / _columns;
    final cardHeight = cardWidth / _cardAspect;
    // Three full rows plus a peek of the next one, so more methods visibly
    // scroll into view; never taller than most of the screen.
    final gridHeight = (_visibleRows * cardHeight + (_visibleRows - 1) * _spacing + 0.35 * cardHeight + _spacing)
        .clamp(cardHeight, media.size.height * 0.6);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.screenBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      padding: EdgeInsets.only(bottom: media.padding.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(color: AppColors.cardBorder, borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(_sidePadding, 16, 8, 16),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                  child: Icon(
                    _isDeposit ? Icons.account_balance_wallet_rounded : Icons.north_east_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_isDeposit ? AppStrings.deposit : AppStrings.withdraw, style: AppTextStyles.headline),
                      const SizedBox(height: 2),
                      Text(
                        _isDeposit ? AppStrings.chooseDepositMethod : AppStrings.chooseWithdrawMethod,
                        style: AppTextStyles.muted,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: AppStrings.close,
                  icon: const Icon(Icons.close_rounded, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          SizedBox(
            height: gridHeight,
            child: FutureBuilder<List<PaymentMethodOption>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator(color: AppColors.primary));
                }
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return _Message(
                    text: error is ApiException ? error.message : AppStrings.methodsLoadFailed,
                    onRetry: _retry,
                  );
                }
                final methods = snapshot.data!;
                if (methods.isEmpty) return _Message(text: AppStrings.noMethods);
                return GridView.builder(
                  key: const Key('payment-method-grid'),
                  padding: const EdgeInsets.fromLTRB(_sidePadding, 0, _sidePadding, _spacing),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisSpacing: _spacing,
                    crossAxisSpacing: _spacing,
                    childAspectRatio: _cardAspect,
                  ),
                  itemCount: methods.length,
                  itemBuilder: (context, i) => _MethodCard(
                    option: methods[i],
                    onTap: () => Navigator.of(context).pop(methods[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.option, required this.onTap});

  final PaymentMethodOption option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final info = option.info;
    final radius = BorderRadius.circular(20);
    return Material(
      key: Key('method-${info.id}'),
      // A light wash of the method's own color, as in the BAARI design.
      color: Color.alphaBlend(info.color.withOpacity(0.07), Colors.white),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: info.color.withOpacity(0.18), width: 1.2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: LayoutBuilder(
            builder: (context, box) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MethodIcon(method: info.id, size: (box.maxHeight * 0.52).clamp(28.0, 56.0)),
                SizedBox(height: box.maxHeight * 0.07),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    info.label,
                    maxLines: 1,
                    style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: AppTextStyles.muted, textAlign: TextAlign.center),
            if (onRetry != null) TextButton(onPressed: onRetry, child: Text(AppStrings.tryAgain)),
          ],
        ),
      ),
    );
  }
}
