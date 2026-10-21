import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/widgets/wallet_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Wallet _wallet({String? walletId = 'BE482913', String? promo = 'RAMADAN26', String bonus = '2.50'}) => Wallet(
      availableBalance: '4.83',
      pendingBalance: '0.80',
      totalDeposit: '9.80',
      totalWithdraw: '0.00',
      bonusBalance: bonus,
      walletId: walletId,
      promoCode: promo,
    );

Widget _host(Wallet? wallet, {bool loading = false}) => MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF3A0353),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [WalletCard(wallet: wallet, loading: loading)],
        ),
      ),
    );

Future<void> _screen(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('shows the balance, promo code, Wallet ID and bonus from the wallet', (tester) async {
    await _screen(tester, const Size(390, 844));
    await tester.pumpWidget(_host(_wallet()));
    expect(find.text('\$4.83'), findsOneWidget);
    expect(find.text('Promo Code'), findsOneWidget);
    expect(find.text('RAMADAN26'), findsOneWidget);
    expect(find.text('Wallet ID'), findsOneWidget);
    expect(find.text('BE482913'), findsOneWidget);
    expect(find.text('Bonus'), findsOneWidget);
    expect(find.text('\$2.50'), findsOneWidget);
    // Xiran is gone from the card; Promo Code and Wallet ID sit side by side.
    expect(find.text('Xiran'), findsNothing);
    expect(find.text('\$0.80'), findsNothing);
    final promo = tester.getRect(find.byKey(const Key('promo-code')));
    final id = tester.getRect(find.byKey(const Key('wallet-id')));
    expect(promo.top, id.top);
    expect(promo.right < id.left, isTrue);
    expect(tester.getRect(find.byKey(const Key('bonus'))).top > promo.bottom, isTrue, reason: 'bonus is below them');
  });

  testWidgets('copies the Wallet ID and the promo code', (tester) async {
    await _screen(tester, const Size(390, 844));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_host(_wallet()));
    await tester.tap(find.descendant(of: find.byKey(const Key('wallet-id')), matching: find.byTooltip('Copy')));
    await tester.pump();
    expect(copied, 'BE482913');
    expect(find.text('BE482913 copied'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const Key('promo-code')), matching: find.byTooltip('Copy')));
    await tester.pump();
    expect(copied, 'RAMADAN26');
  });

  testWidgets('no promo code: a dash and nothing to copy, never an example code', (tester) async {
    await _screen(tester, const Size(390, 844));
    await tester.pumpWidget(_host(_wallet(promo: null, bonus: '0.00')));
    expect(find.descendant(of: find.byKey(const Key('promo-code')), matching: find.text('—')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('promo-code')), matching: find.byTooltip('Copy')), findsNothing);
    expect(find.text('BAARI50'), findsNothing);
    expect(find.text('\$0.00'), findsOneWidget); // bonus
  });

  testWidgets('each customer sees their own Wallet ID', (tester) async {
    await _screen(tester, const Size(390, 844));
    await tester.pumpWidget(_host(_wallet(walletId: 'BE111111')));
    expect(find.text('BE111111'), findsOneWidget);
    await tester.pumpWidget(_host(_wallet(walletId: 'BE222222')));
    expect(find.text('BE222222'), findsOneWidget);
    expect(find.text('BE111111'), findsNothing);
    expect(find.text('BE12345'), findsNothing);
  });

  testWidgets('while loading there are no codes to show', (tester) async {
    await _screen(tester, const Size(390, 844));
    await tester.pumpWidget(_host(null, loading: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Copy'), findsNothing);
  });

  for (final size in const [Size(320, 568), Size(360, 640), Size(412, 915), Size(600, 1000)]) {
    testWidgets('fits a ${size.width.toInt()}px-wide screen without clipping', (tester) async {
      await _screen(tester, size);
      await tester.pumpWidget(_host(_wallet(walletId: 'BE999999', promo: 'WELCOME-2026-OFFER')));
      expect(tester.takeException(), isNull);
      expect(find.text('BE999999'), findsOneWidget);
      expect(find.text('WELCOME-2026-OFFER'), findsOneWidget);
    });
  }

  testWidgets('Somali labels', (tester) async {
    await _screen(tester, const Size(360, 640));
    AppLanguage.current.value = AppLanguage.somali;
    await tester.pumpWidget(_host(_wallet()));
    expect(find.text('Aqoonsiga Boorsada'), findsOneWidget);
    expect(find.text('Koodhka Dallacsiinta'), findsOneWidget);
    expect(find.text('Gunno'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
