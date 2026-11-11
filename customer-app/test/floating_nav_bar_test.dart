// The floating bottom bar: Hoyga, Dalabaadka, TIPS, Xogtayda on a rounded deep-purple bar, the selected
// tab on a glowing violet wave that slides to the next tab; labels on one line; above the system area.
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/widgets/floating_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<NavTab> _tabs() => [
      NavTab(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
          label: AppStrings.home),
      NavTab(
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long_rounded,
          label: AppStrings.orders),
      NavTab(
          icon: Icons.tips_and_updates_outlined,
          selectedIcon: Icons.tips_and_updates_rounded,
          label: AppStrings.tips),
      NavTab(
          icon: Icons.person_outline_rounded,
          selectedIcon: Icons.person_rounded,
          label: AppStrings.profile),
    ];

Future<void> _pump(WidgetTester tester,
    {double width = 393,
    double scale = 1.0,
    double bottomInset = 0,
    int selected = 0,
    ValueChanged<int>? onSelected}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
        bottomNavigationBar: FloatingNavBar(
            tabs: _tabs(),
            selectedIndex: selected,
            onSelected: onSelected ?? (_) {})),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.somali);

  testWidgets('the four tabs in Somali, each clickable', (tester) async {
    final taps = <int>[];
    await _pump(tester, onSelected: taps.add);
    for (final l in ['Hoyga', 'Dalabaadka', 'Talooyin', 'Xogtayda']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(Key('nav-tab-$i')));
    }
    expect(taps, [0, 1, 2, 3]);
  });

  testWidgets(
      'it floats: margins at the sides, rounded, above the system navigation area',
      (tester) async {
    await _pump(tester, bottomInset: 24);
    final bar = tester.getRect(find.byKey(const Key('floating-nav')));
    final deco = tester.getRect(find
        .descendant(
            of: find.byKey(const Key('floating-nav')),
            matching: find.byType(DecoratedBox))
        .first);
    expect(deco.left, greaterThan(0), reason: 'floating: not edge to edge');
    expect(deco.right, lessThan(393));
    expect(bar.bottom, 800,
        reason:
            'the area under the bar belongs to the bar (it is not covered by the system area)');
    expect(800 - deco.bottom, greaterThanOrEqualTo(24),
        reason: 'the bar itself ends above the system navigation');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the glowing wave slides to the tapped tab', (tester) async {
    int selected = 0;
    late StateSetter set;
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        set = setState;
        return Scaffold(
            bottomNavigationBar: FloatingNavBar(
                tabs: _tabs(),
                selectedIndex: selected,
                onSelected: (i) => set(() => selected = i)));
      }),
    ));
    await tester.pumpAndSettle();
    CustomPainter painter() => tester
        .widget<CustomPaint>(find.byKey(const Key('nav-highlight')))
        .painter!;
    // Position of the highlight, read from the painter.
    double pos() => (painter() as dynamic).position as double;
    expect(pos(), 0);
    await tester.tap(find.byKey(const Key('nav-tab-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(pos(), allOf(greaterThan(0), lessThan(3)),
        reason: 'on its way: it slides, it does not jump');
    await tester.pumpAndSettle();
    expect(pos(), 3);
    expect(selected, 3);
  });

  for (final (name, width, scale) in [
    ('a small phone', 320.0, 1.0),
    ('a normal phone, larger text', 393.0, 1.3),
    ('a small phone with very large text', 320.0, 2.0),
  ]) {
    testWidgets('$name: every label on one line, nothing overflows',
        (tester) async {
      await _pump(tester, width: width, scale: scale, selected: 1);
      final one = tester.getSize(find.text('Talooyin')).height;
      for (final l in ['Hoyga', 'Dalabaadka', 'Talooyin', 'Xogtayda']) {
        expect(tester.getSize(find.text(l)).height, closeTo(one, 0.5),
            reason: '$l is on one line');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('English too', (tester) async {
    AppLanguage.current.value = AppLanguage.english;
    await _pump(tester);
    for (final l in ['Home', 'Orders', 'TIPS', 'Profile']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
  });
}
