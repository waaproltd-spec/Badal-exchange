// Light and dark, the language in Account > Settings, and the fingerprint
// unlock (with the password as the backup).
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/screens/app_lock_gate.dart';
import 'package:badal_agent_app/screens/unlock_screen.dart';
import 'package:badal_agent_app/services/app_lock.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:badal_agent_app/theme/app_theme.dart';
import 'package:badal_agent_app/theme/theme_mode.dart';
import 'package:badal_agent_app/theme/theme_scope.dart';
import 'package:badal_agent_app/widgets/app_settings_panel.dart';
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

class _Session extends Session {
  _Session() : super(api: AgentApi());
}

DateTime _clock = DateTime(2026, 11, 4, 9);
AppLock _lock(_Bio bio) => AppLock(storage: const FlutterSecureStorage(), biometrics: bio, now: () => _clock);

void _phone(WidgetTester tester, [Size size = const Size(393, 851)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    _clock = DateTime(2026, 11, 4, 9);
    AppLanguage.current.value = AppLanguage.english;
    AppThemeMode.current.value = ThemeMode.light;
  });
  tearDown(() {
    AppLanguage.current.value = AppLanguage.english;
    AppThemeMode.current.value = ThemeMode.light;
  });

  group('light and dark', () {
    test('light is a clean white design, dark is black; the brand purple stays', () {
      expect(AppColors.background, const Color(0xFFF7F5FB));
      expect(AppColors.surface, const Color(0xFFFFFFFF));
      expect(AppThemeMode.isDark, isFalse);
      expect(AppTheme.current.brightness, Brightness.light);
      AppThemeMode.current.value = ThemeMode.dark;
      expect(AppThemeMode.isDark, isTrue);
      expect(AppColors.background, const Color(0xFF0C0A10));
      expect(AppColors.surface, const Color(0xFF16131D));
      expect(AppColors.textPrimary, const Color(0xFFF3EEF8));
      expect(AppTheme.current.brightness, Brightness.dark);
      expect(AppTheme.current.scaffoldBackgroundColor, const Color(0xFF0C0A10));
      expect(AppColors.purpleDark, const Color(0xFF3A0353));
    });

    test('light, dark or the phone: kept on the phone and read back', () async {
      await AppThemeMode.set(ThemeMode.dark);
      expect((await SharedPreferences.getInstance()).getString('theme_mode'), 'dark');
      AppThemeMode.current.value = ThemeMode.light;
      await AppThemeMode.load();
      expect(AppThemeMode.current.value, ThemeMode.dark);
      await AppThemeMode.set(ThemeMode.system);
      await AppThemeMode.load();
      expect(AppThemeMode.current.value, ThemeMode.system);
    });

    testWidgets('choosing Dark repaints the open screen in place', (tester) async {
      _phone(tester);
      Color? seen;
      await tester.pumpWidget(ThemeModeScope(
        builder: (context) => MaterialApp(
          theme: AppTheme.current,
          home: Scaffold(
            backgroundColor: AppColors.background,
            body: Builder(builder: (context) {
              seen = AppColors.background;
              return const AppSettingsPanel();
            }),
          ),
        ),
      ));
      expect(seen, const Color(0xFFF7F5FB));
      await tester.tap(find.byKey(const Key('seg-Dark')));
      await tester.pumpAndSettle();
      expect(AppThemeMode.current.value, ThemeMode.dark);
      expect(seen, const Color(0xFF0C0A10));
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, const Color(0xFF0C0A10));
      await tester.tap(find.byKey(const Key('seg-Light')));
      await tester.pumpAndSettle();
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, const Color(0xFFF7F5FB));
    });
  });

  group('Account > Settings', () {
    Future<(AppLock, _Bio)> panel(WidgetTester tester, {bool fingerprint = true}) async {
      _phone(tester);
      final bio = _Bio()..available = fingerprint;
      final lock = _lock(bio);
      await tester.pumpWidget(ThemeModeScope(
        builder: (context) => MaterialApp(
          theme: AppTheme.current,
          home: Scaffold(body: SingleChildScrollView(child: AppSettingsPanel(lock: lock))),
        ),
      ));
      await tester.pumpAndSettle();
      return (lock, bio);
    }

    testWidgets('the language switch changes the texts at once and is kept', (tester) async {
      await panel(tester);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      await tester.tap(find.byKey(const Key('seg-Soomaali')));
      await tester.pumpAndSettle();
      expect(AppLanguage.current.value, AppLanguage.somali);
      expect(find.text('Luqadda'), findsOneWidget);
      expect(find.text('Muuqaalka'), findsOneWidget);
      expect(find.text('Madow'), findsOneWidget);
      expect(find.text('Furitaanka faraha'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('app_language'), 'so');
      await tester.tap(find.byKey(const Key('seg-English')));
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('fingerprint unlock: switched on after the fingerprint matched, off again', (tester) async {
      final (lock, bio) = await panel(tester);
      expect(tester.widget<Switch>(find.byKey(const Key('fingerprint-switch'))).value, isFalse);
      await tester.tap(find.byKey(const Key('fingerprint-switch')));
      await tester.pumpAndSettle();
      expect(bio.prompts, 1);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isFalse, reason: 'switching it on does not lock the agent out');
      expect(tester.widget<Switch>(find.byKey(const Key('fingerprint-switch'))).value, isTrue);
      expect((await const FlutterSecureStorage().read(key: 'agent_applock_fingerprint')), '1');
      await tester.tap(find.byKey(const Key('fingerprint-switch')));
      await tester.pumpAndSettle();
      expect(lock.enabled, isFalse);
      expect(await const FlutterSecureStorage().read(key: 'agent_applock_fingerprint'), isNull);
    });

    testWidgets('a fingerprint that does not match, or a phone without one, leaves it off', (tester) async {
      final (lock, bio) = await panel(tester);
      bio.matches = false;
      await tester.tap(find.byKey(const Key('fingerprint-switch')));
      await tester.pumpAndSettle();
      expect(lock.enabled, isFalse);
      expect(bio.prompts, 1);
    });

    testWidgets('no fingerprint on the phone: it says so and stays off', (tester) async {
      final (lock, bio) = await panel(tester, fingerprint: false);
      await tester.tap(find.byKey(const Key('fingerprint-switch')));
      await tester.pumpAndSettle();
      expect(lock.enabled, isFalse);
      expect(bio.prompts, 0);
      expect(find.text('No fingerprint is set up on this phone.'), findsOneWidget);
    });
  });

  group('the lock', () {
    test('survives a restart locked, and a minute away locks it', () async {
      final bio = _Bio();
      final lock = _lock(bio);
      await lock.load();
      expect(lock.enabled, isFalse);
      await lock.enable();
      expect(lock.locked, isFalse);
      final restarted = _lock(_Bio());
      await restarted.load();
      expect(restarted.enabled, isTrue);
      expect(restarted.locked, isTrue, reason: 'the app starts locked');

      restarted.unlock();
      restarted.appPaused();
      _clock = _clock.add(const Duration(seconds: 20));
      restarted.appResumed();
      expect(restarted.locked, isFalse);
      restarted.appPaused();
      _clock = _clock.add(AppLock.lockAfter);
      restarted.appResumed();
      expect(restarted.locked, isTrue);
    });

    test('the system fingerprint prompt does not count as being away; off means nothing locks', () async {
      final lock = _lock(_Bio());
      await lock.enable();
      final prompt = lock.authenticate('why');
      lock.appPaused();
      await prompt;
      _clock = _clock.add(const Duration(minutes: 5));
      lock.appResumed();
      expect(lock.locked, isFalse);

      await lock.disable();
      lock.appPaused();
      _clock = _clock.add(const Duration(hours: 1));
      lock.appResumed();
      expect(lock.locked, isFalse);
      expect(lock.enabled, isFalse);
    });
  });

  group('the unlock screen', () {
    Future<(_Bio, List<String>, List<String>)> open(WidgetTester tester, {bool matches = true, Size size = const Size(393, 851)}) async {
      _phone(tester, size);
      final bio = _Bio()..matches = matches;
      final lock = _lock(bio);
      await lock.enable();
      final events = <String>[];
      final checked = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.current,
        home: UnlockScreen(
          lock: lock,
          name: 'Cali Xasan',
          onVerified: () => events.add('verified'),
          verifyPassword: (p) async {
            checked.add(p);
            if (p != 'my-password-1') throw const ApiException(statusCode: 400, code: 'INVALID', message: 'Invalid credentials');
          },
        ),
      ));
      await tester.pump();
      await tester.pump();
      return (bio, events, checked);
    }

    testWidgets('the fingerprint is asked for at once; a match unlocks', (tester) async {
      final (bio, events, _) = await open(tester);
      expect(bio.prompts, 1);
      expect(bio.lastReason, 'Verify your identity to open Badal Exchange');
      expect(events, ['verified']);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Cali Xasan'), findsOneWidget);
    });

    testWidgets('a fingerprint that does not match says so; it can be tried again; the password is the backup', (tester) async {
      final (bio, events, checked) = await open(tester, matches: false);
      expect(events, isEmpty);
      expect(find.text('Fingerprint not recognized. Use your password.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('unlock-fingerprint')));
      await tester.pump();
      expect(bio.prompts, 2);

      await tester.tap(find.byKey(const Key('unlock-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unlock-fingerprint')), findsNothing);
      await tester.enterText(find.byKey(const Key('unlock-password-field')), 'wrong');
      await tester.tap(find.byKey(const Key('unlock-password-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Invalid credentials'), findsOneWidget);
      expect(events, isEmpty);
      await tester.enterText(find.byKey(const Key('unlock-password-field')), 'my-password-1');
      await tester.tap(find.byKey(const Key('unlock-password-submit')));
      await tester.pumpAndSettle();
      expect(checked, ['wrong', 'my-password-1']);
      expect(events, ['verified']);
    });

    testWidgets('the password can be shown and hidden', (tester) async {
      await open(tester, matches: false);
      await tester.tap(find.byKey(const Key('unlock-switch')));
      await tester.pumpAndSettle();
      bool obscured() => tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('unlock-password-field')), matching: find.byType(EditableText))).obscureText;
      expect(obscured(), isTrue);
      await tester.tap(find.byKey(const Key('unlock-toggle-password')));
      await tester.pump();
      expect(obscured(), isFalse);
    });

    testWidgets('Somali, dark and a small phone', (tester) async {
      AppLanguage.current.value = AppLanguage.somali;
      AppThemeMode.current.value = ThemeMode.dark;
      await open(tester, matches: false, size: const Size(320, 568));
      expect(find.text('Ku soo dhawoow mar kale'), findsOneWidget);
      expect(find.text('Faraha lama aqoonsan. Isticmaal erayga sirta.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('unlock-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Fur'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the lock over the app', () {
    Future<(AppLock, _Session)> app(WidgetTester tester, {bool signedIn = true}) async {
      _phone(tester);
      final lock = _lock(_Bio());
      await lock.enable();
      lock.lock();
      final session = _Session()..status = signedIn ? AuthStatus.loggedIn : AuthStatus.loggedOut;
      await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
        value: session,
        child: MaterialApp(
          theme: AppTheme.current,
          builder: (context, child) => AppLockGate(
            lock: lock,
            child: child!,
            passwordCheck: (s, p) async {
              if (p != 'my-password-1') throw const ApiException(statusCode: 400, code: 'INVALID', message: 'Invalid credentials');
            },
          ),
          home: const Scaffold(body: Center(child: Text('the app', key: Key('the-app')))),
        ),
      ));
      await tester.pump();
      await tester.pump();
      return (lock, session);
    }

    testWidgets('covers the app until the fingerprint matches', (tester) async {
      final (lock, _) = await app(tester);
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse, reason: 'the fingerprint matched at once');
      expect(find.byKey(const Key('unlock-screen')), findsNothing);
      expect(find.byKey(const Key('the-app')), findsOneWidget);
    });

    testWidgets('the password opens it when the fingerprint is not there', (tester) async {
      _phone(tester);
      final bio = _Bio()..matches = false;
      final lock = _lock(bio);
      await lock.enable();
      lock.lock();
      final session = _Session()..status = AuthStatus.loggedIn;
      await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
        value: session,
        child: MaterialApp(
          theme: AppTheme.current,
          builder: (context, child) => AppLockGate(lock: lock, child: child!, passwordCheck: (s, p) async {}),
          home: const Scaffold(body: Center(child: Text('the app'))),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('unlock-screen')), findsOneWidget);
      await tester.tap(find.byKey(const Key('unlock-switch')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock-password-field')), 'anything');
      await tester.tap(find.byKey(const Key('unlock-password-submit')));
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse);
      expect(find.byKey(const Key('unlock-screen')), findsNothing);
    });

    testWidgets('does not show to a signed-out agent (the login screen is not locked)', (tester) async {
      await app(tester, signedIn: false);
      expect(find.byKey(const Key('unlock-screen')), findsNothing);
    });
  });
}
