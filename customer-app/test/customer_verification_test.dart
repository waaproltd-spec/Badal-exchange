// Customer verification: the PIN (kept only on the phone, hashed), the
// fingerprint (the phone answers yes or no; nothing is stored or sent), the
// account password as the way in, the lock when the app opens or comes back,
// and the settings in Profile.
import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/auth_user.dart';
import 'package:badal_exchange_customer/screens/profile/verification_settings_screen.dart';
import 'package:badal_exchange_customer/screens/security/app_lock_gate.dart';
import 'package:badal_exchange_customer/screens/security/pin_setup_screen.dart';
import 'package:badal_exchange_customer/screens/security/verification_screen.dart';
import 'package:badal_exchange_customer/services/app_lock.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bio implements DeviceBiometrics {
  bool available = true;
  bool matches = true;
  int prompts = 0;
  String? lastReason;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    lastReason = reason;
    return matches;
  }
}

class _Api extends CustomerApi {
  _Api() : super(ApiClient());
  final checked = <String>[];
  String password = 'my-password-1';

  @override
  Future<void> verifyPassword({required String phone, required String password}) async {
    checked.add(password);
    if (password != this.password) {
      throw const ApiException(status: 400, code: 'INVALID_LOGIN', message: 'Lambarka ama erayga sirta waa khalad');
    }
  }
}

class _Auth extends AuthProvider {
  _Auth(CustomerApi api, {this.signedIn = true}) : super(apiClient: ApiClient(), customerApi: api);
  bool signedIn;
  String? loggedOutWith;

  @override
  bool get isAuthenticated => signedIn;

  @override
  AuthUser? get user => const AuthUser(phone: '252610000001', name: 'Cali Xasan');

  @override
  Future<void> logoutToLogin(String message) async {
    loggedOutWith = message;
    signedIn = false;
    notifyListeners();
  }
}

DateTime _clock = DateTime(2026, 11, 4, 9);

