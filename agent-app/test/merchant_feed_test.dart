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
  Future<MerchantFeedStatus> merchantFeedCredit(bool on) async {
    calls.add('credit $on');
    return status = MerchantFeedStatus(state: status.state, creditOn: on, creditedToday: 2);
  }

  @override
  Future<MerchantFeedStatus> merchantFeedPayouts(bool on) async {
    calls.add('payouts $on');
    return status = MerchantFeedStatus(state: status.state, payoutsOn: on);
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
    expect(find.byKey(const Key('feed-auto-hint')), findsOneWidget, reason: 'says the phone enters it, and that it can be typed');
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

  testWidgets('crediting can be switched off and on, with today\'s counts', (tester) async {
    await tester.pumpWidget(_app(const MerchantFeedStatus(state: 'ok', creditOn: true, creditedToday: 3, unmatchedToday: 1)));
    await tester.pumpAndSettle();
    expect(find.text('Credited (24 h): 3 · Not matched: 1'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('feed-credit'))).value, isTrue);
    await tester.tap(find.byKey(const Key('feed-credit')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['credit false']);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('feed-credit'))).value, isFalse);
  });


  testWidgets('withdrawals sent from Sahal: switch and today\'s count', (tester) async {
    await tester.pumpWidget(_app(const MerchantFeedStatus(state: 'ok', payoutsOn: true, payoutsCompletedToday: 4)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('feed-payouts')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Completed (24 h): 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feed-payouts')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['payouts false']);
  });

}
