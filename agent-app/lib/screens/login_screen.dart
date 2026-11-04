import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import 'home_shell.dart';
import '../l10n/tr.dart';

/// The nine digits typed after the +252 country code. Whatever the agent
/// types or pastes is cleaned up: only digits are kept, a country code that
/// came with the number (+252, 252, even twice: 252252) and a leading 0 are
/// dropped, and nothing past nine digits is accepted. So the number can never
/// end up with the country code twice.
String localPhoneDigits(String input) {
  var digits = input.replaceAll(RegExp(r'\D'), '');
  var changed = true;
  while (changed) {
    changed = false;
    if (digits.startsWith('252')) {
      digits = digits.substring(3);
      changed = true;
    } else if (digits.startsWith('0')) {
      digits = digits.substring(1);
      changed = true;
    }
  }
  return digits.length > 9 ? digits.substring(0, 9) : digits;
}

/// Keeps the phone field to [localPhoneDigits] while typing and pasting.
class LocalPhoneFormatter extends TextInputFormatter {
  const LocalPhoneFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final cleaned = localPhoneDigits(newValue.text);
    if (cleaned == newValue.text) return newValue;
    return TextEditingValue(text: cleaned, selection: TextSelection.collapsed(offset: cleaned.length));
  }
}

/// Agent login: purple and white, the +252 country code fixed in front of the
/// nine digits, the password with a show / hide eye, and the same sign-in as
/// before ([Session.login] with the full number, 252 and the nine digits).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _countryCode = '252';

  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit(Session session) async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final ok = await session.login(
      phone: '$_countryCode${localPhoneDigits(_phoneController.text)}',
      password: _passwordController.text,
    );
    if (ok && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();

    return Scaffold(
      backgroundColor: const Color(0xFFFBF9FF),
      body: Stack(
        children: [
          const Positioned(top: 0, left: 0, right: 0, height: 210, child: _Wave(top: true)),
          const Positioned(bottom: 0, left: 0, right: 0, height: 130, child: _Wave(top: false)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 36),
                        Center(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(26),
                              boxShadow: [
                                BoxShadow(color: AppColors.purpleDark.withOpacity(0.28), blurRadius: 24, offset: const Offset(0, 10)),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(26),
                              child: Image.asset('assets/brand/logo.png', key: const Key('brand-logo'), width: 92, height: 92),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Tx(
                          'BADAL EXCHANGE',
                          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.purpleDark, letterSpacing: 0.4),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                            decoration: BoxDecoration(color: const Color(0xFFEBDDFB), borderRadius: BorderRadius.circular(30)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: const [
                              Icon(Icons.account_circle_rounded, color: AppColors.purpleDark, size: 22),
                              SizedBox(width: 8),
                              Tx('Agent App', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: AppColors.purpleDark)),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 30),
                        _Field(
                          child: Row(children: [
                            const SizedBox(width: 12),
                            const _CountryCode(),
                            Container(width: 1.4, height: 28, margin: const EdgeInsets.symmetric(horizontal: 10), color: const Color(0xFFD9C3F2)),
                            Expanded(
                              child: TextFormField(
                                key: const Key('phone-field'),
                                controller: _phoneController,
                                decoration: const InputDecoration(
                                  hintText: 'Phone number',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  errorBorder: InputBorder.none,
                                  focusedErrorBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.symmetric(vertical: 18),
                                ),
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                                keyboardType: TextInputType.phone,
                                textInputAction: TextInputAction.next,
                                inputFormatters: const [LocalPhoneFormatter()],
                                validator: (v) => localPhoneDigits(v ?? '').length == 9 ? null : 'Enter the 9 digits after +252',
                              ),
                            ),
                            const SizedBox(width: 12),
                          ]),
                        ),
                        const SizedBox(height: 14),
                        _Field(
                          child: Row(children: [
                            const SizedBox(width: 16),
                            const Icon(Icons.lock_rounded, color: AppColors.purpleDark, size: 26),
                            const SizedBox(width: 14),
                            Expanded(
                              child: TextFormField(
                                key: const Key('password-field'),
                                controller: _passwordController,
                                decoration: const InputDecoration(
                                  hintText: 'Password',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  errorBorder: InputBorder.none,
                                  focusedErrorBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.symmetric(vertical: 18),
                                ),
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                                obscureText: _obscurePassword,
                                enableSuggestions: false,
                                autocorrect: false,
                                textInputAction: TextInputAction.done,
                                validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                                onFieldSubmitted: (_) => _submit(session),
                              ),
                            ),
                            IconButton(
                              key: const Key('toggle-password'),
                              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                              icon: Icon(_obscurePassword ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                  color: AppColors.purpleDark, size: 26),
                              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            ),
                            const SizedBox(width: 4),
                          ]),
                        ),
                        if (session.loginError != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            key: const Key('login-error'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.statusFailed.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.statusFailed.withOpacity(0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline, color: AppColors.statusFailed, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Tx(
                                    session.loginError!,
                                    style: const TextStyle(color: AppColors.statusFailed, fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 26),
                        _LoginButton(busy: session.isBusy, onPressed: () => _submit(session)),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFD9C3F2)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.verified_user_outlined, color: AppColors.purpleDark, size: 40),
                            Container(width: 1, height: 52, margin: const EdgeInsets.symmetric(horizontal: 14), color: const Color(0xFFD9C3F2)),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Tx('Authorized agents only.',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.purpleDark)),
                                SizedBox(height: 2),
                                Tx('Logging in registers this device for EVC Plus SMS payment verification.',
                                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                              ]),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A white rounded field with a soft purple outline and shadow.
class _Field extends StatelessWidget {
  const _Field({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFD9C3F2), width: 1.4),
          boxShadow: [BoxShadow(color: AppColors.purple.withOpacity(0.14), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: child,
      );
}

/// The Somali flag and +252, the default (and only) country code.
class _CountryCode extends StatelessWidget {
  const _CountryCode();

  @override
  Widget build(BuildContext context) => Row(
        key: const Key('country-code'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 28,
            decoration: BoxDecoration(color: const Color(0xFF4189DD), borderRadius: BorderRadius.circular(5)),
            child: const Icon(Icons.star_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('+252', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const Icon(Icons.arrow_drop_down_rounded, color: AppColors.purpleDark, size: 26),
        ],
      );
}

/// The purple gradient Log in button; a spinner while signing in.
class _LoginButton extends StatelessWidget {
  const _LoginButton({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: busy ? 0.8 : 1,
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF8A1CF0), Color(0xFF4B0A8F)]),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: AppColors.purpleDark.withOpacity(0.35), blurRadius: 18, offset: const Offset(0, 8))],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('login-button'),
              borderRadius: BorderRadius.circular(22),
              onTap: busy ? null : onPressed,
              child: SizedBox(
                height: 62,
                child: Center(
                  child: busy
                      ? const SizedBox(height: 26, width: 26, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                      : Row(mainAxisSize: MainAxisSize.min, children: const [
                          Icon(Icons.login_rounded, color: Colors.white, size: 28),
                          SizedBox(width: 12),
                          Tx('Log in', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                        ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The purple wave at the top (or the bottom) of the screen.
class _Wave extends StatelessWidget {
  const _Wave({required this.top});
  final bool top;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _WavePainter(top: top));
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.top});
  final bool top;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // A pale wave behind, then the deep purple one in front.
    final pale = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.55)
      ..cubicTo(w * 0.7, h * 1.0, w * 0.35, h * 0.2, 0, h * 0.85)
      ..close();
    final deep = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.42)
      ..cubicTo(w * 0.72, h * 0.95, w * 0.3, h * 0.15, 0, h * 0.5)
      ..close();
    canvas.save();
    if (!top) {
      canvas.translate(w, h);
      canvas.rotate(3.14159265);
    }
    canvas.drawPath(pale, Paint()..color = const Color(0xFFEBDDFB));
    canvas.drawPath(
      deep,
      Paint()
        ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF5A12B8), Color(0xFF3A0353)])
            .createShader(Rect.fromLTWH(0, 0, w, h)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.top != top;
}
