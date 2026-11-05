// TIPS (Shaxaha) in the Agent App: the Admin Dashboard management (list, create, edit,
// publish, delete, sales and revenue, purchase history and refunds) and the Agent view.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/tips.dart';
import 'package:badal_agent_app/screens/admin/tips_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _tip(String id, String title, {bool paid = false, bool published = false, String price = '0.00', int sales = 0, String revenue = '0.00'}) => {
      'id': id, 'title': title, 'sport': 'football', 'teamCount': 4, 'isPaid': paid, 'price': price,
      'oddsCode': 'CODE-$id', 'totalOdds': 9.5, 'published': published, 'sales': sales, 'revenue': revenue,
      'matches': [
        {'match': 'Arsenal v Chelsea', 'pick': 'Over 2.5', 'odds': 1.85}
      ],
    };

Map<String, dynamic> _purchase(String id, {String status = 'completed'}) => {
      'id': id, 'tipId': 't2', 'title': 'VIP', 'sport': 'football', 'customerName': 'Asha', 'customerPhone': '252611111111',
      'price': '3.00', 'status': status, 'createdAt': '2026-11-04T10:00:00Z', 'refundReason': status == 'refunded' ? 'Wrong tip' : null,
    };

class _Api extends AgentApi {
  _Api() : super();

  final calls = <String>[];
  Map<String, Object?>? saved;
  List<Map<String, dynamic>> tips = [_tip('t1', 'Free pick', published: true), _tip('t2', 'VIP', paid: true, price: '3.00', published: true, sales: 2, revenue: '6.00')];
  List<Map<String, dynamic>> purchases = [_purchase('p1')];
  ApiException? refundFails;

  @override
  Future<List<ManagedTip>> getTips([String status = 'all']) async {
    calls.add('tips $status');
    return [for (final t in tips) ManagedTip.fromJson(t)];
  }

  @override
  Future<TipsStats> getTipsStats() async => TipsStats.fromJson({
        'tips': 2, 'published': 2, 'sales': 2, 'revenue': '6.00', 'salesToday': 1, 'revenueToday': '3.00',
        'sales7d': 2, 'revenue7d': '6.00', 'refunds': 0, 'refunded': '0.00',
      });

  @override
  Future<ManagedTip> saveTip({
    String? id, required String title, required String sport, required int teamCount, required bool isPaid, String? price,
    required String oddsCode, double? totalOdds, List<TipMatchEntry> matches = const [], String? note, Uint8List? image, bool removeImage = false,
  }) async {
    calls.add('save');
    saved = {
      'id': id, 'title': title, 'sport': sport, 'teams': teamCount, 'paid': isPaid, 'price': price, 'code': oddsCode,
      'total': totalOdds, 'matches': matches.map((m) => m.toJson()).toList(), 'note': note, 'image': image?.length, 'removeImage': removeImage,
    };
    return ManagedTip.fromJson(_tip(id ?? 'new', title));
  }

  @override
  Future<ManagedTip> publishTip(String id, bool published) async {
    calls.add('publish $id $published');
    final i = tips.indexWhere((t) => t['id'] == id);
    tips[i] = {...tips[i], 'published': published};
    return ManagedTip.fromJson(tips[i]);
  }

  @override
  Future<void> deleteTip(String id) async {
    calls.add('delete $id');
    tips.removeWhere((t) => t['id'] == id);
  }

  @override
  Future<List<TipPurchaseRecord>> getTipPurchases({String? tipId}) async {
    calls.add('history $tipId');
    return [for (final p in purchases) TipPurchaseRecord.fromJson(p)];
  }

  @override
  Future<void> refundTipPurchase(String id, String reason) async {
    calls.add('refund $id $reason');
    if (reason.trim().length < 3) throw const ApiException(statusCode: 400, code: 'VALIDATION_ERROR', message: 'Write the reason for the refund');
    if (refundFails != null) throw refundFails!;
    purchases = [_purchase(id, status: 'refunded')];
  }

