// End-to-end check of Dalab-Reseller-style deposits and withdrawals through
// the Agent App's own code: real carrier SMS text -> SmsBridge (Dalab
// parsers) -> Supabase matching -> wallet credit; withdrawal -> PayoutRunner
// -> payout reports -> wallet debit. Only the phone's USSD session is faked
// (FakePayoutDevice). Skipped unless SUPABASE_E2E_URL and
// SUPABASE_E2E_ANON_KEY are set.
import 'dart:io';
import 'dart:math';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_client.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/payout/payout_runner.dart';
import 'package:badal_agent_app/services/sms_log_store.dart';
import 'package:badal_agent_app/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const payoutPhone = 'payout-phone';
const pin = '4321';

class FakePayoutDevice implements PayoutDevice {
  final List<String> dialed = [];
  final List<String> pins = [];
  UssdPayoutResult Function(String ussd) next = (_) => const UssdPayoutResult(
        outcome: 'SUCCESS',
        step1Status: 'step1_success',
        step1Text: 'Fadlan geli PIN-kaaga',
        step2Status: 'success',
        step2Text: '[-EVCPLUS-] ayaad uwareejisay',
      );

  @override
  Future<PayoutDeviceStatus> status() async => const PayoutDeviceStatus(accessibilityEnabled: true, permissionsGranted: true);

  @override
  Future<UssdPayoutResult> runPayout({required int simSlot, required String ussd, required String pin}) async {
    dialed.add(ussd);
    pins.add(pin);
    return next(ussd);
  }

  @override
  Future<void> openAccessibilitySettings() async {}
}

