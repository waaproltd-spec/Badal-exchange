// Several accounts under one betting platform in the Agent App: the list says
// how many there are and which is in use; each account has its own ON / OFF,
// Test connection and credentials; the admin selects the one in use.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/language.dart';
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
    {
      'key': 'login',
      'label': 'Login / Username',
      'required': true,
      'secret': false
    },
    {
      'key': 'password',
      'label': 'Cashier password',
      'required': true,
      'secret': true
    },
    {
      'key': 'accountId',
      'label': 'Cashdesk ID (World / Wallet ID)',
      'required': true,
      'secret': false
    },
    {
      'key': 'apiSecret',
      'label': 'Hash (API secret / signature key)',
      'required': true,
      'secret': true
    },
  ],
});

Map<String, dynamic> _acc(String id, String label,
        {bool selected = false,
        bool enabled = false,
        String status = 'not_configured',
        String? cashdesk,
        int orders = 0,
        String? message,
        bool saved = false}) =>
    {
      'id': id,
      'label': label,
      'selected': selected,
      'enabled': enabled,
      'status': status,
      'accountId': cashdesk,
      'login': saved ? 'ca••••r2' : null,
      'hasPassword': saved,
      'hasApiSecret': saved,
      'orders': orders,
      'lastMessage': message,
      'virtual': false,
    };

/// The server's answer, kept here so a call changes what the screen shows next.
class _Server {
  List<Map<String, dynamic>> accounts = [
    _acc('a1', 'Account 1',
        selected: true,
        enabled: true,
        status: 'connected',
        cashdesk: '1111111',
        orders: 12,
        saved: true),
    _acc('a2', 'Account 2',
        cashdesk: '2222222', status: 'not_tested', saved: true),
  ];

  BettingPlatform get platform => BettingPlatform.fromJson({
        'method': '888starz',
        'name': '888STARZ',
        'adapter': 'cashdeskbot',
        'builtIn': true,
        'active': true,
        'mode': 'cashdesk',
        'status': 'connected',
        'accounts': accounts,
        'selectedAccountId': accounts.firstWhere((a) => a['selected'] == true,
            orElse: () => {'id': null})['id'],
      });

  Map<String, dynamic> byId(String id) =>
      accounts.firstWhere((a) => a['id'] == id);
}

class _Api extends AgentApi {
  _Api(this.s);
  final _Server s;
  final calls = <String>[];

  @override
  Future<({List<BettingAdapter> adapters, List<BettingPlatform> platforms})>
      getBettingPlatforms() async =>
          (adapters: [_adapter], platforms: [s.platform]);

  @override
  Future<BettingPlatform> addBettingAccount(String method,
      {String? label}) async {
    calls.add('add $method ${label ?? '-'}');
    s.accounts.add(_acc('a${s.accounts.length + 1}',
        label ?? 'Account ${s.accounts.length + 1}'));
    return s.platform;
  }

  @override
  Future<BettingPlatform> saveBettingAccount(String accountId,
      {String? apiUrl,
      String? login,
      String? password,
      String? cashdeskId,
      String? apiSecret,
      String? apiKey}) async {
    calls.add('save $accountId $login $password $cashdeskId $apiSecret');
    final a = s.byId(accountId);
    a['accountId'] = cashdeskId ?? a['accountId'];
    a['status'] = 'not_tested';
    a['hasPassword'] = true;
    a['hasApiSecret'] = true;
    a['login'] = 'sa••••ed';
    a['enabled'] = a['selected'] == true;
    return s.platform;
  }

  @override
  Future<BettingPlatform> testBettingAccount(
      String method, String accountId) async {
    calls.add('test $method $accountId');
    final a = s.byId(accountId);
    a['status'] = accountId == 'a2' &&
            calls.where((c) => c == 'test $method a2').length == 1
        ? 'error'
        : 'connected';
    a['lastMessage'] = a['status'] == 'error'
        ? 'CashdeskBot rejected the request: invalid sign'
        : 'Connected: balance 100';
    return s.platform;
  }

