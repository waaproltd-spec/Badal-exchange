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
import 'package:badal_exchange_customer/widgets/auth_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Serves an empty wallet for the home screen after sign-up.
class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Wallet> getWallet() async =>
      const Wallet(availableBalance: '0.00', pendingBalance: '0.00', totalDeposit: '0.00', totalWithdraw: '0.00');

  @override
  Future<List<Order>> getOrders() async => const [];

  @override
  Future<List<HomeAd>> getHomeAds() async => const [];
}

/// Records sign-ups; [result] decides how each one ends.
class _FakeAuth extends AuthProvider {
  _FakeAuth(CustomerApi api) : super(apiClient: ApiClient(), customerApi: api);

  final calls = <Map<String, String>>[];
  Future<void> Function() result = () async {};

  @override
  Future<void> register({required String phone, required String name, required String password}) {
    calls.add({'phone': phone, 'name': name, 'password': password});
    return result();
  }
}

late _FakeAuth _auth;

Widget _app(Widget home) {
  final api = _FakeApi();
  _auth = _FakeAuth(api);
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: _auth),
      ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: api)),
      ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
    ],
    child: MaterialApp(theme: AppTheme.light, home: home),
  );
}

Future<void> _phone(WidgetTester tester, [Size size = const Size(393, 851)]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.reset);
}

Finder _input(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText));

Future<void> _fill(WidgetTester tester,
    {String name = 'Amina Hassan', String phone = '612345678', String pw = 'secret-123', String? confirm}) async {
  await tester.enterText(_input('register-name'), name);
  await tester.enterText(_input('register-phone'), phone);
  await tester.enterText(_input('register-password'), pw);
  await tester.enterText(_input('register-confirm'), confirm ?? pw);
}

/// Scrolls the (lazily built) form until [key] is on screen.
Future<Finder> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  return target;
}

