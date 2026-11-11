import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/screens/notifications/notifications_screen.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

AppNotification _n(int i, String kind, {String status = 'completed', Map<String, dynamic> extra = const {}}) => AppNotification.fromJson({
      'id': 'n$i',
      'title': 'Server title $i',
      'body': 'Server body $i',
      'createdAt': DateTime.utc(2026, 11, 11, 12).subtract(Duration(minutes: i)).toIso8601String(),
      'kind': kind,
      if (kind != 'broadcast') 'status': status,
      ...extra,
    });

class _Api extends CustomerApi {
  _Api(this.all) : super(ApiClient());
  final List<AppNotification> all;
  final calls = <String>[];

  @override
  Future<List<AppNotification>> getNotifications({DateTime? before, int limit = 30}) async {
    calls.add('${before?.toIso8601String()}|$limit');
    final rows = all.where((n) => before == null || n.createdAt.isBefore(before)).toList();
    return rows.take(limit).toList();
  }
}

Widget _app(_Api api) => Provider<CustomerApi>.value(value: api, child: MaterialApp(theme: AppTheme.current, home: const NotificationsScreen()));

final _sent = {'amount': '1.00', 'reference': 'TRFC1A2776A', 'balanceAfter': '0.00', 'counterpartName': 'Yaasiin maxamed adan', 'counterpartWalletId': 'BE773710'};
final _withdraw = {'amount': '10.00', 'method': 'EVC Plus', 'reference': 'EXJTFGGR', 'transactionRef': null, 'balanceAfter': '4.50'};
final _deposit = {'amount': '25.00', 'method': 'EVC Plus', 'reference': 'EXDEP001', 'transactionRef': 'TXN-998', 'balanceAfter': '29.50'};

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.somali);

  testWidgets('money sent, withdrawal and deposit: title, name, wallet ID, amount, balance, provider, transaction ID, date, green badge', (tester) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_Api([_n(1, 'transfer_sent', extra: _sent), _n(2, 'withdraw', extra: _withdraw), _n(3, 'deposit', extra: _deposit)])));
    await tester.pumpAndSettle();
    expect(find.text('Lacag ayaad dirtay'), findsOneWidget);
    expect(find.text('Yaasiin maxamed adan'), findsOneWidget);
    expect(find.text('BE773710'), findsOneWidget);
    expect(find.text('-\$1.00'), findsOneWidget);
    expect(find.text('\$0.00'), findsOneWidget, reason: 'the remaining balance');
    expect(find.text('Lacag-bixinta way guulaysatay'), findsOneWidget);
    expect(find.text('EVC Plus'), findsNWidgets(2));
    expect(find.text('Dhigashadu way guulaysatay'), findsOneWidget);
    expect(find.text('+\$25.00'), findsOneWidget);
    expect(find.text('Guulaystay'), findsNWidgets(3));
    Color colorOf(String t) => tester.widget<Text>(find.text(t)).style!.color!;
    expect(colorOf('-\$10.00').red > colorOf('-\$10.00').green, isTrue, reason: 'a withdrawal amount is red');
    expect(colorOf('+\$25.00').green > colorOf('+\$25.00').red, isTrue, reason: 'a deposit is green');
  });

  testWidgets('failed is red and pending is orange; a broadcast keeps its title and text', (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_Api([
      _n(1, 'withdraw', status: 'failed', extra: _withdraw),
      _n(2, 'deposit', status: 'pending', extra: _deposit),
      _n(3, 'broadcast'),
    ])));
    await tester.pumpAndSettle();
    final failed = tester.widget<Text>(find.text('Fashilmay'));
    final pending = tester.widget<Text>(find.text('Sugaya'));
    expect(failed.style!.color!.red > 200 && failed.style!.color!.green < 120, isTrue, reason: 'red');
    expect(pending.style!.color!.red > 200 && pending.style!.color!.green > 120 && pending.style!.color!.blue < 80, isTrue, reason: 'orange');
    expect(find.text('Server title 3'), findsOneWidget);
    expect(find.text('Server body 3'), findsOneWidget);
    expect(find.byKey(const Key('notification-status')), findsNWidgets(2), reason: 'a broadcast has no status badge');
  });

  testWidgets('no transaction ID and no copy icon on any notification', (tester) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_Api([_n(1, 'transfer_sent', extra: _sent), _n(2, 'withdraw', extra: _withdraw), _n(3, 'deposit', extra: _deposit)])));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
    expect(find.text('Aqoonsiga Dhaqdhaqaaqa'), findsNothing);
    for (final ref in ['TRFC1A2776A', 'EXJTFGGR', 'EXDEP001', 'TXN-998']) {
      expect(find.text(ref), findsNothing, reason: ref);
    }
  });

  testWidgets('older notifications load when the end is reached: each once, newest first; nothing is read again needlessly', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api([for (var i = 1; i <= 70; i++) _n(i, 'broadcast')]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1), reason: 'one page at first');
    for (var i = 0; i < 40; i++) {
      await tester.drag(find.byKey(const Key('notifications-list')), const Offset(0, -1500));
      await tester.pumpAndSettle();
    }
    expect(api.calls.length, 3, reason: '30 + 30 + 10, then it stops asking: ${api.calls}');
    expect(find.text('Server title 70'), findsOneWidget, reason: 'the oldest is reachable');
    final list = tester.widget<ListView>(find.byKey(const Key('notifications-list')));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount, 70 * 2 - 1, reason: '70 notifications, no spinner left');
  });

  testWidgets('fits 320 / 360 / 411 px in Somali and English with a long name; pull to refresh starts again', (tester) async {
    final long = {..._sent, 'counterpartName': 'Abdirahman Mohamed Abdullahi Ahmed Warsame Hussein'};
    for (final size in const [Size(320, 640), Size(360, 780), Size(411, 891)]) {
      for (final lang in [AppLanguage.somali, AppLanguage.english]) {
        AppLanguage.current.value = lang;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_app(_Api([_n(1, 'transfer_sent', extra: long), _n(2, 'withdraw', extra: _withdraw), _n(3, 'deposit', extra: _deposit)])));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size $lang');
      }
    }
    addTearDown(tester.view.reset);
  });
}
