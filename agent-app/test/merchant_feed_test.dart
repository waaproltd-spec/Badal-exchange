import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/merchant_feed_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends AgentApi {
  MerchantFeedStatus status;
  final calls = <String>[];
  _FakeApi(this.status);

  @override
  Future<MerchantFeedStatus> getMerchantFeedStatus() async => status;

  @override
  Future<MerchantFeedStatus> merchantFeedSignIn() async {
    calls.add('sign-in');
    return status = const MerchantFeedStatus(state: 'needs_code', message: 'Sahal sent an access code');
  }

  @override
  Future<MerchantFeedStatus> merchantFeedCode(String code) async {
    calls.add('code $code');
    return status = const MerchantFeedStatus(state: 'code_entered', message: 'Checking the code…');
  }
}

late _FakeApi _api;

Widget _app(MerchantFeedStatus s) {
  _api = _FakeApi(s);
  final api = _api;
  return ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: const MaterialApp(home: MerchantFeedScreen(poll: Duration(hours: 1))),
  );
}

void main() {
  testWidgets('stopped: Sign in to Sahal, then the SMS code is typed and sent once', (tester) async {
    await tester.pumpWidget(_app(const MerchantFeedStatus(state: 'stopped', message: 'The portal asks for a second sign-in code')));
    await tester.pumpAndSettle();
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.byKey(const Key('feed-code')), findsNothing);

    await tester.tap(find.byKey(const Key('feed-sign-in')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['sign-in']);
    expect(find.text('Code needed'), findsOneWidget);
    expect(find.byKey(const Key('feed-sign-in')), findsNothing, reason: 'no second SMS while one is due');

    await tester.enterText(find.byKey(const Key('feed-code')), '32a3');
    await tester.tap(find.byKey(const Key('feed-send-code')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the code from the SMS (numbers only).'), findsOneWidget);
    expect(_api.calls, ['sign-in']);

    await tester.enterText(find.byKey(const Key('feed-code')), ' 323 713 ');
    await tester.tap(find.byKey(const Key('feed-send-code')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['sign-in', 'code 323713']);
    expect(find.text('Checking the code…'), findsWidgets);
  });

  testWidgets('signed in: shows what was read; signing in again is still possible', (tester) async {
    await tester.pumpWidget(_app(MerchantFeedStatus(state: 'ok', rowsSeen: 10, lastOkAt: DateTime(2026, 10, 22, 18, 5))));
    await tester.pumpAndSettle();
    expect(find.text('Signed in · reading'), findsOneWidget);
    expect(find.textContaining('Payments read: 10'), findsOneWidget);
    expect(find.text('Sign in again (new code)'), findsOneWidget);
  });

  testWidgets('login not set up: no sign-in button', (tester) async {
    await tester.pumpWidget(_app(const MerchantFeedStatus(state: 'not_configured', message: 'Set GOLIS_MERCHANT_USERNAME')));
    await tester.pumpAndSettle();
    expect(find.text('Login not set up'), findsOneWidget);
    expect(find.byKey(const Key('feed-sign-in')), findsNothing);
  });
}
