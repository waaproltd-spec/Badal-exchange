// The Dashboard says which source carries the deposit payments: Sahal Active, Agent SIM Fallback Active,
// or Both Sources Unavailable.
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> show(WidgetTester t, Map<String, dynamic> json) async {
  await t.pumpWidget(MaterialApp(home: Scaffold(body: PaymentSourceCard(data: PaymentSource.fromJson(json)))));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
  });

  testWidgets('Sahal Active', (t) async {
    await show(t, {'source': 'sahal'});
    expect(find.text('Sahal Active'), findsOneWidget);
    expect(find.text('Agent SIM Fallback Active'), findsNothing);
  });

  testWidgets('Agent SIM Fallback Active, with what the SMS credited', (t) async {
    await show(t, {'source': 'agent_sim', 'creditedBySmsToday': 3, 'waitingToday': 1});
    expect(find.text('Agent SIM Fallback Active'), findsOneWidget);
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('Both Sources Unavailable', (t) async {
    await show(t, {'source': 'none'});
    expect(find.text('Both Sources Unavailable'), findsOneWidget);
  });

  testWidgets('an unknown answer is shown as unavailable, never as active', (t) async {
    await show(t, {});
    expect(find.text('Both Sources Unavailable'), findsOneWidget);
  });
}
