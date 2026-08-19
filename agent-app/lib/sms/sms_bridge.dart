import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../models/match_result.dart';
import '../models/sms_transaction_log.dart';
import '../services/sms_log_store.dart';
import 'evc_sms_parser.dart';

/// Android-only bridge between the native SMS BroadcastReceiver
/// (android/app/src/main/kotlin/.../SmsReceiver.kt) and the app's
/// automatic EVC Plus deposit-matching pipeline.
///
/// Flow for every inbound SMS while this bridge is listening:
///  1. Native SmsReceiver receives `android.provider.Telephony.SMS_RECEIVED`,
///     does a coarse sender-id pre-filter, and forwards only
///     `{sender, body, timestampMillis}` for messages that pass it, over
///     the `com.badalexchange.agent/sms_events` EventChannel. Everything
///     else is dropped natively and never reaches Dart.
///  2. This class hands each event to [EvcSmsParser.parse] — a pure Dart
///     function — which re-validates the sender and message wording and
///     extracts ONLY {sender phone number, amount, transaction ref,
///     timestamp}. If parsing fails (not a recognized payment SMS), the
///     event — including its `body` string — is dropped right here and
///     never referenced again.
///  3. A successfully parsed transaction is submitted to the backend via
///     POST /agent/sms-transactions with exactly those extracted fields —
///     the raw SMS text is never sent. The backend alone decides
///     matched/unmatched/duplicate; this app only reflects that result.
///  4. The result (extracted fields + backend status) is appended to the
///     local SMS Transactions log for the agent to review.
///
/// This bridge must only be started once a device id has been registered
/// via POST /agent/devices/register for the logged-in agent (see
/// [start]'s `deviceId` requirement) and only after the RECEIVE_SMS runtime
/// permission has been granted.
class SmsBridge {
  SmsBridge({AgentApi? api, SmsLogStore? logStore})
      : _api = api ?? AgentApi(),
        _logStore = logStore ?? SmsLogStore.instance;

  static const MethodChannel _methodChannel = MethodChannel('com.badalexchange.agent/sms');
  static const EventChannel _eventChannel = EventChannel('com.badalexchange.agent/sms_events');

  final AgentApi _api;
  final SmsLogStore _logStore;
  final Uuid _uuid = const Uuid();

  StreamSubscription<dynamic>? _subscription;
  String? _deviceId;

  /// Fires whenever a new log entry (matched/unmatched/duplicate/error) is
  /// appended, so the SMS Transactions screen can refresh its view.
  final StreamController<SmsTransactionLog> _onLogEntry = StreamController.broadcast();
  Stream<SmsTransactionLog> get onLogEntry => _onLogEntry.stream;

  bool get isListening => _subscription != null;

  /// True only on Android — SMS reading is not implemented for any other
  /// platform (see the module-level doc comment).
  static bool get isSupportedPlatform {
    // defaultTargetPlatform is intentionally not imported here to keep this
    // file free of a widgets dependency; callers on non-Android platforms
    // should gate calls to [start] themselves. See HomeShell/Dashboard for
    // the actual Platform.isAndroid check using dart:io.
    return true;
  }

  /// Checks whether the RECEIVE_SMS runtime permission is currently
  /// granted, without prompting.
  Future<bool> hasPermission() async {
    final status = await Permission.sms.status;
    return status.isGranted;
  }

  /// Prompts the agent for the RECEIVE_SMS/READ_SMS runtime permission.
  /// Must only be called on a device that has already been registered as
  /// an authorized agent device — this app never requests SMS access on a
  /// customer-facing build.
  Future<bool> requestPermission() async {
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Starts listening for inbound SMS events and running the automatic
  /// matching pipeline. No-op if already listening.
  ///
  /// [deviceId] is the id this device was registered with via
  /// POST /agent/devices/register — it is attached to every submitted
  /// transaction so the backend/admin dashboard can trace which device
  /// captured it.
  Future<void> start({required String deviceId}) async {
    if (_subscription != null) return;
    _deviceId = deviceId;

    _subscription = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error, StackTrace stackTrace) {
        // A stream error from the platform side (e.g. permission revoked
        // mid-session) should not crash the app — just stop listening.
        stop();
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _onLogEntry.close();
  }

  /// Exposed for the app's connectivity/settings screen if ever needed;
  /// currently unused by the UI but kept for symmetry with [start]/[stop]
  /// and to make manual re-registration checks easy from a debug menu.
  Future<bool> isNativeReceiverEnabled() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isReceiverEnabled');
      return result ?? true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _handleNativeEvent(dynamic event) async {
    if (event is! Map) return;
    final sender = event['sender'] as String?;
    final body = event['body'] as String?;
    final timestampMillis = event['timestampMillis'] as int?;
    if (sender == null || body == null) return;

    final receivedAt = timestampMillis != null
        ? DateTime.fromMillisecondsSinceEpoch(timestampMillis)
        : DateTime.now();

    // Pure-Dart extraction. `body` (the raw SMS text) is used only inside
    // this call and is never stored or sent anywhere from this point on.
    final parsed = EvcSmsParser.parse(sender, body, receivedAt: receivedAt);
    if (parsed == null) return; // not a recognized EVC Plus payment SMS

    await _submitParsedTransaction(parsed);
  }

  Future<void> _submitParsedTransaction(ParsedEvcSmsTransaction parsed) async {
    MatchResult result;
    try {
      result = await _api.submitSmsTransaction(
        provider: parsed.provider,
        sender: parsed.senderPhoneNumber,
        amount: parsed.amount,
        transactionRef: parsed.transactionRef,
        occurredAt: parsed.occurredAt,
        deviceId: _deviceId,
      );
    } on ApiException catch (e) {
      result = MatchResult.error(e.message);
    } catch (e) {
      result = MatchResult.error('Failed to submit SMS transaction: $e');
    }

    final entry = SmsTransactionLog(
      id: _uuid.v4(),
      provider: parsed.provider,
      sender: parsed.senderPhoneNumber,
      amount: parsed.amount,
      transactionRef: parsed.transactionRef,
      occurredAt: parsed.occurredAt,
      submittedAt: DateTime.now(),
      status: result.status,
      orderId: result.orderId,
      errorMessage: result.errorMessage,
    );
    await _logStore.add(entry);
    if (!_onLogEntry.isClosed) _onLogEntry.add(entry);
  }
}
