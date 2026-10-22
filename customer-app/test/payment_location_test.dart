import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:badal_exchange_customer/theme/colors.dart';
import 'package:badal_exchange_customer/theme/theme_mode.dart';
import 'package:badal_exchange_customer/widgets/payment_location_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the copy buttons put on the clipboard.
final _clipboard = <String>[];

Future<void> _pump(WidgetTester tester, {required double width, String? city = 'Mogadishu', String? street = 'FURAHA 5'}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.current,
    home: Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Align(alignment: Alignment.topCenter, child: PaymentLocationCard(city: city, street: street)),
      ),
    ),
  ));
}

void main() {
  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    _clipboard.clear();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') _clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      },
    );
  });
  tearDown(() => AppThemeMode.current.value = ThemeMode.system);

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets('${mode.name}, $width wide: both values readable, each Copy copies its own value', (tester) async {
        AppThemeMode.current.value = mode;
        await _pump(tester, width: width);

        expect(find.text('Payment Location'), findsOneWidget);
        expect(find.text('Use this address if required.'), findsOneWidget);
        expect(find.text('City'), findsOneWidget);
        expect(find.text('Mogadishu'), findsOneWidget);
        expect(find.text('Street'), findsOneWidget);
        expect(find.text('FURAHA 5'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Values are not shrunk below a readable size.
        for (final v in ['Mogadishu', 'FURAHA 5']) {
          expect(tester.getSize(find.text(v)).height, greaterThanOrEqualTo(15));
        }
        // Phones: one value per row, barely if at all scaled down. (The test
        // font draws every letter as a full square, far wider than the app's
        // font, so this is the worst case.)
        for (final v in ['Mogadishu', 'FURAHA 5']) {
          final box = tester.getSize(find.ancestor(of: find.text(v), matching: find.byType(FittedBox)).first);
          final text = tester.getSize(find.text(v));
          expect(box.width / text.width, greaterThanOrEqualTo(0.75), reason: '$v is readable');
        }
        expect(tester.getTopLeft(find.text('Mogadishu')).dy, lessThan(tester.getTopLeft(find.text('FURAHA 5')).dy));

        await tester.tap(find.byKey(const Key('copy-city')));
        await tester.pump();
        expect(_clipboard, ['Mogadishu']);
        expect(find.text('Mogadishu copied'), findsOneWidget);

        await tester.tap(find.byKey(const Key('copy-street')));
        await tester.pump();
        expect(_clipboard, ['Mogadishu', 'FURAHA 5']);
        expect(find.text('FURAHA 5 copied'), findsOneWidget);

        // Theme colors follow the mode.
        final card = tester.widget<Container>(find.byKey(const Key('payment-location')));
        expect((card.decoration! as BoxDecoration).color, mode == ThemeMode.dark ? const Color(0xFF22152B) : Colors.white);
        final value = tester.widget<Text>(find.text('Mogadishu'));
        expect(value.style!.color, mode == ThemeMode.dark ? const Color(0xFFF4ECF7) : const Color(0xFF24062F));
      });
    }
  }

  testWidgets('wide screens (tablet): city and street side by side', (tester) async {
    await _pump(tester, width: 900);
    expect(tester.getTopLeft(find.text('Mogadishu')).dy, tester.getTopLeft(find.text('FURAHA 5')).dy);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header folds the values away and back', (tester) async {
    await _pump(tester, width: 390);
    await tester.tap(find.byKey(const Key('payment-location-toggle')));
    await tester.pump();
    expect(find.text('Mogadishu'), findsNothing);
    expect(find.byKey(const Key('copy-street')), findsNothing);
    await tester.tap(find.byKey(const Key('payment-location-toggle')));
    await tester.pump();
    expect(find.text('FURAHA 5'), findsOneWidget);
  });

  testWidgets('only the values that are set are shown', (tester) async {
    await _pump(tester, width: 412, city: null);
    expect(find.text('City'), findsNothing);
    expect(find.byKey(const Key('copy-city')), findsNothing);
    expect(find.text('FURAHA 5'), findsOneWidget);
  });

  testWidgets('Somali labels', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _pump(tester, width: 320);
    expect(find.text('Goobta Lacag-bixinta'), findsOneWidget);
    expect(find.text('Magaalada'), findsOneWidget);
    expect(find.text('Waddada'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the server sends the location with the method; none means no card', () {
    final withLocation = PaymentMethodOption.fromJson(const {
      'method': 'onexbet', 'label': '1XBET', 'kind': 'platform', 'color': '#1D4ED8', 'initials': '1X',
      'depositNumbers': [],
      'paymentLocation': {'city': 'Mogadishu', 'street': 'FURAHA 5'},
    });
    expect(withLocation.paymentCity, 'Mogadishu');
    expect(withLocation.paymentStreet, 'FURAHA 5');
    expect(withLocation.hasPaymentLocation, isTrue);

    final none = PaymentMethodOption.fromJson(const {
      'method': 'evc_plus', 'label': 'EVC Plus', 'kind': 'mobile_money', 'color': '#16A34A', 'initials': 'EVC',
      'depositNumbers': [],
      'paymentLocation': null,
    });
    expect(none.hasPaymentLocation, isFalse);
  });
}
