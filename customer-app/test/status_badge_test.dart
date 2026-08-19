import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  testWidgets('renders the correct label for each known order status', (tester) async {
    final expected = <String, String>{
      'pending': 'Pending',
      'processing': 'Processing',
      'completed': 'Completed',
      'failed': 'Failed',
      'cancelled': 'Cancelled',
      'expired': 'Expired',
    };

    for (final entry in expected.entries) {
      await _pump(tester, entry.key);
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets('falls back to the raw status string for an unknown status', (tester) async {
    await _pump(tester, 'something_new');
    expect(find.text('something_new'), findsOneWidget);
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
