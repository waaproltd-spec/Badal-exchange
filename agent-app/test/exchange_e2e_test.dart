// End-to-end check of the exchange flow through the Agent App's own code:
// real carrier SMS text -> SmsBridge (Dalab parsers) -> Supabase matching ->
// ExchangePayoutRunner -> payout reports. Only the phone's USSD session is
// faked (FakePayoutDevice); everything else is the real app and backend.
// Skipped unless SUPABASE_E2E_URL and SUPABASE_E2E_ANON_KEY are set.
import 'dart:io';
import 'dart:math';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_client.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/exchange.dart';
import 'package:badal_agent_app/payout/exchange_payout_runner.dart';
import 'package:badal_agent_app/services/sms_log_store.dart';
import 'package:badal_agent_app/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const payoutPhone = 'e2e-payout-phone';
const pin = '4321';

class FakePayoutDevice implements PayoutDevice {
  final List<String> dialed = [];
  final List<String> pins = [];
  UssdPayoutResult Function(String ussd) next = (ussd) => const UssdPayoutResult(
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
  late ExchangePayoutRunner runner;
  late SupabaseClient customer;
  late String evcToEdahab;
  late String edahabToEvc;

  Future<ExchangeOrder> createOrder(String corridor, String amount, String sender, String receiver) async {
    final j = await customer.rpc('customer_create_exchange_order', params: {
      'p_corridor_id': corridor, 'p_amount': amount, 'p_sender_phone': sender, 'p_receiver_phone': receiver,
      'p_client_request_id': '${digits(8)}-${digits(4)}-4${digits(3)}-a${digits(3)}-${digits(12)}',
    });
    return ExchangeOrder.fromJson(j as Map<String, dynamic>);
  }

  Future<ExchangeOrder> customerOrder(String id) async =>
      ExchangeOrder.fromJson(await customer.rpc('customer_exchange_order', params: {'p_id': id}) as Map<String, dynamic>);

  Future<void> sms(String sender, String body, {int? simSlot}) =>
      bridge.handleSms(PendingSms(sender: sender, body: body, receivedAt: DateTime.now(), simSlot: simSlot, deviceId: payoutPhone));

  setUpAll(() async {
    if (skip != null) return;
    SharedPreferences.setMockInitialValues({});
    await ExchangePayoutRunner.setAutoPayoutEnabled(true);
    api = AgentApi(client: ApiClient(supabase: newClient()));
    await api.login(phone: '252610000002', password: 'ChangeMe123!');
    await api.loadMethodCatalog();
    bridge = SmsBridge(api: api, logStore: SmsLogStore.instance);
    device = FakePayoutDevice();
    runner = ExchangePayoutRunner(api: api, device: device);

    // Payout wallets on "this phone": EVC on SIM 1, eDahab on SIM 2.
    await api.savePayoutWallet(method: 'evc_plus', phoneNumber: evcNumber(), deviceId: payoutPhone, simSlot: 1);
    await api.savePayoutWallet(method: 'edahab', phoneNumber: edahabNumber(), deviceId: payoutPhone, simSlot: 2);
    var settings = await api.getExchangeSettings();
    final mine = settings.payoutWallets.where((w) => w.deviceId == payoutPhone).toList();
    final evcWallet = mine.lastWhere((w) => w.method == 'evc_plus');
    final edahabWallet = mine.lastWhere((w) => w.method == 'edahab');
    await api.setPayoutWalletPin(evcWallet.id, pin);
    await api.setPayoutWalletPin(edahabWallet.id, pin);
    settings = await api.getExchangeSettings();
    for (final c in settings.corridors) {
      await api.saveExchangeCorridor(c,
          rate: 1, feeType: 'percentage', feeValue: 2, minAmount: 0.5, maxAmount: 500,
          payoutWalletId: c.toMethod == 'edahab' ? edahabWallet.id : evcWallet.id, enabled: true);
      if (c.fromMethod == 'evc_plus') {
        evcToEdahab = c.id;
      } else {
        edahabToEvc = c.id;
      }
    }

    // Orders left waiting for a payout by earlier runs would be swept too.
    for (final o in await api.getExchangePayoutQueue()) {
      await api.reverseExchangeOrder(o.id, reason: 'e2e cleanup');
    }

    final phone = '2526${digits(8)}';
    customer = newClient();
    await customer.rpc('register_customer', params: {'p_phone': phone, 'p_name': 'Exchange E2E', 'p_password': 'Customer-Pass-1'});
    await customer.auth.signInWithPassword(email: authEmailFor(phone), password: 'Customer-Pass-1');
  });

  test('EVC Plus: order first, real SMS (0-prefixed phone, no reference) verifies it, payout completes once', () async {
    final sender = evcNumber();
    final receiver = edahabNumber();
    final order = await createOrder(evcToEdahab, '3', sender, receiver);
    expect(order.status, 'pending');
    expect(order.amountReceived, '2.94');

    // Not paid yet: the sweeper must not touch it.
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed, isEmpty);

    await sms('192', '[-EVCPLUS-] waxaad \$3 ka heshay 0$sender, Tar: ${tar()} haraagagu waa \$9.505.', simSlot: 1);
    expect((await customerOrder(order.id)).status, 'in_progress');

    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed, ['*110*$receiver*2*94#']);
    expect(device.pins, [pin]);
    final done = await customerOrder(order.id);
    expect(done.status, 'completed');

    // Sweeping again never pays it twice.
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, 1);
  }, skip: skip);

  test('eDahab: SMS arrives before the order; the order is verified the moment it is created', () async {
    final sender = edahabNumber();
    final receiver = evcNumber();
    await sms('eDahab',
        '4 Dollar Ayaad Ka Heshay Cali Xasan.Code-ka:NA. Lambarka :$sender  Aqanoosiga : PP${digits(6)}.${digits(4)}.F${digits(5)} '
        'Haraagaaga Cusubi Waa: 9.61 Dollar..Tariikh:07-10-2026[-eDahab-Service-]',
        simSlot: 2);
    final order = await createOrder(edahabToEvc, '4', '252$sender', receiver);
    expect(order.status, 'in_progress');

    final before = device.dialed.length;
    final result = await runner.payOrder(order, deviceId: payoutPhone);
    expect(result.completed, isTrue);
    expect(device.dialed.last, '*712*$receiver*3*92#');
    expect(device.dialed.length, before + 1);
    expect((await customerOrder(order.id)).status, 'completed');
  }, skip: skip);

  test('wrong amount, wrong phone and duplicate SMS do not pay', () async {
    final sender = evcNumber();
    final order = await createOrder(evcToEdahab, '5', sender, edahabNumber());
    await sms('192', '[-EVCPLUS-] waxaad \$5.50 ka heshay $sender, Tar: ${tar()}', simSlot: 1);
    await sms('192', '[-EVCPLUS-] waxaad \$5 ka heshay ${evcNumber()}, Tar: ${tar()}', simSlot: 1);
    expect((await customerOrder(order.id)).status, 'pending');

    final body = '[-EVCPLUS-] waxaad \$5 ka heshay $sender, Tar: ${tar()}';
    await sms('192', body, simSlot: 1);
    await sms('192', body, simSlot: 1); // redelivered
    expect((await customerOrder(order.id)).status, 'in_progress');
    final logs = await SmsLogStore.instance.loadAll();
    expect(logs.first.status.name, 'duplicate');
    // Not paid out in this test.
    await api.reverseExchangeOrder(order.id, reason: 'e2e cleanup');
    expect((await customerOrder(order.id)).status, 'cancelled');
  }, skip: skip);

  test('failed payout: order failed, not redialed; retry needs confirmation and never pays twice', () async {
    final sender = evcNumber();
    final receiver = edahabNumber();
    final order = await createOrder(evcToEdahab, '6', sender, receiver);
    await sms('192', '[-EVCPLUS-] waxaad \$6 ka heshay $sender, Tar: ${tar()}', simSlot: 1);

    device.next = (_) => const UssdPayoutResult(
        outcome: 'STEP2_FAILED', step1Status: 'step1_success', step1Text: 'Geli PIN', step2Status: 'failed', step2Text: 'Haraagaagu kuma filna');
    final first = await runner.payOrder(await customerOrder(order.id), deviceId: payoutPhone);
    expect(first.completed, isFalse);
    final failed = await customerOrder(order.id);
    expect(failed.status, 'failed');
    expect(failed.failureReason, contains('kuma filna'));

    final dialsBefore = device.dialed.length;
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dialsBefore, reason: 'a failed order is never redialed on its own');

    await expectLater(api.retryExchangePayout(order.id),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFIRM_NOT_PAID')));
    await api.retryExchangePayout(order.id, confirmedNotPaid: true);

    device.next = (_) => const UssdPayoutResult(
        outcome: 'SUCCESS', step1Status: 'step1_success', step2Status: 'success', step2Text: 'ayaad u warejisay');
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dialsBefore + 1);
    expect((await customerOrder(order.id)).status, 'completed');
    await runner.sweep(deviceId: payoutPhone);
    expect(device.dialed.length, dialsBefore + 1);
    await expectLater(api.retryExchangePayout(order.id, confirmedNotPaid: true), throwsA(isA<ApiException>()));
  }, skip: skip);

  test('unclear payout result: the carrier\'s payout SMS on the payout phone completes it', () async {
    final sender = edahabNumber();
    final receiver = evcNumber();
    final order = await createOrder(edahabToEvc, '7', sender, receiver);
    await sms('eDahab',
        '7 Dollar Ayaad Ka Heshay Cali.Code-ka:NA. Lambarka :$sender  Aqanoosiga : PP${digits(6)}.${digits(4)}.A${digits(5)} [-eDahab-Service-]',
        simSlot: 2);
    expect((await customerOrder(order.id)).status, 'in_progress');

    device.next = (_) => const UssdPayoutResult(
        outcome: 'TIMEOUT', step1Status: 'step1_success', step2Status: 'ambiguous', step2Text: 'No final confirmation received after entering the PIN.');
    await runner.payOrder(await customerOrder(order.id), deviceId: payoutPhone);
    expect((await customerOrder(order.id)).status, 'failed');

    await sms('192', '[-EVCPLUS-] \$6.86 ayaad uwareejisay CALI XASAN ($receiver), Tar: ${tar()}, Haraagaagu waa \$36.965.');
    final done = await customerOrder(order.id);
    expect(done.status, 'completed');
  }, skip: skip);
}
