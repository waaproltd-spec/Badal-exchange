import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../l10n/strings.dart';
import '../models/payment_method.dart';
import '../models/payment_numbers.dart';
import '../theme/colors.dart';
import '../theme/theme_mode.dart';
import '../theme/text_styles.dart';
import 'method_icon.dart';

enum PaymentDirection { deposit, withdraw }

/// Opens the Deposit or Withdraw method picker as a bottom sheet over the
/// (dimmed) wallet dashboard. Returns the chosen method, or null when the
/// sheet is closed. [ownPhone] (the customer's registered number) limits
/// mobile money to that number's own network: deposits come from it and
/// withdrawals go to it.
Future<PaymentMethodOption?> showPaymentMethodSheet(BuildContext context, PaymentDirection direction, {String? ownPhone}) {
  return showModalBottomSheet<PaymentMethodOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (_) => PaymentMethodSheet(direction: direction, ownPhone: ownPhone),
  );
}

/// Every payment method the backend currently offers (methods switched OFF
/// in the Agent App don't appear), in the backend's order, as a 3-column
/// grid. Every method fits on screen without scrolling: cards get shorter
/// on small phones. Only if even the shortest cards can't fit (a very small
/// screen or many methods) does the grid scroll.
class PaymentMethodSheet extends StatefulWidget {
  const PaymentMethodSheet({super.key, required this.direction, this.ownPhone});

  final PaymentDirection direction;

  /// The customer's registered number: a deposit shows only its network's mobile money.
  final String? ownPhone;

  @override
  State<PaymentMethodSheet> createState() => _PaymentMethodSheetState();
}

class _PaymentMethodSheetState extends State<PaymentMethodSheet> {
  static const _columns = 3;
  static const _spacing = 10.0;
  static const _sidePadding = 16.0;
  static const _cardAspect = 1.2; // width / height, when there is room
  static const _minCardHeight = 64.0;

  /// Space the sheet keeps for its handle, title and bottom padding.
  static const _headerHeight = 132.0;

  late Future<List<PaymentMethodOption>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _retry() => setState(() => _future = _load());

  /// The customer's numbers: when an admin authorized another number on a
  /// network, that network is offered too (never fails: none if unreadable).
  PaymentNumbers _numbers = PaymentNumbers.none;

  Future<List<PaymentMethodOption>> _load() async {
    final api = context.read<CustomerApi>();
    final results = await Future.wait<Object>([api.getPaymentMethods(), api.getPaymentNumbers()]);
    _numbers = results[1] as PaymentNumbers;
    return results[0] as List<PaymentMethodOption>;
  }

  bool get _isDeposit => widget.direction == PaymentDirection.deposit;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final cardWidth = (media.size.width - 2 * _sidePadding - (_columns - 1) * _spacing) / _columns;
    // The sheet may use the screen below the status bar, minus a strip of
    // the dimmed dashboard and the bottom inset.
    final maxGrid = media.size.height - media.padding.top - media.padding.bottom - _headerHeight - 72;

    /// Card height and grid height so all [count] methods fit when possible.
    (double, double) layout(int count) {
      final rows = (count / _columns).ceil().clamp(1, 99);
      final gaps = (rows - 1) * _spacing + _spacing;
      final card = ((maxGrid - gaps) / rows).clamp(_minCardHeight, cardWidth / _cardAspect);
      return (card, (rows * card + gaps).clamp(card, maxGrid));
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.screenBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
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
                  decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
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
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_isDeposit ? AppStrings.deposit : AppStrings.withdraw,
                            maxLines: 1, style: AppTextStyles.headline),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isDeposit ? AppStrings.chooseDepositMethod : AppStrings.chooseWithdrawMethod,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
          // Flexible: on a screen shorter than estimated the grid takes what
          // is left and scrolls instead of overflowing the sheet.
          Flexible(
            child: FutureBuilder<List<PaymentMethodOption>>(
              future: _future,
              builder: (context, snapshot) {
                final placeholder = layout(9).$2;
                if (snapshot.connectionState != ConnectionState.done) {
                  return SizedBox(
                    height: placeholder,
                    child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
                  );
                }
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return SizedBox(
                    height: placeholder,
                    child: _Message(
                      text: error is ApiException ? error.message : AppStrings.methodsLoadFailed,
                      onRetry: _retry,
                    ),
                  );
                }
                final methods = depositMethodsFor(snapshot.data!, widget.ownPhone, numbers: _numbers);
                if (methods.isEmpty) return SizedBox(height: placeholder, child: _Message(text: AppStrings.noMethods));
                final (cardHeight, gridHeight) = layout(methods.length);
                return SizedBox(
                  height: gridHeight,
                  child: GridView.builder(
                    key: const Key('payment-method-grid'),
                    padding: const EdgeInsets.fromLTRB(_sidePadding, 0, _sidePadding, _spacing),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns,
                      mainAxisSpacing: _spacing,
                      crossAxisSpacing: _spacing,
                      mainAxisExtent: cardHeight,
                    ),
                    itemCount: methods.length,
                    itemBuilder: (context, i) => _MethodCard(
                      option: methods[i],
                      onTap: () => Navigator.of(context).pop(methods[i]),
                    ),
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
      color: Color.alphaBlend(info.color.withOpacity(AppThemeMode.isDark ? 0.14 : 0.07), AppColors.surface),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: info.color.withOpacity(AppThemeMode.isDark ? 0.35 : 0.18), width: 1.2),
          ),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: LayoutBuilder(
            builder: (context, box) {
              // Logo as wide as the card allows, the name below it.
              final nameHeight = (box.maxHeight * 0.24).clamp(16.0, 24.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth, maxHeight: box.maxWidth / MethodLogo.aspect),
                      child: MethodLogo(method: info.id, radius: 10),
                    ),
                  ),
                  SizedBox(height: box.maxHeight * 0.06),
                  SizedBox(
                    height: nameHeight,
                    width: box.maxWidth,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        info.label,
                        maxLines: 1,
                        style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 17),
                      ),
                    ),
                  ),
                ],
              );
            },
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
