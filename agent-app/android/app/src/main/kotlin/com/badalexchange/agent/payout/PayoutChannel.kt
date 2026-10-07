package com.badalexchange.agent.payout

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.locks.ReentrantLock

/**
 * `com.badalexchange.agent/payout` MethodChannel (Dart side:
 * lib/payout/exchange_payout_runner.dart):
 *
 *  - `status` -> {accessibilityEnabled, permissionsGranted}
 *  - `openAccessibilitySettings`
 *  - `runPayout({simSlot, ussd, pin})` -> the carrier session result:
 *    {outcome, step1Status, step1Text, step2Status?, step2Text?}
 *
 * The backend calls (start the attempt, report each step) stay in Dart; this
 * side only runs the USSD session.
 */
object PayoutChannel {
    private const val CHANNEL = "com.badalexchange.agent/payout"

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "accessibilityEnabled" to PayoutUssdBridge.isAccessibilityServiceEnabled(app),
                        "permissionsGranted" to PayoutRunner.hasRequiredPermissions(app),
                    )
                )
                "openAccessibilitySettings" -> {
                    app.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "runPayout" -> {
                    val slot = call.argument<Int>("simSlot") ?: 1
                    val ussd = call.argument<String>("ussd")
                    val pin = call.argument<String>("pin")
                    if (ussd.isNullOrBlank() || pin.isNullOrBlank()) {
                        result.error("BAD_ARGS", "ussd and pin are required", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val out = PayoutRunner.run(app, slot, ussd, pin)
                        Handler(Looper.getMainLooper()).post { result.success(out) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }
}

/**
 * Port of Dalab's ExchangeUssdOrchestrator + ExchangeUssdDialer, minus the
 * backend calls: dial `*prefix*number*amount#` with ACTION_CALL on the payout
 * wallet's SIM, wait for the carrier's PIN prompt, inject the PIN, read the
 * final answer. The PIN only goes into an input field the carrier showed in
 * reply to this dial; it is never sent into an unexpected screen.
 */
object PayoutRunner {
    /** One live USSD session on this phone at a time (Dalab UssdSimLock + InteractiveUssdScreenLock). */
    private val sessionLock = ReentrantLock(true)

    /** Real confirmed Somali wording of a completed transfer (Dalab, from 28
     * production rows): EVC "ayaad uwareejisay", eDahab "ayad u warejisay".
     * Fail closed: anything else is not a success. */
    private val SUCCESS_KEYWORDS = listOf("wareejisay", "warejisay")

    fun looksLikeConfirmedPayout(text: String): Boolean {
        val lower = text.trim().lowercase()
        return lower.isNotEmpty() && SUCCESS_KEYWORDS.any { lower.contains(it) }
    }

    fun hasRequiredPermissions(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED

    private fun result(outcome: String, step1Status: String?, step1Text: String?, step2Status: String? = null, step2Text: String? = null) =
        mapOf(
            "outcome" to outcome,
            "step1Status" to step1Status,
            "step1Text" to step1Text,
            "step2Status" to step2Status,
            "step2Text" to step2Text,
        )

    fun run(context: Context, simSlot: Int, ussd: String, pin: String): Map<String, Any?> {
        // Nothing was dialed in these cases: step 1 failed, no money moved.
        if (!PayoutUssdBridge.isAccessibilityServiceEnabled(context)) {
            return result("ACCESSIBILITY_NOT_ENABLED", "failed", "Automatic payout is not enabled on this phone (Accessibility).")
        }
        if (!hasRequiredPermissions(context)) {
            return result("PERMISSION_DENIED", "failed", "Phone permissions are not granted.")
        }
        val subscriptionId = subscriptionIdForSlot(context, simSlot)
            ?: return result("NO_SIM_PRESENT", "failed", "SIM $simSlot is not in this phone.")

        sessionLock.lock()
        // The carrier's dialog must be drawn for the accessibility service to
        // read it, so the screen is woken for the session (Dalab).
        @Suppress("DEPRECATION")
        val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
            "BaariAgent:ExchangePayout",
        )
        wakeLock?.acquire(80_000)
        PayoutUssdBridge.arm()
        try {
            try {
                dial(context, subscriptionId, ussd)
            } catch (e: Exception) {
                return result("STEP1_FAILED", "failed", "Could not start the dial: ${e.javaClass.simpleName}")
            }

            val first = awaitSkippingConfirmations(30_000)
            if (first !is UssdDialogEvent.DialogSeen) {
                return result("TIMEOUT", "failed", "No response from the carrier within 30 seconds.")
            }
            if (!first.hasInput) {
                // Not the expected PIN prompt (e.g. "invalid number"): the PIN
                // is never typed into an unexpected screen.
                return result("STEP1_FAILED", "ambiguous", first.text)
            }

            PayoutUssdBridge.armPinInjection(pin)
            val submitted = awaitSkippingConfirmations(15_000)
            if (submitted !is UssdDialogEvent.PinSubmitted) {
                return result("STEP2_FAILED", "step1_success", first.text, "ambiguous", "PIN entry could not be confirmed automatically.")
            }

            val final = awaitSkippingConfirmations(25_000)
            if (final !is UssdDialogEvent.DialogSeen) {
                return result("TIMEOUT", "step1_success", first.text, "ambiguous", "No final confirmation received after entering the PIN.")
            }
            val success = looksLikeConfirmedPayout(final.text)
            return result(if (success) "SUCCESS" else "STEP2_FAILED", "step1_success", first.text, if (success) "success" else "failed", final.text)
        } finally {
            PayoutUssdBridge.disarm()
            if (wakeLock?.isHeld == true) wakeLock.release()
            sessionLock.unlock()
        }
    }

    /** Skips auto-tapped confirmation screens; drains a stale event left over
     * from the previous step first (Dalab). */
    private fun awaitSkippingConfirmations(timeoutMs: Long): UssdDialogEvent? {
        PayoutUssdBridge.drainStaleEvents()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return null
            val event = PayoutUssdBridge.awaitNextEvent(remaining) ?: return null
            if (event is UssdDialogEvent.ConfirmationAdvanced) continue
            return event
        }
    }

    private fun subscriptionIdForSlot(context: Context, oneBasedSlot: Int): Int? = try {
        val manager = context.getSystemService(SubscriptionManager::class.java)
        @Suppress("MissingPermission")
        manager?.activeSubscriptionInfoList?.firstOrNull { it.simSlotIndex == oneBasedSlot - 1 }?.subscriptionId
    } catch (_: SecurityException) {
        null
    }

    /** ACTION_CALL (not sendUssdRequest) so Android shows its own USSD reply
     * dialog, which the accessibility service drives (Dalab ExchangeUssdDialer). */
    private fun dial(context: Context, subscriptionId: Int, ussd: String) {
        val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:" + Uri.encode(ussd))).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            phoneAccountFor(context, subscriptionId)?.let { putExtra(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
        }
        context.startActivity(intent)
    }

    private fun phoneAccountFor(context: Context, subscriptionId: Int): PhoneAccountHandle? = try {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        @Suppress("MissingPermission")
        val handles = telecom?.callCapablePhoneAccounts.orEmpty()
        val official = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                handles.firstOrNull { telephony?.getSubscriptionId(it) == subscriptionId }
            } catch (_: SecurityException) {
                null
            }
        } else null
        official ?: handles.firstOrNull { it.id == subscriptionId.toString() }
    } catch (_: SecurityException) {
        null
    }
}
