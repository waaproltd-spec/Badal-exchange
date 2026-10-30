import 'dart:convert';

import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:badal_exchange_customer/widgets/method_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1 x 1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

Widget _icon(String method) => MaterialApp(home: Scaffold(body: Center(child: MethodIcon(method: method, size: 48))));

void main() {
  late List<PaymentMethodInfo> before;
  setUp(() => before = paymentMethods);
  tearDown(() => paymentMethods = before);

  testWidgets('a platform added in the Agent App shows the logo a manager gave it', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'wowbet', 'label': 'wowbet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'WO', 'cashdesk': true, 'logo': _png},
    ]);
    expect(methodInfo('wowbet').logo, isNotNull);
    await tester.pumpWidget(_icon('wowbet'));
    expect(find.byKey(const Key('logo-wowbet')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('WO'), findsNothing, reason: 'the logo replaces the initials');
  });

  testWidgets('no logo (or a null one): the initials, as before', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'wowbet', 'label': 'wowbet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'WO', 'logo': null},
    ]);
    expect(methodInfo('wowbet').logo, isNull);
    await tester.pumpWidget(_icon('wowbet'));
    expect(find.text('WO'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('an unreadable logo never breaks the catalog: the initials show', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'wowbet', 'label': 'wowbet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'WO', 'logo': '!!not base64!!'},
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true},
    ]);
    expect(methodInfo('wowbet').logo, isNull);
    expect(methodInfo('melbet').label, 'MELBET', reason: 'the rest of the catalog is used');
    await tester.pumpWidget(_icon('wowbet'));
    expect(find.text('WO'), findsOneWidget);
  });

  testWidgets('a built-in platform keeps its own logo from the app', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true},
    ]);
    await tester.pumpWidget(_icon('melbet'));
    expect(find.byKey(const Key('logo-melbet')), findsOneWidget);
  });

  testWidgets('a logo a manager gave a built-in platform replaces the one built into the app', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true, 'logo': _png},
    ]);
    expect(methodInfo('melbet').logo, isNotNull);
    await tester.pumpWidget(_icon('melbet'));
    expect(find.byKey(const Key('logo-melbet')), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>(), reason: 'the manager\'s picture, not the asset');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 120, child: MethodLogo(method: 'melbet'))))));
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
  });

  testWidgets('a logo that cannot be read falls back to the logo built into the app', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true,
       'logo': base64Encode(utf8.encode('this is not a picture'))},
    ]);
    await tester.pumpWidget(_icon('melbet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byWidgetPredicate((w) => w is Image && w.image is AssetImage), findsOneWidget);
    expect(find.text('MB'), findsNothing);
  });

  test('a logo change in the catalog is noticed (screens rebuild); the same catalog is not', () {
    final base = {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true};
    applyPaymentMethodCatalog([{...base, 'logo': null}]);
    final v0 = paymentMethodLogosVersion.value;
    applyPaymentMethodCatalog([{...base, 'logo': null}]);
    expect(paymentMethodLogosVersion.value, v0, reason: 'nothing changed');
    applyPaymentMethodCatalog([{...base, 'logo': _png}]);
    expect(paymentMethodLogosVersion.value, v0 + 1, reason: 'a manager gave it a logo');
    applyPaymentMethodCatalog([{...base, 'logo': _png}]);
    expect(paymentMethodLogosVersion.value, v0 + 1);
    applyPaymentMethodCatalog([{...base, 'logo': null}]);
    expect(paymentMethodLogosVersion.value, v0 + 2, reason: 'the logo was taken back');
  });

  testWidgets('the method grid shows an added platform\'s logo in the same wide tile as the built-in ones', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'wowbet', 'label': 'wowbet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'WO', 'cashdesk': true, 'logo': _png},
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true},
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            child: Column(mainAxisSize: MainAxisSize.min, children: const [
              MethodLogo(method: 'wowbet'),
              MethodLogo(method: 'melbet'),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump();
    final added = tester.getSize(find.byKey(const Key('wide-logo-wowbet')));
    final builtIn = tester.getSize(find.byKey(const Key('wide-logo-melbet')));
    expect(added, builtIn, reason: 'the same 2.4 : 1 tile');
    expect(added.width / added.height, closeTo(MethodLogo.aspect, 0.01));
    expect(find.text('WO'), findsNothing);
    // Nothing is painted under the logo's own tile (no light outline round a dark one).
    final box = tester.widget<DecoratedBox>(find.byKey(const Key('wide-logo-wowbet')));
    expect((box.decoration as BoxDecoration).color, isNull);
  });

  testWidgets('an added platform without a logo keeps its initials in the grid', (tester) async {
    applyPaymentMethodCatalog([
      {'method': 'wowbet', 'label': 'wowbet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'WO', 'cashdesk': true},
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 240, height: 100, child: MethodLogo(method: 'wowbet')))));
    expect(find.text('WO'), findsOneWidget);
    expect(find.byKey(const Key('wide-logo-wowbet')), findsNothing);
  });
}
