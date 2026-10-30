import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/payment_numbers.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import 'own_phone_box.dart';

/// The phone number a mobile-money deposit comes from / a withdrawal goes to.
/// The registered number, locked, for everyone -- unless an admin authorized
/// this customer for the network: then the number can be typed, or picked from
/// the registered number is the starting value.
/// The screen owns [controller] (the 9 digits after 252) and sends what it
/// holds, so what the customer sees in the box is exactly what is used.
class PayNumberBox extends StatefulWidget {
  const PayNumberBox({super.key, required this.method, required this.ownLocal, required this.numbers, required this.controller, this.fieldKey});

  final String method;

  /// The registered number's 9 digits; null when it can't be read.
  final String? ownLocal;
  final PaymentNumbers numbers;
  final TextEditingController controller;
  final Key? fieldKey;

  @override
  State<PayNumberBox> createState() => _PayNumberBoxState();
}

class _PayNumberBoxState extends State<PayNumberBox> {
  @override
  Widget build(BuildContext context) {
    if (!widget.numbers.allows(widget.method)) {
      return OwnPhoneBox(key: widget.fieldKey, local: widget.ownLocal);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 18,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(AppStrings.phoneNumber.toUpperCase(), maxLines: 1, style: AppTextStyles.label),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 58,
          decoration: BoxDecoration(
            color: AppColors.fieldBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.fieldBorder, width: 1.5),
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              Text('+252', style: AppTextStyles.muted.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 10), color: AppColors.fieldBorder),
              Expanded(
                child: TextField(
                  key: widget.fieldKey,
                  controller: widget.controller,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
                  style: AppTextStyles.fieldValue.copyWith(fontWeight: FontWeight.w800),
                  decoration: const InputDecoration(border: InputBorder.none, isDense: true, hintText: '61xxxxxxx'),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ],
    );
  }
}
