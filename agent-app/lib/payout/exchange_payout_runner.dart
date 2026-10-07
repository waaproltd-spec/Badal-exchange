import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../models/exchange.dart';

/// What the phone's own USSD automation can do right now.
class PayoutDeviceStatus {
  final bool accessibilityEnabled;
  final bool permissionsGranted;

  const PayoutDeviceStatus({required this.accessibilityEnabled, required this.permissionsGranted});

  bool get ready => accessibilityEnabled && permissionsGranted;
}

/// Result of one carrier USSD session, as reported by the native side
/// (android/.../payout/PayoutChannel.kt). Statuses are the backend's:
/// step 1 `step1_success | failed | ambiguous`, step 2 `success | failed |
/// ambiguous` (null when step 2 never started, i.e. no PIN was entered).
class UssdPayoutResult {
  final String outcome;
  final String step1Status;
  final String? step1Text;
  final String? step2Status;
  final String? step2Text;

  const UssdPayoutResult({
    required this.outcome,
    required this.step1Status,
    this.step1Text,
    this.step2Status,
    this.step2Text,
  });

  factory UssdPayoutResult.fromMap(Map<dynamic, dynamic> m) => UssdPayoutResult(
        outcome: m['outcome'] as String? ?? 'STEP1_FAILED',
        step1Status: m['step1Status'] as String? ?? 'failed',
        step1Text: m['step1Text'] as String?,
        step2Status: m['step2Status'] as String?,
        step2Text: m['step2Text'] as String?,
      );
}

/// The phone side of a payout. [NativePayoutDevice] in the app; a fake in tests.
abstract class PayoutDevice {
  Future<PayoutDeviceStatus> status();
  Future<UssdPayoutResult> runPayout({required int simSlot, required String ussd, required String pin});
  Future<void> openAccessibilitySettings();
}

class NativePayoutDevice implements PayoutDevice {
  static const MethodChannel _channel = MethodChannel('com.badalexchange.agent/payout');

  @override
  Future<PayoutDeviceStatus> status() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('status') ?? const {};
      return PayoutDeviceStatus(
        accessibilityEnabled: m['accessibilityEnabled'] as bool? ?? false,
        permissionsGranted: m['permissionsGranted'] as bool? ?? false,
      );
    } on MissingPluginException {
      return const PayoutDeviceStatus(accessibilityEnabled: false, permissionsGranted: false);
    }
  }

  @override
  Future<UssdPayoutResult> runPayout({required int simSlot, required String ussd, required String pin}) async {
    final m = await _channel.invokeMethod<Map<dynamic, dynamic>>('runPayout', {'simSlot': simSlot, 'ussd': ussd, 'pin': pin});
    return UssdPayoutResult.fromMap(m ?? const {});
  }

  @override
  Future<void> openAccessibilitySettings() => _channel.invokeMethod<void>('openAccessibilitySettings');
}

class PayoutOutcome {
  final bool completed;
  final String message;

  const PayoutOutcome(this.completed, this.message);
}

/// Exchange payout engine, port of Dalab Internet's ExchangeUssdOrchestrator
/// + ExchangeSelfHealSweeper:
///
///  1. `agent_exchange_start_dial` locks the order, refuses anything that is
///     not a verified (in progress) order or already paid, and returns a new
///     attempt with the payout wallet's PIN. An unfinished earlier attempt
///     comes back without the PIN, so it can never be dialed twice.
///  2. The phone runs the carrier's USSD transfer (number + amount, then the
///     PIN when the carrier asks for it).
///  3. Each step is reported back. Success completes the order; anything
///     else fails it, and a failure after the PIN step needs a manager to
///     confirm "not paid" before a retry. A report that can't reach the
///     server is queued and replayed (the server ignores repeats).
///
/// The sweeper pays verified orders automatically, one at a time, but only
/// orders whose payout wallet is set to this phone, never an order that was
/// already dialed (unless a manager asked for another try), and only while
/// automatic payouts are switched on for this phone.
class ExchangePayoutRunner {
  ExchangePayoutRunner({required AgentApi api, PayoutDevice? device})
      : _api = api,
        device = device ?? NativePayoutDevice();

  static const _reportQueueKey = 'baari_exchange_report_queue_v1';
  static const _autoKey = 'baari_exchange_auto_payout';

  final AgentApi _api;
  final PayoutDevice device;
  final Set<String> _inFlight = {};
  Timer? _timer;
  String? _deviceId;
  bool _sweeping = false;

  bool get isRunning => _timer != null;

