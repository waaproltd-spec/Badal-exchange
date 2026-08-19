import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../l10n/strings.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../root/root_shell.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthProvider>().register(
            phone: _phoneController.text.trim(),
            name: _nameController.text.trim(),
            password: _passwordController.text,
          );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RootShell()),
        (route) => false,
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.register, style: AppTextStyles.title)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Create your account', style: AppTextStyles.headline),
              const SizedBox(height: 8),
              Text('Start exchanging with Badal Exchange', style: AppTextStyles.muted),
              const SizedBox(height: 32),
              AppTextField(
                label: AppStrings.fullName,
                controller: _nameController,
                keyboardType: TextInputType.name,
                hint: 'e.g. Amina Hassan',
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your full name' : null,
              ),
              const SizedBox(height: 20),
              AppTextField(
                label: AppStrings.phoneNumber,
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                hint: 'e.g. 2526XXXXXXX',
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.telephoneNumber],
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter your phone number' : null,
              ),
              const SizedBox(height: 20),
              AppTextField(
                label: AppStrings.password,
                controller: _passwordController,
                obscureText: true,
                hint: 'At least 8 characters',
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Enter a password';
                  if (v.length < 8) return 'Password must be at least 8 characters';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              AppTextField(
                label: AppStrings.confirmPassword,
                controller: _confirmPasswordController,
                obscureText: true,
                hint: 'Re-enter your password',
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) {
                  if (v != _passwordController.text) return 'Passwords do not match';
                  return null;
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 28),
              PrimaryButton(label: AppStrings.register, onPressed: _submit, loading: _submitting),
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text.rich(
                    TextSpan(
                      text: '${AppStrings.haveAccount} ',
                      style: AppTextStyles.muted,
                      children: [
                        TextSpan(
                          text: AppStrings.login,
                          style: AppTextStyles.body.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
