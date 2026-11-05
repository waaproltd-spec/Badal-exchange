import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/widgets/withdrawal_approval_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester,
    {Uri? wa, String? id, List<Uri>? opened, bool opens = true, double w = 360}) async {
  tester.view.physicalSize = Size(w * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: WithdrawalApprovalSheet(
          whatsappLink: wa,
          customerId: id,
          reason: null,
          launch: (u) async {
            opened?.add(u);
            return opens && u.scheme != 'tg';
          },
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets(
      'title, message, two buttons; nothing to copy, no usernames or URLs',
      (tester) async {
    await _pump(tester, wa: Uri.parse('https://wa.me/252612345678'));
    expect(find.byKey(const Key('approval-title')), findsOneWidget);
    expect(find.byKey(const Key('approval-check')), findsOneWidget);
    expect(find.byKey(const Key('approval-icon')), findsOneWidget);
    expect(find.byKey(const Key('contact-admin-whatsapp')), findsOneWidget);
    expect(find.byKey(const Key('contact-admin-telegram')), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
    expect(find.textContaining('wa.me'), findsNothing);
    expect(find.textContaining('@Badalaisupportbot'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('side by side, on a narrow phone too', (tester) async {
    for (final w in [320.0, 360.0, 412.0]) {
      await _pump(tester, wa: Uri.parse('https://wa.me/252612345678'), w: w);
      final a = tester.getRect(find.byKey(const Key('contact-admin-whatsapp')));
      final b = tester.getRect(find.byKey(const Key('contact-admin-telegram')));
      expect(a.top, b.top);
      expect(a.right, lessThan(b.left));
      expect(b.right, lessThanOrEqualTo(w));
      expect(tester.takeException(), isNull, reason: 'width $w');
    }
  });

  testWidgets('WhatsApp opens the configured link', (tester) async {
    final opened = <Uri>[];
    await _pump(tester,
        wa: Uri.parse('https://wa.me/252612345678?text=Hi'), opened: opened);
    await tester.tap(find.byKey(const Key('contact-admin-whatsapp')));
    await tester.pump();
    expect(opened.single.toString(), 'https://wa.me/252612345678?text=Hi');
  });

  testWidgets('Telegram opens @Badalaisupportbot: the app, else the web page',
      (tester) async {
    final opened = <Uri>[];
    await _pump(tester, opened: opened);
    await tester.tap(find.byKey(const Key('contact-admin-telegram')));
    await tester.pump();
    expect(opened.map((u) => u.toString()), [
      'tg://resolve?domain=Badalaisupportbot',
      'https://t.me/Badalaisupportbot'
    ]);
  });

  testWidgets('app missing: a message, no crash', (tester) async {
    await _pump(tester,
        wa: Uri.parse('https://wa.me/252612345678'), opens: false);
    await tester.tap(find.byKey(const Key('contact-admin-whatsapp')));
    await tester.pump();
    expect(
        find.text(AppStrings.approvalAppMissing('WhatsApp')), findsOneWidget);
  });

  testWidgets('Telegram missing too: a message, no crash', (tester) async {
    await _pump(tester, opens: false);
    await tester.tap(find.byKey(const Key('contact-admin-telegram')));
    await tester.pump();
    expect(
        find.text(AppStrings.approvalAppMissing('Telegram')), findsOneWidget);
  });

  testWidgets('no WhatsApp number set: says so', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('contact-admin-whatsapp')));
    await tester.pump();
    expect(find.text(AppStrings.supportNotSet), findsOneWidget);
  });

  testWidgets('Telegram opens the bot with the start code carrying the Customer ID', (tester) async {
    final opened = <Uri>[];
    await _pump(tester, id: 'BX45495228', opened: opened);
    await tester.tap(find.byKey(const Key('contact-admin-telegram')));
    await tester.pump();
    expect(opened.map((u) => u.toString()), [
      'tg://resolve?domain=Badalaisupportbot&start=fasax_BX45495228',
      'https://t.me/Badalaisupportbot?start=fasax_BX45495228',
    ]);
  });
}
