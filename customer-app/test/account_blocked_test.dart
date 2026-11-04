// A blocked customer: the Account Blocked card (English and Somali) with Contact Support; refused at login;
// signed out by itself when the account is blocked while the app is open; unblocked, the login works again.
import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/models/auth_user.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/screens/auth/account_unblocked_screen.dart';
import 'package:badal_exchange_customer/screens/auth/login_screen.dart';
import 'package:badal_exchange_customer/screens/root/root_shell.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/state/wallet_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

class _Api extends CustomerApi {
  _Api(this.client) : super(client);

  final ApiClient client;
  Map<String, String> contacts = {
    'whatsapp': '',
    'telegram': '',
    'facebook': ''
  };
  int logouts = 0;
  int checks = 0;
  bool blocked = false;

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Map<String, String>> getSupportContacts() async => contacts;

  @override
  Future<Wallet> getWallet() async => const Wallet(
      availableBalance: '1.00',
      pendingBalance: '0.00',
      totalDeposit: '0.00',
      totalWithdraw: '0.00');

  @override
  Future<List<Order>> getOrders() async => const [];

  @override
  Future<List<HomeAd>> getHomeAds() async => const [];

  @override
  Future<void> logout() async => logouts++;

  @override
  Future<bool> verifySession() async {
    checks++;
    if (blocked) {
      client.onAccountBlocked
          ?.call(); // what the api client does when the server refuses with "Account is disabled"
      throw const ApiException(
          status: 403, code: 'ACCOUNT_BLOCKED', message: 'blocked');
    }
    return true;
  }
}

/// Logging in: refused while [blocked].
class _Auth extends AuthProvider {
  _Auth(ApiClient client, CustomerApi api, GlobalKey<NavigatorState> nav)
      : super(apiClient: client, customerApi: api, navigatorKey: nav);

  bool blockedAccount = false;
  int attempts = 0;

  @override
  Future<void> login({required String phone, required String password}) async {
    attempts++;
    if (blockedAccount)
      throw ApiException(
          status: 403,
          code: 'ACCOUNT_BLOCKED',
          message: AppStrings.accountBlockedMessage);
  }
}

late ApiClient _client;
late _Api _api;
late _Auth _auth;
final _nav = GlobalKey<NavigatorState>();

Widget _app({Widget home = const LoginScreen()}) {
  _client = ApiClient();
  _api = _Api(_client);
  _auth = _Auth(_client, _api, _nav);
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: _api),
      ChangeNotifierProvider<AuthProvider>.value(value: _auth),
      ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: _api)),
      ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: _api)),
    ],
    child: MaterialApp(navigatorKey: _nav, theme: AppTheme.current, home: home),
  );
}

