import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/merchant_feed_screen.dart';
import 'package:badal_agent_app/screens/admin/sahal_account_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends AgentApi {
  SahalAccountStatus status;
  final calls = <String>[];
  _FakeApi(this.status);

  @override
  Future<SahalAccountStatus> getSahalAccount() async => status;

  @override
  Future<SahalAccountStatus> saveSahalAccount({required String username, required String password, String? pin, String? currency}) async {
    calls.add('save $username|$password|$pin');
    return status = _status(pending: SahalPendingAccount(username: username, hasPin: (pin ?? '').isNotEmpty, status: 'draft', message: 'Saved.'));
  }

  @override
  Future<SahalAccountStatus> testSahalAccount() async {
    calls.add('test');
    return status = _status(pending: const SahalPendingAccount(username: '252900000055', status: 'testing', message: 'Signing in…'));
  }

  @override
  Future<SahalAccountStatus> sahalAccountCode(String code) async {
    calls.add('code $code');
    return status = _status(pending: const SahalPendingAccount(username: '252900000055', status: 'code_entered'));
  }

  @override
  Future<SahalAccountStatus> discardSahalAccount() async {
    calls.add('discard');
    return status = _status();
  }

  @override
  Future<SahalAccountStatus> activateSahalAccount({required bool depositCodesUpdated}) async {
    calls.add('activate $depositCodesUpdated');
    return status = _status(source: 'database', username: '252900000055');
  }

  @override
  Future<SahalAccountStatus> checkSahalConnection() async {
    calls.add('check');
    return status;
  }

  @override
  Future<MerchantFeedStatus> merchantFeedSignIn() async {
    calls.add('reconnect');
    return const MerchantFeedStatus(state: 'ready');
  }

  @override
  Future<bool> setSahalRenewIdle(bool on) async {
    calls.add('renew-idle $on');
    status = _status(renewIdle: on);
    return on;
  }

  @override
  Future<MerchantFeedStatus> getMerchantFeedStatus() async => const MerchantFeedStatus(state: 'ok');
}

SahalAccountStatus _status({
  String connection = 'connected',
  String source = 'environment',
  String? username,
  SahalPendingAccount? pending,
  bool renewIdle = true,
}) =>
    SahalAccountStatus(
      connection: connection,
      feedMessage: connection == 'connected' ? '10 rows' : 'Sahal sent an access code',
      lastReadAt: DateTime.utc(2026, 10, 29, 4, 17),
      source: source,
      activeUsername: username,
      pending: pending,
      sessionActive: true,
      sessionStartedAt: DateTime.utc(2026, 10, 29, 3, 58),
      sessionAgeSeconds: 1200,
      lastLoginAt: DateTime.utc(2026, 10, 29, 3, 58),
      lastRenewalAt: DateTime.utc(2026, 10, 29, 3, 58),
      openDeposits: 1,
      openWithdrawals: 0,
      renewIdle: renewIdle,
    );

late _FakeApi _api;

