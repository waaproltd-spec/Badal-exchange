package com.badalexchange.agent

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.util.Log

/**
 * Native half of the payment-SMS pipeline (port of Dalab Internet's
 * SmsReceiver). Reassembles the (possibly multi-part) SMS, resolves which
 * SIM slot it arrived on, and forwards `{sender, body, timestampMillis,
 * simSlot}` to Dart over the `com.badalexchange.agent/sms_events`
 * EventChannel.
 *
 * There is no sender filter here: real payment SMS come from short codes
 * like "192" and "eDahab", and Dalab's parsers check each one's own sender
 * list. Dart (lib/sms/payment_sms_parsers.dart) decides what is a payment
 * SMS and drops everything else without sending it anywhere.
 *
 * When the app process isn't running there is no Dart listener; the SMS is
 * then picked up by the inbox rescan (MainActivity `scanInbox`) the next
 * time the app starts, exactly like Dalab's SmsInboxScanner.
 *
 * Never aborts the broadcast and never logs the SMS body.
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BaariSmsReceiver"
        private const val SIM_SLOT_RETRY_DELAY_MS = 300L

        /** Set by MainActivity while the EventChannel has an active listener. */
        @Volatile
        var listener: ((Map<String, Any?>) -> Unit)? = null

        /**
         * 1-based SIM slot for a subscription id, or null when it can't be
         * resolved (single-SIM phone, no READ_PHONE_STATE, OEM without the
         * extra). The backend then matches on the device alone.
         */
        fun simSlotForSubscription(context: Context, subscriptionId: Int): Int? {
            return try {
                if (subscriptionId <= 0) return null
                if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
                    return null
                }
                val manager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
                    ?: return null
                @Suppress("MissingPermission")
                val info = manager.getActiveSubscriptionInfo(subscriptionId) ?: return null
                info.simSlotIndex + 1
            } catch (e: Exception) {
                null
            }
        }

        /** Dalab: SubscriptionManager can briefly report nothing right after delivery; retry once. */
        private fun resolveSimSlot(context: Context, intent: Intent): Int? {
            val subscriptionId = intent.extras?.getInt("subscription", -1) ?: -1
            simSlotForSubscription(context, subscriptionId)?.let { return it }
            Thread.sleep(SIM_SLOT_RETRY_DELAY_MS)
            return simSlotForSubscription(context, subscriptionId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read incoming SMS parts: ${e.message}")
            return
        }
        if (messages.isNullOrEmpty()) return

        val sender = messages.first().originatingAddress ?: return
        val body = buildString {
            for (part in messages) append(part.messageBody ?: "")
        }
        val timestampMillis = messages.first().timestampMillis

        val currentListener = listener
        if (currentListener == null) {
            Log.d(TAG, "SMS received with no active listener; the inbox rescan will pick it up.")
            return
        }

        val pending = goAsync()
        Thread {
            try {
                val simSlot = resolveSimSlot(context.applicationContext, intent)
                val payload = mapOf(
                    "sender" to sender,
                    "body" to body,
                    "timestampMillis" to timestampMillis,
                    "simSlot" to simSlot,
                )
                // EventChannel sinks must be called on the main thread.
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    try {
                        listener?.invoke(payload)
                    } finally {
                        pending.finish()
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed forwarding SMS: ${e.message}")
                pending.finish()
            }
        }.start()
    }
}
