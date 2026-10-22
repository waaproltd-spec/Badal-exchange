import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../theme/colors.dart';

/// Compact "Payment Location" card for cash-desk deposits (1XBET,
/// 888STARZ): the city and street the platform asks for when the customer
/// makes a payment code, each with a Copy button. The header folds the
/// values away. Side by side on wider phones, stacked on narrow ones.
class PaymentLocationCard extends StatefulWidget {
  const PaymentLocationCard({super.key, this.city, this.street});

  final String? city;
  final String? street;

  @override
  State<PaymentLocationCard> createState() => _PaymentLocationCardState();
}

class _PaymentLocationCardState extends State<PaymentLocationCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final fields = [
      if ((widget.city ?? '').isNotEmpty)
        _LocationField(
            copyKey: const Key('copy-city'), icon: Icons.location_city_rounded, label: AppStrings.city, value: widget.city!),
      if ((widget.street ?? '').isNotEmpty)
        _LocationField(
            copyKey: const Key('copy-street'), icon: Icons.add_road_rounded, label: AppStrings.street, value: widget.street!),
    ];
    final divider = Divider(height: 1, thickness: 1, color: AppColors.cardBorder);

    return Container(
      key: const Key('payment-location'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('payment-location-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
                    child: Icon(Icons.location_on_rounded, color: AppColors.primary, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppStrings.paymentLocation,
                            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(AppStrings.paymentLocationHint,
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  Icon(_open ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
          if (_open && fields.isNotEmpty) ...[
            divider,
            LayoutBuilder(builder: (context, constraints) {
              // Side by side only when each half fits its icon, full-size
              // value and Copy; otherwise one per row, so nothing shrinks.
              if (fields.length == 2 && (constraints.maxWidth - 1) / 2 >= _LocationField.widthFor(context, fields)) {
                return IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(child: fields[0]),
                      VerticalDivider(width: 1, thickness: 1, color: AppColors.cardBorder, indent: 10, endIndent: 10),
                      Expanded(child: fields[1]),
                    ],
                  ),
                );
              }
              return Column(children: [
                for (var i = 0; i < fields.length; i++) ...[if (i > 0) divider, fields[i]],
              ]);
            }),
          ],
        ],
      ),
    );
  }
}

class _LocationField extends StatelessWidget {
  const _LocationField({required this.copyKey, required this.icon, required this.label, required this.value});

  final Key copyKey;
  final IconData icon;
  final String label;
  final String value;

  static const _valueStyle = TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5);

  /// Width a field needs to show the longest of [fields] unscaled: padding,
  /// icon and gaps (12+36+10+6+10) plus about 80 for the Copy button.
  static double widthFor(BuildContext context, List<_LocationField> fields) {
    var widest = 0.0;
    for (final f in fields) {
      final painter = TextPainter(
        text: TextSpan(text: f.value, style: _valueStyle),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return 74 + 80 + widest;
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(AppStrings.copied(value))));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: _valueStyle.copyWith(color: AppColors.textPrimary)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            key: copyKey,
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(AppStrings.copy),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryDark,
              side: BorderSide(color: AppColors.primary, width: 1.3),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
