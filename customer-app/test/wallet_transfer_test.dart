import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/models/wallet_transfer.dart';
import 'package:badal_exchange_customer/screens/wallet/wallet_transfer_screen.dart';
import 'package:badal_exchange_customer/state/wallet_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:badal_exchange_customer/widgets/primary_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends CustomerApi {
  _FakeApi({this.hasPin = true}) : super(ApiClient());

  bool hasPin;
  String balance = '100.00';
  final lookups = <String>[];
  final sends = <Map<String, String>>[];
  final pinsSet = <String>[];
  int wrongPinsLeft = 0; // answer WRONG_PIN this many times, then work
  bool lock = false;
  bool wrongPassword = false;
  final history = <WalletTransfer>[];

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Wallet> getWallet() async => Wallet(
      availableBalance: balance, pendingBalance: '0.00', totalDeposit: '0.00', totalWithdraw: '0.00', walletId: 'BE295683');

  @override
  Future<WalletPinStatus> getWalletPinStatus() async => WalletPinStatus(hasPin: hasPin);

  @override
  Future<bool> setWalletPin({required String pin, required String password}) async {
    if (wrongPassword) return false;
    pinsSet.add(pin);
    hasPin = true;
    return true;
  }

  @override
  Future<TransferRecipient> lookupTransferRecipient(String walletId) async {
    lookups.add(walletId);
    if (walletId == 'BE295683') return TransferRecipient(found: true, self: true, walletId: walletId);
    if (walletId == 'BE000000') return const TransferRecipient(found: false);
    if (walletId == 'BE999999') throw const ApiException(status: 429, code: 'TOO_MANY_ATTEMPTS', message: 'Isku-day badan');
    return TransferRecipient(found: true, walletId: walletId, name: 'Bilan Receiver');
  }

  @override
  Future<TransferOutcome> sendWalletTransfer({
    required String toWallet,
    required String amount,
    required String pin,
    required String idempotencyKey,
  }) async {
    sends.add({'to': toWallet, 'amount': amount, 'pin': pin, 'key': idempotencyKey});
    if (lock) return const TransferOutcome(ok: false, code: 'PIN_LOCKED');
    if (wrongPinsLeft > 0) {
      wrongPinsLeft--;
      return TransferOutcome(ok: false, code: 'WRONG_PIN', attemptsLeft: wrongPinsLeft + 2);
    }
    final t = WalletTransfer(
        id: 't${sends.length}', reference: 'TRF12345678', direction: 'sent', amount: amount, fee: '0.00',
        counterpartName: 'Bilan Receiver', counterpartWalletId: toWallet, balanceAfter: '74.50', createdAt: DateTime(2026, 11, 11, 9, 30));
    history.insert(0, t);
    balance = '74.50';
    return TransferOutcome(ok: true, transfer: t);
  }

  @override
  Future<List<WalletTransfer>> getWalletTransfers() async => List.of(history);
}

Widget _app(_FakeApi api) => MultiProvider(
      providers: [
        Provider<CustomerApi>.value(value: api),
        ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: api)..load()),
      ],
      child: MaterialApp(theme: AppTheme.current, home: const WalletTransferScreen()),
    );

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(api));
  await tester.pumpAndSettle();
}

Future<void> _verify(WidgetTester tester, String id) async {
  await tester.enterText(find.byKey(const Key('transfer-wallet-id')), id);
  await tester.pump();
  await tester.tap(find.byKey(const Key('transfer-verify')));
  await tester.pumpAndSettle();
}