void main() {
  final url = Platform.environment['SUPABASE_E2E_URL'];
  final key = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final skip = (url == null || key == null) ? 'set SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY' : null;
  final rnd = Random();

  SupabaseClient newClient() => SupabaseClient(url!, key!, authOptions: const AuthClientOptions(autoRefreshToken: false));
  String digits(int n) => List.generate(n, (_) => rnd.nextInt(10)).join();
  String evcNumber() => '61${digits(7)}';
  String edahabNumber() => '62${digits(7)}';
  String tar() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.day)}/${two(n.month)}/${two(n.year % 100)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  late AgentApi api;
  late SmsBridge bridge;
  late FakePayoutDevice device;
  late PayoutRunner runner;
  late SupabaseClient customer;

  Future<Map<String, dynamic>> deposit(String method, String amount, String phone) async =>
      await customer.rpc('customer_create_deposit', params: {
        'p_method': method, 'p_amount': amount, 'p_phone_number': phone, 'p_idempotency_key': const Uuid().v4(),
      }) as Map<String, dynamic>;
  Future<Map<String, dynamic>> withdraw(String method, String amount, String phone) async =>
      await customer.rpc('customer_create_withdrawal', params: {
        'p_method': method, 'p_amount': amount, 'p_phone_number': phone, 'p_idempotency_key': const Uuid().v4(),
      }) as Map<String, dynamic>;
  Future<Map<String, dynamic>> order(String id) async =>
      await customer.rpc('customer_order', params: {'p_id': id}) as Map<String, dynamic>;
  Future<String> balance() async => (await customer.rpc('customer_wallet') as Map<String, dynamic>)['availableBalance'] as String;

  Future<void> sms(String sender, String body, {int? simSlot}) =>
      bridge.handleSms(PendingSms(sender: sender, body: body, receivedAt: DateTime.now(), simSlot: simSlot, deviceId: payoutPhone));
  Future<void> evcPayment(String amount, String from) =>
      sms('192', '[-EVCPLUS-] waxaad \$$amount ka heshay 0$from, Tar: ${tar()} haraagagu waa \$9.505.', simSlot: 1);
  Future<void> edahabPayment(String amount, String from) => sms('eDahab',
      '$amount Dollar Ayaad Ka Heshay Cali Xasan.Code-ka:NA. Lambarka :$from  Aqanoosiga : PP${digits(6)}.${digits(4)}.F${digits(5)} '
      'Haraagaaga Cusubi Waa: 9.61 Dollar..Tariikh:07-10-2026[-eDahab-Service-]',
      simSlot: 2);

  setUpAll(() async {
    if (skip != null) return;
    SharedPreferences.setMockInitialValues({});
    await PayoutRunner.setAutoPayoutEnabled(true);
    api = AgentApi(client: ApiClient(supabase: newClient()));
    await api.login(phone: '252610000002', password: 'ChangeMe123!');
    await api.loadMethodCatalog();
    bridge = SmsBridge(api: api, logStore: SmsLogStore.instance);
    device = FakePayoutDevice();
    runner = PayoutRunner(api: api, device: device);

    // Baari's EVC Plus (SIM 1) and eDahab (SIM 2) wallets on "this phone".
    for (final (method, slot) in [('evc_plus', 1), ('edahab', 2)]) {
      var wallets = (await api.getPayoutWallets()).where((w) => w.method == method).toList();
      if (wallets.isEmpty) {
        await api.savePayoutWallet(method: method, phoneNumber: method == 'edahab' ? edahabNumber() : evcNumber());
        wallets = (await api.getPayoutWallets()).where((w) => w.method == method).toList();
      }
      final w = wallets.first; // the oldest: the one withdrawals are paid from
      await api.savePayoutWallet(id: w.id, method: method, phoneNumber: w.phoneNumber, deviceId: payoutPhone, simSlot: slot);
      await api.setPayoutWalletPin(w.id, pin);
    }
    // Withdrawals left waiting by earlier runs would be swept too.
    for (final o in await api.getPayoutQueue()) {
      await api.failWithdrawal(o.id, reason: 'e2e cleanup');
    }

    final phone = '2526${digits(8)}';
    customer = newClient();
    await customer.rpc('register_customer', params: {'p_phone': phone, 'p_name': 'Payments E2E', 'p_password': 'Customer-Pass-1'});
    await customer.auth.signInWithPassword(email: authEmailFor(phone), password: 'Customer-Pass-1');
  });

  test('EVC Plus deposit: the real SMS (0-prefixed phone, no reference) credits the wallet once', () async {
    final from = evcNumber();
    final d = await deposit('evc_plus', '30', '252$from');
    expect(d['status'], 'pending');
    await evcPayment('30', from);
    final done = await order(d['id'] as String);
    expect(done['status'], 'completed');
    final credited = await balance();
    expect(credited, done['netAmount']);
    // The same SMS redelivered: logged as a duplicate, nothing credited again.
    final body = '[-EVCPLUS-] waxaad \$30 ka heshay 0$from, Tar: ${tar()}';
    await sms('192', body, simSlot: 1);
    await sms('192', body, simSlot: 1);
    expect(await balance(), credited);
  }, skip: skip);

  test('eDahab: SMS arrives before the deposit order; the order completes when created', () async {
    final before = double.parse(await balance());
    final from = edahabNumber();
    await edahabPayment('20', from);
    final d = await deposit('edahab', '20', from);
    expect(d['status'], 'completed');
    expect(double.parse(await balance()), greaterThan(before));
  }, skip: skip);

  test('wrong amount and wrong phone never credit', () async {
    final from = evcNumber();
    final d = await deposit('evc_plus', '5', from);
    await evcPayment('5.50', from);
    await evcPayment('5', evcNumber());
    expect((await order(d['id'] as String))['status'], 'pending');
  }, skip: skip);

  test('withdrawal: paid out automatically from the agent phone, debited once, never twice', () async {
    final to = edahabNumber();
    final w = await withdraw('edahab', '10', to);
    final afterReserve = await balance();
    await runner.sweep(deviceId: payoutPhone);
    final net = double.parse(w['netAmount'] as String);
    final cents = ((net - net.truncate()) * 100).round();
    expect(device.dialed.last, '*110*$to*${net.truncate()}${cents == 0 ? '' : '*${cents.toString().padLeft(2, '0')}'}#');
    expect(device.pins.last, pin);
    expect((await order(w['id'] as String))['status'], 'completed');
    expect(await balance(), afterReserve);
    final dials = device.dialed.length;
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dials);
  }, skip: skip);

  test('payout fails after the PIN: held, not redialed; retry needs confirmation and pays once', () async {
    final w = await withdraw('evc_plus', '6', evcNumber());
    final id = w['id'] as String;
    device.next = (_) => const UssdPayoutResult(
        outcome: 'STEP2_FAILED', step1Status: 'step1_success', step1Text: 'Geli PIN', step2Status: 'failed', step2Text: 'Haraagaagu kuma filna');
    await runner.sweep(deviceId: payoutPhone);
    final held = await order(id);
    expect(held['status'], 'processing');
    final dials = device.dialed.length;
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dials, reason: 'never redialed on its own');
    await expectLater(api.failWithdrawal(id, reason: 'carrier said no'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFIRM_NOT_PAID')));
    await expectLater(api.retryPayout(id), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFIRM_NOT_PAID')));
    expect((await api.getPayouts(reviewOnly: true)).map((o) => o.id), contains(id));

    await api.retryPayout(id, confirmedNotPaid: true);
    device.next = (_) => const UssdPayoutResult(
        outcome: 'SUCCESS', step1Status: 'step1_success', step2Status: 'success', step2Text: 'ayaad uwareejisay');
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dials + 1);
    expect((await order(id))['status'], 'completed');
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dials + 1);
    final detail = await api.getPayout(id);
    expect(detail.dialAttempts.where((a) => a.status == 'success').length, 1);
  }, skip: skip);

  test('payout fails before the PIN: withdrawal failed and the customer refunded', () async {
    final before = await balance();
    final w = await withdraw('edahab', '4', edahabNumber());
    device.next = (_) => const UssdPayoutResult(outcome: 'TIMEOUT', step1Status: 'failed', step1Text: 'No response from the carrier');
    await runner.sweep(deviceId: payoutPhone);
    expect((await order(w['id'] as String))['status'], 'failed');
    expect(await balance(), before);
  }, skip: skip);

  test('unclear payout: the carrier\'s "you transferred" SMS on the payout phone completes it', () async {
    final to = evcNumber();
    final w = await withdraw('evc_plus', '7', to);
    device.next = (_) => const UssdPayoutResult(
        outcome: 'TIMEOUT', step1Status: 'step1_success', step2Status: 'ambiguous', step2Text: 'No final confirmation received');
    await runner.sweep(deviceId: payoutPhone);
    expect((await order(w['id'] as String))['status'], 'processing');
    await sms('192', '[-EVCPLUS-] \$${w['netAmount']} ayaad uwareejisay CALI XASAN ($to), Tar: ${tar()}, Haraagaagu waa \$36.965.');
    expect((await order(w['id'] as String))['status'], 'completed');
  }, skip: skip);
}
