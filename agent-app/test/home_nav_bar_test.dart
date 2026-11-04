// The six bottom tabs: every label on one line (no "Commissio / n"). Widths here are the real font's
// (Roboto, about 5.9 dp per character at 11 sp, semi-bold); the test font is far wider and would say nothing.
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/widgets/home_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _roboto(String word) => word.length * 5.9;

const _en = [
  'Dashboard',
  'Users',
  'Reports',
  'Commission',
  'History',
  'Account'
];
const _so = [
  'Dashboard',
  'Macaamiil',
  'Warbixinno',
  'Guddiga (Commission)',
  'Taariikh',
  'Koontada'
];

double? _fit(double width, double scale, List<String> labels) =>
    HomeNavBar.fittingSize(
        width: width,
        scaler: TextScaler.linear(scale),
        labels: labels,
        measure: _roboto);

Future<void> _pump(WidgetTester tester,
    {required double width, double scale = 1.0}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
          size: Size(width, 800), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
          bottomNavigationBar:
              HomeNavBar(selectedIndex: 0, onSelected: (_) {})),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  test(
      'on a 393 dp phone Commission fits at a slightly smaller label size, also at a larger text size',
      () {
    expect(_fit(393, 1.0, _en), closeTo(11 * 55.5 / 59, 0.01),
        reason: 'Commission (59 dp) shrinks to the tab (55.5 dp)');
    final large = _fit(393, 1.15, _en)!;
    expect(large, lessThan(10));
    expect(large, greaterThan(8.5));
    // Whatever size is chosen, the widest word now fits the tab: no "Commissio / n".
    expect(
        10 * 5.9 * 1.15 * large / 11, lessThanOrEqualTo(393 / 6 - 10 + 0.01));
  });

  test('a phone where everything already fits keeps the normal size', () {
    expect(_fit(600, 1.0, _en), 11);
  });

  test(
      'too narrow or too large to read: null, so only the selected tab shows its label',
      () {
    expect(_fit(320, 1.5, _en), isNull);
    expect(_fit(360, 2.0, _en), isNull);
  });

  test('Somali words fit the same way', () {
    final s = _fit(393, 1.0, _so);
    expect(s, isNotNull);
    expect(s!, lessThanOrEqualTo(11));
  });

  testWidgets(
      'the curved bar: six tabs, the selected one is a raised purple circle above the bar',
      (tester) async {
    await _pump(tester, width: 393);
    expect(find.byKey(const Key('home-nav')), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(Key('nav-tab-$i')), findsOneWidget);
    }
    final circle = find.byKey(const Key('nav-selected-circle'));
    expect(circle, findsOneWidget);
    final bar = tester.getRect(find.byKey(const Key('nav-tab-0')));
    expect(tester.getRect(circle).top, lessThan(bar.top),
        reason: 'the circle sits above the bar');
    // Under Dashboard (the first of six equal tabs).
    expect(tester.getCenter(circle).dx, closeTo(393 / 6 / 2, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tab selects it and the circle slides there',
      (tester) async {
    int selected = 0;
    late StateSetter set;
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        set = setState;
        return Scaffold(
            bottomNavigationBar: HomeNavBar(
                selectedIndex: selected,
                onSelected: (i) => set(() => selected = i)));
      }),
    ));
    await tester.pumpAndSettle();
    final circle = find.byKey(const Key('nav-selected-circle'));
    final x0 = tester.getCenter(circle).dx;
    await tester.tap(find.byKey(const Key('nav-tab-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final mid = tester.getCenter(circle).dx;
    expect(mid, greaterThan(x0), reason: 'on its way');
    await tester.pumpAndSettle();
    expect(selected, 3);
    expect(tester.getCenter(circle).dx, closeTo(393 / 6 * 3.5, 1),
        reason: 'under Commission');
    expect(mid, lessThan(tester.getCenter(circle).dx),
        reason: 'it slid, it did not jump');
    expect(find.text('Commission'), findsOneWidget);
  });

  testWidgets(
      'a narrow phone with very large text: only the selected label shows, nothing overflows',
      (tester) async {
    await _pump(tester, width: 320, scale: 2.0);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Commission'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Somali labels', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    // (A wide screen: the test font is much wider than the phone's, so on 360 dp it would hide the labels.)
    await _pump(tester, width: 760);
    expect(find.text('Bogga Hore'), findsOneWidget);
    expect(find.text('Warbixinno'), findsOneWidget);
    expect(find.text('Guddiga (Commission)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