  static Future<bool> autoPayoutEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoKey) ?? false;
  }

  static Future<void> setAutoPayoutEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoKey, on);
  }

  /// Starts the automatic sweep (every 30 seconds) for this phone.
  void start({required String deviceId}) {
    _deviceId = deviceId;
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => sweep());
    unawaited(sweep());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass: replay queued reports, then pay what this phone should pay.
  Future<void> sweep({String? deviceId}) async {
    deviceId ??= _deviceId;
    if (_sweeping || deviceId == null) return;
    _sweeping = true;
    try {
      await flushReports();
      if (!await autoPayoutEnabled()) return;
      if (!(await device.status()).ready) return;
      final queue = await _api.getExchangePayoutQueue();
      final payable = queue.where((o) =>
          o.payoutDeviceId == deviceId && (!o.hasDialAttempt || o.payoutRequested));
      for (final order in payable) {
        await payOrder(order, deviceId: deviceId);
      }
    } catch (_) {
      // Network trouble: the next pass tries again.
    } finally {
      _sweeping = false;
    }
  }

  /// Pays one verified order from this phone.
  Future<PayoutOutcome> payOrder(ExchangeOrder order, {required String deviceId}) async {
    if (!_inFlight.add(order.id)) {
      return const PayoutOutcome(false, 'This payout is already running on this phone.');
    }
    try {
      final status = await device.status();
      if (!status.accessibilityEnabled) {
        return const PayoutOutcome(false, 'Automatic payout is not enabled on this phone. Turn on "Baari exchange payouts" in Accessibility settings.');
      }
      if (!status.permissionsGranted) {
        return const PayoutOutcome(false, 'Phone and call permissions are needed to send payouts.');
      }

      final ExchangeDialStart start;
      try {
        start = await _api.startExchangeDial(order.id, deviceId: deviceId);
      } on ApiException catch (e) {
        return PayoutOutcome(false, e.message);
      }
      final pin = start.pin;
      if (!start.isNew || pin == null) {
        return const PayoutOutcome(false,
            'An earlier payout attempt for this order has not reported its result yet. It is not dialed again; '
            'if the phone never reports, the order goes to manager review after 10 minutes.');
      }

      UssdPayoutResult result;
      try {
        result = await device.runPayout(simSlot: start.simSlot, ussd: start.ussd, pin: pin);
      } catch (e) {
        // Unknown whether the PIN reached the carrier: unclear, so a retry
        // needs a manager to confirm the money did not go out.
        await _report(start.attemptId, 2, 'ambiguous', 'The app failed during the payout: $e');
        return const PayoutOutcome(false, 'The payout was interrupted. Check the payout wallet before retrying.');
      }

      await _report(start.attemptId, 1, result.step1Status, result.step1Text);
      if (result.step1Status == 'step1_success' && result.step2Status != null) {
        await _report(start.attemptId, 2, result.step2Status!, result.step2Text);
      }
      final ok = result.step2Status == 'success';
      return PayoutOutcome(ok, ok ? 'Payout sent.' : (result.step2Text ?? result.step1Text ?? result.outcome));
    } finally {
      _inFlight.remove(order.id);
    }
  }

  Future<void> _report(String attemptId, int step, String status, String? text) async {
    final item = {'attemptId': attemptId, 'step': step, 'status': status, 'response': text};
    if (!await _send(item)) await _enqueue(item);
  }

  /// True when the server took it (or rejected it for good).
  Future<bool> _send(Map<String, dynamic> item) async {
    final attemptId = item['attemptId'] as String;
    final status = item['status'] as String;
    final response = item['response'] as String?;
    try {
      if (item['step'] == 1) {
        await _api.reportExchangeStep1(attemptId, status: status, response: response);
      } else {
        await _api.reportExchangeStep2(attemptId, status: status, response: response);
      }
      return true;
    } on ApiException catch (e) {
      return !(e.isNetworkError || e.statusCode >= 500 || e.isUnauthorized);
    } catch (_) {
      return false;
    }
  }

  Future<void> _enqueue(Map<String, dynamic> item) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _decode(prefs.getString(_reportQueueKey))..add(item);
    await prefs.setString(_reportQueueKey, jsonEncode(list));
  }

  /// Replays queued step reports in order (step 1 before step 2).
  Future<void> flushReports() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _decode(prefs.getString(_reportQueueKey));
    if (list.isEmpty) return;
    final remaining = <Map<String, dynamic>>[];
    for (final item in list) {
      final blocked = remaining.any((r) => r['attemptId'] == item['attemptId']);
      if (blocked || !await _send(item)) remaining.add(item);
    }
    await prefs.setString(_reportQueueKey, jsonEncode(remaining));
  }

  static List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}
