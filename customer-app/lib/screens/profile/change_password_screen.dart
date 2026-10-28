import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/auth_fields.dart';
import '../../widgets/primary_button.dart';

/// Profile -> Change Password: the current password, then the new one
/// twice. This phone stays signed in.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<CustomerApi>().changePassword(currentPassword: _current.text, newPassword: _next.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.passwordChanged)));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code == 'INVALID_PASSWORD' ? AppStrings.wrongCurrentPassword : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.changePassword, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              AuthTextField(
                key: const Key('current-password'),
                label: AppStrings.currentPassword,
                icon: Icons.lock_outline_rounded,
                controller: _current,
                hint: AppStrings.currentPasswordHint,
                password: true,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
                validator: (v) => (v ?? '').isEmpty ? AppStrings.enterPassword : null,
              ),
              const SizedBox(height: 16),
              AuthTextField(
                key: const Key('new-password'),
                label: AppStrings.newPassword,
                icon: Icons.lock_rounded,
                controller: _next,
                hint: AppStrings.passwordHint,
                password: true,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) {
                  if ((v ?? '').length < 8) return AppStrings.passwordTooShort;
                  if (v == _current.text) return AppStrings.newPasswordSame;
                  return null;
                },
              ),
              const SizedBox(height: 16),
              AuthTextField(
                key: const Key('confirm-password'),
                label: AppStrings.confirmPassword,
                icon: Icons.lock_rounded,
                controller: _confirm,
                hint: AppStrings.confirmPasswordHint,
                password: true,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                onSubmitted: (_) => _submit(),
                validator: (v) => v != _next.text ? AppStrings.passwordsDontMatch : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, key: const Key('change-password-error'), style: const TextStyle(color: AppColors.error)),
              ],
              const SizedBox(height: 28),
              PrimaryButton(
                key: const Key('save-password'),
                label: AppStrings.changePassword,
                loading: _saving,
                onPressed: _saving ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
