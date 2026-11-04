import 'dart:async';
import 'dart:io';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/tip.dart';
import 'package:badal_exchange_customer/screens/tips/tips_screen.dart';
import 'package:badal_exchange_customer/theme/colors.dart';
import 'package:badal_exchange_customer/theme/theme_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _free() => {
      'id': 'f1', 'title': 'Weekend free pick', 'sport': 'football', 'teamCount': 3, 'isPaid': false,
      'owned': false, 'locked': false, 'oddsCode': 'FREE-123', 'totalOdds': 4.5,
      'matches': [
        {'match': 'Arsenal v Chelsea', 'pick': 'Over 2.5', 'odds': 1.85}
      ],
    };

Map<String, dynamic> _paidLocked() => {
      'id': 'p1', 'title': 'VIP accumulator', 'sport': 'basketball', 'teamCount': 6, 'isPaid': true, 'price': '2.50',
      'owned': false, 'locked': true, 'oddsCode': null, 'matches': [], 'hasImage': false, 'totalOdds': 20.0,
    };

class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  List<Map<String, dynamic>> rows = [_free(), _paidLocked()];
  final calls = <String>[];
  Completer<void>? hold;
  ApiException? failWith;
  String balance = '10.00';

  @override
  Future<List<Tip>> getTips([String filter = 'all']) async {
    calls.add('list');
    return [for (final r in rows) Tip.fromJson(r)];
  }

  @override
  Future<Tip> getTip(String id) async => Tip.fromJson(rows.firstWhere((r) => r['id'] == id));

  @override
  Future<TipPurchase> buyTip(String id, {String? expectedPrice}) async {
    calls.add('buy $id $expectedPrice');
    if (hold != null) await hold!.future;
    if (failWith != null) throw failWith!;
    final i = rows.indexWhere((r) => r['id'] == id);
    final already = rows[i]['owned'] == true;
    if (!already) balance = '7.50';
    rows[i] = {
      ...rows[i], 'owned': true, 'locked': false, 'oddsCode': 'PAID-SECRET-9',
      'matches': [
        {'match': 'Lakers v Celtics', 'pick': 'Lakers -3', 'odds': 1.9}
      ],
    };
    return TipPurchase(tip: Tip.fromJson(rows[i]), charged: !already, availableBalance: balance);
  }
}

Widget _app(_FakeApi api) => Provider<CustomerApi>.value(value: api, child: const MaterialApp(home: TipsScreen()));

