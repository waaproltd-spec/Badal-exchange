import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/widgets/status_badge.dart';
import 'package:badal_exchange_customer/theme/colors.dart';

Future<void> _pump(WidgetTester tester, String status) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: StatusBadge(status: status)),
    ),
  );
}

void main() {
  // The labels follow the app language: English here (the app starts in Somali).
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('shows only Completed or Failed; anything not final reads as being verified, never Pending', (tester) async {
    final expected = <String, String>{
      'completed': 'Completed',
      'failed': 'Failed',
      // Cancelled and expired are definitive too.
      'cancelled': 'Failed',
      'expired': 'Failed',
      // Not final: the server is still confirming.
      'pending': 'Your payment is being verified…',
      'processing': 'Your payment is being verified…',
    };

    for (final entry in expected.entries) {
      await _pump(tester, entry.key);
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      expect(find.text('Pending'), findsNothing, reason: entry.key);
      expect(find.text('Processing'), findsNothing, reason: entry.key);
    }
  });

  testWidgets('a status this app does not know is "being verified", never Failed or the raw word', (tester) async {
    await _pump(tester, 'something_new');
    expect(find.text('Your payment is being verified…'), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    expect(find.text('something_new'), findsNothing);
  });

  testWidgets('uses the semantic color for a completed order', (tester) async {
    await _pump(tester, 'completed');
    final text = tester.widget<Text>(find.text('Completed'));
    expect(text.style?.color, AppColors.statusCompleted);
  });

  testWidgets('uses the semantic color for a failed order', (tester) async {
    await _pump(tester, 'failed');
    final text = tester.widget<Text>(find.text('Failed'));
    expect(text.style?.color, AppColors.statusFailed);
  });
}
