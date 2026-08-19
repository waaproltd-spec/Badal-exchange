import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Labeled input matching the mockup: 12px uppercase muted label above a
/// rounded, light gray-purple field with a 1.5px border.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.validator,
    this.textInputAction,
    this.autofocus = false,
    this.obscureText = false,
    this.enabled = true,
    this.autofillHints,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final bool obscureText;
  final bool enabled;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTextStyles.label),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          textInputAction: textInputAction,
          autofocus: autofocus,
          obscureText: obscureText,
          enabled: enabled,
          autofillHints: autofillHints,
          style: AppTextStyles.fieldValue,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppTextStyles.fieldValue.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w500),
            filled: true,
            fillColor: AppColors.fieldBackground,
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.fieldBorder, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.fieldBorder, width: 1.5),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.fieldBorder, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.error, width: 1.5),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.error, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
