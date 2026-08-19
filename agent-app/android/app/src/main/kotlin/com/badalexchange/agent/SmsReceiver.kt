package com.badalexchange.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Native half of the EVC Plus SMS auto-matching pipeline.
 *
 * This receiver deliberately does the *minimum* work possible before
 * handing off to Dart:
 *  1. Reassemble the (possibly multi-part) SMS into a single sender +
 *     body string.
 *  2. Apply a coarse, native sender-id allow-list pre-filter — this list
 *     mirrors (but is independent of) EvcSmsConfig.allowedSenderIds in
 *     lib/sms/evc_sms_parser.dart. Any message from an unrecognized sender
 *     is dropped right here: it is never forwarded to Dart, never logged,
 *     never stored.
 *  3. For messages that pass, forward only `{sender, body, timestampMillis}`
 *     to the currently-attached Dart isolate via [listener] (wired to an
 *     EventChannel by MainActivity). Dart's EvcSmsParser then performs the
 *     authoritative, unit-tested parsing — including a second, more
 *     specific sender check and a "looks like a payment" wording check —
 *     and extracts only {sender phone number, amount, transaction ref,
 *     timestamp} before anything is ever sent to the backend.
 *
 * This receiver never aborts the broadcast (no abortBroadcast() call), so
 * the SMS still reaches the device's normal messaging app — this app only
 * observes it, it does not intercept or hide it from the agent.
 *
 * IMPORTANT: this file intentionally does not log the SMS body (not even
 * at Log.d) — see the "extraction only, never raw text" requirement in the
 * product brief. Only non-sensitive diagnostic breadcrumbs (e.g. "ignored:
 * unrecognized sender") are logged.
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BadalSmsReceiver"

        /**
         * Best-effort guess at known Hormuud/EVC Plus SMS sender ids.
         *
         * TODO(confirm-with-telco): this MUST be confirmed/updated against a
         * real EVC Plus payment-notification SMS captured on a test device
         * before production rollout — see the matching TODO in
         * lib/sms/evc_sms_parser.dart, which is the authoritative source of
         * truth for sender matching (this native list only needs to be
         * permissive enough not to drop a legitimate message; Dart makes the
         * final call).
         */
        private val ALLOWED_SENDER_IDS = listOf("EVCPLUS", "EVC PLUS", "HORMUUD", "EVC")

        /** Set by MainActivity while the EventChannel has an active listener. */
        @Volatile
        var listener: ((Map<String, Any?>) -> Unit)? = null

        private fun isAuthorizedSender(address: String?): Boolean {
            if (address.isNullOrBlank()) return false
            val normalized = address.trim().uppercase()
            return ALLOWED_SENDER_IDS.any { normalized.contains(it) }
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

        val sender = messages.first().originatingAddress
        if (!isAuthorizedSender(sender)) {
            // Not a recognized EVC Plus sender — drop immediately. Nothing
            // about this message (sender or body) is retained or forwarded.
            return
        }

        // Multi-part SMS: concatenate parts in order to reconstruct the
        // full message body before handing off to Dart for parsing.
        val body = buildString {
            for (part in messages) {
                append(part.messageBody ?: "")
            }
        }
        val timestampMillis = messages.first().timestampMillis

        val currentListener = listener
        if (currentListener == null) {
            // No live Dart isolate/EventChannel listener right now (app not
            // currently running) — nothing to forward to. We intentionally
            // do not queue/persist the body in that case; see MainActivity's
            // doc comment on the tradeoff this implies.
            Log.d(TAG, "Authorized sender SMS received but no active listener; dropping.")
            return
        }

        currentListener(
            mapOf(
                "sender" to sender,
                "body" to body,
                "timestampMillis" to timestampMillis,
            )
        )
    }
}