Future<void> _open(WidgetTester tester, SahalAccountStatus s) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _api = _FakeApi(s);
  final api = _api;
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: const MaterialApp(home: SahalAccountScreen(poll: Duration(hours: 1))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the connection, the session and the account; Test connection reads without signing in again', (tester) async {
    await _open(tester, _status());
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const Key('account-session')), findsOneWidget);
    expect(find.textContaining('Last successful login: 2026-10-29 06:58'), findsOneWidget, reason: 'Somalia time (UTC+3)');
    expect(find.textContaining('Last renewal: 2026-10-29 06:58'), findsOneWidget);
    expect(find.text('Account: set on the server'), findsOneWidget);
    expect(find.byKey(const Key('account-reconnect')), findsNothing, reason: 'only when not connected');
    await tester.tap(find.byKey(const Key('account-check')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['check']);
  });

  testWidgets('authentication required / disconnected: Reconnect is offered and starts the sign-in', (tester) async {
    await _open(tester, _status(connection: 'authentication_required'));
    expect(find.text('Authentication required'), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-reconnect')));
    await tester.pumpAndSettle();
    expect(_api.calls, contains('reconnect'));
  });

  testWidgets('password and PIN are masked, sent once, emptied, and never shown again', (tester) async {
    await _open(tester, _status());
    expect(tester.widget<TextField>(find.byKey(const Key('account-password'))).obscureText, isTrue);
    expect(tester.widget<TextField>(find.byKey(const Key('account-pin'))).obscureText, isTrue);
    await tester.enterText(find.byKey(const Key('account-username')), '252900000055');
    await tester.enterText(find.byKey(const Key('account-password')), 'Pa55-secret');
    await tester.enterText(find.byKey(const Key('account-pin')), '4321');
    await tester.tap(find.byKey(const Key('account-save')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['save 252900000055|Pa55-secret|4321']);
    expect(tester.widget<TextField>(find.byKey(const Key('account-password'))).controller!.text, isEmpty);
    expect(tester.widget<TextField>(find.byKey(const Key('account-pin'))).controller!.text, isEmpty);
    expect(find.textContaining('Pa55-secret'), findsNothing);
    expect(find.textContaining('4321'), findsNothing);
    expect(find.byKey(const Key('pending-username')), findsOneWidget);
    expect(find.textContaining('Password: saved (hidden)'), findsOneWidget);
    expect(find.text('Account: set on the server'), findsOneWidget, reason: 'the working account is unchanged');
  });

  testWidgets('a login with no password is not sent', (tester) async {
    await _open(tester, _status());
    await tester.enterText(find.byKey(const Key('account-username')), '252900000055');
    await tester.tap(find.byKey(const Key('account-save')));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty);
    expect(find.byKey(const Key('account-error')), findsOneWidget);
  });

  testWidgets('a saved login: Test, then the SMS code is typed once; Activate waits for a verified test', (tester) async {
    await _open(tester, _status(pending: const SahalPendingAccount(username: '252900000055', hasPin: true, status: 'draft')));
    expect(tester.widget<ElevatedButton>(find.byKey(const Key('pending-activate'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('pending-test')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['test']);
    expect(find.text('Testing…'), findsOneWidget);

    _api.status = _status(pending: const SahalPendingAccount(username: '252900000055', status: 'needs_code', message: 'Sahal sent a code'));
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: _api),
      child: const MaterialApp(home: SahalAccountScreen(poll: Duration(hours: 1))),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pending-code')), '654 321');
    await tester.tap(find.byKey(const Key('pending-send-code')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['test', 'code 654321']);
  });

  testWidgets('Activate: says what is open, needs the deposit-code confirmation for another account, then switches', (tester) async {
    await _open(tester, _status(pending: SahalPendingAccount(username: '252900000055', hasPin: true, status: 'verified', verifiedAt: DateTime.now())));
    await tester.tap(find.byKey(const Key('pending-activate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('activate-dialog')), findsOneWidget);
    expect(find.textContaining('1 deposit(s) waiting for payment'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byKey(const Key('activate-go'))).onPressed, isNull, reason: 'confirm the deposit codes first');
    await tester.tap(find.byKey(const Key('activate-confirm-codes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('activate-go')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['activate true']);
    expect(find.text('Account: 252900000055'), findsOneWidget);
  });

  testWidgets('Cancel in the dialog changes nothing; Discard drops the new login', (tester) async {
    await _open(tester, _status(pending: SahalPendingAccount(username: '252900000055', status: 'verified', verifiedAt: DateTime.now())));
    await tester.tap(find.byKey(const Key('pending-activate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty);
    await tester.tap(find.byKey(const Key('pending-discard')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['discard']);
    expect(find.byKey(const Key('pending-username')), findsNothing);
  });

  testWidgets('renewing an idle session can be switched off', (tester) async {
    await _open(tester, _status());
    await tester.tap(find.byKey(const Key('account-renew-idle')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['renew-idle false']);
  });

  testWidgets('the Sahal sign-in screen links to the account screen', (tester) async {
    _api = _FakeApi(_status());
    final api = _api;
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api),
      child: const MaterialApp(home: MerchantFeedScreen(poll: Duration(hours: 1))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feed-open-account')));
    await tester.pumpAndSettle();
    expect(find.text('Sahal Merchant Account'), findsOneWidget);
  });
}
