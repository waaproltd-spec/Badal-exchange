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
    expect(methodInfo('melbet').label, 'MELBET', 'the rest of the catalog is used');
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
}
