import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../models/match_result.dart';
import '../models/sms_transaction_log.dart';
import '../services/sms_log_store.dart';
import 'payment_sms_parsers.dart';

/// Android payment-SMS pipeline, ported from Dalab Internet's SmsReceiver +
/// SmsUploadFlow + PendingActionQueue + SmsInboxScanner:
///
///  1. The native SmsReceiver forwards every inbound SMS with its SIM slot.
///  2. [PaymentSmsParsers.classify] decides what it is:
///     - a customer's incoming payment: uploaded with its parsed provider,
///       amount, phone and reference to `agent_ingest_payment_sms`, which
///       dedupes it and matches it to at most one pending
///       wallet deposit (the backend alone decides);
///     - the payout phone's own "you transferred" SMS: reported to
///       `agent_payout_confirmation` (completes the withdrawal it paid);
///     - unparsed but money-looking: uploaded with no parsed fields, so a
///       manager can see it and resolve it by hand;
///     - anything else (personal texts, OTPs): dropped, never sent.
///  3. An upload that fails on the network or a server error goes to a
///     persistent queue and is retried (on start, every minute, and after
///     the next successful upload). The backend's dedupe (carrier
///     reference, or sender + body + minute) makes a retried or rescanned
///     SMS safe: it can never pay an order twice.
///  4. On start, the inbox is rescanned for the last 24 hours, so payments
///     that arrived while the app was closed are still processed, each with
///     its own SMS timestamp.
class SmsBridge {
  SmsBridge({AgentApi? api, SmsLogStore? logStore})
      : _api = api ?? AgentApi(),
        _logStore = logStore ?? SmsLogStore.instance;

  static const MethodChannel _methodChannel = MethodChannel('com.badalexchange.agent/sms');
  static const EventChannel _eventChannel = EventChannel('com.badalexchange.agent/sms_events');

  static const _queueKey = 'baari_sms_pending_v1';
  static const _lastScanKey = 'baari_sms_last_inbox_scan_ms';
  static const _maxQueue = 500;
  static const _lookback = Duration(hours: 24);

  final AgentApi _api;
  final SmsLogStore _logStore;
  final Uuid _uuid = const Uuid();

  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  String? _deviceId;
  bool _flushing = false;

  /// Serializes uploads so queue writes never interleave.
  Future<void> _chain = Future.value();

  final StreamController<SmsTransactionLog> _onLogEntry = StreamController.broadcast();
  Stream<SmsTransactionLog> get onLogEntry => _onLogEntry.stream;

  bool get isListening => _subscription != null;

  static bool get isSupportedPlatform => true;

  Future<bool> hasPermission() async => (await Permission.sms.status).isGranted;

  /// Requests SMS access, plus phone state so the SIM slot of each SMS can
  /// be resolved (optional: without it matching uses the device alone).
  Future<bool> requestPermission() async {
    final status = await Permission.sms.request();
    await Permission.phone.request();
    return status.isGranted;
  }

  Future<void> start({required String deviceId}) async {
    if (_subscription != null) return;
    _deviceId = deviceId;
    _subscription = _eventChannel.receiveBroadcastStream().listen(
      (event) => _enqueueWork(() => _handleEvent(event)),
      onError: (Object error, StackTrace stackTrace) => stop(),
      cancelOnError: false,
    );
    _retryTimer = Timer.periodic(const Duration(minutes: 1), (_) => _enqueueWork(_flushQueue));
    _enqueueWork(_flushQueue);
    _enqueueWork(_scanInbox);
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _onLogEntry.close();
  }

