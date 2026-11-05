import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// One tab of the [FloatingNavBar].
class NavTab {
  const NavTab(
      {required this.icon, required this.selectedIcon, required this.label});

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// The bottom bar: a floating, rounded deep-purple bar. The selected tab sits on a bright violet,
/// glowing wave-shaped highlight that slides (and flows) to the next tab when it changes; its icon
/// and label are white. Every label stays on one line (it shrinks to fit), at the phone's own text
/// size, and the bar floats above the system navigation area, so it never covers the page.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar(
      {super.key,
      required this.tabs,
      required this.selectedIndex,
      required this.onSelected});

  final List<NavTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _side = 14;
  static const double _gap = 10;
  static const double _radius = 28;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // A larger system font makes the bar a little taller (the label grows with it).
    final scale = media.textScaler.scale(12) / 12;
    final barHeight = 64 + (scale - 1).clamp(0.0, 0.6) * 30;
    final width = media.size.width - _side * 2;
    final tabWidth = width / tabs.length;
    return Padding(
      key: const Key('floating-nav'),
      padding:
          EdgeInsets.fromLTRB(_side, _gap, _side, _gap + media.padding.bottom),
      child: SizedBox(
        height: barHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.navDeep, AppColors.navMid, AppColors.navDeep],
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.navBrightDeep.withOpacity(0.35),
                  blurRadius: 22,
                  offset: const Offset(0, 8)),
              BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 3)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: TweenAnimationBuilder<double>(
              // The highlight slides from the old tab to the new one.
              tween: Tween<double>(end: selectedIndex.toDouble()),
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutCubic,
              builder: (context, pos, _) => Stack(children: [
                Positioned.fill(
                  child: CustomPaint(
                    key: const Key('nav-highlight'),
                    painter: _WavePainter(
                        position: pos, tabWidth: tabWidth, count: tabs.length),
                  ),
                ),
                Row(children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _NavItem(
                        key: Key('nav-tab-$i'),
                        tab: tabs[i],
                        selected: i == selectedIndex,
                        onTap: () => onSelected(i),
                      ),
                    ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem(
      {super.key,
      required this.tab,
      required this.selected,
      required this.onTap});

  final NavTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : Colors.white.withOpacity(0.82);
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        containedInkWell: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  duration: const Duration(milliseconds: 250),
                  scale: selected ? 1.12 : 1,
                  child: Icon(selected ? tab.selectedIcon : tab.icon,
                      color: color, size: 25),
                ),
                const SizedBox(height: 3),
                // One line, whatever the text size: it shrinks to the width of its tab.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                        color: color),
                    maxLines: 1,
                    child: Text(tab.label, maxLines: 1, softWrap: false),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The glowing violet wave behind the selected tab: rounded at the left, its right edge a slanted S-curve,
/// its top and bottom edges gently waving; the wave moves with the highlight.
class _WavePainter extends CustomPainter {
  _WavePainter(
      {required this.position, required this.tabWidth, required this.count});

  final double position;
  final double tabWidth;
  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final left = position * tabWidth - (position == 0 ? 0 : 6);
    final first = position <= 0.001;
    final last = position >= count - 1 - 0.001;
    final l = first ? 0.0 : left;
    final r = math.min(size.width, (position + 1) * tabWidth + (last ? 0 : 14));
    const corner = 26.0;
    final phase = position * math.pi * 1.5;
    double wave(double t, double amp) =>
        math.sin(t * math.pi * 2 + phase) * amp;

    final path = Path()
      ..moveTo(l + corner, 0)
      ..lineTo(r - 26, 0)
      // The slanted S at the right edge.
      ..cubicTo(r - 6, 0, r - 16, h, r + (last ? 0 : 4), h)
      ..lineTo(l + corner, h)
      ..quadraticBezierTo(l, h, l, h - corner)
      ..lineTo(l, corner)
      ..quadraticBezierTo(l, 0, l + corner, 0)
      ..close();

    // The glow, then the body in a bright violet gradient.
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.navBright.withOpacity(0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    final body = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: const [AppColors.navBright, AppColors.navBrightDeep],
      ).createShader(Rect.fromLTRB(l, 0, r, h));
    canvas.drawPath(path, body);

    // A soft wave across the highlight (it flows as the highlight moves).
    final flow = Path()..moveTo(l, h * 0.72);
    final span = math.max(1.0, r - l);
    for (var i = 0; i <= 24; i++) {
      final t = i / 24;
      flow.lineTo(l + span * t, h * 0.72 + wave(t, 5));
    }
    flow
      ..lineTo(r, h)
      ..lineTo(l, h)
      ..close();
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(flow, Paint()..color = Colors.white.withOpacity(0.14));
    canvas.restore();
    // A thin light edge on the top.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(0.35),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.position != position || old.tabWidth != tabWidth;
}
