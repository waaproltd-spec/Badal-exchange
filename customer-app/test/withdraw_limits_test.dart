import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/quote.dart';
import 'package:badal_exchange_customer/models/withdraw_limits.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_details_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

WithdrawLimits _limits({
  bool verified = false,
  String status = 'not_submitted',
  String dailyLimit = '50.00',
  String dailyUsed = '0.00',
  String monthlyLimit = '500.00',
  String monthlyUsed = '0.00',
  String? warning,
  bool askKyc = true,
}) {
  String left(String limit, String used) => (double.parse(limit) - double.parse(used)).clamp(0, double.infinity).toStringAsFixed(2);
  final dl = left(dailyLimit, dailyUsed);
  final ml = left(monthlyLimit, monthlyUsed);
  final avail = double.parse(dl) < double.parse(ml) ? dl : ml;
  return WithdrawLimits.fromJson({
    'enabled': true,
    'kyc': {'status': status, 'verified': verified},
    'daily': {'limit': dailyLimit, 'used': dailyUsed, 'remaining': dl, 'custom': false},
    'monthly': {'limit': monthlyLimit, 'used': monthlyUsed, 'remaining': ml, 'custom': false},
    'availableNow': avail,
    'canWithdraw': double.parse(avail) > 0,
    'warning': warning,
    'askKyc': askKyc,
    'ifVerified': {'daily': '500.00', 'monthly': '5000.00'},
  });
}

class _Api extends CustomerApi {
  _Api(this.limits) : super(ApiClient());
  final WithdrawLimits? limits;
  int quotes = 0;

  @override
  Future<WithdrawLimits?> getWithdrawLimits() async => limits;

  @override
  Future<Quote> createQuote({required String direction, required String method, required String amount}) async {
    quotes++;
    throw StateError('a quote must not be asked for here');
  }
}

Future<void> _open(WidgetTester tester, _Api api, {String balance = '900.00'}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  AppLanguage.current.value = AppLanguage.english;
  await tester.pumpWidget(Provider<CustomerApi>.value(
    value: api,
    child: MaterialApp(home: WithdrawDetailsScreen(method: 'evc_plus', ownPhone: '252610338686', availableBalance: balance)),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('an unverified customer sees status, limits, what is used and left, and the KYC prompt', (tester) async {
    await _open(tester, _Api(_limits(dailyUsed: '20.00', monthlyUsed: '120.00')));
    expect(find.byKey(const Key('withdraw-limits-card')), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('\$30.00 left'), findsOneWidget);
    expect(find.text('\$380.00 left'), findsOneWidget);
    expect(find.text('\$20.00 of \$50.00 withdrawn'), findsOneWidget);
    expect(find.text('\$120.00 of \$500.00 withdrawn'), findsOneWidget);
    expect(find.byKey(const Key('kyc-prompt')), findsOneWidget);
    expect(find.byKey(const Key('complete-kyc')), findsOneWidget);
    expect(find.byKey(const Key('limit-warning')), findsNothing);
  });

  testWidgets('a verified customer: verified status, higher limits, no KYC prompt', (tester) async {
    await _open(tester, _Api(_limits(verified: true, status: 'approved', dailyLimit: '500.00', monthlyLimit: '5000.00', askKyc: false)));
    expect(find.text('KYC verified'), findsOneWidget);
    expect(find.text('\$0.00 of \$500.00 withdrawn'), findsOneWidget);
    expect(find.text('\$0.00 of \$5000.00 withdrawn'), findsOneWidget);
    expect(find.byKey(const Key('kyc-prompt')), findsNothing);
    expect(find.byKey(const Key('complete-kyc')), findsNothing);
  });

  testWidgets('near the limit: a warning; at it: withdrawal is stopped before any request', (tester) async {
    await _open(tester, _Api(_limits(dailyUsed: '42.00', warning: 'near_daily')));
    expect(find.byKey(const Key('limit-warning')), findsOneWidget);
    expect(find.textContaining('close to today'), findsOneWidget);
  });

  testWidgets('limit reached: a clear message, Continue makes no request', (tester) async {
    final api = _Api(_limits(dailyUsed: '50.00', warning: 'daily_reached'));
    await _open(tester, api);
    expect(find.textContaining('reached today'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, '5');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    await tester.pump();
    expect(api.quotes, 0);
    expect(find.textContaining('reached today'), findsNWidgets(2));
  });

  testWidgets('more than what is left is stopped; "Withdraw all" fills only what is left', (tester) async {
    final api = _Api(_limits(dailyUsed: '20.00'));
    await _open(tester, api);
    final amount = find.byType(TextFormField).last;
    await tester.enterText(amount, '40');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    await tester.pump();
    expect(api.quotes, 0);
    expect(find.textContaining('more than you can withdraw now (\$30.00)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('withdraw-all')));
    await tester.pump();
    expect(tester.widget<TextFormField>(amount).controller!.text, '30.00');
  });

  testWidgets('limits that cannot be read change nothing: the form works as before', (tester) async {
    await _open(tester, _Api(null));
    expect(find.byKey(const Key('withdraw-limits-card')), findsNothing);
    await tester.tap(find.byKey(const Key('withdraw-all')));
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byType(TextFormField).last).controller!.text, '900.00');
  });
}