  @override
  Future<BettingPlatform> setBettingAccountEnabled(
      String accountId, bool enabled) async {
    calls.add('enable $accountId $enabled');
    final a = s.byId(accountId);
    if (enabled && a['status'] != 'connected') {
      throw const ApiException(
          statusCode: 409,
          code: 'NOT_TESTED',
          message:
              'Test the connection first: only an account whose credentials passed can be switched on');
    }
    if (!enabled && a['selected'] == true) {
      throw const ApiException(
          statusCode: 409,
          code: 'ACCOUNT_IN_USE',
          message:
              'This account is in use: select another account first, or switch the platform off');
    }
    a['enabled'] = enabled;
    return s.platform;
  }

  @override
  Future<BettingPlatform> selectBettingAccount(String accountId) async {
    calls.add('select $accountId');
    for (final a in s.accounts) {
      a['selected'] = a['id'] == accountId;
    }
    return s.platform;
  }

  @override
  Future<BettingPlatform> renameBettingAccount(
      String accountId, String label) async {
    calls.add('rename $accountId $label');
    s.byId(accountId)['label'] = label;
    return s.platform;
  }

  @override
  Future<BettingPlatform> removeBettingAccount(
      String accountId, String reason) async {
    calls.add('remove $accountId $reason');
    s.accounts.removeWhere((a) => a['id'] == accountId);
    return s.platform;
  }
}

Future<_Api> _pump(WidgetTester tester, Widget home,
    {_Server? server, Size size = const Size(393, 1800)}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api(server ?? _Server());
  await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return api;
}

BettingPlatformScreen _screen(_Server s) => BettingPlatformScreen(
    method: '888starz', adapter: _adapter, initial: s.platform);

