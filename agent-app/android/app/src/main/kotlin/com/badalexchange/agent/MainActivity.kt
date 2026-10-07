package com.badalexchange.agent

import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.badalexchange.agent.payout.PayoutChannel

/**
 * Hosts the SMS platform channels (Dart side: lib/sms/sms_bridge.dart):
 *
 *  - `com.badalexchange.agent/sms_events` (EventChannel): every inbound SMS
 *    as `{sender, body, timestampMillis, simSlot}` (see [SmsReceiver]).
 *  - `com.badalexchange.agent/sms` (MethodChannel):
 *    - `isReceiverEnabled`
 *    - `scanInbox({sinceMillis})`: inbox SMS newer than sinceMillis (at
 *      most 200, oldest first), same shape as the events. Port of Dalab's
 *      SmsInboxScanner: catches payments that arrived while the app was
 *      closed. Each SMS keeps its own DATE, so the backend's
 *      sender+body+minute dedupe recognizes one it already has.
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
                    "scanInbox" -> {
                        val since = (call.argument<Number>("sinceMillis") ?: 0).toLong()
                        Thread {
                            try {
                                val rows = scanInbox(since)
                                Handler(Looper.getMainLooper()).post { result.success(rows) }
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post { result.error("SCAN_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        PayoutChannel.register(this, flutterEngine)
    }

    private fun scanInbox(sinceMillis: Long): List<Map<String, Any?>> {
        val projection = arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.SUBSCRIPTION_ID)
        val rows = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            projection,
            "${Telephony.Sms.DATE} > ?",
            arrayOf(sinceMillis.toString()),
            "${Telephony.Sms.DATE} DESC LIMIT 200",
        )?.use { c ->
            val addressIdx = c.getColumnIndex(Telephony.Sms.ADDRESS)
            val bodyIdx = c.getColumnIndex(Telephony.Sms.BODY)
            val dateIdx = c.getColumnIndex(Telephony.Sms.DATE)
            val subIdx = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
            while (c.moveToNext()) {
                val address = if (addressIdx >= 0) c.getString(addressIdx) else null
                val body = if (bodyIdx >= 0) c.getString(bodyIdx) else null
                if (address == null || body == null) continue
                val subscriptionId = if (subIdx >= 0) c.getInt(subIdx) else -1
                rows.add(
                    mapOf(
                        "sender" to address,
                        "body" to body,
                        "timestampMillis" to (if (dateIdx >= 0) c.getLong(dateIdx) else 0L),
                        "simSlot" to SmsReceiver.simSlotForSubscription(applicationContext, subscriptionId),
                    )
                )
            }
        }
        return rows.asReversed()
    }

    override fun onDestroy() {
        SmsReceiver.listener = null
        eventSink = null
        super.onDestroy()
    }
}