Future<void> _pin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin-key-$d')));
    await tester.pump();
  }
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('send: Wallet ID, name, amount, PIN, confirm', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    expect(find.byKey(const Key('transfer-amount')), findsNothing, reason: 'the amount comes after the name is checked');
    expect(tester.widget<FilledButton>(find.byKey(const Key('transfer-verify'))).onPressed, isNull, reason: 'not a Wallet ID yet');
    await _verify(tester, 'be592850');
    expect(api.lookups, ['BE592850']);
    expect(tester.widget<Text>(find.byKey(const Key('transfer-recipient-name'))).data, 'Bilan Receiver');
    expect(find.text(AppStrings.transferFree), findsOneWidget);
    await tester.enterText(find.byKey(const Key('transfer-amount')), '25.5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-transfer-sheet')), findsOneWidget);
    expect(find.byKey(const Key('confirm-amount')), findsOneWidget);
    expect(find.text('Bilan Receiver · BE592850'), findsOneWidget);
    expect(find.text(AppStrings.transferFree), findsWidgets);
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-confirm'))).onPressed, isNull,
        reason: 'no PIN yet');
    await _pin(tester, '4827');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    expect(api.sends, hasLength(1));
    expect(api.sends.single['to'], 'BE592850');
    expect(api.sends.single['amount'], '25.5');
    expect(api.sends.single['pin'], '4827');
    expect(find.byKey(const Key('confirm-transfer-sheet')), findsNothing);
    expect(find.byKey(const Key('transfer-done')), findsOneWidget);
    expect(find.text('TRF12345678'), findsNothing, reason: 'shown as "Reference: TRF…"');
    expect(find.textContaining('TRF12345678'), findsWidgets);
    expect(tester.widget<Text>(find.byKey(const Key('transfer-balance'))).data, '\$74.50', reason: 'the balance is reloaded at once');
    expect(find.byKey(const Key('transfer-t1')), findsOneWidget, reason: 'it is in the history');
    expect(find.byKey(const Key('transfer-recipient')), findsNothing, reason: 'the form starts again');
  });

  testWidgets('unknown, own and rate-limited Wallet IDs say so; nothing can be sent', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await _verify(tester, 'BE000000');
    expect(find.text(AppStrings.recipientNotFound), findsOneWidget);
    expect(find.byKey(const Key('transfer-amount')), findsNothing);
    await _verify(tester, 'BE295683');
    expect(find.text(AppStrings.ownWalletId), findsOneWidget);
    await _verify(tester, 'BE999999');
    expect(find.text('Isku-day badan'), findsOneWidget);
    expect(find.byKey(const Key('transfer-send')), findsNothing);
    // editing the ID forgets a verified name
    await _verify(tester, 'BE111111');
    expect(find.byKey(const Key('transfer-recipient')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('transfer-wallet-id')), 'BE11111');
    await tester.pump();
    expect(find.byKey(const Key('transfer-recipient')), findsNothing);
  });

  testWidgets('more than the balance can not be sent; a bad amount neither', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await _verify(tester, 'BE592850');
    await tester.enterText(find.byKey(const Key('transfer-amount')), '100.01');
    await tester.pump();
    expect(find.byKey(const Key('transfer-too-much')), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-send'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('transfer-amount')), '0');
    await tester.pump();
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-send'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('transfer-amount')), '100');
    await tester.pump();
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-send'))).onPressed, isNotNull);
    expect(api.sends, isEmpty);
  });

  testWidgets('a wrong PIN says how many tries are left and clears the PIN; a locked PIN says so and sends nothing more', (tester) async {
    final api = _FakeApi()..wrongPinsLeft = 1;
    await _pump(tester, api);
    await _verify(tester, 'BE592850');
    await tester.enterText(find.byKey(const Key('transfer-amount')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer-send')));
    await tester.pumpAndSettle();
    await _pin(tester, '1111');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.wrongWalletPin(2)), findsOneWidget);
    expect(find.byKey(const Key('transfer-done')), findsNothing);
    // the PIN was cleared: the button is off again
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-confirm'))).onPressed, isNull);
    api.lock = true;
    await _pin(tester, '2222');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.walletPinLocked), findsOneWidget);
    final before = api.sends.length;
    await _pin(tester, '3333');
    await tester.pump();
    expect(tester.widget<PrimaryButton>(find.byKey(const Key('transfer-confirm'))).onPressed, isNull, reason: 'locked');
    expect(api.sends.length, before);
  });

  testWidgets('a retry reuses the same key (never sends twice); a new transfer after success gets a new key', (tester) async {
    final api = _FakeApi()..wrongPinsLeft = 1;
    await _pump(tester, api);
    await _verify(tester, 'BE592850');
    await tester.enterText(find.byKey(const Key('transfer-amount')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer-send')));
    await tester.pumpAndSettle();
    await _pin(tester, '1111');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    await _pin(tester, '4827');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    expect(api.sends, hasLength(2));
    expect(api.sends[0]['key'], api.sends[1]['key']);
    await _verify(tester, 'BE592850');
    await tester.enterText(find.byKey(const Key('transfer-amount')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer-send')));
    await tester.pumpAndSettle();
    await _pin(tester, '4827');
    await tester.tap(find.byKey(const Key('transfer-confirm')));
    await tester.pumpAndSettle();
    expect(api.sends, hasLength(3));
    expect(api.sends[2]['key'], isNot(api.sends[0]['key']));
  });

  testWidgets('first time: the Wallet PIN is created (4 digits twice, with the password) before the first transfer', (tester) async {
    final api = _FakeApi(hasPin: false);
    await _pump(tester, api);
    await _verify(tester, 'BE592850');
    await tester.enterText(find.byKey(const Key('transfer-amount')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-pin-sheet')), findsOneWidget);
    expect(api.sends, isEmpty);
    await tester.enterText(find.byKey(const Key('new-pin')), '4827');
    await tester.enterText(find.byKey(const Key('new-pin-again')), '4828');
    await tester.enterText(find.byKey(const Key('new-pin-password')), 'ChangeMe123!');
    await tester.tap(find.byKey(const Key('save-pin')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.pinsDoNotMatch), findsOneWidget);
    expect(api.pinsSet, isEmpty);
    api.wrongPassword = true;
    await tester.enterText(find.byKey(const Key('new-pin-again')), '4827');
    await tester.tap(find.byKey(const Key('save-pin')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.wrongPassword), findsOneWidget);
    api.wrongPassword = false;
    await tester.tap(find.byKey(const Key('save-pin')));
    await tester.pumpAndSettle();
    expect(api.pinsSet, ['4827']);
    expect(find.byKey(const Key('confirm-transfer-sheet')), findsOneWidget, reason: 'then straight on to the confirmation');
  });

  testWidgets('Somali', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    final api = _FakeApi();
    await _pump(tester, api);
    await _verify(tester, 'BE592850');
    expect(find.text('Bilaash 100% · khidmad \$0.00'), findsOneWidget);
    expect(find.text(AppStrings.noTransfers), findsOneWidget);
  });
}
