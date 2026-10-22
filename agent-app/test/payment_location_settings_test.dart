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
    await tester.pumpWidget(_app(_settings('melbet', 'MELBET')));
    expect(find.text('PAYMENT LOCATION'), findsNothing);
    expect(find.byKey(const Key('payment-city')), findsNothing);
  });
}
