// End-to-end check of CustomerApi against a running Supabase stack. Skipped
// unless SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY are set, e.g. after
// `supabase start`:
//   SUPABASE_E2E_URL=http://127.0.0.1:54321 SUPABASE_E2E_ANON_KEY=<publishable key> flutter test test/supabase_e2e_test.dart
import 'dart:io';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final url = Platform.environment['SUPABASE_E2E_URL'];
  final key = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final skip = (url == null || key == null) ? 'set SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY' : null;

  SupabaseClient newClient() => SupabaseClient(url!, key!, authOptions: const AuthClientOptions(autoRefreshToken: false));

  test('customer flow: register, login, deposit, live update, orders', () async {
    final phone = '2527${DateTime.now().millisecondsSinceEpoch % 100000000}';
    final client = ApiClient(supabase: newClient());
    final api = CustomerApi(client);

    await api.loadMethodCatalog();
    await api.register(phone: phone, name: 'Flutter E2E', password: 'Flutter-Pass-1');
    expect(client.hasSession, isTrue);

    final wallet = await api.getWallet();
    expect(wallet.availableBalance, '0.00');

    final methods = await api.getPaymentMethods();
    expect(methods.map((m) => m.info.id), contains('evc_plus'));

    final quote = await api.createQuote(direction: 'deposit', method: 'evc_plus', amount: '12');
    expect(quote.netAmount, '11.80');

    await expectLater(
      api.withdraw(method: 'evc_plus', phoneNumber: phone, amount: '50', idempotencyKey: 'k-${DateTime.now().microsecondsSinceEpoch}'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'INSUFFICIENT_BALANCE').having((e) => e.status, 'status', 400)),
    );

    final changes = <String>[];
    final sub = api.liveChanges.listen(changes.add);
    client.startLive();
    await Future<void>.delayed(const Duration(seconds: 3));

    final order = await api.deposit(
      method: 'evc_plus', phoneNumber: phone, amount: '12', idempotencyKey: 'k-${DateTime.now().microsecondsSinceEpoch}');
    expect(order.status, 'pending');

    // An agent confirms the payment.
    final agent = newClient();
    await agent.auth.signInWithPassword(email: authEmailFor('252610000002'), password: 'ChangeMe123!');
    final match = await agent.rpc('agent_submit_mobile_money_transaction', params: {
      'p_method': 'evc_plus',
      'p_sender_phone': phone,
      'p_amount': '12',
      'p_transaction_ref': 'FL${DateTime.now().millisecondsSinceEpoch}',
      'p_occurred_at': DateTime.now().toUtc().toIso8601String(),
      'p_idempotency_key': 'k-${DateTime.now().microsecondsSinceEpoch}',
    });
    expect(match['status'], 'matched');

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline) && !changes.contains('wallets')) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(changes, containsAll(<String>['orders', 'wallets']));

    expect((await api.getWallet()).availableBalance, '11.80');
    final orders = await api.getOrders();
    expect(orders.first.status, 'completed');
    expect((await api.getOrder(order.id)).status, 'completed');
    await api.getHomeAds();
    await api.getNotifications();

    await sub.cancel();
    await api.logout();
    expect(client.hasSession, isFalse);

    await expectLater(
      api.login(phone: phone, password: 'wrong-password'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid credentials')),
    );
    await expectLater(
      api.login(phone: '252610000002', password: 'ChangeMe123!'), // an agent, not a customer
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid credentials')),
    );
    await api.login(phone: phone, password: 'Flutter-Pass-1');
    expect(await api.verifySession(), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
