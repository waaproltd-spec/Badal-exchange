import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/auth_fields.dart';
import '../../widgets/brand/baari_logo.dart';
import '../../widgets/primary_button.dart';
import '../root/root_shell.dart';
import 'login_screen.dart';

/// Create Account: full name, +252 phone (9 digits typed), password and
/// confirmation with show/hide. The backend checks everything again.
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
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthProvider>().register(
            // The backend's format: 252 + the 9 local digits.
            phone: '252${_phoneController.text}',
            name: _nameController.text.trim(),
            password: _passwordController.text,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RootShell()),
        (route) => false,
      );
      messenger.showSnackBar(SnackBar(content: Text(AppStrings.accountCreated)));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _goToLogin() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle.light,
        backgroundColor: AppColors.purpleDark,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(decoration: BoxDecoration(gradient: AppColors.headerGradient)),
        leading: IconButton(
          tooltip: AppStrings.back,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _goToLogin,
        ),
        title: Text(AppStrings.register, style: AppTextStyles.appBarTitle),
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: _Decor())),
          SafeArea(
            top: false,
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  children: [
                    const Align(alignment: Alignment.centerLeft, child: BaariLogo(markSize: 44)),
                    const SizedBox(height: 18),
                    Text(AppStrings.createYourAccount, style: AppTextStyles.headline),
                    const SizedBox(height: 4),
                    Text(AppStrings.registerSubtitle, style: AppTextStyles.muted),
                    const SizedBox(height: 20),
                    AuthTextField(
                      key: const Key('register-name'),
                      label: AppStrings.fullName,
                      icon: Icons.person_rounded,
                      controller: _nameController,
                      hint: AppStrings.fullNameHint,
                      keyboardType: TextInputType.name,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.name],
                      validator: (v) => (v ?? '').trim().isEmpty ? AppStrings.enterFullName : null,
                    ),
                    const SizedBox(height: 14),
                    SomaliPhoneField(
                      key: const Key('register-phone'),
                      label: AppStrings.phoneNumber,
                      controller: _phoneController,
                      textInputAction: TextInputAction.next,
                      validator: (v) => !RegExp(r'^\d{9}$').hasMatch(v ?? '')
                          ? AppStrings.enterPhone9
                          : (hasApprovedPhonePrefix(v!) ? null : AppStrings.phonePrefixes),
                    ),
                    const SizedBox(height: 14),
                    AuthTextField(
                      key: const Key('register-password'),
                      label: AppStrings.password,
                      icon: Icons.lock_rounded,
                      controller: _passwordController,
                      hint: AppStrings.passwordHint,
                      password: true,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      validator: (v) => (v ?? '').length < 8 ? AppStrings.passwordTooShort : null,
                    ),
                    const SizedBox(height: 14),
                    AuthTextField(
                      key: const Key('register-confirm'),
                      label: AppStrings.confirmPassword,
                      icon: Icons.lock_rounded,
                      controller: _confirmPasswordController,
                      hint: AppStrings.confirmPasswordHint,
                      password: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.newPassword],
                      onSubmitted: (_) => _submit(),
                      validator: (v) => v != _passwordController.text ? AppStrings.passwordsDontMatch : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        key: const Key('register-error'),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.error.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.error.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    PrimaryButton(
                      key: const Key('register-submit'),
                      label: AppStrings.register,
                      trailingIcon: Icons.arrow_forward_rounded,
                      gradient: AppColors.brandGradient,
                      onPressed: _submit,
                      loading: _submitting,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Divider(color: AppColors.cardBorder, thickness: 1.2)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(AppStrings.or, style: AppTextStyles.label),
                        ),
                        Expanded(child: Divider(color: AppColors.cardBorder, thickness: 1.2)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('go-to-login'),
                      onPressed: _goToLogin,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: AppColors.surface.withOpacity(0.6),
                        side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_add_alt_1_rounded, color: AppColors.primaryDark, size: 22),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                text: '${AppStrings.haveAccount} ',
                                style: AppTextStyles.body.copyWith(fontSize: 14, color: AppColors.textPrimary),
                                children: [
                                  TextSpan(
                                    text: AppStrings.login,
                                    style: AppTextStyles.body.copyWith(
                                      fontSize: 14,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft brand shapes behind the form: a purple arc with an orange dot at
/// the top right and a lilac wave at the bottom.
class _Decor extends StatelessWidget {
  const _Decor();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          right: -90,
          top: -110,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [AppColors.purple.withOpacity(0.85), AppColors.purpleDark.withOpacity(0.9)],
              ),
            ),
          ),
        ),
        Positioned(
          right: 18,
          top: 40,
          child: Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [AppColors.lightGold, AppColors.accentOrange]),
            ),
          ),
        ),
        Positioned(
          left: -80,
          right: -80,
          bottom: -170,
          child: Container(
            height: 240,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.elliptical(400, 120)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.purpleSecondary.withOpacity(0.25), AppColors.purple.withOpacity(0.45)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
