// End-to-end check of the customer's exchange screens' API calls against a
// running Supabase stack (skipped unless SUPABASE_E2E_URL and
// SUPABASE_E2E_ANON_KEY are set). The agent side is driven with raw RPCs.
import 'dart:io';
import 'dart:math';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

void main() {
  final url = Platform.environment['SUPABASE_E2E_URL'];
  final key = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final skip = (url == null || key == null) ? 'set SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY' : null;
  final rnd = Random();
  String digits(int n) => List.generate(n, (_) => rnd.nextInt(10)).join();

  SupabaseClient newClient() => SupabaseClient(url!, key!, authOptions: const AuthClientOptions(autoRefreshToken: false));

  test('exchange: options, quote, order with 0-prefixed numbers, live verification', () async {
    // Agent sets up an EVC Plus -> eDahab exchange.
    final agent = newClient();
    await agent.auth.signInWithPassword(email: authEmailFor('252610000002'), password: 'ChangeMe123!');
    final evc = await agent.rpc('manage_save_payout_wallet',
        params: {'p_id': null, 'p_method': 'evc_plus', 'p_phone_number': '61${digits(7)}'}) as Map<String, dynamic>;
    final edahab = await agent.rpc('manage_save_payout_wallet',
        params: {'p_id': null, 'p_method': 'edahab', 'p_phone_number': '62${digits(7)}'}) as Map<String, dynamic>;
    final settings = await agent.rpc('manage_exchange_settings') as Map<String, dynamic>;
    for (final c in (settings['corridors'] as List).cast<Map<String, dynamic>>()) {
      await agent.rpc('manage_save_exchange_corridor', params: {
        'p_id': c['id'], 'p_rate': 1, 'p_fee_type': 'percentage', 'p_fee_value': 2, 'p_min_amount': 0.5,
        'p_max_amount': 500, 'p_payout_wallet_id': c['toMethod'] == 'edahab' ? edahab['id'] : evc['id'], 'p_enabled': true,
      });
    }

    final phone = '2527${digits(8)}';
    final client = ApiClient(supabase: newClient());
    final api = CustomerApi(client);
    await api.register(phone: phone, name: 'Exchange Customer', password: 'Flutter-Pass-1');

    final options = await api.exchangeOptions();
    final option = options.firstWhere((o) => o.fromMethod == 'evc_plus');
    expect(option.toMethod, 'edahab');
    final quote = await api.exchangeQuote(optionId: option.id, amount: '10');
    expect(quote.amountReceived, '9.80');

    final sender = '61${digits(7)}';
    final receiver = '62${digits(7)}';
    final requestId = const Uuid().v4();
    final order = await api.createExchangeOrder(
        optionId: option.id, amount: '10', senderPhone: '0$sender', receiverPhone: '0$receiver', clientRequestId: requestId);
    expect(order.status, 'pending');
    expect(order.senderPhone, sender);
    expect(order.collectionUssd, matches(RegExp(r'^\*712\*\d{9}\*10#$')));
    // A double tap returns the same order.
    final again = await api.createExchangeOrder(
        optionId: option.id, amount: '10', senderPhone: sender, receiverPhone: receiver, clientRequestId: requestId);
    expect(again.id, order.id);

    final changes = <String>[];
    final sub = api.liveChanges.listen(changes.add);
    var connected = false;
    for (var i = 0; i < 5 && !connected; i++) {
      connected = await client.startLive().timeout(const Duration(seconds: 10), onTimeout: () => false);
      if (!connected) {
        client.stopLive();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    expect(connected, isTrue);
    await Future<void>.delayed(const Duration(seconds: 3));

    // The real EVC Plus SMS reaches the agent phone.
    final res = await agent.rpc('agent_ingest_payment_sms', params: {
      'p_sender': '192',
      'p_body': '[-EVCPLUS-] waxaad \$10 ka heshay 0$sender, Tar: ${digits(2)}/10/26 20:19:52',
      'p_received_at': DateTime.now().toUtc().toIso8601String(),
      'p_parsed_provider': 'Hormuud', 'p_parsed_amount': '10', 'p_parsed_phone': '0$sender',
    }) as Map<String, dynamic>;
    expect(res['matchStatus'], 'matched');

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline) && !changes.contains('exchange_orders')) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(changes, contains('exchange_orders'));
    expect((await api.exchangeOrder(order.id)).status, 'in_progress');
    expect((await api.exchangeOrders()).map((o) => o.id), contains(order.id));

    await sub.cancel();
    client.stopLive();
    // Leave nothing waiting for a payout on the shared test database.
    await agent.rpc('manage_exchange_reverse', params: {'p_id': order.id, 'p_reason': 'e2e cleanup'});
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
