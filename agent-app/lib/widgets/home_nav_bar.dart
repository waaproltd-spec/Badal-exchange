import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../theme/app_theme.dart';

/// The six bottom tabs on a curved white bar: the selected tab is a raised purple circle (deep-purple
/// gradient, soft glow) that sits above the bar on a smooth hump, and slides to the next tab when it
/// changes. Every label stays on one line: the text is made just small enough for the longest word
/// ("Commission", "Warbixinno") to fit the width of a tab, at the phone's own text size. Only when even
/// that would be unreadably small (a narrow phone or a very large text size) does only the selected tab
/// show its label.
class HomeNavBar extends StatelessWidget {
  const HomeNavBar(
      {super.key, required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _normal = 11;
  static const double _smallest = 8.5;

  static List<String> get labels => [
        tr('Dashboard'),
        tr('Users'),
        tr('Reports'),
        tr('Commission'),
        tr('History'),
        tr('Account')
      ];

  /// Width of [word] at the normal size, with the text scale not applied: the real font's.
  static double _measure(String word) {
    final p = TextPainter(
      text: TextSpan(
          text: word,
          style:
              const TextStyle(fontSize: _normal, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return p.width;
  }

  /// The label size that fits the widest word of [labels] into one tab, or null when it would be too small.
  /// [measure] is the width of a word at the normal size (tests give the real font's widths).
  static double? fittingSize({
    required double width,
    required TextScaler scaler,
    required List<String> labels,
    double Function(String word)? measure,
  }) {
    final tabWidth = width / labels.length - 10; // the tab's own padding
    final scale = scaler.scale(_normal) / _normal;
    var size = _normal;
    for (final label in labels) {
      for (final word in label.split(RegExp(r'\s+'))) {
        if (word.isEmpty) continue;
        final w = (measure ?? _measure)(word) * scale;
        if (w > tabWidth)
          size = size < _normal * tabWidth / w ? size : _normal * tabWidth / w;
      }
    }
    return size < _smallest ? null : size;
  }

  static const _icons = [
    (Icons.grid_view_outlined, Icons.grid_view_rounded),
    (Icons.people_outline_rounded, Icons.people_rounded),
    (Icons.bar_chart_outlined, Icons.bar_chart_rounded),
    (Icons.payments_outlined, Icons.payments_rounded),
    (Icons.history_rounded, Icons.history_toggle_off_rounded),
    (Icons.person_outline_rounded, Icons.person_rounded),
  ];

  /// Space above the bar for the raised circle and the hump.
  static const double topSpace = 28;
  static const double barHeight = 62;
  static const double circle = 52;

  @override
  Widget build(BuildContext context) {
    final names = labels;
    final width = MediaQuery.sizeOf(context).width;
    final size = fittingSize(
        width: width, scaler: MediaQuery.textScalerOf(context), labels: names);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final tabWidth = width / names.length;
    return SizedBox(
      key: const Key('home-nav'),
      height: topSpace + barHeight + bottom,
      child: TweenAnimationBuilder<double>(
        // The circle slides from the old tab to the new one.
        tween: Tween<double>(end: selectedIndex.toDouble()),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        builder: (context, pos, _) {
          final cx = tabWidth * (pos + 0.5);
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BarPainter(
                    centerX: cx,
                    color: AppColors.surface,
                    shadow: AppColors.primary),
              ),
            ),
            // The raised button.
            Positioned(
              left: cx - circle / 2,
              top: 0,
              child: Container(
                key: const Key('nav-selected-circle'),
                width: circle,
                height: circle,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.purple, AppColors.purpleDark],
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.primary.withOpacity(0.5),
                        blurRadius: 18,
                        spreadRadius: 1,
                        offset: const Offset(0, 4)),
                  ],
                ),
                child: Icon(_icons[selectedIndex].$2,
                    color: AppColors.onPrimary, size: 26),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: topSpace,
              height: barHeight + bottom,
              child: Row(children: [
                for (var i = 0; i < names.length; i++)
                  Expanded(
                    child: _Tab(
                      key: Key('nav-tab-$i'),
                      index: i,
                      selected: i == selectedIndex,
                      icon: _icons[i].$1,
                      label: names[i],
                      fontSize: size ?? _normal,
                      showLabel: size != null || i == selectedIndex,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.index,
    required this.selected,
    required this.icon,
    required this.label,
    required this.fontSize,
    required this.showLabel,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final IconData icon;
  final String label;
  final double fontSize;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 34,
        containedInkWell: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(children: [
            // The icon of the selected tab is in the raised circle: this one fades out as the circle arrives.
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: selected ? 0 : 1,
              child: Icon(icon, size: 24, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            if (showLabel)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected
                        ? AppColors.primaryDark
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  child: Text(label, maxLines: 1, softWrap: false),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The white bar with a smooth hump over the selected tab (where the raised circle sits).
class _BarPainter extends CustomPainter {
  _BarPainter(
      {required this.centerX, required this.color, required this.shadow});

  final double centerX;
  final Color color;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    const top = HomeNavBar.topSpace;
    const radius = 26.0;
    const hump = 13.0;
    const half = 50.0;
    final w = size.width;
    final cx = centerX.clamp(radius + half * 0.6, w - radius - half * 0.6);
    final a = cx - half;
    final b = cx + half;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, top + radius)
      ..quadraticBezierTo(0, top, radius, top)
      ..lineTo(a, top)
      ..cubicTo(a + 22, top, cx - 34, top - hump, cx, top - hump)
      ..cubicTo(cx + 34, top - hump, b - 22, top, b, top)
      ..lineTo(w - radius, top)
      ..quadraticBezierTo(w, top, w, top + radius)
      ..lineTo(w, size.height)
      ..close();
    canvas.drawShadow(path, shadow.withOpacity(0.55), 10, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.centerX != centerX || old.color != color || old.shadow != shadow;
}