  Future<bool> isNativeReceiverEnabled() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isReceiverEnabled') ?? true;
    } on MissingPluginException {
      return false;
    }
  }

  void _enqueueWork(Future<void> Function() work) {
    _chain = _chain.then((_) => work()).catchError((Object _) {});
  }

  /// Runs one SMS through the pipeline (also used by the end-to-end test).
  Future<void> handleSms(PendingSms sms) => _process(sms, fromQueue: false);

  Future<void> _handleEvent(dynamic event) async {
    final sms = PendingSms.fromNative(event, deviceId: _deviceId);
    if (sms == null) return;
    await _process(sms, fromQueue: false);
  }

  /// Dalab SmsInboxScanner: everything since the last scan (at most 24h
  /// back). The cutoff is saved before processing so an interrupted pass
  /// doesn't redo the whole batch.
  Future<void> _scanInbox() async {
    final prefs = await SharedPreferences.getInstance();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(_lastScanKey) ?? 0;
    final cutoff = last > startedAt - _lookback.inMilliseconds ? last : startedAt - _lookback.inMilliseconds;
    List<dynamic>? rows;
    try {
      rows = await _methodChannel.invokeMethod<List<dynamic>>('scanInbox', {'sinceMillis': cutoff});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    await prefs.setInt(_lastScanKey, startedAt);
    for (final row in rows ?? const []) {
      final sms = PendingSms.fromNative(row, deviceId: _deviceId);
      if (sms != null) await _process(sms, fromQueue: false);
    }
  }

  Future<void> _flushQueue() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final queue = await _loadQueue();
      if (queue.isEmpty) return;
      final remaining = <PendingSms>[];
      for (final sms in queue) {
        final outcome = await _process(sms, fromQueue: true);
        if (outcome == _Outcome.retry) remaining.add(sms);
      }
      await _saveQueue(remaining);
    } finally {
      _flushing = false;
    }
  }

  Future<_Outcome> _process(PendingSms sms, {required bool fromQueue}) async {
    final c = PaymentSmsParsers.classify(sms.sender, sms.body);
    if (!c.isRelevant) return _Outcome.done;
    try {
      if (c.payoutSent != null) {
        final sent = c.payoutSent!;
        final res = await _api.reportPayoutConfirmation(
          receiverPhone: sent.receiverPhone,
          amount: sent.amount,
          rawText: sent.rawText,
          provider: sent.provider,
          reference: sent.reference,
          receivedAt: sms.receivedAt,
        );
        final completed = res['result'] == 'completed';
        await _log(
          provider: '${sent.provider} payout',
          phone: sent.receiverPhone,
          amount: sent.amount,
          ref: sent.reference,
          at: sms.receivedAt,
          status: completed ? MatchStatus.matched : MatchStatus.unmatched,
          orderId: res['orderId'] as String?,
          message: completed ? null : res['result'] as String?,
        );
      } else {
        final p = c.payment;
        final res = await _api.ingestPaymentSms(
          sender: sms.sender,
          body: sms.body,
          receivedAt: sms.receivedAt,
          provider: p?.provider,
          amount: p?.amount,
          phone: p?.phone,
          transactionRef: p?.transactionRef,
          simSlot: sms.simSlot,
          deviceId: sms.deviceId,
        );
        if (p != null) {
          final match = res['matchStatus'] as String?;
          final already = res['status'] == 'already_processed';
          await _log(
            provider: p.provider,
            phone: p.phone,
            amount: p.amount,
            ref: p.transactionRef,
            at: sms.receivedAt,
            status: already
                ? MatchStatus.duplicate
                : match == 'matched'
                    ? MatchStatus.matched
                    : MatchStatus.unmatched,
            orderId: res['orderId'] as String?,
            message: match == 'ambiguous'
                ? 'More than one order fits: left for manual review'
                : already
                    ? null
                    : res['reason'] as String?,
          );
        }
      }
      if (!fromQueue) _enqueueWork(_flushQueue);
      return _Outcome.done;
    } on ApiException catch (e) {
      if (e.isNetworkError || e.statusCode >= 500 || e.isUnauthorized) {
        if (!fromQueue) await _addToQueue(sms);
        return _Outcome.retry;
      }
      await _log(
        provider: c.payment?.provider ?? c.payoutSent?.provider ?? 'SMS',
        phone: c.payment?.phone ?? c.payoutSent?.receiverPhone,
        amount: c.payment?.amount ?? c.payoutSent?.amount ?? '',
        ref: c.payment?.transactionRef,
        at: sms.receivedAt,
        status: MatchStatus.error,
        message: e.message,
      );
      return _Outcome.done;
    } catch (_) {
      if (!fromQueue) await _addToQueue(sms);
      return _Outcome.retry;
    }
  }

  Future<void> _log({
    required String provider,
    String? phone,
    required String amount,
    String? ref,
    required DateTime at,
    required MatchStatus status,
    String? orderId,
    String? message,
  }) async {
    final entry = SmsTransactionLog(
      id: _uuid.v4(),
      provider: provider,
      sender: phone,
      amount: amount,
      transactionRef: ref ?? '',
      occurredAt: at,
      submittedAt: DateTime.now(),
      status: status,
      orderId: orderId,
      errorMessage: message,
    );
    await _logStore.add(entry);
    if (!_onLogEntry.isClosed) _onLogEntry.add(entry);
  }

  Future<List<PendingSms>> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => PendingSms.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveQueue(List<PendingSms> queue) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = queue.length > _maxQueue ? queue.sublist(queue.length - _maxQueue) : queue;
    await prefs.setString(_queueKey, jsonEncode(trimmed.map((e) => e.toJson()).toList()));
  }

  Future<void> _addToQueue(PendingSms sms) async {
    final queue = await _loadQueue();
    if (queue.any((q) => q.sameAs(sms))) return;
    queue.add(sms);
    await _saveQueue(queue);
  }
}

enum _Outcome { done, retry }

/// One SMS waiting to be processed (Dalab SmsUploadAction).
class PendingSms {
  PendingSms({
    required this.sender,
    required this.body,
    required this.receivedAt,
    this.simSlot,
    this.deviceId,
  });

  final String sender;
  final String body;
  final DateTime receivedAt;
  final int? simSlot;
  final String? deviceId;

  static PendingSms? fromNative(dynamic event, {String? deviceId}) {
    if (event is! Map) return null;
    final sender = event['sender'] as String?;
    final body = event['body'] as String?;
    if (sender == null || body == null || body.isEmpty) return null;
    final ts = event['timestampMillis'];
    final slot = event['simSlot'];
    return PendingSms(
      sender: sender,
      body: body,
      receivedAt: ts is int && ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now(),
      simSlot: slot is int ? slot : null,
      deviceId: deviceId,
    );
  }

  bool sameAs(PendingSms o) =>
      o.sender == sender && o.body == body && o.receivedAt.isAtSameMomentAs(receivedAt);

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'body': body,
        'receivedAt': receivedAt.toUtc().toIso8601String(),
        'simSlot': simSlot,
        'deviceId': deviceId,
      };

  factory PendingSms.fromJson(Map<String, dynamic> j) => PendingSms(
        sender: j['sender'] as String,
        body: j['body'] as String,
        receivedAt: DateTime.parse(j['receivedAt'] as String),
        simSlot: j['simSlot'] as int?,
        deviceId: j['deviceId'] as String?,
      );
}
