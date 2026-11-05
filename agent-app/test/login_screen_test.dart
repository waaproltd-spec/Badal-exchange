// The agent login screen: purple and white, +252 in front of the nine digits,
// a show / hide eye on the password, and the same sign-in call as before.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/screens/login_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Session extends Session {
  _Session() : super(api: AgentApi());
  final calls = <({String phone, String password})>[];

  @override
  Future<bool> login({required String phone, required String password}) async {
    calls.add((phone: phone, password: password));
    return false; // stays on the login screen
  }

  void busy(bool value) {
    isBusy = value;
    notifyListeners();
  }

  void failWith(String message) {
    loginError = message;
    notifyListeners();
  }
}

Future<_Session> _open(WidgetTester tester, {Size size = const Size(393, 851)}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = _Session();
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(value: session, child: const MaterialApp(home: LoginScreen())));
  await tester.pump();
  return session;
}

Finder _inner(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText));
String _typed(WidgetTester tester, String key) => tester.widget<EditableText>(_inner(key)).controller.text;

void main() {
  group('the number after +252', () {
    test('only the nine digits are kept; a country code (even twice) and a 0 are dropped', () {
      expect(localPhoneDigits('610000002'), '610000002');
      expect(localPhoneDigits('252610000002'), '610000002');
      expect(localPhoneDigits('+252 61 0000002'), '610000002');
      expect(localPhoneDigits('252252610000002'), '610000002');
      expect(localPhoneDigits('+252+252610000002'), '610000002');
      expect(localPhoneDigits('0610000002'), '610000002');
      expect(localPhoneDigits('2520610000002'), '610000002');
      expect(localPhoneDigits('6100000029999'), '610000002', reason: 'nothing past nine digits');
      expect(localPhoneDigits('61-00 00x002'), '610000002');
      expect(localPhoneDigits('25'), '25');
      expect(localPhoneDigits('252'), '');
      expect(localPhoneDigits(''), '');
    });
  });

  testWidgets('shows the Somali flag with +252 already in place, the Agent App badge and the notice', (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('brand-logo')), findsOneWidget);
    expect(find.text('BADAL EXCHANGE'), findsOneWidget);
    expect(find.text('Agent App'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('country-code')), matching: find.text('+252')), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget, reason: 'the star of the flag');
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Authorized agents only.'), findsOneWidget);
    expect(_typed(tester, 'phone-field'), isEmpty, reason: 'the field starts empty: +252 is not typed');
  });

  testWidgets('nine digits log in with 252 in front, and the password as typed', (tester) async {
    final session = await _open(tester);
    await tester.enterText(find.byKey(const Key('phone-field')), '610000002');
    await tester.enterText(find.byKey(const Key('password-field')), 'ChangeMe123!');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(session.calls, hasLength(1));
    expect(session.calls.single.phone, '252610000002');
    expect(session.calls.single.password, 'ChangeMe123!');
  });

  testWidgets('a country code typed or pasted is never doubled', (tester) async {
    final session = await _open(tester);
    for (final input in ['252610000002', '+252610000002', '252252610000002', '0610000002']) {
      await tester.enterText(find.byKey(const Key('phone-field')), input);
      await tester.pump();
      expect(_typed(tester, 'phone-field'), '610000002', reason: input);
    }
    await tester.enterText(find.byKey(const Key('password-field')), 'x');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(session.calls.single.phone, '252610000002');
  });

  testWidgets('no more than nine digits can be typed', (tester) async {
    await _open(tester);
    await tester.enterText(find.byKey(const Key('phone-field')), '61000000299');
    await tester.pump();
    expect(_typed(tester, 'phone-field'), '610000002');
  });

  testWidgets('a short number, or no password, is not sent', (tester) async {
    final session = await _open(tester);
    await tester.enterText(find.byKey(const Key('phone-field')), '6100');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(find.text('Enter the 9 digits after +252'), findsOneWidget);
    expect(session.calls, isEmpty);

    await tester.enterText(find.byKey(const Key('phone-field')), '610000002');
    await tester.enterText(find.byKey(const Key('password-field')), '');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(find.text('Enter your password'), findsOneWidget);
    expect(session.calls, isEmpty);
  });

  testWidgets('the eye shows and hides the password', (tester) async {
    await _open(tester);
    bool obscured() => tester.widget<EditableText>(_inner('password-field')).obscureText;
    await tester.enterText(find.byKey(const Key('password-field')), 'secret-pw');
    expect(obscured(), isTrue, reason: 'hidden by default');
    expect(find.byTooltip('Show password'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle-password')));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(_typed(tester, 'password-field'), 'secret-pw');
    await tester.tap(find.byKey(const Key('toggle-password')));
    await tester.pump();
    expect(obscured(), isTrue);
  });

  testWidgets('while signing in the button shows a spinner and does nothing; a refusal is shown', (tester) async {
    final session = await _open(tester);
    await tester.enterText(find.byKey(const Key('phone-field')), '610000002');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    session.busy(true);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Log in'), findsNothing);
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(session.calls, isEmpty);

    session.busy(false);
    session.failWith('Invalid credentials');
    await tester.pump();
    expect(find.byKey(const Key('login-error')), findsOneWidget);
    expect(find.text('Invalid credentials'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('fits a small phone and a big one without overflow', (tester) async {
    for (final size in const [Size(320, 568), Size(393, 851), Size(768, 1024)]) {
      await _open(tester, size: size);
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.enterText(find.byKey(const Key('phone-field')), '610000002');
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });
}
