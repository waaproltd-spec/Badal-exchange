import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:badal_exchange_customer/models/player.dart';
import 'package:badal_exchange_customer/models/quote.dart';
import 'package:badal_exchange_customer/screens/deposit/deposit_details_screen.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_confirm_screen.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_details_screen.dart';
import 'package:badal_exchange_customer/widgets/payment_method_sheet.dart';
import 'package:badal_exchange_customer/widgets/primary_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// The ten methods, in the order the backend serves them.
const _catalog = [
  ('evc_plus', 'EVC Plus', 'mobile_money', '#16A34A', 'EVC'),
  ('golis', 'Golis', 'mobile_money', '#0EA5E9', 'GO'),
  ('telesom', 'ZAAD', 'mobile_money', '#EAB308', 'ZA'),
  ('edahab', 'eDahab', 'mobile_money', '#EA580C', 'eD'),
  ('onexbet', '1XBET', 'platform', '#1D4ED8', '1X'),
  ('melbet', 'MELBET', 'platform', '#CA8A04', 'MB'),
  ('winwin', 'WinWin', 'platform', '#7C3AED', 'WW'),
  ('dbbet', 'DBbet', 'platform', '#DC2626', 'DB'),
  ('betwinner', 'Betwinner', 'platform', '#15803D', 'BW'),
  ('888starz', '888STARZ', 'platform', '#7C3AED', '888'),
];

List<Map<String, dynamic>> get _catalogJson => [
      for (final (id, label, kind, color, initials) in _catalog)
        {
          'method': id, 'label': label, 'kind': kind, 'color': color, 'initials': initials,
          'minWithdraw': '0.30', 'maxWithdraw': '4000.00',
          'depositNumbers': [
            if (id == 'evc_plus') {'number': '610338686', 'label': 'Baari'},
            if (id == 'edahab') {'number': '620000001', 'label': null},
            if (id == 'golis') {'number': '0907000001', 'label': null},
          ],
          if (id == 'onexbet' || id == '888starz' || id == 'winwin') 'paymentLocation': {'city': 'Mogadishu', 'street': 'FURAHA 5'},
        },
    ];

/// Records what the screens send instead of calling the backend.
class FakeCustomerApi extends CustomerApi {
  FakeCustomerApi() : super(ApiClient());

  final submitted = <Map<String, Object?>>[];

  /// Account IDs the customer used before, per platform.
  final savedAccounts = <String, String>{'onexbet': '7841228', '888starz': '7841228', 'winwin': '7841228'};

  @override
  Future<String?> getPlatformAccount(String method) async => savedAccounts[method];

  /// Players the platforms know: ID -> name (null: the platform gives none).
  final players = <String, String?>{'1847412855': 'Yaasin Maxamed', '2222': null};

  /// The next player searches that fail, as the backend reports it.
  int failLookups = 0;
  final lookups = <String>[];

  @override
  Future<PlayerLookup> findPlayer(String method, String accountId) async {
    lookups.add('$method:$accountId');
    if (failLookups > 0) {
      failLookups--;
      throw const ApiException(status: 503, code: 'PLAYER_LOOKUP_UNAVAILABLE', message: 'Could not check the player.');
    }
    return PlayerLookup(found: players.containsKey(accountId), accountId: accountId, name: players[accountId]);
  }

  @override
  Future<List<PaymentMethodOption>> getPaymentMethods() async =>
      _catalogJson.map(PaymentMethodOption.fromJson).toList();

  @override
  Future<Quote> createQuote({required String direction, required String method, required String amount}) async =>
      Quote(
        quoteId: 'q',
        method: method,
        direction: direction,
        amount: amount,
        rate: 1,
        fee: '0.00',
        netAmount: amount,
        walletDelta: amount,
      );

