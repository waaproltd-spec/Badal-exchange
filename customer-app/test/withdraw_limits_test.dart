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
  testWidgets('the withdraw screen no longer shows the limits card (the Profile does)', (tester) async {
    await _open(tester, _Api(_limits(dailyUsed: '20.00', monthlyUsed: '120.00')));
    expect(find.byKey(const Key('withdraw-limits-card')), findsNothing);
    expect(find.byKey(const Key('kyc-prompt')), findsNothing);
    expect(find.byKey(const Key('complete-kyc')), findsNothing);
    expect(find.byKey(const Key('withdraw-continue')), findsOneWidget);
  });

  testWidgets('limit reached: Continue makes no request and says so in Somali', (tester) async {
    final api = _Api(_limits(dailyUsed: '50.00', warning: 'daily_reached'));
    await _open(tester, api);
    await tester.enterText(find.byType(TextFormField).last, '5');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    await tester.pump();
    expect(api.quotes, 0);
    expect(find.textContaining('xadka maanta'), findsOneWidget);
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
    expect(find.textContaining('\$30.00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('withdraw-all')));
    await tester.pump();
    expect(tester.widget<TextFormField>(amount).controller!.text, '30.00');
  });

  testWidgets('limits that cannot be read change nothing: the form works as before', (tester) async {
    await _open(tester, _Api(null));
    await tester.tap(find.byKey(const Key('withdraw-all')));
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byType(TextFormField).last).controller!.text, '900.00');
  });
}
