import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/betting_platforms_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _adapter = BettingAdapter.fromJson({
  'adapter': 'cashdeskbot',
  'label': 'CashdeskBot partner API',
  'defaultApiUrl': 'https://partners.servcul.com/CashdeskBotAPI',
  'fields': [
    {'key': 'apiUrl', 'label': 'API URL', 'required': false, 'secret': false},
    {'key': 'login', 'label': 'Login / Username', 'required': true, 'secret': false},
    {'key': 'password', 'label': 'Cashier password', 'required': true, 'secret': true},
    {'key': 'accountId', 'label': 'Cashdesk ID (World / Wallet ID)', 'required': true, 'secret': false},
    {'key': 'apiSecret', 'label': 'Hash (API secret / signature key)', 'required': true, 'secret': true},
  ],
});

BettingPlatform _p(String status, {bool active = false, bool saved = false, bool builtIn = false, String? message}) =>
    BettingPlatform.fromJson({
      'method': 'premierbet', 'name': 'PremierBet', 'adapter': 'cashdeskbot', 'builtIn': builtIn, 'active': active,
      'status': status, 'accountId': saved ? '1198475' : null, 'login': saved ? 'ca••••r1' : null,
      'hasPassword': saved, 'hasApiSecret': saved, 'lastMessage': message,
    });

class _FakeApi extends AgentApi {
  BettingPlatform p = _p('not_configured');
  final calls = <String>[];

  @override
  Future<({List<BettingAdapter> adapters, List<BettingPlatform> platforms})> getBettingPlatforms() async =>
      (adapters: [_adapter], platforms: [p]);

  @override
  Future<BettingPlatform> saveBettingPlatform(String method,
      {String? apiUrl, String? login, String? password, String? accountId, String? apiSecret, String? apiKey}) async {
    calls.add('save $login $password $accountId $apiSecret');
    return p = _p('not_tested', saved: true);
  }

  @override
  Future<BettingPlatform> testBettingPlatform(String method) async {
    calls.add('test');
    return p = _p('error', saved: true, message: 'CashdeskBot rejected the request: invalid or missing "sign" signature.');
  }

  @override
  Future<BettingPlatform> setBettingPlatformActive(String method, bool active) async {
    calls.add('active $active');
    if (p.status != 'connected') {
      throw const ApiException(statusCode: 409, code: 'NOT_TESTED', message: 'Test the connection first');
    }
    return p = _p('connected', saved: true, active: active);
  }

  @override
  Future<void> deleteBettingPlatform(String method, String reason) async => calls.add('delete $reason');
}

Future<_FakeApi> _pump(WidgetTester tester, Widget home, [_FakeApi? fake]) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final api = fake ?? _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('a platform: required fields, secrets hidden after saving, the test result, removing with a reason', (tester) async {
    final api = _FakeApi();
    await _pump(tester, BettingPlatformScreen(method: 'premierbet', adapter: _adapter, initial: api.p), api);
    expect(find.text('Not set up'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('platform-test'))).onPressed, isNull, reason: 'nothing to test yet');

    await tester.tap(find.byKey(const Key('platform-save')));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsNWidgets(4));
    expect(api.calls, isEmpty);

    await tester.enterText(find.byKey(const Key('field-login')), 'cashier1');
    await tester.enterText(find.byKey(const Key('field-password')), 'pass-123');
    await tester.enterText(find.byKey(const Key('field-accountId')), '12ab');
    await tester.enterText(find.byKey(const Key('field-apiSecret')), 'hash-xyz');
    await tester.tap(find.byKey(const Key('platform-save')));
    await tester.pumpAndSettle();
    expect(find.text('Digits only'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field-accountId')), '1198475');
    await tester.tap(find.byKey(const Key('platform-save')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'save cashier1 pass-123 1198475 hash-xyz');
    expect(find.text('Not tested'), findsOneWidget);
    expect(find.text('pass-123'), findsNothing, reason: 'a saved secret is not shown again');
    expect(find.text('hash-xyz'), findsNothing);
    expect(find.text('Saved: leave empty to keep'), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('platform-test')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'test');
    expect(find.text('Error'), findsOneWidget);
    expect(find.textContaining('invalid or missing "sign"'), findsOneWidget);

    await tester.tap(find.byKey(const Key('platform-remove')));
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(FilledButton, 'Remove');
    expect(tester.widget<FilledButton>(remove).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('remove-reason')), 'Contract ended');
    await tester.pump();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'delete Contract ended');
  });

  testWidgets('the list: status per platform; switching on an untested one is refused with the reason', (tester) async {
    final api = _FakeApi()..p = _p('not_tested', saved: true);
    await _pump(tester, const BettingPlatformsScreen(), api);
    expect(find.text('PremierBet'), findsOneWidget);
    expect(find.text('Not tested'), findsOneWidget);
    await tester.tap(find.byKey(const Key('platform-active-premierbet')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'active true');
    expect(find.text('Test the connection first'), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const Key('platform-active-premierbet'))).value, isFalse);
  });

  testWidgets('a built-in platform cannot be removed', (tester) async {
    final api = _FakeApi()..p = _p('server', builtIn: true, active: true);
    await _pump(tester, BettingPlatformScreen(method: 'premierbet', adapter: _adapter, initial: api.p), api);
    expect(find.text('Server secrets'), findsOneWidget);
    expect(find.byKey(const Key('platform-remove')), findsNothing);
  });

  testWidgets('a built-in platform shows the logo the Customer App has, in the list and on its page, and its logo can be replaced', (tester) async {
    final api = _FakeApi()
      ..p = BettingPlatform.fromJson({
        'method': 'onexbet', 'name': '1XBET', 'adapter': 'cashdeskbot', 'builtIn': true, 'active': true, 'status': 'server',
      });
    await _pump(tester, const BettingPlatformsScreen(), api);
    expect(find.byKey(const Key('platform-builtin-logo-onexbet')), findsOneWidget);
    expect(find.byIcon(Icons.sports_soccer_rounded), findsNothing);
    await tester.tap(find.byKey(const Key('platform-onexbet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('platform-builtin-logo-card')), findsOneWidget);
    expect(find.byKey(const Key('wide-logo-onexbet')), findsWidgets);
    // The built-in logo can be replaced (and brought back).
    expect(find.text('Replace logo'), findsOneWidget);
    expect(find.text('The logo built into the Customer App'), findsOneWidget);
    expect(find.byKey(const Key('platform-logo-remove')), findsNothing, reason: 'nothing to bring back yet');
  });
}
