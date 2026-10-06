// End-to-end check of AgentApi against a running Supabase stack. Skipped
// unless SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY are set, e.g. after
// `supabase start`:
//   SUPABASE_E2E_URL=http://127.0.0.1:54321 SUPABASE_E2E_ANON_KEY=<publishable key> flutter test test/supabase_e2e_test.dart
import 'dart:io';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_client.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/match_result.dart';
import 'package:badal_agent_app/state/live_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final url = Platform.environment['SUPABASE_E2E_URL'];
  final key = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final skip = (url == null || key == null) ? 'set SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY' : null;

  SupabaseClient newClient() => SupabaseClient(url!, key!, authOptions: const AuthClientOptions(autoRefreshToken: false));
  String uniq() => '${DateTime.now().microsecondsSinceEpoch}';

  test('agent flow: login, console, confirm deposit, withdrawals, management', () async {
    final client = ApiClient(supabase: newClient());
    final api = AgentApi(client: client);

    await expectLater(
      api.login(phone: '252610000003', password: 'ChangeMe123!'), // a customer, not an agent
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid credentials')),
    );
    final me = await api.login(phone: '252610000002', password: 'ChangeMe123!');
    expect(me.name, 'Demo Agent');
    await api.loadMethodCatalog();
    await api.registerDevice(deviceId: 'e2e-device-1', deviceLabel: 'E2E');

    final live = LiveUpdates(() => client.supabase)..start();
    final changes = <String>[];
    final sub = live.changes.listen(changes.add);
    await Future<void>.delayed(const Duration(seconds: 3));

    // A customer places a deposit and a withdrawal.
    final phone = '2528${DateTime.now().millisecondsSinceEpoch % 100000000}';
    final customer = newClient();
    await customer.rpc('register_customer', params: {'p_phone': phone, 'p_name': 'Agent E2E', 'p_password': 'Customer-Pass-1'});
    await customer.auth.signInWithPassword(email: authEmailFor(phone), password: 'Customer-Pass-1');
    await customer.rpc('customer_create_deposit', params: {
      'p_method': 'edahab', 'p_amount': '30', 'p_phone_number': phone, 'p_idempotency_key': uniq()});

    final pending = await api.getPendingDeposits();
    expect(pending.any((o) => o.phoneNumber == phone), isTrue);

    final result = await api.submitMobileMoneyTransaction(
      method: 'edahab', senderPhone: phone, amount: '30', transactionRef: 'ED${uniq()}', occurredAt: DateTime.now());
    expect(result.status, MatchStatus.matched);

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline) && !changes.contains('orders')) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(changes, contains('orders'));

    final withdrawal = await customer.rpc('customer_create_withdrawal', params: {
      'p_method': 'edahab', 'p_amount': '10', 'p_phone_number': phone, 'p_idempotency_key': uniq()});
    final started = await api.startWithdrawal(withdrawal['id'] as String);
    expect(started.status, 'processing');
    final done = await api.completeWithdrawal(withdrawal['id'] as String, transactionRef: 'PAY${uniq()}');
    expect(done.status, 'completed');

    final dash = await api.getDashboard();
    expect(dash.totalTransactions, greaterThan(0));
    final customers = await api.getCustomers(query: phone);
    expect(customers.single.phone, phone);
    final detail = await api.getCustomer(customers.single.id);
    expect(detail.recentOrders, isNotEmpty);
    expect(await api.getCustomerLedger(customers.single.id), isNotEmpty);
    final report = await api.getReport(period: 'monthly');
    expect(report.series.length, 30);
    final history = await api.getHistory(query: phone);
    expect(history, isNotEmpty);
    expect((await api.getHistory(type: 'confirmation')).every((h) => h.kind == 'confirmation'), isTrue);
    final account = await api.getAccount();
    expect(account.canManageSettings, isTrue);

    // Management (Account -> Admin features).
    final methods = await api.getMethodSettings();
    expect(methods.length, 10);
    await api.setMethodEnabled('golis', false);
    await api.setMethodEnabled('golis', true);
    await api.setRate('evc_plus', 'withdraw', 1.0);
    await api.setFee('evc_plus', 'withdraw', type: 'percent', value: 1);
    await api.setWithdrawalLimits('evc_plus', min: 1, max: 500);
    await api.saveHomeAd(title: 'E2E ad', enabled: true);
    final ad = (await api.getHomeAds()).firstWhere((a) => a.title == 'E2E ad');
    await api.deleteHomeAd(ad.id);
    await api.saveDepositNumber(method: 'edahab', number: '61${uniq().substring(8)}', enabled: true);
    expect(await api.getDepositNumbers(), isNotEmpty);
    await api.sendNotification(title: 'E2E', body: 'Hello from the agent app test');
    expect((await api.getSentNotifications()).first.title, 'E2E');
    await api.saveContacts(account.contacts);
    expect(await api.getAgents(), isNotEmpty);
    expect(await api.getIntegrations(), hasLength(2));
    await api.testIntegration('evc_plus');
    expect(await api.getAuditLogs(), isNotEmpty);
    expect(await api.getAllWalletTransactions(), isNotEmpty);
    expect((await api.getProfile()).name, 'Demo Agent');

    await sub.cancel();
    await live.stop();
    await client.signOut(); // api.logout() also clears the device keystore
    expect(client.hasSession, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