  Order _order(String direction, String method, String? amount) => Order(
        id: 'o${submitted.length}',
        orderCode: 'EXTEST${submitted.length}',
        direction: direction,
        method: method,
        status: 'pending',
        statusMessage: 'Pending',
        amount: amount ?? '0.00',
        fee: '0.00',
        netAmount: amount ?? '0.00',
        amountPending: amount == null,
        createdAt: DateTime.utc(2026, 10, 21),
      );

  @override
  Future<Order> deposit({
    required String method,
    String? phoneNumber,
    String? accountId,
    required String? amount,
    required String idempotencyKey,
    String? platformCode,
  }) async {
    submitted.add({
      'kind': 'deposit', 'method': method, 'phone': phoneNumber, 'account': accountId,
      'amount': amount, 'code': platformCode, 'key': idempotencyKey,
    });
    return _order('deposit', method, amount);
  }

  @override
  Future<Order> withdraw({
    required String method,
    String? phoneNumber,
    String? accountId,
    required String amount,
    required String idempotencyKey,
  }) async {
    submitted.add({
      'kind': 'withdraw', 'method': method, 'phone': phoneNumber, 'account': accountId,
      'amount': amount, 'key': idempotencyKey,
    });
    return _order('withdraw', method, amount);
  }
}

Widget _app(FakeCustomerApi api, Widget home) => Provider<CustomerApi>.value(
      value: api,
      child: MaterialApp(home: home),
    );

/// A home screen with a button that opens the sheet and shows the result.
class _SheetHost extends StatefulWidget {
  const _SheetHost(this.direction);
  final PaymentDirection direction;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  String picked = 'none';

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('picked:$picked'),
            ElevatedButton(
              onPressed: () async {
                final option = await showPaymentMethodSheet(context, widget.direction);
                setState(() => picked = option?.info.id ?? 'closed');
              },
              child: const Text('open'),
            ),
          ]),
        ),
      );
}

