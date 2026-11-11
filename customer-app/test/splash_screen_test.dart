import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/screens/splash_screen.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:badal_exchange_customer/widgets/brand/baari_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Api extends CustomerApi {
  _Api() : super(ApiClient());

  @override
  Future<void> loadMethodCatalog() async {}
}

class _Auth extends AuthProvider {
  _Auth(CustomerApi api, {this.ready = true}) : super(apiClient: ApiClient(), customerApi: api);

  bool ready;

  @override
  bool get initializing => !ready;

  void finish() {
    ready = true;
    notifyListeners();
  }
}

Future<_Auth> _open(WidgetTester tester, {bool ready = true}) async {
  final api = _Api();
  final auth = _Auth(api, ready: ready);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
    ],
    child: MaterialApp(theme: AppTheme.current, home: SplashScreen(destination: (_) => const Text('HOME'))),
  ));
  return auth;
}

void main() {
  setUp(() => SplashScreen.played = false);

  testWidgets('the logo animation lasts exactly 3 seconds, then the app goes on', (tester) async {
    await _open(tester);
    expect(find.byType(BaariLogoMark), findsOneWidget);
    expect(SplashScreen.duration, const Duration(seconds: 3));

    await tester.pump(const Duration(milliseconds: 1000)); // fade and zoom in done
    expect(find.byType(BaariLogoMark), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000)); // glows and the turning light
    expect(find.byType(BaariLogoMark), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 990)); // 2.99 s: still the animation
    expect(find.text('HOME'), findsNothing);
    expect(find.byType(BaariLogoMark), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 20)); // 3.01 s: on to the app
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('HOME'), findsOneWidget);
    expect(find.byType(BaariLogoMark), findsNothing);
  });

  testWidgets('the logo fades in during the first second and out in the last', (tester) async {
    await _open(tester);
    double opacity() => tester.widget<Opacity>(find.ancestor(of: find.byType(BaariLogoMark), matching: find.byType(Opacity)).first).opacity;
    expect(opacity(), lessThan(0.1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacity(), inExclusiveRange(0.3, 1.0));
    await tester.pump(const Duration(milliseconds: 1000)); // 1.5 s: fully shown
    expect(opacity(), 1.0);
    await tester.pump(const Duration(milliseconds: 1000)); // 2.5 s: fading out
    expect(opacity(), inExclusiveRange(0.0, 1.0));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('it waits for the session to be restored, then goes on', (tester) async {
    final auth = await _open(tester, ready: false);
    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('HOME'), findsNothing, reason: 'the session is not known yet');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    auth.finish();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('shown once per launch: when the screen is built again it goes straight on', (tester) async {
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('HOME'), findsOneWidget);
    expect(SplashScreen.played, isTrue);

    // e.g. the language is changed and the app rebuilds its first screen.
    await tester.pumpWidget(const SizedBox());
    final before = DateTime.now();
    await _open(tester);
    await tester.pumpAndSettle(); // goes on after the first frame: nothing here takes 3 seconds
    expect(find.text('HOME'), findsOneWidget, reason: 'no second 3-second animation');
    expect(find.byType(BaariLogoMark), findsNothing);
    expect(DateTime.now().difference(before), lessThan(const Duration(seconds: 3)));
  });
}
