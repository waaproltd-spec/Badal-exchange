import 'package:badal_agent_app/theme/app_theme.dart';
import 'package:badal_agent_app/widgets/console_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The Customer App's badge shows the same six words (customer-app
  // test/status_badge_test.dart), from the same orders.status.
  testWidgets('every order status is shown with the same word as in the Customer App', (tester) async {
    const expected = {
      'pending': 'Pending',
      'processing': 'Processing',
      'completed': 'Completed',
      'failed': 'Failed',
      'cancelled': 'Cancelled',
      'expired': 'Expired',
    };
    for (final e in expected.entries) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatusPill(e.key))));
      expect(find.text(e.value), findsOneWidget, reason: e.key);
    }
  });

  test('colours: pending amber, processing blue, completed green, failed red, cancelled and expired gray', () {
    expect(StatusPill.colorFor('pending'), AppColors.statusPending);
    expect(StatusPill.colorFor('processing'), AppColors.statusProcessing);
    expect(StatusPill.colorFor('completed'), AppColors.statusCompleted);
    expect(StatusPill.colorFor('failed'), AppColors.statusFailed);
    expect(StatusPill.colorFor('cancelled'), AppColors.statusDuplicate);
    expect(StatusPill.colorFor('expired'), AppColors.statusDuplicate);
  });
}