Future<void> _phone(WidgetTester tester, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    applyPaymentMethodCatalog(_catalogJson);
  });

  for (final direction in PaymentDirection.values) {
    for (final size in const [Size(320, 568), Size(360, 640), Size(390, 844), Size(412, 892)]) {
      testWidgets('${direction.name} sheet on ${size.width.toInt()}x${size.height.toInt()}: all ten methods on screen, no scrolling',
          (tester) async {
        await _phone(tester, size: size);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
        await tester.pumpWidget(_app(FakeCustomerApi(), _SheetHost(direction)));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text(direction == PaymentDirection.deposit ? 'Choose a deposit method' : 'Choose a withdrawal method'),
            findsOneWidget);
        expect(find.byTooltip('Close'), findsOneWidget);

        // Three columns: cards 1, 4, 7 and 10 line up, as do 2, 5 and 8.
        final x = [for (final m in _catalog) tester.getTopLeft(find.byKey(Key('method-${m.$1}'))).dx];
        expect({x[0], x[3], x[6], x[9]}.length, 1);
        expect({x[1], x[4], x[7]}.length, 1);
        expect(x[0] < x[1] && x[1] < x[2], isTrue);

        // Every card is fully inside the grid and on screen, and nothing scrolls.
        final grid = tester.getRect(find.byKey(const Key('payment-method-grid')));
        expect(grid.bottom <= size.height, isTrue);
        for (final m in _catalog) {
          final card = tester.getRect(find.byKey(Key('method-${m.$1}')));
          expect(grid.contains(card.topLeft) && grid.contains(card.bottomRight - const Offset(1, 1)), isTrue,
              reason: '${m.$2} should be fully visible');
        }
        // Each card: the method's full logo (2.4 : 1, most of the card's
        // width) above its name.
        for (final m in _catalog) {
          final card = tester.getRect(find.byKey(Key('method-${m.$1}')));
          final logo = tester.getRect(find.byKey(Key('wide-logo-${m.$1}')));
          expect(logo.width / logo.height, closeTo(2.4, 0.05));
          expect(logo.width >= card.width * 0.7, isTrue, reason: '${m.$2} logo is ${logo.width} wide in a ${card.width} card');
          expect(card.contains(logo.topLeft) && card.contains(logo.bottomRight - const Offset(1, 1)), isTrue);
          expect(find.descendant(of: find.byKey(Key('method-${m.$1}')), matching: find.text(m.$2)), findsOneWidget);
        }
        final position = tester.state<ScrollableState>(
                find.descendant(of: find.byKey(const Key('payment-method-grid')), matching: find.byType(Scrollable)))
            .position;
        expect(position.maxScrollExtent, 0, reason: 'nothing to scroll');
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.text('picked:closed'), findsOneWidget);
      });
    }

    testWidgets('${direction.name} sheet: every method can be picked', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(FakeCustomerApi(), _SheetHost(direction)));
      for (final m in _catalog) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(Key('method-${m.$1}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('method-${m.$1}')));
        await tester.pumpAndSettle();
        expect(find.text('picked:${m.$1}'), findsOneWidget);
      }
    });
  }

  testWidgets('the sheet fits a small phone', (tester) async {
    await _phone(tester, size: const Size(320, 568));
    await tester.pumpWidget(_app(FakeCustomerApi(), const _SheetHost(PaymentDirection.deposit)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('method-evc_plus')), findsOneWidget);
  });

  testWidgets('Somali: the sheet and forms switch language', (tester) async {
    await _phone(tester);
    AppLanguage.current.value = AppLanguage.somali;
    await tester.pumpWidget(_app(FakeCustomerApi(), const _SheetHost(PaymentDirection.withdraw)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Bixin'), findsOneWidget);
    expect(find.text('Dooro habka bixinta'), findsOneWidget);
  });

  testWidgets('Somali on a small phone: withdrawal form and confirmation fit', (tester) async {
    await _phone(tester, size: const Size(320, 568));
    AppLanguage.current.value = AppLanguage.somali;
    final api = FakeCustomerApi();
    final option = (await api.getPaymentMethods()).firstWhere((o) => o.info.id == 'onexbet');
    await tester.pumpWidget(_app(api, WithdrawDetailsScreen(method: 'onexbet', option: option, availableBalance: '1.25')));
    expect(find.text('Dhammaystir Bixinta'), findsOneWidget);
    // The balance, then account and amount side by side, then the limits.
    expect(find.text('\$1.25'), findsOneWidget);
    expect(find.text('Labixida ugu yar waa \$0.30, labixida ugu badan waa \$4000.00'), findsOneWidget);
    final fieldsRow = find.byType(TextFormField);
    expect(tester.getTopLeft(fieldsRow.at(0)).dy, tester.getTopLeft(fieldsRow.at(1)).dy);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '1847412855');
    await tester.enterText(fields.at(1), '3');
    await tester.scrollUntilVisible(find.text('Sii wad'), 120, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Sii wad'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sii wad'));
    await tester.pumpAndSettle();
    expect(find.text('Xaqiiji Bixinta'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Xaqiiji'), 120, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Xaqiiji'));
    await tester.pumpAndSettle();
    expect(find.text('USD la bixiyay'), findsOneWidget);
    expect(api.submitted.single, containsPair('kind', 'withdraw'));
  });

  testWidgets('without a registered number, mobile money cannot be submitted', (tester) async {
    await _phone(tester);
    final api = FakeCustomerApi();
    final option = (await api.getPaymentMethods()).first;
    await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option)));
    await tester.enterText(find.byKey(const Key('deposit-amount')), '2');
    await tester.pump();
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('confirm-deposit'))).onPressed, isNull);

    await tester.pumpWidget(_app(api, const WithdrawDetailsScreen(method: 'evc_plus')));
    await tester.enterText(find.byType(TextFormField).last, '2');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(api.submitted, isEmpty);
  });

  testWidgets('deposit: Change reopens the sheet and switches method', (tester) async {
    await _phone(tester);
    final api = FakeCustomerApi();
    final option = (await api.getPaymentMethods()).first;
    await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option, ownPhone: '252610338686')));
    await tester.tap(find.byKey(const Key('change-method')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a deposit method'), findsOneWidget);
    await tester.tap(find.byKey(const Key('method-golis')));
    await tester.pumpAndSettle();
    expect(find.text('GOLIS'), findsOneWidget);
    expect(find.text('+252 610338686'), findsOneWidget, reason: 'the registered number carries over');
  });

  testWidgets('deposit in Somali on a small phone fits', (tester) async {
    await _phone(tester, size: const Size(320, 568));
    AppLanguage.current.value = AppLanguage.somali;
    final api = FakeCustomerApi();
    final option = (await api.getPaymentMethods()).first;
    await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option, ownPhone: '252610338686')));
    await tester.enterText(find.byKey(const Key('deposit-amount')), '2');
    await tester.pump();
    expect(find.text('Dhammaystir Dhigashada'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('LACAGTA KU DIR KOONTADAAN'), 120,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    expect(find.text('LACAGTA KU DIR KOONTADAAN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Every method opens the right form and submits the right kind of order.
  for (final m in _catalog) {
    final (id, label, kind, _, _) = m;
    final isPlatform = kind == 'platform';
    // Mobile money always uses the customer's registered number.
    final identifier = isPlatform ? '1847412855' : '252610338686';

    testWidgets('withdraw $label: ${isPlatform ? 'account ID' : 'phone'} form -> confirm -> one withdrawal', (tester) async {
      await _phone(tester);
      final api = FakeCustomerApi();
      await tester.pumpWidget(_app(api, WithdrawDetailsScreen(method: id, ownPhone: '252610338686')));
      final fields = find.byType(TextFormField);
      if (isPlatform) {
        expect(find.text('$label Account ID'.toUpperCase()), findsOneWidget);
        expect(fields, findsNWidgets(2));
      } else {
        // No phone field: the registered number is shown, not editable.
        expect(find.text('$label Phone Number'.toUpperCase()), findsNothing);
        expect(fields, findsOneWidget);
        expect(find.text('+252 610338686'), findsOneWidget);
      }
      // Validation before anything is sent.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text(isPlatform ? 'Enter your account ID' : 'Enter a valid amount'), findsOneWidget);

      if (isPlatform) await tester.enterText(fields.at(0), identifier);
      await tester.enterText(fields.last, '2.50');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm Withdrawal'), findsOneWidget);
      // Destination, amount, fee and total before confirming.
      expect(find.text(isPlatform ? identifier : '+252 610338686'), findsOneWidget);
      if (id == '888starz' || id == 'onexbet' || id == 'winwin') {
        // Found at the platform first, with the name it gave.
        expect(find.text('Player ID: Find a Player'), findsOneWidget);
        expect(find.text('Yaasin Maxamed'), findsOneWidget);
        expect(api.lookups, ['$id:$identifier']);
      } else {
        expect(find.text('Player Name'), findsNothing);
        expect(api.lookups, isEmpty);
      }
      expect(find.text('Fee'), findsOneWidget);
      expect(find.text('Total Deducted'), findsOneWidget);
      expect(find.text('\$2.50'), findsNWidgets(3)); // amount, total deducted, you receive
      await tester.tap(find.text('Confirm'));
      await tester.tap(find.text('Confirm'), warnIfMissed: false); // a double tap submits once
      await tester.pumpAndSettle();

      expect(api.submitted, hasLength(1));
      expect(api.submitted.single, containsPair('kind', 'withdraw'));
      expect(api.submitted.single, containsPair('method', id));
      expect(api.submitted.single, containsPair(isPlatform ? 'account' : 'phone', identifier));
      expect(api.submitted.single, containsPair('amount', '2.50'));
      expect(find.byKey(const Key('result-status')), findsOneWidget); // the result screen
      expect(find.text('USD Withdrawn'), findsOneWidget);
    });

    testWidgets('deposit $label: Complete Deposit form -> one deposit', (tester) async {
      await _phone(tester);
      final api = FakeCustomerApi();
      final option = (await api.getPaymentMethods()).firstWhere((o) => o.info.id == id);
      await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option, ownPhone: '252610338686')));
      expect(find.text('Complete Deposit'), findsOneWidget);
      expect(find.text(label.toUpperCase()), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      // Nothing to submit until the form is filled.
      final confirm = find.byKey(const Key('confirm-deposit'));
      expect(tester.widget<PrimaryButton>(confirm).onPressed, isNull);

      final usesCode = id == '888starz' || id == 'onexbet' || id == 'winwin';
      if (usesCode) {
        // The account ID used last time is filled in; the payment code is typed.
        await tester.pump();
        expect(find.text('$label Account ID'.toUpperCase()), findsOneWidget);
        expect(find.byType(TextFormField), findsNWidgets(2));
        expect(find.widgetWithText(TextFormField, '7841228'), findsOneWidget);
      } else if (isPlatform) {
        expect(find.text('$label Account ID'.toUpperCase()), findsOneWidget);
        await tester.enterText(find.byType(TextFormField).first, identifier);
      } else {
        // No phone field: the registered number is shown, not editable.
        expect(find.byType(TextFormField), findsOneWidget);
        expect(find.text('+252 610338686'), findsOneWidget);
      }
      if (usesCode) {
        // Cash desk: payment code, no amount (the platform's payout decides it).
        expect(find.text('Betting cashier deposit'), findsOneWidget);
        expect(find.byKey(const Key('deposit-amount')), findsNothing);
        await tester.enterText(find.byKey(const Key('payment-code')), 'ABC123');
        // Payment Location under Confirm Deposit.
        expect(find.byKey(const Key('payment-location')), findsOneWidget);
        expect(find.text('Mogadishu'), findsOneWidget);
        expect(find.text('FURAHA 5'), findsOneWidget);
      } else {
        await tester.enterText(find.byKey(const Key('deposit-amount')), '5');
      }
      await tester.pump();

      // Where to send the money: a USSD code to dial for EVC Plus / eDahab.
      final ussd = {'evc_plus': '*712*610338686*5#', 'edahab': '*110*620000001*5#'}[id];
      if (ussd != null) expect(find.text(ussd), findsOneWidget);
      if (id == 'golis') expect(find.text('0907000001'), findsOneWidget);
      if (isPlatform) expect(find.byKey(const Key('pay-to-card')), findsNothing);

      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.tap(confirm, warnIfMissed: false); // a double tap submits once
      await tester.pumpAndSettle();

      expect(api.submitted, hasLength(1));
      expect(api.submitted.single, containsPair('kind', 'deposit'));
      expect(api.submitted.single, containsPair('method', id));
      expect(api.submitted.single, containsPair(isPlatform ? 'account' : 'phone', usesCode ? '7841228' : identifier));
      expect(api.submitted.single, containsPair('amount', usesCode ? null : '5'));
      expect(api.submitted.single, containsPair('code', usesCode ? 'ABC123' : null));
      expect(find.byKey(const Key('result-status')), findsOneWidget); // the result screen
      expect(find.text('USD Deposited'), findsOneWidget);
    });
  }

  testWidgets('deposit 1XBET: the account ID is empty the first time, and can be changed', (tester) async {
    await _phone(tester);
    final api = FakeCustomerApi()..savedAccounts.clear();
    final option = (await api.getPaymentMethods()).firstWhere((o) => o.info.id == 'onexbet');
    await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option, ownPhone: '252610338686')));
    await tester.pump();
    expect(find.byKey(const Key('account-id')), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '7841228'), findsNothing);
    await tester.enterText(find.byKey(const Key('payment-code')), 'ABC123');
    await tester.pump();
    final confirm = find.byKey(const Key('confirm-deposit'));
    expect(tester.widget<PrimaryButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byType(TextFormField).first, '7841228');
    await tester.pump();
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(api.submitted.single, containsPair('account', '7841228'));
    expect(api.submitted.single, containsPair('code', 'ABC123'));
  });

  group('Confirm Withdrawal: Find a Player', () {
    Future<FakeCustomerApi> open(WidgetTester tester, String method, String account,
        {int failLookups = 0, Size size = const Size(393, 851)}) async {
      await _phone(tester, size: size);
      final api = FakeCustomerApi()..failLookups = failLookups;
      final quote = await api.createQuote(direction: 'withdraw', method: method, amount: '500');
      await tester.pumpWidget(_app(api, WithdrawConfirmScreen(quote: quote, accountId: account)));
      return api;
    }

    PrimaryButton confirmButton(WidgetTester tester) =>
        tester.widget<PrimaryButton>(find.byKey(const Key('confirm-withdrawal')));
    String nameShown(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('player-name'))).data!;

    testWidgets('a valid ID: the player\'s name above the amount, then Confirm', (tester) async {
      final api = await open(tester, '888starz', '1847412855');
      expect(nameShown(tester), 'Checking...');
      expect(confirmButton(tester).onPressed, isNull, reason: 'not before the platform answers');
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('player-id'))).data, '1847412855');
      expect(nameShown(tester), 'Yaasin Maxamed');
      expect(tester.getTopLeft(find.byKey(const Key('player-name'))).dy,
          lessThan(tester.getTopLeft(find.text('Amount (USD)')).dy));
      for (final row in ['Fee', 'Total Deducted', 'You will receive']) {
        expect(find.text(row), findsOneWidget);
      }
      expect(find.byKey(const Key('player-problem')), findsNothing);
      await tester.tap(find.byKey(const Key('confirm-withdrawal')));
      await tester.pumpAndSettle();
      expect(api.submitted.single, containsPair('account', '1847412855'));
    });

    testWidgets('no name from the platform: says so, nothing made up; Confirm allowed', (tester) async {
      final api = await open(tester, 'onexbet', '2222');
      await tester.pumpAndSettle();
      expect(nameShown(tester), 'Not provided by 1XBET');
      expect(confirmButton(tester).onPressed, isNotNull);
      expect(api.lookups, ['onexbet:2222']);
    });

    testWidgets('an unknown ID: not found, Confirm stays off', (tester) async {
      final api = await open(tester, '888starz', '9999');
      await tester.pumpAndSettle();
      expect(nameShown(tester), 'Player not found');
      expect(find.text('No 888STARZ player has the ID 9999. Go back and check the Player ID.'), findsOneWidget);
      expect(find.byKey(const Key('retry-player')), findsNothing);
      expect(confirmButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(const Key('confirm-withdrawal')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(api.submitted, isEmpty);
    });

    testWidgets('the platform failing: Confirm off until a retry finds the player', (tester) async {
      final api = await open(tester, '888starz', '1847412855', failLookups: 1);
      await tester.pumpAndSettle();
      expect(find.text('Could not check the player right now.'), findsOneWidget);
      expect(nameShown(tester), '—');
      expect(confirmButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(const Key('retry-player')));
      await tester.pumpAndSettle();
      expect(nameShown(tester), 'Yaasin Maxamed');
      expect(find.byKey(const Key('player-problem')), findsNothing);
      expect(confirmButton(tester).onPressed, isNotNull);
      expect(api.lookups, hasLength(2));
    });

    for (final somali in [false, true]) {
      testWidgets('${somali ? 'Somali' : 'English'} on a 320x568 phone: fits, not found message too', (tester) async {
        AppLanguage.current.value = somali ? AppLanguage.somali : AppLanguage.english;
        await open(tester, '888starz', '1847412855', size: const Size(320, 568));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await open(tester, '888starz', '99999999', size: const Size(320, 568));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byKey(const Key('confirm-withdrawal')), 100,
            scrollable: find.byType(Scrollable).first);
        expect(find.byKey(const Key('player-problem')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
