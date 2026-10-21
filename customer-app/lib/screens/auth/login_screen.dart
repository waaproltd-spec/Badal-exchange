import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../utils/support_links.dart';
import '../../l10n/strings.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/auth_fields.dart';
import '../../widgets/brand/baari_logo.dart';
import '../../widgets/primary_button.dart';
import '../root/root_shell.dart';
import 'register_screen.dart';

/// Log In: +252 phone (9 digits typed) and password, Remember me, Forgot
/// password (support contacts), and Create Account.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _rememberMe = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
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
      await context.read<AuthProvider>().loginWithLocalNumber(
            local: _phoneController.text,
            password: _passwordController.text,
            rememberMe: _rememberMe,
          );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RootShell()),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.status == 401 ? AppStrings.invalidLogin : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _createAccount() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterScreen()));
  }

  void _forgotPassword() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.screenBackground,
      builder: (_) => _ForgotPasswordSheet(api: context.read<CustomerApi>()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: _Decor())),
          SafeArea(
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                  children: [
                    const Center(child: BaariLogoMark(size: 76)),
                    const SizedBox(height: 10),
                    const Center(child: BaariWordmark(fontSize: 32)),
                    const SizedBox(height: 18),
                    Text(AppStrings.welcomeBack, textAlign: TextAlign.center, style: AppTextStyles.headline.copyWith(fontSize: 30)),
                    const SizedBox(height: 4),
                    Text(AppStrings.loginSubtitle, textAlign: TextAlign.center, style: AppTextStyles.muted.copyWith(fontSize: 15)),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: AppColors.cardBorderSoft),
                        boxShadow: [
                          BoxShadow(color: AppColors.purpleDark.withOpacity(0.06), blurRadius: 24, offset: const Offset(0, 8)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SomaliPhoneField(
                            key: const Key('login-phone'),
                            label: AppStrings.phoneNumber,
                            controller: _phoneController,
                            textInputAction: TextInputAction.next,
                            validator: (v) => RegExp(r'^\d{9}$').hasMatch(v ?? '') ? null : AppStrings.enterPhone9,
                          ),
                          const SizedBox(height: 14),
                          AuthTextField(
                            key: const Key('login-password'),
                            label: AppStrings.password,
                            icon: Icons.lock_rounded,
                            controller: _passwordController,
                            hint: '••••••••',
                            password: true,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _submit(),
                            validator: (v) => (v ?? '').isEmpty ? AppStrings.enterPassword : null,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  key: const Key('remember-me'),
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => setState(() => _rememberMe = !_rememberMe),
                                  child: Row(
                                    children: [
                                      Checkbox(
                                        value: _rememberMe,
                                        onChanged: (v) => setState(() => _rememberMe = v ?? true),
                                        activeColor: AppColors.purple,
                                        visualDensity: VisualDensity.compact,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                                      ),
                                      Flexible(
                                        child: Text(
                                          AppStrings.rememberMe,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTextStyles.body.copyWith(fontSize: 14),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // Shrinks rather than overflows on narrow phones.
                              Flexible(
                                child: TextButton(
                                  key: const Key('forgot-password'),
                                  onPressed: _forgotPassword,
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                    minimumSize: const Size(0, 40),
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      AppStrings.forgotPassword,
                                      style: AppTextStyles.body.copyWith(
                                        fontSize: 14,
                                        color: AppColors.primaryDark,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 6),
                            Container(
                              key: const Key('login-error'),
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
                          const SizedBox(height: 12),
                          PrimaryButton(
                            key: const Key('login-submit'),
                            label: AppStrings.login,
                            trailingIcon: Icons.arrow_forward_rounded,
                            gradient: AppColors.brandGradient,
                            onPressed: _submit,
                            loading: _submitting,
                          ),
                          const SizedBox(height: 14),
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
                          const SizedBox(height: 14),
                          OutlinedButton.icon(
                            key: const Key('create-account'),
                            onPressed: _createAccount,
                            icon: Icon(Icons.person_add_alt_1_rounded, color: AppColors.primaryDark, size: 22),
                            label: Text(
                              AppStrings.register,
                              style: AppTextStyles.body.copyWith(
                                fontSize: 16,
                                color: AppColors.primaryDark,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(54),
                              side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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

/// How to get a new password: contact support (links set in the Agent App).
class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet({required this.api});

  final CustomerApi api;

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  Map<String, String>? _contacts;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.api.getSupportContacts().then(
      (c) => mounted ? setState(() => _contacts = c) : null,
      onError: (_) => mounted ? setState(() => _failed = true) : null,
    );
  }

  static Uri? _link(String kind, String value) => supportLink(kind, value);

  @override
  Widget build(BuildContext context) {
    final contacts = _contacts;
    final links = [
      for (final (kind, label, icon) in const [
        ('whatsapp', 'WhatsApp', Icons.chat_rounded),
        ('telegram', 'Telegram', Icons.send_rounded),
        ('facebook', 'Facebook', Icons.facebook_rounded),
      ])
        if (contacts != null && (contacts[kind] ?? '').isNotEmpty && _link(kind, contacts[kind]!) != null)
          (label, icon, _link(kind, contacts[kind]!)!),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(AppStrings.forgotPasswordTitle, style: AppTextStyles.title),
            const SizedBox(height: 8),
            Text(AppStrings.forgotPasswordBody, style: AppTextStyles.muted),
            const SizedBox(height: 16),
            if (contacts == null && !_failed)
              Center(child: CircularProgressIndicator(color: AppColors.primary))
            else if (links.isEmpty)
              Text(AppStrings.noSupportContacts, style: AppTextStyles.muted.copyWith(color: AppColors.error))
            else
              for (final (label, icon, uri) in links)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: OutlinedButton.icon(
                    key: Key('support-$label'),
                    onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication),
                    icon: Icon(icon, color: AppColors.primaryDark),
                    label: Text(label, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// Soft brand shapes: a purple blob with an orange dot at the top left, a
/// lilac circle at the top right and a lilac wave at the bottom.
class _Decor extends StatelessWidget {
  const _Decor();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: -120,
          top: -140,
          child: Container(
            width: 290,
            height: 260,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [AppColors.purpleDark, AppColors.purple]),
            ),
          ),
        ),
        Positioned(
          left: 66,
          top: 54,
          child: Container(
            width: 50,
            height: 50,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [AppColors.lightGold, AppColors.accentOrange]),
            ),
          ),
        ),
        Positioned(
          right: -90,
          top: 10,
          child: Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.screenBackground, AppColors.purpleSecondary.withOpacity(0.35)],
              ),
            ),
          ),
        ),
        Positioned(
          left: -80,
          right: -80,
          bottom: -170,
          child: Container(
            height: 250,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.elliptical(400, 130)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.purpleSecondary.withOpacity(0.25), AppColors.purple.withOpacity(0.5)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
