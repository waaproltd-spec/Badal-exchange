import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/withdraw_limits.dart';
import 'package:badal_exchange_customer/screens/profile/profile_screen.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

WithdrawLimits _limits({bool verified = false, String status = 'not_submitted', String dUsed = '32.50', String mUsed = '120.00'}) {
  final dl = verified ? 500.0 : 50.0;
  final ml = verified ? 5000.0 : 500.0;
  final du = double.parse(dUsed);
  final mu = double.parse(mUsed);
  return WithdrawLimits.fromJson({
    'enabled': true,
    'kyc': {'status': status, 'verified': verified},
    'daily': {'limit': dl.toStringAsFixed(2), 'used': dUsed, 'remaining': (dl - du).toStringAsFixed(2)},
    'monthly': {'limit': ml.toStringAsFixed(2), 'used': mUsed, 'remaining': (ml - mu).toStringAsFixed(2)},
    'availableNow': (dl - du).toStringAsFixed(2),
    'canWithdraw': true,
    'askKyc': !verified && status != 'pending_review',
    'ifVerified': {'daily': '500.00', 'monthly': '5000.00'},
  });
}

class _Api extends CustomerApi {
  _Api() : super(ApiClient());
  WithdrawLimits? limits = _limits();
  int loads = 0;

  @override
  Future<WithdrawLimits?> getWithdrawLimits() async {
    loads++;
    return limits;
  }
}

Future<_Api> _open(WidgetTester tester, {Size size = const Size(360, 720)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  AppLanguage.current.value = AppLanguage.english;
  final api = _Api();
  final auth = AuthProvider(apiClient: ApiClient(), customerApi: api);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<CustomerApi>.value(value: api), ChangeNotifierProvider<AuthProvider>.value(value: auth)],
    child: MaterialApp(theme: AppTheme.current, home: const ProfileScreen()),
  ));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  testWidgets('shows KYC status, both limits with used and remaining, and the other options', (tester) async {
    await _open(tester);
    expect(find.text('Not verified'), findsWidgets);
    expect(find.text('\$50'), findsOneWidget);
    expect(find.text('\$500'), findsOneWidget);
    expect(find.text('\$32.50'), findsOneWidget);
    expect(find.text('\$17.50'), findsOneWidget);
    expect(find.text('\$120.00'), findsOneWidget);
    expect(find.text('\$380.00'), findsOneWidget);
    expect(find.text('65%'), findsOneWidget);
    expect(find.text('24%'), findsOneWidget);
    expect(find.byKey(const Key('language')), findsOneWidget);
    expect(find.byKey(const Key('theme-mode')), findsOneWidget);
    expect(find.byKey(const Key('kyc-verification')), findsOneWidget);
    expect(find.byKey(const Key('change-password')), findsOneWidget);
    expect(find.byKey(const Key('logout')), findsOneWidget);
  });

  testWidgets('everything fits one screen on a normal phone: nothing to scroll', (tester) async {
    await _open(tester);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a verified customer: verified status and the higher limits', (tester) async {
    final api = await _Api().._noop();
    api.limits = _limits(verified: true, status: 'approved', dUsed: '0.00', mUsed: '0.00');
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final auth = AuthProvider(apiClient: ApiClient(), customerApi: api);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<CustomerApi>.value(value: api), ChangeNotifierProvider<AuthProvider>.value(value: auth)],
      child: MaterialApp(theme: AppTheme.current, home: const ProfileScreen()),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('KYC verified'), findsWidgets);
    expect(find.text('\$500'), findsOneWidget);
    expect(find.text('\$5000'), findsOneWidget);
  });

  testWidgets('pending KYC still shows the unverified limits, as "in review"', (tester) async {
    final api = await _open(tester);
    api.limits = _limits(status: 'pending_review');
    ProfileScreen.refresh.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('KYC in review'), findsWidgets);
    expect(find.text('\$50'), findsOneWidget);
  });

  testWidgets('opening the Profile tab reloads the limits (what was just withdrawn shows)', (tester) async {
    final api = await _open(tester);
    expect(api.loads, 1);
    api.limits = _limits(dUsed: '40.00');
    ProfileScreen.refresh.value++;
    await tester.pump();
    await tester.pump();
    expect(api.loads, 2);
    expect(find.text('\$40.00'), findsOneWidget);
    expect(find.text('\$10.00'), findsOneWidget);
  });

  testWidgets('language and appearance can be changed; View Details opens the details', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('seg-Soomaali')));
    await tester.pump();
    expect(AppLanguage.current.value, AppLanguage.somali);
    await tester.tap(find.byKey(const Key('seg-English')));
    await tester.pump();
    expect(AppLanguage.current.value, AppLanguage.english);
    await tester.tap(find.byKey(const Key('limits-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('withdraw-limits-card')), findsOneWidget);
    expect(find.byKey(const Key('complete-kyc')), findsOneWidget);
  });
}

extension on _Api {
  void _noop() {}
}
