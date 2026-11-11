import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/bonus.dart';
import 'package:badal_exchange_customer/screens/bonus/bonus_screen.dart';
import 'package:badal_exchange_customer/theme/colors.dart';
import 'package:badal_exchange_customer/widgets/bonus_widgets.dart';
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
  bool refuse = false;

  @override
  Future<BonusInfo> getBonus() async => info;

  @override
  Future<BonusInfo> moveBonus() async {
    moves++;
    if (refuse || !info.canTransfer) throw const ApiException(status: 409, code: 'NO_BONUS', message: 'No bonus to move');
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
    expect(find.textContaining('You earn'), findsNothing, reason: 'no rate line on the card');
    expect(find.text('Bonus earned (1%)'), findsOneWidget);
    expect(find.text('On \$100.00 withdrawal'), findsOneWidget);
    expect(find.text('eDahab'), findsOneWidget, reason: 'the platform has its own chip');
    expect(find.text('+\$1.00'), findsOneWidget);
  });

  testWidgets('Transfer Bonus to Main Wallet moves it all, once', (tester) async {
    final api = _FakeApi(_info('3.00', [_earned]));
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-bonus')));
    await tester.pumpAndSettle();
    expect(api.moves, 0, reason: 'nothing moves before the customer confirms');
    expect(find.byKey(const Key('confirm-move-bonus-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-move-bonus')));
    await tester.pumpAndSettle();
    expect(api.moves, 0, reason: 'cancelled');
    await tester.tap(find.byKey(const Key('move-bonus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-move-bonus')));
    await tester.pumpAndSettle();
    expect(api.moves, 1);
    expect(find.byKey(const Key('move-bonus-done')), findsOneWidget);
    expect(find.text('\$3.00 moved to your main wallet'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
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
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('move-bonus'))).onPressed, isNull);
  });

  testWidgets('a fraction of a cent shows exactly, with its percentage; under a cent cannot be transferred', (tester) async {
    await tester.pumpWidget(_app(_FakeApi(BonusInfo.fromJson({
      'balance': '0.006',
      'transferable': '0.00',
      'rate': '2%',
      'totalEarned': '0.006',
      'entries': [
        {'kind': 'earned', 'amount': '0.006', 'rate': '2%', 'createdAt': '2026-10-28T04:42:00Z',
         'orderCode': 'EX888', 'orderAmount': '0.30', 'direction': 'withdraw', 'methodLabel': '888STARZ'},
      ],
    }))));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('bonus-balance'))).data, '\$0.006');
    expect(find.text('Bonus earned (2%)'), findsOneWidget);
    expect(find.text('On \$0.30 withdrawal'), findsOneWidget);
    expect(find.text('888STARZ'), findsOneWidget);
    expect(find.text('+\$0.006'), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('move-bonus'))).onPressed, isNull);
    expect(find.text('At least \$0.01 is needed to transfer.'), findsOneWidget);
  });

  testWidgets('a failed transfer says so; the filters show earned / transferred; colors: green earned, purple moved, red reversed; 320 px fits', (tester) async {
    final api = _FakeApi(_info('3.00', [
      _earned,
      {'kind': 'moved', 'amount': '1.00', 'createdAt': '2026-10-28T10:00:00Z'},
      {'kind': 'reversed', 'amount': '0.50', 'createdAt': '2026-10-28T11:00:00Z'},
    ]));
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Bonus History'), findsOneWidget);
    expect(find.byType(BonusEntryTile), findsNWidgets(3));
    await tester.tap(find.byKey(const Key('bonus-filter-earned')));
    await tester.pumpAndSettle();
    expect(find.byType(BonusEntryTile), findsNWidgets(2), reason: 'earned + reversed');
    await tester.tap(find.byKey(const Key('bonus-filter-moved')));
    await tester.pumpAndSettle();
    expect(find.byType(BonusEntryTile), findsNWidgets(1));
    await tester.tap(find.byKey(const Key('bonus-filter-all')));
    await tester.pumpAndSettle();
    Color colorOf(String text) => tester.widget<Text>(find.text(text)).style!.color!;
    expect(colorOf('+\$1.00'), AppColors.success);
    expect(colorOf('−\$0.50'), AppColors.error);
    expect(colorOf('−\$1.00'), const Color(0xFFB57BFF));
    // a refused transfer: the server's message in a dialog, nothing hidden
    api.refuse = true;
    await tester.tap(find.byKey(const Key('move-bonus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-move-bonus')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('move-bonus-failed')), findsOneWidget);
    expect(find.text('No bonus to move'), findsOneWidget);
  });
}
