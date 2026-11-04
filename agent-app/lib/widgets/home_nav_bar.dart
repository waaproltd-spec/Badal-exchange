import 'package:flutter/material.dart';

import '../l10n/tr.dart';

/// The six bottom tabs. Every label stays on one line: the text is made just small enough for the
/// longest word ("Commission", "Warbixinno") to fit the width of a tab, at the phone's own text size.
/// Only when even that would be unreadably small (a narrow phone or a very large text size) does only
/// the selected tab show its label.
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

  @override
  Widget build(BuildContext context) {
    final names = labels;
    final size = fittingSize(
        width: MediaQuery.sizeOf(context).width,
        scaler: MediaQuery.textScalerOf(context),
        labels: names);
    final theme = Theme.of(context).navigationBarTheme;
    return NavigationBarTheme(
      data: theme.copyWith(
        labelTextStyle: WidgetStatePropertyAll(
          (theme.labelTextStyle?.resolve(const {}) ??
                  const TextStyle(fontWeight: FontWeight.w600))
              .copyWith(fontSize: size ?? _normal),
        ),
      ),
      child: NavigationBar(
        key: const Key('home-nav'),
        selectedIndex: selectedIndex,
        labelBehavior: size == null
            ? NavigationDestinationLabelBehavior.onlyShowSelected
            : NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: onSelected,
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.grid_view_outlined),
              selectedIcon: const Icon(Icons.grid_view_rounded),
              label: names[0]),
          NavigationDestination(
              icon: const Icon(Icons.people_outline_rounded),
              selectedIcon: const Icon(Icons.people_rounded),
              label: names[1]),
          NavigationDestination(
              icon: const Icon(Icons.bar_chart_outlined),
              selectedIcon: const Icon(Icons.bar_chart_rounded),
              label: names[2]),
          NavigationDestination(
              icon: const Icon(Icons.payments_outlined),
              selectedIcon: const Icon(Icons.payments_rounded),
              label: names[3]),
          NavigationDestination(
              icon: const Icon(Icons.history_rounded),
              selectedIcon: const Icon(Icons.history_toggle_off_rounded),
              label: names[4]),
          NavigationDestination(
              icon: const Icon(Icons.person_outline_rounded),
              selectedIcon: const Icon(Icons.person_rounded),
              label: names[5]),
        ],
      ),
    );
  }
}
