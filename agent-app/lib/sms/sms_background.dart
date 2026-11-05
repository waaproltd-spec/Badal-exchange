import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../api/agent_api.dart';
import '../api/api_client.dart';
import '../l10n/tr.dart';
import '../models/match_result.dart';
import '../models/sms_transaction_log.dart';
import '../services/device_identity.dart';
import '../services/sms_log_store.dart';
import 'sms_bridge.dart';

/// Reads the SMS that arrive while the app is not on screen.
///
/// The Android receiver (SmsReceiver.kt) wakes up for every SMS even when the app is closed. When the app
/// itself is not running it starts a small headless Flutter engine that runs [smsBackgroundMain]: it takes
/// the SMS the receiver kept, runs them through the same pipeline as the open app (Sahal's access code is
/// handed to the server, which enters it into the Sahal sign-in; payment SMS are uploaded) and says
/// `done`, after which the engine is shut down. Nothing is shown and nothing is typed.
///
/// Limits of Android: a force-stopped app, a phone that restricts the app's battery use, or an SMS read
/// permission that was taken away receive nothing; the inbox rescan on the next start then picks the
/// SMS up (an access code is only good for 10 minutes).
const MethodChannel _channel = MethodChannel('com.badalexchange.agent/sms_background');

@pragma('vm:entry-point')
Future<void> smsBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  var handled = 0;
  try {
    await ApiClient.initialize();
    final payloads = (await _channel.invokeMethod<List<dynamic>>('take')) ?? const [];
    final deviceId = await DeviceIdentity.instance.getOrCreateDeviceId();
    handled = await SmsBackground.process(payloads, api: AgentApi(), deviceId: deviceId);
  } catch (e) {
    // Never the SMS text; only that it went wrong.
    debugPrint('smsBackgroundMain: ${e.runtimeType}');
  } finally {
    try {
      await _channel.invokeMethod('done', handled);
    } catch (_) {}
  }
}

class SmsBackground {
  SmsBackground._();

  /// Runs the SMS the receiver kept through the pipeline. Returns how many were handled. Nothing is done
  /// without a signed-in agent (the server would refuse anyway), and one SMS that fails never stops the
  /// others (an upload that fails on the network is queued by the pipeline and retried).
  static Future<int> process(
    List<dynamic> payloads, {
    required AgentApi api,
    required String deviceId,
    SmsBridge? bridge,
    Duration sessionWait = const Duration(seconds: 6),
  }) async {
    // The saved login is read while the engine starts: give it a moment before saying nobody is signed in.
    final deadline = DateTime.now().add(sessionWait);
    while (!api.client.hasSession && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!api.client.hasSession) {
      debugPrint('SmsBackground: no signed-in agent, ${payloads.length} SMS left for the inbox rescan');
      if (payloads.isNotEmpty) await _note(tr('Could not read an SMS in the background: sign in to the Agent App again.'));
      return 0;
    }
    final pipeline = bridge ?? SmsBridge(api: api);
    var handled = 0;
    for (final p in payloads) {
      final sms = PendingSms.fromNative(p, deviceId: deviceId);
      if (sms == null) continue;
      try {
        await pipeline.handleSms(sms);
        handled++;
      } catch (e) {
        debugPrint('SmsBackground: one SMS failed (${e.runtimeType})');
      }
    }
    return handled;
  }

  /// A line in SMS Transactions, so a manager can see that the background read went wrong (never the SMS).
  static Future<void> _note(String message) async {
    try {
      await SmsLogStore.instance.add(SmsTransactionLog(
        id: 'bg-${DateTime.now().microsecondsSinceEpoch}',
        provider: 'SMS',
        sender: null,
        amount: '',
        transactionRef: '',
        occurredAt: DateTime.now(),
        submittedAt: DateTime.now(),
        status: MatchStatus.error,
        orderId: null,
        errorMessage: message,
      ));
    } catch (_) {}
  }
}