void main() {
  tearDown(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets(
      'the list says how many accounts a platform has and which one is in use',
      (tester) async {
    await _pump(tester, const BettingPlatformsScreen());
    expect(find.text('2 accounts · in use: Account 1'), findsOneWidget);
    final one = _Server()
      ..accounts = [
        _acc('a1', 'Account 1',
            selected: true, enabled: true, status: 'connected')
      ];
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const BettingPlatformsScreen(), server: one);
    expect(find.byKey(const Key('platform-accounts-888starz')), findsNothing,
        reason: 'one account: nothing new on the list');
  });

  testWidgets(
      'each account has its own status, ON / OFF and orders; the account in use is marked',
      (tester) async {
    final s = _Server();
    await _pump(tester, _screen(s));
    expect(find.text('ACCOUNTS'), findsOneWidget);
    expect(find.byKey(const Key('account-inuse-a1')), findsOneWidget);
    expect(find.byKey(const Key('account-inuse-a2')), findsNothing);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a1')))
            .value,
        isTrue);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a2')))
            .value,
        isFalse);
    expect(find.text('12 orders handled'), findsOneWidget);
    expect(find.text('Cashdesk ID 1111111'), findsOneWidget);
    expect(find.text('Cashdesk ID 2222222'), findsOneWidget);
    expect(find.text('Not tested'), findsOneWidget,
        reason: 'Account 2 has its own status');
  });

  testWidgets(
      'Account 2: Test connection on its own, ON only after it passed, then the admin selects it',
      (tester) async {
    final s = _Server();
    final api = await _pump(tester, _screen(s));
    // Not switched on before a test.
    await tester.tap(find.byKey(const Key('account-enabled-a2')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'enable a2 true');
    expect(find.textContaining('Test the connection first'), findsOneWidget);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a2')))
            .value,
        isFalse);
    // "Use this account" waits for ON.
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('account-select-a2')))
            .onPressed,
        isNull);
    // Its own test: it fails first, with the provider's answer on that account only.
    await tester.tap(find.byKey(const Key('account-test-a2')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'test 888starz a2');
    expect(find.text('Error'), findsWidgets);
    expect(find.textContaining('invalid sign'), findsOneWidget);
    expect(find.textContaining('Connected: balance'), findsNothing,
        reason: 'Account 1 shows nothing of that test');
    // Tested again: passes.
    await tester.tap(find.byKey(const Key('account-test-a2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-status-a2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-enabled-a2')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a2')))
            .value,
        isTrue);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a1')))
            .value,
        isTrue,
        reason: 'Account 1 is untouched');
    // Select it.
    await tester.tap(find.byKey(const Key('account-select-a2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'select a2');
    expect(find.byKey(const Key('account-inuse-a2')), findsOneWidget);
    expect(find.byKey(const Key('account-inuse-a1')), findsNothing);
    // The account in use can not be switched off.
    await tester.tap(find.byKey(const Key('account-enabled-a2')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'enable a2 false',
        reason: 'the server refuses switching off the account in use (backend test)');
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-a2')))
            .value,
        isTrue);
  });

  testWidgets(
      'adding an account, with a name or without; renaming; removing one that is not in use, with a reason',
      (tester) async {
    final s = _Server();
    final api = await _pump(tester, _screen(s));
    await tester.tap(find.byKey(const Key('account-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-name-ok')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'add 888starz -',
        reason: 'no name: the server numbers it');
    expect(find.text('Account 3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('account-name')), 'Cashier North');
    await tester.tap(find.byKey(const Key('account-name-ok')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'add 888starz Cashier North');
    expect(find.text('Cashier North'), findsOneWidget);

    // Rename.
    await tester.tap(find.byKey(const Key('account-menu-a3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('account-name')), 'Cashier South');
    await tester.tap(find.byKey(const Key('account-name-ok')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'rename a3 Cashier South');

    // The account in use can not be removed; another can, with a reason.
    await tester.tap(find.byKey(const Key('account-menu-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Remove account'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-menu-a3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove account'));
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(FilledButton, 'Remove');
    expect(tester.widget<FilledButton>(remove).onPressed, isNull,
        reason: 'a reason is needed');
    await tester.enterText(
        find.byKey(const Key('remove-reason')), 'Closed the cash desk');
    await tester.pump();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'remove a3 Closed the cash desk');
    expect(find.text('Cashier South'), findsNothing);
  });

  testWidgets(
      'Edit credentials of another account: its own form, saved and tested for that account only',
      (tester) async {
    final s = _Server();
    final api = await _pump(tester, _screen(s));
    await tester.tap(find.byKey(const Key('account-edit-a2')));
    await tester.pumpAndSettle();
    expect(find.text('888STARZ · Account 2'), findsOneWidget);
    expect(find.text('Saved: leave empty to keep'), findsNWidgets(2));
    await tester.enterText(
        find.byKey(const Key('account-field-login')), 'second-cashier');
    await tester.enterText(
        find.byKey(const Key('account-field-password')), 'pass-2');
    await tester.enterText(
        find.byKey(const Key('account-field-accountId')), '12ab');
    await tester.tap(find.byKey(const Key('account-save')));
    await tester.pumpAndSettle();
    expect(find.text('Digits only'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('save')), isEmpty);
    await tester.enterText(
        find.byKey(const Key('account-field-accountId')), '3333333');
    await tester.tap(find.byKey(const Key('account-save')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'save a2 second-cashier pass-2 3333333 null');
    expect(find.text('pass-2'), findsNothing,
        reason: 'a saved secret is not shown again');
    await tester.tap(find.byKey(const Key('account-test')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'test 888starz a2');
    // Account 1's form is not this one.
    expect(find.byKey(const Key('field-login')), findsNothing);
  });

  testWidgets(
      'a built-in platform not saved yet shows its one account on the server\'s secrets, and can get a second',
      (tester) async {
    final s = _Server()
      ..accounts = [
        {
          'id': null,
          'label': 'Account 1',
          'selected': true,
          'enabled': true,
          'status': 'server',
          'orders': 0,
          'virtual': true
        },
      ];
    final api = await _pump(tester, _screen(s), server: s);
    expect(find.text('Server secrets'), findsWidgets);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('account-enabled-server')))
            .onChanged,
        isNull);
    expect(find.byKey(const Key('account-test-server')), findsNothing);
    await tester.tap(find.byKey(const Key('account-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-name-ok')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'add 888starz -');
  });

  testWidgets('in Somali, dark and on a small phone', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    final s = _Server();
    await _pump(tester, _screen(s), size: const Size(320, 800));
    expect(find.text('AKOONNADA'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('account-inuse-a1')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('La isticmaalayo'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('account-select-a2')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Isticmaal akoonkan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
