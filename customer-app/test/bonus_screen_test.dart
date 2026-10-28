import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/bonus.dart';
import 'package:badal_exchange_customer/screens/bonus/bonus_screen.dart';
import 'package:badal_exchange_customer/widgets/primary_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

BonusInfo _info(String balance, List<Map<String, dynamic>> entries, {String rate = '1%'}) => BonusInfo.fromJson({
      'balance': balance,
      'rate': rate,
      'totalEarned': '3.00',
      'entries': entries,
    });

final _earned = {
  'kind': 'earned', 'amount': '1.00', 'rate': '1%', 'createdAt': '2026-10-28T09:00:00Z',
  'orderCode': 'EX1', 'withdrawal': '100.00', 'methodLabel': 'eDahab',
};

class _FakeApi extends CustomerApi {
  _FakeApi(this.info) : super(ApiClient());

  BonusInfo info;
  int moves = 0;

  @override
  Future<BonusInfo> getBonus() async => info;

  @override
  Future<BonusInfo> moveBonus() async {
    moves++;
    if (!info.hasBalance) throw const ApiException(status: 409, code: 'NO_BONUS', message: 'No bonus to move');
    info = _info('0.00', [
      {'kind': 'moved', 'amount': info.balance, 'createdAt': '2026-10-28T10:00:00Z'},
      _earned,
    ]);
    return info;
  }
}

Widget _app(_FakeApi api) =>
    Provider<CustomerApi>.value(value: api, child: const MaterialApp(home: BonusScreen()));

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('shows the balance, the rate and the history', (tester) async {
    await tester.pumpWidget(_app(_FakeApi(_info('3.00', [_earned]))));
    await tester.pumpAndSettle();
    expect(find.text('\$3.00'), findsOneWidget);
    expect(find.textContaining('You earn 1% of every completed withdrawal'), findsOneWidget);
    expect(find.text('Bonus earned (1%)'), findsOneWidget);
    expect(find.text('On \$100.00 withdrawal • eDahab'), findsOneWidget);
    expect(find.text('+\$1.00'), findsOneWidget);
  });

  testWidgets('Transfer Bonus to Main Wallet moves it all, once', (tester) async {
    final api = _FakeApi(_info('3.00', [_earned]));
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-bonus')));
    await tester.pumpAndSettle();
    expect(api.moves, 1);
    expect(find.text('\$3.00 moved to your main wallet'), findsOneWidget);
    expect(find.byKey(const Key('bonus-balance')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('bonus-balance'))).data, '\$0.00');
    expect(find.text('Moved to main wallet'), findsOneWidget);
    // Nothing left: the button is off.
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('move-bonus'))).onPressed, isNull);
  });

  testWidgets('no bonus yet, and off for this customer', (tester) async {
    await tester.pumpWidget(_app(_FakeApi(_info('0.00', [], rate: '0%'))));
    await tester.pumpAndSettle();
    expect(find.text('No bonus yet'), findsOneWidget);
    expect(find.text('The bonus is off for your account.'), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('move-bonus'))).onPressed, isNull);
  });
}
