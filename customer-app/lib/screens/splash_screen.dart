import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/customer_api.dart';
import '../state/auth_provider.dart';
import '../theme/colors.dart';
import '../widgets/brand/baari_logo.dart';
import 'auth/login_screen.dart';
import 'root/root_shell.dart';

/// The launch screen: a 3-second animation (the logo fades and zooms in, blue
/// and green glows with a turning light, then everything fades out), after
/// which the app goes where it always went -- the app shell when a session was
/// restored, the login screen otherwise. If the session is still being
/// restored when the animation ends, it waits for it.
///
/// Shown once per launch: the app rebuilds this screen when the language is
/// changed, and then it goes straight on without the animation.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.destination});

  /// Where to go after the animation (tests); by default the app shell or the login.
  final WidgetBuilder? destination;

  /// The animation is exactly this long.
  static const duration = Duration(milliseconds: 3000);

  /// True once the animation has been started in this launch of the app.
  static bool played = false;

  /// The glow colours (blue and green).
  static const glowBlue = Color(0xFF2F80FF);
  static const glowGreen = Color(0xFF1FD38E);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AuthProvider _auth;
  late final AnimationController _controller;
  bool _animating = false;
  bool _animationDone = false;
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    _controller = AnimationController(vsync: this, duration: SplashScreen.duration);
    // Shared payment-method catalog; doesn't block startup.
    unawaited(context.read<CustomerApi>().loadMethodCatalog());
    _animating = !SplashScreen.played;
    if (_animating) {
      SplashScreen.played = true;
      _controller.forward().whenComplete(() {
        if (!mounted) return;
        // Still restoring the session after the animation: a small spinner meanwhile.
        setState(() => _animationDone = true);
        _tryRedirect();
      });
    } else {
      _animationDone = true;
    }
    if (_auth.initializing) {
      _auth.addListener(_onAuthChanged);
    } else {
      _tryRedirect();
    }
  }

  void _onAuthChanged() {
    if (!_auth.initializing) {
      _auth.removeListener(_onAuthChanged);
      _tryRedirect();
    }
  }

  /// Goes on once the animation is over and the session is known.
  void _tryRedirect() {
    if (!mounted || _redirected || !_animationDone || _auth.initializing) return;
    _redirected = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: widget.destination ?? (_) => _auth.isAuthenticated ? const RootShell() : const LoginScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 0 -> 1 over [from, to] of the animation (0..1), eased.
  static double _ramp(double t, double from, double to, [Curve curve = Curves.easeInOut]) =>
      curve.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    const logoSize = 128.0;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: Center(
        child: _animating && _animationDone && _auth.initializing
            ? SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
              )
            : _animating && !_animationDone
            ? AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value;
                  // 0-1 s: fade and zoom in. 1-2 s: glows and the turning light.
                  // 2-3 s: everything fades out.
                  final fadeIn = _ramp(t, 0, 1 / 3, Curves.easeOut);
                  final fadeOut = 1 - _ramp(t, 2 / 3, 1);
                  final glow = _ramp(t, 1 / 3, 0.5) * fadeOut;
                  final scale = 0.8 + 0.2 * _ramp(t, 0, 1 / 3, Curves.easeOutCubic);
                  final turns = ((t - 1 / 3) * 3).clamp(0.0, 2.0);
                  return Opacity(
                    opacity: (fadeIn * fadeOut).clamp(0.0, 1.0),
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: logoSize * 2.4,
                        height: logoSize * 2.4,
                        child: CustomPaint(
                          painter: _GlowPainter(glow: glow, angle: turns * 2 * math.pi, logoSize: logoSize),
                          child: Center(
                            child: Transform.scale(
                              scale: scale,
                              child: const BaariLogoMark(size: logoSize),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BaariLogo(markSize: 64),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Blue and green glows around the logo and a light that turns around it.
class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.glow, required this.angle, required this.logoSize});

  final double glow;
  final double angle;
  final double logoSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (glow <= 0) return;
    final center = size.center(Offset.zero);
    final r = logoSize / 2;

    // Two soft glows, blue and green, circling the logo.
    for (final (color, offset) in [(SplashScreen.glowBlue, 0.0), (SplashScreen.glowGreen, math.pi)]) {
      final a = angle * 0.5 + offset;
      final c = center + Offset(math.cos(a), math.sin(a)) * r * 0.45;
      final radius = r * 1.7;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [color.withOpacity(0.5 * glow), color.withOpacity(0)])
              .createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }

    // The turning light: a bright arc running around the logo's edge.
    final ring = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: logoSize + 14, height: logoSize + 14),
      Radius.circular(logoSize * 0.22 + 7),
    );
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            Colors.transparent,
            SplashScreen.glowBlue.withOpacity(0.95 * glow),
            SplashScreen.glowGreen.withOpacity(0.95 * glow),
            Colors.transparent,
          ],
          stops: const [0.0, 0.3, 0.55, 0.75],
          transform: GradientRotation(angle),
        ).createShader(ring.outerRect),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.glow != glow || old.angle != angle;
}
