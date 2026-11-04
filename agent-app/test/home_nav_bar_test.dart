// The six bottom tabs: every label on one line (no "Commissio / n"). Widths here are the real font's
// (Roboto, about 5.9 dp per character at 11 sp, semi-bold); the test font is far wider and would say nothing.
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/widgets/home_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
      'the bar draws all six tabs without overflow on a 393 dp phone and on a narrow one',
      (tester) async {
    await _pump(tester, width: 393, scale: 1.15);
    expect(find.byKey(const Key('home-nav')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, width: 320, scale: 2.0);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