  @override
  Future<TipPurchasesView> getAgentTipPurchases({String? search}) async {
    calls.add('agent ${search ?? ''}');
    return TipPurchasesView.fromJson({
      'summary': {'sales': 2, 'revenue': '6.00', 'tips': 2, 'published': 2},
      'purchases': purchases,
    });
  }
}

Future<_Api> _pump(WidgetTester tester, Widget home, {Size size = const Size(393, 1800), _Api? api}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final a = api ?? _Api();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: a), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return a;
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('the list shows each tip with its status, price, code, sales and the totals', (tester) async {
    await _pump(tester, const TipsManagementScreen());
    expect(find.text('Free pick'), findsOneWidget);
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('\$3.00'), findsWidgets);
    expect(find.text('Code: CODE-t2'), findsOneWidget);
    expect(find.byKey(const Key('tip-sales-t2')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('tip-sales-t2'))).data, '2 sales • \$6.00 revenue');
    expect(tester.widget<Text>(find.byKey(const Key('tips-stat-sales'))).data, '2');
    expect(tester.widget<Text>(find.byKey(const Key('tips-stat-revenue'))).data, '\$6.00');
  });

  testWidgets('publish and unpublish are one switch; the filter asks the server', (tester) async {
    final api = await _pump(tester, const TipsManagementScreen());
    await tester.tap(find.byKey(const Key('tip-publish-t1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('publish t1 false'));
    expect(tester.widget<Switch>(find.byKey(const Key('tip-publish-t1'))).value, isFalse);
    await tester.ensureVisible(find.byKey(const Key('tips-filter-paid')));
    await tester.tap(find.byKey(const Key('tips-filter-paid')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('tips paid'));
  });

  testWidgets('delete asks first', (tester) async {
    final api = await _pump(tester, const TipsManagementScreen());
    await tester.tap(find.byKey(const Key('tip-menu-t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('delete')), isEmpty);
    expect(find.textContaining('Customers will no longer see this tip'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('delete t1'));
    expect(find.text('Free pick'), findsNothing);
  });

  testWidgets('a new paid tip: sport, teams, price, code, matches and odds are all sent', (tester) async {
    final api = await _pump(tester, const TipFormScreen(), size: const Size(393, 2400));
    await tester.tap(find.byKey(const Key('tip-save')));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty, reason: 'required fields first');
    await tester.enterText(find.byKey(const Key('tip-title')), 'Weekend VIP');
    await tester.enterText(find.byKey(const Key('tip-teams')), '5');
    await tester.tap(find.text('Paid'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-save')));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty, reason: 'a paid tip needs a price and a code');
    await tester.enterText(find.byKey(const Key('tip-price')), '2.50');
    await tester.enterText(find.byKey(const Key('tip-code')), 'ABC-123');
    await tester.enterText(find.byKey(const Key('tip-total-odds')), '12.4');
    await tester.tap(find.byKey(const Key('tip-add-match')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tip-match-name-0')), 'Arsenal v Chelsea');
    await tester.enterText(find.byKey(const Key('tip-match-pick-0')), 'Over 2.5');
    await tester.enterText(find.byKey(const Key('tip-match-odds-0')), '1.85');
    await tester.tap(find.byKey(const Key('tip-save')));
    await tester.pumpAndSettle();
    expect(api.saved, {
      'id': null, 'title': 'Weekend VIP', 'sport': 'football', 'teams': 5, 'paid': true, 'price': '2.50', 'code': 'ABC-123',
      'total': 12.4, 'matches': [{'match': 'Arsenal v Chelsea', 'pick': 'Over 2.5', 'odds': 1.85}], 'note': null, 'image': null, 'removeImage': false,
    });
  });

  testWidgets('a picture is chosen, checked and sent with the tip', (tester) async {
    // A real 1x1 PNG.
    final jpeg = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
    final api = await _pump(tester, TipFormScreen(pickImage: () async => jpeg), size: const Size(393, 2400));
    await tester.enterText(find.byKey(const Key('tip-title')), 'With picture');
    await tester.enterText(find.byKey(const Key('tip-teams')), '2');
    await tester.enterText(find.byKey(const Key('tip-code')), 'X1');
    await tester.tap(find.byKey(const Key('tip-image-choose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-save')));
    await tester.pumpAndSettle();
    expect(api.saved!['image'], jpeg.length);
    expect(api.saved!['paid'], false);
    expect(api.saved!['price'], isNull);
  });

  testWidgets('a file that is not a picture is refused before sending', (tester) async {
    final api = await _pump(tester, TipFormScreen(pickImage: () async => Uint8List.fromList([1, 2, 3, 4])), size: const Size(393, 2400));
    await tester.tap(find.byKey(const Key('tip-image-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tip-problem')), findsOneWidget);
    expect(find.byKey(const Key('tip-image-preview')), findsNothing);
    expect(api.calls, isEmpty);
  });

  testWidgets('editing starts from the saved values', (tester) async {
    final tip = ManagedTip.fromJson(_tip('t2', 'VIP', paid: true, price: '3.00', published: true));
    final api = await _pump(tester, TipFormScreen(tip: tip), size: const Size(393, 2400));
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('3.00'), findsOneWidget);
    expect(find.text('CODE-t2'), findsOneWidget);
    expect(find.text('Arsenal v Chelsea'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tip-save')));
    await tester.pumpAndSettle();
    expect(api.saved!['id'], 't2');
    expect(api.saved!['price'], '3.00');
  });

  testWidgets('purchase history: who bought what, and a refund asks for a reason', (tester) async {
    final api = await _pump(tester, const TipPurchasesScreen(manager: true, tipId: 't2', title: 'VIP'));
    expect(find.text('Asha • 252611111111'), findsOneWidget);
    expect(find.text('\$3.00'), findsWidgets);
    expect(find.text('Completed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('refund-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refund-confirm')));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('refund')), ['refund p1 '], reason: 'the server refuses an empty reason and nothing is sent twice');
    await tester.tap(find.byKey(const Key('refund-p1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('refund-reason')), 'Wrong tip');
    await tester.tap(find.byKey(const Key('refund-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Refunded'), findsOneWidget);
    expect(find.byKey(const Key('refund-p1')), findsNothing, reason: 'refunded once only');
  });

  testWidgets('the Agent view is read only: purchases and figures, no refund, search', (tester) async {
    final api = await _pump(tester, const TipPurchasesScreen(manager: false));
    expect(find.text('Asha • 252611111111'), findsOneWidget);
    expect(find.byKey(const Key('tips-stat-sales')), findsOneWidget);
    expect(find.byKey(const Key('refund-p1')), findsNothing);
    await tester.enterText(find.byKey(const Key('tips-search')), 'asha');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.calls, contains('agent asha'));
  });

  testWidgets('Somali on a small phone, no overflow', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _pump(tester, const TipsManagementScreen(), size: const Size(320, 800));
    expect(find.text('Maamulka TIPS'), findsOneWidget);
    expect(find.text('2 iib • \$6.00 dakhli'), findsOneWidget);
    expect(find.text('Bilaash'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const TipFormScreen(), size: const Size(320, 800));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const TipPurchasesScreen(manager: true), size: const Size(320, 800));
    expect(tester.takeException(), isNull);
  });

  test('no colour is written inside the TIPS screens: only the app\'s AppColors', () {
    final src = File('lib/screens/admin/tips_screens.dart').readAsStringSync();
    expect(RegExp(r'Color\(0x|(?<![A-Za-z])Colors\.(?!transparent)').hasMatch(src), isFalse);
    expect(File('lib/models/tips.dart').readAsStringSync().contains('Color('), isFalse);
  });
}