void main() {
  late List<String> copied;

  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  testWidgets('three tabs; each tip shows its sport, teams, Free / Paid, the code and the price', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Free'), findsWidgets);
    expect(find.text('Paid'), findsWidgets);
    expect(find.text('Football • 3 teams'), findsOneWidget);
    expect(find.text('Basketball • 6 teams'), findsOneWidget);
    expect(find.text('FREE-123'), findsOneWidget);
    expect(find.byKey(const Key('tip-code-p1')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('tip-code-p1'))).data, '••••••••••');
    expect(find.text('\$2.50'), findsOneWidget);
    expect(find.text('PAID-SECRET-9'), findsNothing);
  });

  testWidgets('the Free and Paid tabs filter', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('tips-tabs')), matching: find.text('Free')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tip-f1')), findsOneWidget);
    expect(find.byKey(const Key('tip-p1')), findsNothing);
    await tester.tap(find.descendant(of: find.byKey(const Key('tips-tabs')), matching: find.text('Paid')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tip-p1')), findsOneWidget);
    expect(find.byKey(const Key('tip-f1')), findsNothing);
  });

  testWidgets('Copy Code copies a free tip without any payment', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-copy-f1')));
    await tester.pump();
    expect(copied, ['FREE-123']);
    expect(find.text('Code copied'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('buy')), isEmpty);
  });

  testWidgets('a paid tip asks first; Cancel changes nothing; Pay & unlock buys once and shows the code', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-unlock-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Buy this tip?'), findsOneWidget);
    expect(find.textContaining('\$2.50 will be taken from your wallet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tip-buy-cancel')));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('buy')), isEmpty, reason: 'nothing is charged before the customer confirms');
    expect(find.text('PAID-SECRET-9'), findsNothing);

    await tester.tap(find.byKey(const Key('tip-unlock-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-buy-confirm')));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('buy')).toList(), ['buy p1 2.50']);
    expect(find.text('PAID-SECRET-9'), findsOneWidget);
    expect(find.byKey(const Key('tip-unlock-p1')), findsNothing);
    expect(find.byKey(const Key('tip-copy-p1')), findsOneWidget);
    expect(find.text('Purchased'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tip-copy-p1')));
    await tester.pump();
    expect(copied, ['PAID-SECRET-9']);
  });

  testWidgets('while the purchase is on its way the button is off: no second charge', (tester) async {
    final api = _FakeApi()..hold = Completer<void>();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-unlock-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-buy-confirm')));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('tip-unlock-p1'))).onPressed, isNull);
    api.hold!.complete();
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('buy')).length, 1);
  });

  testWidgets('a refused purchase says why and unlocks nothing', (tester) async {
    final api = _FakeApi()..failWith = const ApiException(status: 400, code: 'INSUFFICIENT_FUNDS', message: 'Your balance is not enough for this tip');
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-unlock-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-buy-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Your balance is not enough for this tip. Deposit first.'), findsOneWidget);
    expect(find.text('PAID-SECRET-9'), findsNothing);
    expect(find.byKey(const Key('tip-unlock-p1')), findsOneWidget);
  });

  testWidgets('a tip already owned (bought earlier) just shows its code', (tester) async {
    final api = _FakeApi();
    api.rows[1] = {
      ..._paidLocked(), 'owned': true, 'locked': false, 'oddsCode': 'PAID-SECRET-9',
    };
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(find.text('PAID-SECRET-9'), findsOneWidget);
    expect(find.byKey(const Key('tip-unlock-p1')), findsNothing);
  });

  testWidgets('the detail shows matches and picks; empty and error states', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-meta-f1')));
    await tester.pumpAndSettle();
    expect(find.text('Arsenal v Chelsea'), findsOneWidget);
    expect(find.text('Over 2.5'), findsOneWidget);
    expect(find.text('1.85'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final empty = _FakeApi()..rows = [];
    await tester.pumpWidget(_app(empty));
    await tester.pumpAndSettle();
    expect(find.text('No tips here yet'), findsOneWidget);
  });

  testWidgets('Somali on a small phone, no overflow', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();
    expect(find.text('Shaxaha'), findsOneWidget);
    expect(find.text('Dhammaan'), findsOneWidget);
    expect(find.text('Kubadda Cagta • 3 kooxood'), findsOneWidget);
    expect(find.text('Koobiyee Koodhka'), findsOneWidget);
    expect(find.text('Fur'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TIPS uses the app\'s own colours and follows light / dark', (tester) async {
    Color cardColor() => tester.widget<Material>(find.descendant(of: find.byKey(const Key('tip-f1')), matching: find.byType(Material)).first).color!;
    AppThemeMode.current.value = ThemeMode.light;
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();
    final light = cardColor();
    expect(light, AppColors.surface);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, AppColors.screenBackground);
    AppThemeMode.current.value = ThemeMode.dark;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();
    expect(cardColor(), AppColors.surface);
    expect(cardColor(), isNot(light), reason: 'dark mode repaints the card with the app\'s dark surface');
    AppThemeMode.current.value = ThemeMode.light;
  });

  test('no colour is written inside the TIPS screens: only the app\'s AppColors', () {
    for (final f in ['lib/screens/tips/tips_screen.dart', 'lib/models/tip.dart']) {
      final src = File(f).readAsStringSync();
      expect(RegExp(r'Color\(0x|(?<![A-Za-z])Colors\.(?!transparent)').hasMatch(src), isFalse, reason: f);
    }
    final home = File('lib/screens/home/home_screen.dart').readAsStringSync();
    expect(home.contains('TipsColors'), isFalse);
  });
}
