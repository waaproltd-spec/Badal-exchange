package com.badalexchange.agent

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the two platform channels the SMS bridge uses (see
 * lib/sms/sms_bridge.dart on the Dart side):
 *
 *  - `com.badalexchange.agent/sms_events` (EventChannel): streams
 *    `{sender, body, timestampMillis}` maps for inbound SMS messages that
 *    already passed [SmsReceiver]'s native sender allow-list pre-filter.
 *    Dart-side [EvcSmsParser] performs the authoritative parsing/validation
 *    on every event this stream emits.
 *  - `com.badalexchange.agent/sms` (MethodChannel): reserved for simple
 *    native queries (currently just `isReceiverEnabled`, used defensively
 *    by the Dart side; permission requests themselves are handled by the
 *    permission_handler plugin, not this channel).
 *
 * [SmsReceiver] is a manifest-registered BroadcastReceiver, so it is
 * instantiated fresh by the OS for each broadcast rather than being tied to
 * this Activity. It forwards events through the static
 * [SmsReceiver.Companion.listener] callback, which this Activity wires to
 * the EventChannel's sink while the Flutter engine is attached. This means
 * SMS capture is reliable while the app process is alive (foreground or
 * recently backgrounded); if the OS has fully killed the app process, the
 * broadcast still reaches the receiver (Android delivers it regardless),
 * but there is no live Dart isolate to forward it to until the app is next
 * opened. Making capture fully resilient to a killed process would require
 * a headless Dart execution path (e.g. a foreground service running a
 * background FlutterEngine) — intentionally out of scope here per the
 * product's "keep it simple" instruction; flagged for a follow-up if agents
 * report missed matches while the app was closed for a long time.
 */
class MainActivity : FlutterActivity() {
    private val eventChannelName = "com.badalexchange.agent/sms_events"
    private val methodChannelName = "com.badalexchange.agent/sms"

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    SmsReceiver.listener = { payload -> eventSink?.success(payload) }
                }

                override fun onCancel(arguments: Any?) {
                    SmsReceiver.listener = null
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isReceiverEnabled" -> result.success(true)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        SmsReceiver.listener = null
        eventSink = null
        super.onDestroy()
    }
}
