import 'dart:async';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/screens/auth/login_screen.dart';
import 'package:badal_exchange_customer/screens/auth/register_screen.dart';
import 'package:badal_exchange_customer/screens/root/root_shell.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/state/wallet_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  Map<String, String> contacts = {'whatsapp': '252610000000', 'telegram': '@baari_support', 'facebook': ''};

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Map<String, String>> getSupportContacts() async => contacts;

  @override
  Future<Wallet> getWallet() async =>
      const Wallet(availableBalance: '0.00', pendingBalance: '0.00', totalDeposit: '0.00', totalWithdraw: '0.00');

  @override
  Future<List<Order>> getOrders() async => const [];

  @override
  Future<List<HomeAd>> getHomeAds() async => const [];
}

const _refused = ApiException(status: 401, code: 'UNAUTHORIZED', message: 'Invalid credentials');

/// Accounts by stored phone; records every login attempt.
class _FakeAuth extends AuthProvider {
  _FakeAuth(CustomerApi api) : super(apiClient: ApiClient(), customerApi: api);

  final attempts = <String>[];
  Map<String, String> accounts = {'252612345678': 'secret-123'};
  Future<void>? hold;
  ApiException? failWith;

  @override
  Future<void> login({required String phone, required String password}) async {
    attempts.add(phone);
    if (hold != null) await hold;
    if (failWith != null) throw failWith!;
    if (accounts[phone] != password) throw _refused;
  }
}

late _FakeApi _api;
late _FakeAuth _auth;

Widget _app() {
  _api = _FakeApi();
  _auth = _FakeAuth(_api);
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: _api),
      ChangeNotifierProvider<AuthProvider>.value(value: _auth),
      ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: _api)),
      ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: _api)),
    ],
    child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
  );
}

Future<void> _phone(WidgetTester tester, [Size size = const Size(393, 851)]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.reset);
}

Finder _input(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText));

Future<Finder> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  return target;
}

Future<void> _logIn(WidgetTester tester, {String phone = '612345678', String pw = 'secret-123'}) async {
  await tester.enterText(_input('login-phone'), phone);
  await tester.enterText(_input('login-password'), pw);
  await tester.tap(await _reveal(tester, 'login-submit'));
}

void main() {
  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the screen: +252 on its own, Remember me on, links', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Log in to your BAARI wallet'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('country-code')), matching: find.text('+252')), findsOneWidget);
    expect(find.text('9 digits number'), findsOneWidget);
    expect(find.textContaining('e.g. 2526'), findsNothing);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.byKey(const Key('create-account')), findsOneWidget);
    expect(tester.widget<EditableText>(_input('login-password')).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<EditableText>(_input('login-password')).obscureText, isFalse);
  });

  testWidgets('nothing is sent until the phone has 9 digits and a password is given', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.tap(await _reveal(tester, 'login-submit'));
    await tester.pump();
    expect(find.text('Enter the 9 digits after +252'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    await tester.enterText(_input('login-phone'), '61234567');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.text('Enter the 9 digits after +252'), findsOneWidget);
    expect(_auth.attempts, isEmpty);
  });

  testWidgets('logs in as 252 + 9 digits, once, with a spinner, then the home screen', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    final gate = Completer<void>();
    _auth.hold = gate.future;
    await _logIn(tester);
    await tester.tap(find.byKey(const Key('login-submit')), warnIfMissed: false);
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('login-submit')), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(_auth.attempts, ['252612345678']);
    expect(find.byType(RootShell), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('remember_me'), isTrue);
  });

  testWidgets('an older account saved as 0XXXXXXXXX still logs in; Remember me off is saved', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    _auth.accounts = {'0612345678': 'secret-123'};
    await tester.tap(find.byKey(const Key('remember-me')));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await _logIn(tester);
    await tester.pumpAndSettle();
    expect(_auth.attempts, ['252612345678', '0612345678']);
    expect(find.byType(RootShell), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('remember_me'), isFalse);
  });

  testWidgets('a wrong password says so; other errors are not retried', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await _logIn(tester, pw: 'wrong-pass');
    await tester.pumpAndSettle();
    expect(_auth.attempts, ['252612345678', '0612345678', '612345678']);
    expect(find.text('Wrong phone number or password.'), findsOneWidget);
    expect(find.byType(RootShell), findsNothing);

    _auth.attempts.clear();
    _auth.failWith = const ApiException(status: 0, code: 'NETWORK_ERROR', message: 'No connection. Try again.');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(_auth.attempts, hasLength(1));
    expect(find.text('No connection. Try again.'), findsOneWidget);
  });

  testWidgets('Forgot password shows the support contacts', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.tap(find.byKey(const Key('forgot-password')));
    await tester.pumpAndSettle();
    expect(find.text('Forgot your password?'), findsOneWidget);
    expect(find.byKey(const Key('support-WhatsApp')), findsOneWidget);
    expect(find.byKey(const Key('support-Telegram')), findsOneWidget);
    expect(find.byKey(const Key('support-Facebook')), findsNothing, reason: 'not set');
  });

  testWidgets('Forgot password without contacts says they are not available', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    _api.contacts = {'whatsapp': '', 'telegram': '', 'facebook': ''};
    await tester.tap(find.byKey(const Key('forgot-password')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Support contacts are not available'), findsOneWidget);
  });

  testWidgets('Create Account opens sign-up', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.tap(await _reveal(tester, 'create-account'));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);
  });

  for (final (name, size, somali) in [
    ('small 320x568', const Size(320, 568), false),
    ('small 360x640', const Size(360, 640), false),
    ('Somali 320x568', const Size(320, 568), true),
  ]) {
    testWidgets('$name: fits without overflow, with errors showing', (tester) async {
      AppLanguage.current.value = somali ? AppLanguage.somali : AppLanguage.english;
      await _phone(tester, size);
      await tester.pumpWidget(_app());
      await tester.tap(await _reveal(tester, 'login-submit'));
      await tester.pumpAndSettle();
      final create = await _reveal(tester, 'create-account');
      expect(tester.getRect(create).bottom <= size.height, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