Future<void> _tapSubmit(WidgetTester tester) async => tester.tap(await _reveal(tester, 'register-submit'));

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('+252 shown on its own; the field takes the 9 digits only', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    expect(find.descendant(of: find.byKey(const Key('country-code')), matching: find.text('+252')), findsOneWidget);
    expect(find.text('9 digits number'), findsOneWidget);
    expect(find.textContaining('e.g. 2526'), findsNothing);
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Your wallet, made simple with BAARI'), findsOneWidget);
    expect(find.text('Enter your full name'), findsOneWidget); // name placeholder

    final field = _input('register-phone');
    String typed(String text) {
      tester.testTextInput.updateEditingValue(TextEditingValue(text: text));
      return tester.widget<EditableText>(field).controller.text;
    }

    await tester.tap(field);
    expect(typed('61a2-34 5'), '612345');
    expect(typed('6123456789999'), '612345678', reason: 'no more than 9 digits');
    expect(typed('+252 612 345 678'), '612345678', reason: 'a pasted +252 is dropped');
    expect(typed('0612345678'), '612345678', reason: 'a leading 0 is dropped');
  });

  test('the number formatter on its own', () {
    expect(SomaliLocalNumberFormatter.clean('252907000001'), '907000001');
    expect(SomaliLocalNumberFormatter.clean('2526'), '2526', reason: 'short input is local digits');
    expect(SomaliLocalNumberFormatter.clean(''), '');
  });

  testWidgets('every field is checked before anything is sent', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    await _tapSubmit(tester);
    await tester.pump();
    expect(find.text('Enter your full name'), findsNWidgets(2)); // placeholder + error
    expect(find.text('Enter the 9 digits after +252'), findsOneWidget);
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);

    await _fill(tester, phone: '61234567', pw: 'short', confirm: 'short');
    await _tapSubmit(tester);
    await tester.pump();
    expect(find.text('Enter the 9 digits after +252'), findsOneWidget, reason: '8 digits is not enough');
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);

    await _fill(tester, name: '   ', confirm: 'secret-124');
    await _tapSubmit(tester);
    await tester.pump();
    // The (hidden) placeholder and the error.
    expect(find.text('Enter your full name'), findsNWidgets(2), reason: 'blank name is an error');
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(_auth.calls, isEmpty);
  });

  testWidgets('both password fields have their own show/hide eye, hidden by default', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    bool hidden(String key) => tester.widget<EditableText>(_input(key)).obscureText;
    expect(hidden('register-password'), isTrue);
    expect(hidden('register-confirm'), isTrue);
    expect(hidden('register-name'), isFalse);

    await tester.tap(find.descendant(of: find.byKey(const Key('register-password')), matching: find.byTooltip('Show password')));
    await tester.pump();
    expect(hidden('register-password'), isFalse);
    expect(hidden('register-confirm'), isTrue);

    await tester.tap(find.descendant(of: find.byKey(const Key('register-confirm')), matching: find.byTooltip('Show password')));
    await tester.pump();
    expect(hidden('register-confirm'), isFalse);
    await tester.tap(find.descendant(of: find.byKey(const Key('register-confirm')), matching: find.byTooltip('Hide password')));
    await tester.pump();
    expect(hidden('register-confirm'), isTrue);
  });

  testWidgets('sign-up sends 252 + 9 digits once, shows loading, then the home screen', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    final pending = Completer<void>();
    _auth.result = () => pending.future;
    await _fill(tester, name: '  Amina Hassan ');
    await _tapSubmit(tester);
    await tester.pump();
    await tester.tap(find.byKey(const Key('register-submit')), warnIfMissed: false); // a second tap does nothing
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('register-submit')), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(_auth.calls, [
      {'phone': '252612345678', 'name': 'Amina Hassan', 'password': 'secret-123'}
    ]);

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RootShell), findsOneWidget);
    expect(find.text('Account created. Welcome to BAARI!'), findsOneWidget);
  });

  testWidgets('a backend error is shown and the button works again', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    _auth.result = () async =>
        throw const ApiException(status: 409, code: 'PHONE_TAKEN', message: 'Phone number already registered');
    await _fill(tester);
    await _tapSubmit(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('register-error')), findsOneWidget);
    expect(find.text('Phone number already registered'), findsOneWidget);
    expect(find.byType(RootShell), findsNothing);
    await _tapSubmit(tester);
    await tester.pumpAndSettle();
    expect(_auth.calls, hasLength(2));
  });

  testWidgets('Log In goes back to the login screen it came from', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.tap(find.textContaining('Create Account', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);
    await tester.tap(await _reveal(tester, 'go-to-login'));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('Log In opens the login screen when sign-up was opened first', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const RegisterScreen()));
    await tester.tap(await _reveal(tester, 'go-to-login'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  for (final (name, size, somali) in [
    ('small 320x568', const Size(320, 568), false),
    ('small 360x640', const Size(360, 640), false),
    ('Somali 320x568', const Size(320, 568), true),
  ]) {
    testWidgets('$name: fits without overflow, with errors showing, and scrolls to the button', (tester) async {
      AppLanguage.current.value = somali ? AppLanguage.somali : AppLanguage.english;
      await _phone(tester, size);
      await tester.pumpWidget(_app(const RegisterScreen()));
      await _tapSubmit(tester);
      await tester.pumpAndSettle();
      final login = await _reveal(tester, 'go-to-login');
      expect(tester.getRect(login).bottom <= size.height, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('with the keyboard open, the focused field stays visible', (tester) async {
    await _phone(tester, const Size(360, 640));
    await tester.pumpWidget(_app(const RegisterScreen()));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.showKeyboard(_input('register-confirm'));
    await tester.pumpAndSettle();
    final field = tester.getRect(_input('register-confirm'));
    expect(field.bottom <= 640 - 280, isTrue, reason: 'field ends at ${field.bottom}');
    expect(tester.binding.testTextInput.isVisible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  });
}