Future<void> _phone(WidgetTester tester, {double width = 393}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  test(
      'the server\'s "Account is disabled" and a banned login are both ACCOUNT_BLOCKED',
      () async {
    await expectLater(
      ApiClient.guard(() async => throw const PostgrestException(
          message: 'Account is disabled', code: 'PT403', hint: 'FORBIDDEN')),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'ACCOUNT_BLOCKED')
          .having((e) => e.status, 'status', 403)),
    );
    await expectLater(
      ApiClient.guard(() async => throw const AuthException('User is banned',
          statusCode: '403', code: 'user_banned')),
      throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'ACCOUNT_BLOCKED')),
    );
    // Other refusals are not mistaken for a block.
    await expectLater(
      ApiClient.guard(() async => throw const PostgrestException(
          message: 'Forbidden', code: 'PT403', hint: 'FORBIDDEN')),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FORBIDDEN')),
    );
  });

  testWidgets(
      'the Account Blocked card in English: title, message, support hint, Contact Support',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(home: const LoginScreen(blocked: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-blocked')), findsOneWidget);
    expect(find.text('Account Blocked'), findsOneWidget);
    expect(
        find.text(
            'Your account has been blocked by the administrator. You cannot access your account at this time.'),
        findsOneWidget);
    expect(find.text('Please contact customer support for more information.'),
        findsOneWidget);
    expect(find.text('Contact Support'), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsWidgets);
  });

  testWidgets('and in Somali', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester);
    await tester.pumpWidget(_app(home: const LoginScreen(blocked: true)));
    await tester.pumpAndSettle();
    expect(find.text('Akoonka Waa La Xiray'), findsOneWidget);
    expect(
        find.text(
            'Akoonkaaga waxaa xiray maamulka. Hadda ma geli kartid akoonkaaga.'),
        findsOneWidget);
    expect(
        find.text(
            'Fadlan la xiriir adeegga macaamiisha haddii aad u baahan tahay faahfaahin dheeraad ah.'),
        findsOneWidget);
    expect(find.text('La Xiriir Taageerada'), findsOneWidget);
  });

  testWidgets(
      'Contact Support: with no contact set it says so; with two it offers them',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(home: const LoginScreen(blocked: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('blocked-contact')));
    await tester.pumpAndSettle();
    expect(find.text('The support contact is not set yet.'), findsOneWidget);

    _api.contacts = {
      'whatsapp': '252610000000',
      'telegram': '@baari_support',
      'facebook': ''
    };
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(find.byKey(const Key('blocked-contact')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-whatsapp')), findsOneWidget);
    expect(find.byKey(const Key('support-telegram')), findsOneWidget);
  });

  testWidgets(
      'a blocked account tries to log in: refused, the same card, no home screen, no other error',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    _auth.blockedAccount = true;
    await tester.enterText(find.byKey(const Key('login-phone')), '612345678');
    await tester.enterText(
        find.byKey(const Key('login-password')), 'secret-123');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(_auth.attempts, 1,
        reason: 'a block is not retried with other number forms');
    expect(find.byKey(const Key('account-blocked')), findsOneWidget);
    expect(find.text('Account Blocked'), findsOneWidget);
    expect(find.byType(RootShell), findsNothing);
    // Close the card: still the login screen, nothing opened.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-blocked')), findsNothing);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    expect(find.byType(RootShell), findsNothing);

    // Unblocked: the login works again (and shows no card).
    _auth.blockedAccount = false;
    await tester.tap(find.byKey(const Key('login-submit')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_auth.attempts, 2);
    expect(find.byKey(const Key('account-blocked')), findsNothing);
    expect(find.byKey(const Key('account-unblocked')), findsOneWidget, reason: 'it was blocked, now the server accepts the login: unblocked');
    expect(find.byType(RootShell), findsNothing, reason: 'the success screen comes first');
    await tester.tap(find.byKey(const Key('unblocked-login')));
    await tester.pumpAndSettle();
    expect(find.byType(RootShell), findsOneWidget, reason: 'then the customer is in again, normally');
    expect((await SharedPreferences.getInstance()).getBool('account_was_blocked'), isNull, reason: 'shown once');
  });

  testWidgets(
      'already signed in and using the app: when the account is blocked the phone signs out and shows the card',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(
        _app(home: const Scaffold(body: Center(child: Text('HOME')))));
    _auth.debugSignIn(const AuthUser(phone: '252612345678', name: 'Asha'));
    expect(_auth.isAuthenticated, isTrue);
    expect(find.text('HOME'), findsOneWidget);
    _client.onAccountBlocked!.call();
    await tester.pumpAndSettle();
    expect(_auth.isAuthenticated, isFalse, reason: 'signed out');
    expect(_api.logouts, 1);
    expect(find.text('HOME'), findsNothing,
        reason: 'no screen of the app is left');
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byKey(const Key('account-blocked')), findsOneWidget);
  });

  testWidgets(
      'the periodic / on-resume check asks the server and signs out a blocked account; a signed-out phone asks nothing',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(home: const Scaffold(body: Text('HOME'))));
    await _auth.checkAccount();
    expect(_api.checks, 0, reason: 'nobody is signed in: nothing to ask');
    _auth.debugSignIn(const AuthUser(phone: '252612345678', name: 'Asha'));
    await _auth.checkAccount();
    expect(_api.checks, 1);
    expect(_auth.isAuthenticated, isTrue,
        reason: 'an open account stays signed in');
    _api.blocked = true;
    await _auth.checkAccount();
    await tester.pumpAndSettle();
    expect(_api.checks, 2);
    expect(_auth.isAuthenticated, isFalse);
    expect(find.byKey(const Key('account-blocked')), findsOneWidget);
  });

  testWidgets('a small phone, larger text: the card fits and scrolls',
      (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester, width: 320);
    tester.view.physicalSize = const Size(320, 560);
    await tester.pumpWidget(_app(home: const LoginScreen(blocked: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('blocked-contact')), findsOneWidget);
    final problem = tester.takeException()?.toString() ?? '';
    expect(problem.contains('account_blocked_dialog.dart'), isFalse,
        reason: problem);
  });

  testWidgets('Account Unblocked in English: title, message, a Login button',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(home: AccountUnblockedScreen(onLogin: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Account Unblocked'), findsOneWidget);
    expect(
        find.text(
            'Your account has been restored. You can now log in and access your account normally.'),
        findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('and in Somali, on a small phone', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester, width: 320);
    tester.view.physicalSize = const Size(320, 560);
    await tester.pumpWidget(_app(home: AccountUnblockedScreen(onLogin: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Akoonka Waa La Fasaxay'), findsOneWidget);
    expect(
        find.text(
            'Akoonkaaga dib ayaa loo furay. Hadda waxaad si caadi ah u geli kartaa akoonkaaga.'),
        findsOneWidget);
    expect(find.text('Gali (Login)'), findsOneWidget);
    final problem = tester.takeException()?.toString() ?? '';
    expect(problem.contains('account_unblocked_screen.dart'), isFalse,
        reason: problem);
  });

  testWidgets('the Login button continues into the app', (tester) async {
    await _phone(tester);
    var pressed = 0;
    await tester.pumpWidget(
        _app(home: AccountUnblockedScreen(onLogin: () => pressed++)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unblocked-login')));
    expect(pressed, 1);
  });

  testWidgets(
      'blocked before, unblocked now: the next accepted login shows Account Unblocked once, then home; a normal login goes straight home',
      (tester) async {
    await _phone(tester);
    SharedPreferences.setMockInitialValues(
        {'account_was_blocked': true}); // remembered from when it was blocked
    await tester.pumpWidget(_app());
    Future<void> logIn() async {
      await tester.enterText(find.byKey(const Key('login-phone')), '612345678');
      await tester.enterText(
          find.byKey(const Key('login-password')), 'secret-123');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
    }

    await logIn();
    expect(find.byKey(const Key('account-unblocked')), findsOneWidget);
    expect(_auth.attempts, 1,
        reason: 'the same existing account: no sign-up, nothing is created');
    await tester.tap(find.byKey(const Key('unblocked-login')));
    await tester.pumpAndSettle();
    expect(find.byType(RootShell), findsOneWidget);

    // Later: a plain login, no unblocked screen any more.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app());
    await logIn();
    expect(find.byKey(const Key('account-unblocked')), findsNothing);
    expect(find.byType(RootShell), findsOneWidget);
  });

  testWidgets(
      'still blocked: the Account Blocked card again, no success screen, and it is remembered',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    _auth.blockedAccount = true;
    await tester.enterText(find.byKey(const Key('login-phone')), '612345678');
    await tester.enterText(
        find.byKey(const Key('login-password')), 'secret-123');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-blocked')), findsOneWidget);
    expect(find.byKey(const Key('account-unblocked')), findsNothing);
    expect(
        (await SharedPreferences.getInstance()).getBool('account_was_blocked'),
        isTrue,
        reason: 'so the next accepted login is known to be an unblock');
  });

  testWidgets('signed out because of a block: it is remembered on the phone',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(home: const Scaffold(body: Text('HOME'))));
    _auth.debugSignIn(const AuthUser(phone: '252612345678', name: 'Asha'));
    _client.onAccountBlocked!.call();
    await tester.pumpAndSettle();
    expect(
        (await SharedPreferences.getInstance()).getBool('account_was_blocked'),
        isTrue);
  });
}