AppLock _lock(_Bio bio) => AppLock(storage: const FlutterSecureStorage(), biometrics: bio, now: () => _clock);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(Key('pin-key-$d')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

const _pin = '482913';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    _clock = DateTime(2026, 11, 4, 9);
    AppLanguage.current.value = AppLanguage.english;
  });

  group('the PIN', () {
    test('6 digits, not repeated and not a run', () {
      expect(AppLock.isStrongPin(_pin), isTrue);
      for (final weak in ['111111', '123456', '654321', '12345', '1234567', 'abcdef', '']) {
        expect(AppLock.isStrongPin(weak), isFalse, reason: weak);
      }
    });

    test('is kept hashed and salted on the phone, and survives a restart locked', () async {
      final lock = _lock(_Bio());
      await lock.load();
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      await lock.setPin(_pin, biometric: false);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isFalse, reason: 'not locked right after choosing it');

      const storage = FlutterSecureStorage();
      final stored = await storage.read(key: 'applock_pin');
      expect(stored, isNotNull);
      expect(stored!.contains(_pin), isFalse, reason: 'the PIN itself is never stored');
      final all = (await storage.readAll()).values.join(' ');
      expect(all.contains(_pin), isFalse);

      final restarted = _lock(_Bio());
      await restarted.load();
      expect(restarted.enabled, isTrue);
      expect(restarted.locked, isTrue, reason: 'the app starts locked');
      expect((await restarted.checkPin(_pin)).result, PinCheck.ok);
      expect((await restarted.checkPin('135790')).result, PinCheck.wrong);
    });

    test('two PINs set one after the other get different salts', () async {
      final lock = _lock(_Bio());
      await lock.setPin(_pin);
      final first = await const FlutterSecureStorage().read(key: 'applock_pin');
      await lock.setPin(_pin);
      final second = await const FlutterSecureStorage().read(key: 'applock_pin');
      expect(first, isNot(second));
    });

    test('wrong tries: free for four, then a growing wait, and ten sign the customer out', () async {
      final lock = _lock(_Bio());
      await lock.setPin(_pin);
      for (var i = 0; i < 4; i++) {
        final r = await lock.checkPin('135790');
        expect(r.result, PinCheck.wrong);
        expect(r.wait, Duration.zero);
      }
      final fifth = await lock.checkPin('135790');
      expect(fifth.result, PinCheck.wrong);
      expect(fifth.wait, const Duration(seconds: 30));
      // Waiting: even the right PIN is not looked at.
      final waiting = await lock.checkPin(_pin);
      expect(waiting.result, PinCheck.waiting);
      expect(waiting.wait.inSeconds, inInclusiveRange(29, 30));

      _clock = _clock.add(const Duration(seconds: 31));
      final sixth = await lock.checkPin('135790');
      expect(sixth.wait, const Duration(seconds: 60));

      // The count is kept on the phone: a restart does not reset it.
      final restarted = _lock(_Bio());
      await restarted.load();
      _clock = _clock.add(const Duration(minutes: 20));
      for (var i = 0; i < 3; i++) {
        await restarted.checkPin('135790');
        _clock = _clock.add(const Duration(minutes: 20));
      }
      expect((await restarted.checkPin('135790')).result, PinCheck.tooMany);
    });

    test('a right PIN clears the count', () async {
      final lock = _lock(_Bio());
      await lock.setPin(_pin);
      for (var i = 0; i < 3; i++) {
        await lock.checkPin('135790');
      }
      expect((await lock.checkPin(_pin)).result, PinCheck.ok);
      for (var i = 0; i < 4; i++) {
        expect((await lock.checkPin('135790')).wait, Duration.zero);
      }
    });

    test('turning it off (or logging out) forgets everything', () async {
      final lock = _lock(_Bio());
      await lock.setPin(_pin, biometric: true);
      await lock.disable();
      expect(lock.enabled, isFalse);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      final restarted = _lock(_Bio());
      await restarted.load();
      expect(restarted.locked, isFalse);
    });
  });

  group('locking the app', () {
    test('locks after a minute away, not after a few seconds, and not for the fingerprint prompt', () async {
      final bio = _Bio();
      final lock = _lock(bio);
      await lock.setPin(_pin, biometric: true);

      lock.appPaused();
      _clock = _clock.add(const Duration(seconds: 20));
      lock.appResumed();
      expect(lock.locked, isFalse);

      lock.appPaused();
      _clock = _clock.add(AppLock.lockAfter);
      lock.appResumed();
      expect(lock.locked, isTrue);

      lock.unlock();
      expect(lock.locked, isFalse);
      // The system prompt sends the app to the background for a moment.
      final prompt = lock.authenticateBiometric('why');
      lock.appPaused();
      await prompt;
      _clock = _clock.add(const Duration(minutes: 5));
      lock.appResumed();
      expect(lock.locked, isFalse);
    });

    test('nothing happens when verification is off', () async {
      final lock = _lock(_Bio());
      lock.appPaused();
      _clock = _clock.add(const Duration(hours: 1));
      lock.appResumed();
      expect(lock.locked, isFalse);
    });
  });

  group('the verification screen', () {
    Future<(AppLock, _Bio, _Api, List<String>)> open(WidgetTester tester, {bool fingerprint = false, bool bioMatches = true}) async {
      _phone(tester);
      final bio = _Bio()..matches = bioMatches;
      final lock = _lock(bio);
      await lock.setPin(_pin, biometric: fingerprint);
      final api = _Api();
      final events = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.current,
        home: VerificationScreen(
          lock: lock,
          name: 'Cali Xasan',
          onVerified: () => events.add('verified'),
          onTooManyAttempts: () => events.add('too many'),
          verifyPassword: (p) => api.verifyPassword(phone: '252610000001', password: p),
        ),
      ));
      await tester.pump();
      return (lock, bio, api, events);
    }

    testWidgets('the right PIN verifies; a wrong one says so and clears the dots', (tester) async {
      final (_, __, ___, events) = await open(tester);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Cali Xasan'), findsOneWidget);
      await _type(tester, '135790');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin-error')), findsOneWidget);
      expect(find.text(AppStrings.wrongPin), findsOneWidget);
      expect(events, isEmpty);
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(events, ['verified']);
    });

    testWidgets('the fingerprint is asked for on opening; a match verifies', (tester) async {
      final (_, bio, __, events) = await open(tester, fingerprint: true);
      await tester.pumpAndSettle();
      expect(bio.prompts, 1);
      expect(bio.lastReason, AppStrings.fingerprintReason);
      expect(events, ['verified']);
    });

    testWidgets('a fingerprint that does not match falls back to the PIN', (tester) async {
      final (_, bio, __, events) = await open(tester, fingerprint: true, bioMatches: false);
      await tester.pumpAndSettle();
      expect(events, isEmpty);
      expect(find.text(AppStrings.fingerprintFailed), findsOneWidget);
      expect(find.byKey(const Key('use-fingerprint')), findsOneWidget, reason: 'it can be tried again');
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(events, ['verified']);
      expect(bio.prompts, 1);
    });

    testWidgets('no fingerprint key when the customer did not turn it on', (tester) async {
      final (_, bio, __, ___) = await open(tester);
      expect(find.byKey(const Key('use-fingerprint')), findsNothing);
      expect(bio.prompts, 0);
    });

    testWidgets('the account password is the other way in; a wrong one says so', (tester) async {
      final (_, __, api, events) = await open(tester);
      await tester.tap(find.byKey(const Key('switch-method')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin-dots')), findsNothing);
      await tester.enterText(find.byKey(const Key('verify-password-field')), 'wrong-one');
      await tester.tap(find.byKey(const Key('verify-password')));
      await tester.pumpAndSettle();
      expect(find.text('Lambarka ama erayga sirta waa khalad'), findsOneWidget);
      expect(events, isEmpty);
      await tester.enterText(find.byKey(const Key('verify-password-field')), 'my-password-1');
      await tester.tap(find.byKey(const Key('verify-password')));
      await tester.pumpAndSettle();
      expect(api.checked, ['wrong-one', 'my-password-1']);
      expect(events, ['verified']);
      // And back to the PIN.
    });

    testWidgets('five wrong PINs start a wait that holds the keys', (tester) async {
      final (_, __, ___, events) = await open(tester);
      for (var i = 0; i < 5; i++) {
        await _type(tester, '135790');
        await tester.pumpAndSettle(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Too many wrong tries'), findsOneWidget);
      // The right PIN is not even looked at while waiting.
      await _type(tester, _pin);
      expect(events, isEmpty);
      // Take the screen down (the one-second timer stops with it).
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('fits a 320x568 phone', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final lock = _lock(_Bio());
      await lock.setPin(_pin, biometric: true);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.current,
        home: VerificationScreen(lock: lock, onVerified: () {}, verifyPassword: (_) async {}),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('switch-method')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('choosing a PIN', () {
    Future<List<String?>> run(WidgetTester tester, Future<void> Function() steps) async {
      _phone(tester);
      final result = <String?>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.current,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open'),
              onPressed: () async => result.add(await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinSetupScreen()))),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await steps();
      return result;
    }

    testWidgets('typed twice, then handed back', (tester) async {
      final result = await run(tester, () async {
        expect(find.text(AppStrings.createPinHelp), findsOneWidget);
        await _type(tester, _pin);
        expect(find.text(AppStrings.confirmPinHelp), findsOneWidget);
        await _type(tester, _pin);
      });
      expect(result, [_pin]);
    });

    testWidgets('a weak PIN is refused; PINs that differ start again', (tester) async {
      final result = await run(tester, () async {
        await _type(tester, '123456');
        expect(find.text(AppStrings.weakPin), findsOneWidget);
        await _type(tester, _pin);
        await _type(tester, '135790');
        expect(find.text(AppStrings.pinsDontMatch), findsOneWidget);
        expect(find.text(AppStrings.createPinHelp), findsOneWidget);
      });
      expect(result, isEmpty);
    });

    testWidgets('closing it chooses nothing', (tester) async {
      final result = await run(tester, () async {
        await tester.tap(find.byKey(const Key('pin-setup-close')));
        await tester.pumpAndSettle();
      });
      expect(result, [null]);
    });
  });

  group('the lock over the app', () {
    Future<(AppLock, _Auth)> app(WidgetTester tester, {bool signedIn = true}) async {
      _phone(tester);
      final bio = _Bio();
      final lock = _lock(bio);
      await lock.setPin(_pin, biometric: false);
      lock.lock();
      final api = _Api();
      final auth = _Auth(api, signedIn: signedIn);
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<CustomerApi>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          theme: AppTheme.current,
          builder: (context, child) => AppLockGate(lock: lock, child: child!),
          home: const Scaffold(body: Center(child: Text('the app', key: Key('the-app')))),
        ),
      ));
      await tester.pump();
      return (lock, auth);
    }

    testWidgets('covers the app until the PIN is entered', (tester) async {
      final (lock, _) = await app(tester);
      expect(find.byKey(const Key('verification-screen')), findsOneWidget);
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('verification-screen')), findsNothing);
      expect(find.byKey(const Key('the-app')), findsOneWidget);
      expect(lock.locked, isFalse);
    });

    testWidgets('does not show for a signed-out customer (the login screen is not locked)', (tester) async {
      await app(tester, signedIn: false);
      expect(find.byKey(const Key('verification-screen')), findsNothing);
    });

    testWidgets('the password also opens it', (tester) async {
      final (lock, _) = await app(tester);
      await tester.tap(find.byKey(const Key('switch-method')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('verify-password-field')), 'my-password-1');
      await tester.tap(find.byKey(const Key('verify-password')));
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse);
      expect(find.byKey(const Key('verification-screen')), findsNothing);
    });

    testWidgets('ten wrong PINs sign the customer out to the login screen', (tester) async {
      final (lock, auth) = await app(tester);
      // Nine wrong tries are on record already (the waits are over).
      for (var i = 0; i < 9; i++) {
        await lock.checkPin('135790');
        _clock = _clock.add(const Duration(minutes: 20));
      }
      await _type(tester, '135790');
      await tester.pumpAndSettle();
      expect(auth.loggedOutWith, AppStrings.tooManyPins);
    });
  });

  group('Profile > Verification lock', () {
    Future<(AppLock, _Bio)> page(WidgetTester tester, {bool fingerprint = true}) async {
      _phone(tester);
      final bio = _Bio()..available = fingerprint;
      final lock = _lock(bio);
      final api = _Api();
      final auth = _Auth(api);
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<CustomerApi>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(theme: AppTheme.current, home: VerificationSettingsScreen(lock: lock)),
      ));
      await tester.pumpAndSettle();
      return (lock, bio);
    }

    testWidgets('off by default; the privacy note says the fingerprint never leaves the phone', (tester) async {
      final (lock, _) = await page(tester);
      expect(lock.enabled, isFalse);
      expect(tester.widget<Switch>(find.byKey(const Key('lock-switch'))).value, isFalse);
      expect(find.byKey(const Key('fingerprint-switch')), findsNothing);
      expect(find.text(AppStrings.fingerprintPrivacy), findsOneWidget);
    });

    testWidgets('turning it on: choose a PIN, then the fingerprint', (tester) async {
      final (lock, bio) = await page(tester);
      await tester.tap(find.byKey(const Key('lock-switch')));
      await tester.pumpAndSettle();
      await _type(tester, _pin);
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.useFingerprintToo), findsOneWidget);
      await tester.tap(find.byKey(const Key('fingerprint-yes')));
      await tester.pumpAndSettle();
      expect(bio.prompts, 1);
      expect(lock.enabled, isTrue);
      expect(lock.biometricEnabled, isTrue);
      expect(lock.locked, isFalse, reason: 'choosing a PIN does not lock the customer out');
      expect(tester.widget<Switch>(find.byKey(const Key('lock-switch'))).value, isTrue);
    });

    testWidgets('a phone without a fingerprint is not asked about one', (tester) async {
      final (lock, bio) = await page(tester, fingerprint: false);
      await tester.tap(find.byKey(const Key('lock-switch')));
      await tester.pumpAndSettle();
      await _type(tester, _pin);
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.useFingerprintToo), findsNothing);
      expect(lock.enabled, isTrue);
      expect(lock.biometricEnabled, isFalse);
      expect(bio.prompts, 0);
      expect(tester.widget<Switch>(find.byKey(const Key('fingerprint-switch'))).onChanged, isNull);
      expect(find.text(AppStrings.noFingerprintSet), findsOneWidget);
    });

    testWidgets('turning it off needs the PIN', (tester) async {
      final (lock, _) = await page(tester);
      await lock.setPin(_pin, biometric: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lock-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('verification-screen')), findsOneWidget);
      expect(lock.enabled, isTrue);
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(lock.enabled, isFalse);
    });

    testWidgets('changing the PIN needs the old one first', (tester) async {
      final (lock, _) = await page(tester);
      await lock.setPin(_pin, biometric: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('change-pin')));
      await tester.pumpAndSettle();
      await _type(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin-setup-screen')), findsOneWidget);
      await _type(tester, '135790');
      await _type(tester, '135790');
      await tester.pumpAndSettle();
      expect((await lock.checkPin('135790')).result, PinCheck.ok);
      expect((await lock.checkPin(_pin)).result, PinCheck.wrong);
    });
  });
}
