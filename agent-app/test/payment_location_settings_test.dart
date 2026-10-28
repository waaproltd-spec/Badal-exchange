import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/method_settings_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends AgentApi {
  final calls = <String>[];

  @override
  Future<void> setPaymentLocation(String method, {required String city, required String street}) async {
    calls.add('location $method $city|$street');
  }

  @override
  Future<void> setWithdrawalLimits(String method, {required double min, required double max}) async {
    calls.add('limits $method');
  }

  @override
  Future<void> setMethodEnabled(String method, bool enabled) async => calls.add('enabled $method $enabled');

  @override
  Future<void> setMerchantUssd(String method, {required String code, required bool enabled}) async =>
      calls.add('merchant $method $code $enabled');
}

MethodSettings _mobile(String method, String label, {String? code, bool on = false}) => MethodSettings.fromJson({
      'method': method,
      'label': label,
      'kind': 'mobile_money',
      'enabled': true,
      'minWithdraw': '0.30',
      'maxWithdraw': '500.00',
      'merchantUssd': code,
      'merchantUssdEnabled': on,
    });

Future<void> _save(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

MethodSettings _settings(String method, String label, {String? city, String? street}) => MethodSettings.fromJson({
      'method': method,
      'label': label,
      'kind': 'platform',
      'enabled': true,
      'minWithdraw': '0.30',
      'maxWithdraw': '500.00',
      'paymentLocation': city == null && street == null ? null : {'city': city, 'street': street},
    });

late _FakeApi _api;

Widget _app(MethodSettings s) {
  _api = _FakeApi();
  final api = _api;
  return ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: MaterialApp(home: MethodSettingsScreen(settings: s)),
  );
}

void main() {
  testWidgets('1XBET: shows the current City / Street and saves a change', (tester) async {
    await tester.pumpWidget(_app(_settings('onexbet', '1XBET', city: 'Mogadishu', street: 'FURAHA 5')));
    expect(find.text('PAYMENT LOCATION'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Mogadishu'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'FURAHA 5'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('payment-street')), ' FURAHA 6 ');
    await tester.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['location onexbet Mogadishu|FURAHA 6']);
  });

  testWidgets('saving without changing the location does not send it', (tester) async {
    await tester.pumpWidget(_app(_settings('888starz', '888STARZ', city: 'Mogadishu', street: 'FURAHA 5')));
    await tester.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty);
  });

  testWidgets('other methods have no Payment Location', (tester) async {
    await tester.pumpWidget(_app(_mobile('golis', 'Golis')));
    expect(find.text('PAYMENT LOCATION'), findsNothing);
    expect(find.byKey(const Key('payment-city')), findsNothing);
  });

  testWidgets('EVC Plus merchant code: off by default; saving unchanged sends nothing', (tester) async {
    await tester.pumpWidget(_app(_mobile('evc_plus', 'EVC Plus', code: '*789*090353102*{amount}#')));
    expect(find.text('MERCHANT CODE'), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byKey(const Key('merchant-ussd'))).controller!.text, '*789*090353102*{amount}#');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('merchant-ussd-on'))).value, isFalse);
    expect(find.textContaining('*712*, confirmed automatically'), findsOneWidget);

    await _save(tester);
    expect(_api.calls, isEmpty, reason: 'nothing changed, nothing sent');
  });

  testWidgets('EVC Plus merchant code: switched on and saved', (tester) async {
    await tester.pumpWidget(_app(_mobile('evc_plus', 'EVC Plus', code: '*789*090353102*{amount}#')));
    await tester.scrollUntilVisible(find.byKey(const Key('merchant-ussd-on')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('merchant-ussd-on')));
    await _save(tester);
    expect(_api.calls, ['merchant evc_plus *789*090353102*{amount}# true']);
  });

  testWidgets('a wrongly written code is not saved', (tester) async {
    await tester.pumpWidget(_app(_mobile('golis', 'Golis')));
    await tester.enterText(find.byKey(const Key('merchant-ussd')), '*884*353102*5#');
    await _save(tester);
    expect(find.text('Write it like *789*090353102*{amount}#'), findsOneWidget);
    expect(_api.calls, isEmpty);
  });

  testWidgets('betting platforms have no merchant code', (tester) async {
    await tester.pumpWidget(_app(_settings('melbet', 'MELBET')));
    expect(find.text('MERCHANT CODE'), findsNothing);
  });

}
