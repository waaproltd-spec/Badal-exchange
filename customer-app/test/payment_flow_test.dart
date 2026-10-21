import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:badal_exchange_customer/models/quote.dart';
import 'package:badal_exchange_customer/screens/deposit/deposit_details_screen.dart';
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
          'depositNumbers': [
            if (id == 'evc_plus') {'number': '610338686', 'label': 'Baari'},
            if (id == 'edahab') {'number': '620000001', 'label': null},
            if (id == 'golis') {'number': '0907000001', 'label': null},
            if (id == 'onexbet') {'number': 'WARAN CADDE 24/7', 'label': 'MOGADISHU'},
          ],
        },
    ];

/// Records what the screens send instead of calling the backend.
class FakeCustomerApi extends CustomerApi {
  FakeCustomerApi() : super(ApiClient());

  final submitted = <Map<String, Object?>>[];

  /// Account IDs the customer used before, per platform.
  final savedAccounts = <String, String>{'onexbet': '7841228', '888starz': '7841228'};

  @override
  Future<String?> getPlatformAccount(String method) async => savedAccounts[method];

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
    testWidgets('${direction.name} sheet: 3-column grid, 9 cards up front, the 10th by scrolling', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(FakeCustomerApi(), _SheetHost(direction)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(direction == PaymentDirection.deposit ? 'Choose a deposit method' : 'Choose a withdrawal method'),
          findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);

      // Three columns: cards 1, 4 and 7 line up, as do 2, 5 and 8.
      final x = [for (final m in _catalog.take(9)) tester.getTopLeft(find.byKey(Key('method-${m.$1}'))).dx];
      expect({x[0], x[3], x[6]}.length, 1);
      expect({x[1], x[4], x[7]}.length, 1);
      expect(x[0] < x[1] && x[1] < x[2], isTrue);

      // The first nine are fully on screen inside the grid.
      final grid = tester.getRect(find.byKey(const Key('payment-method-grid')));
      for (final m in _catalog.take(9)) {
        final card = tester.getRect(find.byKey(Key('method-${m.$1}')));
        expect(grid.contains(card.topLeft) && grid.contains(card.bottomRight - const Offset(1, 1)), isTrue,
            reason: '${m.$2} should be fully visible');
      }
      // The tenth is reached by scrolling, not hidden.
      await tester.dragUntilVisible(
          find.byKey(const Key('method-888starz')), find.byKey(const Key('payment-method-grid')), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(find.text('888STARZ'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('picked:closed'), findsOneWidget);
    });

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
    await tester.pumpWidget(_app(api, const WithdrawDetailsScreen(method: 'onexbet')));
    expect(find.text('Faahfaahinta bixinta'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '1847412855');
    await tester.enterText(fields.at(1), '3');
    await tester.tap(find.text('Sii wad'));
    await tester.pumpAndSettle();
    expect(find.text('Xaqiiji Bixinta'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Xaqiiji'), 120);
    await tester.tap(find.text('Xaqiiji'));
    await tester.pumpAndSettle();
    expect(find.text('Bixinta waa la gudbiyay'), findsOneWidget);
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
      expect(find.text('Withdrawal Submitted'), findsOneWidget);
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

      final usesCode = id == '888starz' || id == 'onexbet';
      if (usesCode) {
        // Payment code only: the backend reuses the saved account ID.
        await tester.pump();
        expect(find.text('$label Account ID'.toUpperCase()), findsNothing);
        expect(find.byType(TextFormField), findsOneWidget);
      } else if (isPlatform) {
        expect(find.text('$label Account ID'.toUpperCase()), findsOneWidget);
        await tester.enterText(find.byType(TextFormField).first, identifier);
      } else {
        // No phone field: the registered number is shown, not editable.
        expect(find.byType(TextFormField), findsOneWidget);
        expect(find.text('+252 610338686'), findsOneWidget);
      }
      if (usesCode) {
        // Cash desk: street + payment code, no amount (the platform's payout decides it).
        expect(find.text('Betting cashier deposit'), findsOneWidget);
        expect(find.byKey(const Key('deposit-amount')), findsNothing);
        await tester.enterText(find.byKey(const Key('payment-code')), 'ABC123');
        if (id == 'onexbet') {
          expect(find.byKey(const Key('street-card')), findsOneWidget);
          expect(find.text('MOGADISHU'), findsOneWidget);
          expect(find.text('WARAN CADDE 24/7'), findsOneWidget);
        } else {
          expect(find.byKey(const Key('street-card')), findsNothing);
        }
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
      expect(api.submitted.single, containsPair(isPlatform ? 'account' : 'phone', usesCode ? null : identifier));
      expect(api.submitted.single, containsPair('amount', usesCode ? null : '5'));
      expect(api.submitted.single, containsPair('code', usesCode ? 'ABC123' : null));
      expect(find.text('Deposit Submitted'), findsOneWidget);
    });
  }

  testWidgets('deposit 1XBET the first time: the account ID is asked for once', (tester) async {
    await _phone(tester);
    final api = FakeCustomerApi()..savedAccounts.clear();
    final option = (await api.getPaymentMethods()).firstWhere((o) => o.info.id == 'onexbet');
    await tester.pumpWidget(_app(api, DepositDetailsScreen(option: option, ownPhone: '252610338686')));
    await tester.pump();
    expect(find.byKey(const Key('first-account-id')), findsOneWidget);
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
}
