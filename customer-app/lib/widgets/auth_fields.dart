import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Keeps only the 9 local digits of a Somali number: drops anything that is
/// not a digit, a pasted 252 country code or leading 0, and digits past 9.
class SomaliLocalNumberFormatter extends TextInputFormatter {
  const SomaliLocalNumberFormatter();

  static String clean(String text) {
    var digits = text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 9 && digits.startsWith('252')) digits = digits.substring(3);
    if (digits.startsWith('0')) digits = digits.replaceFirst(RegExp(r'^0+'), '');
    return digits.length > 9 ? digits.substring(0, 9) : digits;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = clean(newValue.text);
    if (text == newValue.text) return newValue;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// Uppercase label above a rounded white field.
class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTextStyles.label),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

OutlineInputBorder _border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: color, width: 1.5),
    );

InputDecoration _decoration({String? hint, Widget? prefix, Widget? suffix}) => InputDecoration(
      prefixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      hintText: hint,
      hintStyle: AppTextStyles.fieldValue.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w500, fontSize: 15),
      filled: true,
      fillColor: AppColors.fieldBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      prefixIcon: prefix,
      suffixIcon: suffix,
      errorMaxLines: 2,
      border: _border(AppColors.fieldBorder),
      enabledBorder: _border(AppColors.fieldBorder),
      disabledBorder: _border(AppColors.fieldBorder),
      focusedBorder: _border(AppColors.primary),
      errorBorder: _border(AppColors.error),
      focusedErrorBorder: _border(AppColors.error),
    );

/// The tinted square holding a field's icon.
class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: AppColors.primaryDark),
      ),
    );
  }
}

/// A labeled text field with an icon tile on the left; for passwords, an
/// eye button on the right shows or hides the text (hidden by default).
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.label,
    required this.icon,
    required this.controller,
    this.hint,
    this.password = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.validator,
    this.onSubmitted,
  });

  final String label;
  final IconData icon;
  final TextEditingController controller;
  final String? hint;
  final bool password;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onSubmitted;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final obscure = widget.password && _hidden;
    return _Labeled(
      label: widget.label,
      child: TextFormField(
        controller: widget.controller,
        obscureText: obscure,
        enableSuggestions: !widget.password,
        autocorrect: !widget.password,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        validator: widget.validator,
        onFieldSubmitted: widget.onSubmitted,
        style: AppTextStyles.fieldValue,
        decoration: _decoration(
          hint: widget.hint,
          prefix: _IconTile(widget.icon),
          suffix: widget.password
              ? IconButton(
                  tooltip: obscure ? AppStrings.showPassword : AppStrings.hidePassword,
                  icon: Icon(
                    obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: AppColors.primaryDark,
                  ),
                  onPressed: () => setState(() => _hidden = !_hidden),
                )
              : null,
        ),
      ),
    );
  }
}

/// Phone number with the Somali flag and +252 shown separately: the
/// customer types only the 9 local digits.
class SomaliPhoneField extends StatelessWidget {
  const SomaliPhoneField({
    super.key,
    required this.label,
    required this.controller,
    this.textInputAction,
    this.validator,
  });

  final String label;

  /// Holds the 9 local digits only.
  final TextEditingController controller;
  final TextInputAction? textInputAction;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return _Labeled(
      label: label,
      child: TextFormField(
        controller: controller,
        keyboardType: TextInputType.phone,
        textInputAction: textInputAction,
        autofillHints: const [AutofillHints.telephoneNumberNational],
        inputFormatters: const [SomaliLocalNumberFormatter()],
        validator: validator,
        style: AppTextStyles.fieldValue.copyWith(letterSpacing: 0.5),
        decoration: _decoration(
          hint: AppStrings.phoneDigitsHint,
          prefix: Container(
            key: const Key('country-code'),
            height: 56,
            margin: const EdgeInsets.only(left: 1.5, right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.primaryTint,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(14.5)),
              border: Border(right: BorderSide(color: AppColors.fieldBorder, width: 1.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Somali flag: a white star on light blue.
                Container(
                  width: 30,
                  height: 20,
                  decoration: BoxDecoration(color: const Color(0xFF4189DD), borderRadius: BorderRadius.circular(3)),
                  child: const Icon(Icons.star_rounded, size: 14, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Text('+252', style: AppTextStyles.fieldValue.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
