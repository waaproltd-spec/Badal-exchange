// The Sahal sign-in screen says whether this phone can read the access code while the app is closed.
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/screens/admin/background_sms_card.dart';
import 'package:badal_agent_app/sms/sms_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
  });

  testWidgets('what Android allows, and the trail of the last background reads', (t) async {
    await t.pumpWidget(_wrap(BackgroundSmsCard(
      smsGranted: () async => true,
      batteryFree: () async => false,
      askBattery: () async => true,
      trail: () async => ['11-05 10:12:44 native: SMS received while the app was closed', '11-05 10:12:46 engine started'],
    )));
    await t.pumpAndSettle();
    expect(find.text('SMS permission allowed'), findsOneWidget);
    expect(find.text('No battery restriction for this app'), findsOneWidget);
    expect(find.byKey(const Key('background-sms-allow')), findsOneWidget, reason: 'the battery is still restricted: a button to allow');
    expect(find.byKey(const Key('background-sms-line-0')), findsOneWidget);
    expect(find.byKey(const Key('background-sms-line-1')), findsOneWidget);
  });

  testWidgets('everything allowed: no button; nothing read yet says so', (t) async {
    await t.pumpWidget(_wrap(BackgroundSmsCard(smsGranted: () async => true, batteryFree: () async => true, trail: () async => const [])));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('background-sms-allow')), findsNothing);
    expect(find.byKey(const Key('background-sms-empty')), findsOneWidget);
  });

  testWidgets('Allow asks for the battery exemption and reads the state again', (t) async {
    var asked = 0;
    var free = false;
    await t.pumpWidget(_wrap(BackgroundSmsCard(
      smsGranted: () async => true,
      batteryFree: () async => free,
      askBattery: () async {
        asked++;
        free = true;
        return true;
      },
      trail: () async => const [],
    )));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('background-sms-allow')));
    await t.pumpAndSettle();
    expect(asked, 1);
    expect(find.byKey(const Key('background-sms-allow')), findsNothing);
  });

  test('the trail keeps the last 12 lines and never an SMS text', () async {
    for (var i = 0; i < 15; i++) {
      await BackgroundSmsLog.add('line $i');
    }
    final lines = await BackgroundSmsLog.lines();
    expect(lines, hasLength(BackgroundSmsLog.keep));
    expect(lines.last, endsWith('line 14'));
    expect(lines.first, endsWith('line 3'));
  });
}
