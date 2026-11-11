import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/payment_numbers.dart';
import 'package:badal_agent_app/screens/admin/payment_numbers_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends AgentApi {
  final calls = <String>[];
  bool enabled = false;
  List<String> methods = const [];
  bool blocked = false;
  bool removed = false;

  @override
  Future<List<PaymentNumberCustomer>> getPaymentNumberCustomers({String? query, String filter = 'all'}) async {
    calls.add('list $filter ${query ?? ''}');
    return [
      PaymentNumberCustomer.fromJson({
        'id': 'c1', 'name': 'Ahmed Ali', 'phone': '252611234567', 'accountId': 'BX00000001',
        'enabled': enabled, 'methods': methods, 'numberCount': removed ? 0 : 1,
      }),
    ];
  }

  @override
  Future<CustomerPaymentNumbers> getCustomerPaymentNumbers(String customerId) async => CustomerPaymentNumbers.fromJson({
        'customer': {'id': 'c1', 'name': 'Ahmed Ali', 'phone': '252611234567', 'accountId': 'BX00000001'},
        'access': {'enabled': enabled, 'methods': methods, 'revokedAt': enabled ? null : '2026-10-30T10:00:00Z', 'revokedBy': enabled ? null : 'Admin'},
        'numbers': removed
            ? []
            : [
                {'id': 'n1', 'method': 'telesom', 'phone': '252612223344', 'label': 'Work', 'addedBy': 'customer', 'uses': 2,
                 'blocked': blocked, 'createdAt': '2026-10-30T09:00:00Z', 'lastUsedAt': '2026-10-30T09:30:00Z'},
              ],
      });

  @override
  Future<void> setPaymentNumberAccess(String customerId, {required bool enabled, List<String>? methods, String? note}) async {
    calls.add('access $enabled ${(methods ?? const []).join(',')}');
    this.enabled = enabled;
    if (methods != null) this.methods = methods;
  }

  @override
  Future<void> addPaymentNumber(String customerId, {required String method, required String phone, String? label}) async {
    calls.add('add $method $phone ${label ?? '-'}');
  }

  @override
  Future<void> setPaymentNumberBlocked(String numberId, bool blocked) async {
    calls.add('block $numberId $blocked');
    this.blocked = blocked;
  }

  @override
  Future<void> removePaymentNumber(String numberId) async {
    calls.add('remove $numberId');
    removed = true;
  }
}

Future<_FakeApi> _pump(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  testWidgets('the list: who is authorized, for which networks; filters and search call the server', (tester) async {
    final api = await _pump(tester, const PaymentNumbersScreen());
    expect(find.text('Ahmed Ali'), findsOneWidget);
    expect(find.text('Not authorized'), findsOneWidget);
    expect(find.text('1 number on file'), findsOneWidget);
    await tester.tap(find.text('Authorized'));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'list authorized ');
    await tester.enterText(find.byType(TextField).first, '6112');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'list authorized 6112');
  });

  testWidgets('a customer is authorized for chosen networks, then revoked; the numbers stay listed', (tester) async {
    final api = await _pump(tester, const CustomerPaymentNumbersScreen(customerId: 'c1'));
    expect(find.text('Not authorized'), findsOneWidget);
    expect(find.text('+252612223344 · ZAAD'), findsOneWidget);
    expect(find.textContaining('added by the customer · used 2 times'), findsOneWidget);

    await tester.tap(find.byKey(const Key('network-golis')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('grant-access')));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'access true evc_plus,telesom,edahab');
    expect(find.text('Authorized'), findsOneWidget);
    expect(find.byKey(const Key('revoke-access')), findsOneWidget);

    await tester.tap(find.byKey(const Key('revoke-access')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'access false ');
    expect(find.text('Not authorized'), findsOneWidget);
    expect(find.text('+252612223344 · ZAAD'), findsOneWidget, reason: 'kept for the admin');
  });

  testWidgets('a number is blocked, unblocked, removed and added', (tester) async {
    final api = await _pump(tester, const CustomerPaymentNumbersScreen(customerId: 'c1'));
    await tester.tap(find.byKey(const Key('block-n1')));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'block n1 true');
    expect(find.text('Blocked'), findsOneWidget);
    await tester.tap(find.byKey(const Key('block-n1')));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'block n1 false');

    await tester.enterText(find.byKey(const Key('new-number-phone')), '612345678');
    await tester.enterText(find.byKey(const Key('new-number-label')), 'Wife');
    await tester.tap(find.byKey(const Key('add-number')));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'add evc_plus 612345678 Wife');

    await tester.tap(find.byKey(const Key('remove-n1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'remove n1');
    expect(find.byKey(const Key('no-numbers')), findsOneWidget);
  });
}
