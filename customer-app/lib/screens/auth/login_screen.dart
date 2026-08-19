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
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthProvider>().login(
            phone: _phoneController.text.trim(),
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
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            children: [
              Text(
                AppStrings.appName,
                style: AppTextStyles.headline.copyWith(color: AppColors.primaryDark),
              ),
              const SizedBox(height: 8),
              Text('Log in to continue', style: AppTextStyles.muted),
              const SizedBox(height: 36),
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
                hint: '••••••••',
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 28),
              PrimaryButton(label: AppStrings.login, onPressed: _submit, loading: _submitting),
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  ),
                  child: Text.rich(
                    TextSpan(
                      text: '${AppStrings.noAccount} ',
                      style: AppTextStyles.muted,
                      children: [
                        TextSpan(
                          text: AppStrings.register,
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
