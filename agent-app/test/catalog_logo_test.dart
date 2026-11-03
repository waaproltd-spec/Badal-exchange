import 'package:badal_agent_app/models/payment_methods.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1 x 1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

Map<String, dynamic> _m(String method, String label, String initials, {String? logo, String kind = 'platform'}) =>
    {'method': method, 'label': label, 'kind': kind, 'color': '#6B7280', 'initials': initials, 'logo': logo};

void main() {
  late List<PaymentMethodInfo> original;
  setUp(() => original = paymentMethods);
  tearDown(() {
    paymentMethods = original;
    clearCatalogLogos();
  });

  Future<void> show(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

  testWidgets('a platform whose logo the server holds shows it, with no logo bundled in the app', (tester) async {
    applyPaymentMethodCatalog([_m('luckypari', 'LuckyPari', 'LU', logo: _png), _m('goldpari', 'Goldpari', 'GO')]);
    await show(tester, const Column(children: [MethodBadge(method: 'luckypari'), MethodBadge(method: 'goldpari')]));
    expect(find.byKey(const Key('badge-logo-luckypari')), findsOneWidget);
    expect(find.text('LU'), findsNothing, reason: 'the logo, not the letters');
    expect(find.byKey(const Key('badge-logo-goldpari')), findsNothing);
    expect(find.text('GO'), findsOneWidget, reason: 'no logo anywhere: the letters');
  });

  testWidgets('the wide tile (Company Balances) shows the server logo too', (tester) async {
    applyPaymentMethodCatalog([_m('betandyou', 'Betandyou', 'BE', logo: _png)]);
    await show(tester, const MethodLogo(method: 'betandyou', width: 120));
    expect(find.byKey(const Key('wide-server-logo-betandyou')), findsOneWidget);
    expect(find.text('BE'), findsNothing);
  });

  testWidgets('a logo that arrives later (or changes) redraws the badges; removing it brings the letters back', (tester) async {
    applyPaymentMethodCatalog([_m('luckypari', 'LuckyPari', 'LU')]);
    await show(tester, const MethodBadge(method: 'luckypari'));
    expect(find.text('LU'), findsOneWidget);
    applyPaymentMethodCatalog([_m('luckypari', 'LuckyPari', 'LU', logo: _png)]);
    await tester.pump();
    expect(find.byKey(const Key('badge-logo-luckypari')), findsOneWidget);
    applyPaymentMethodCatalog([_m('luckypari', 'LuckyPari', 'LU')]);
    await tester.pump();
    expect(find.text('LU'), findsOneWidget);
  });

  testWidgets('a built-in platform keeps its own tile; a logo the server holds for it (a replacement) wins', (tester) async {
    await show(tester, const MethodLogo(method: 'onexbet', width: 120));
    expect(find.byKey(const Key('wide-logo-onexbet')), findsOneWidget);
    expect(find.byKey(const Key('wide-server-logo-onexbet')), findsNothing);
    applyPaymentMethodCatalog([_m('onexbet', '1XBET', '1X', logo: _png)]);
    await tester.pump();
    expect(find.byKey(const Key('wide-server-logo-onexbet')), findsOneWidget);
  });

  testWidgets('an unreadable logo from the server is ignored: the letters stay', (tester) async {
    applyPaymentMethodCatalog([_m('luckypari', 'LuckyPari', 'LU', logo: '***not base64***')]);
    await show(tester, const MethodBadge(method: 'luckypari'));
    expect(find.text('LU'), findsOneWidget);
    expect(catalogLogo('luckypari'), isNull);
  });
}
