package com.badalexchange.agent.payout

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** What the accessibility service saw in the carrier's USSD dialog (Dalab UssdDialogEvent). */
sealed class UssdDialogEvent {
    data class DialogSeen(val text: String, val hasInput: Boolean) : UssdDialogEvent()
    object PinSubmitted : UssdDialogEvent()

    /** An intermediate Send/OK/Yes screen with no input was auto-confirmed:
     * not the carrier's answer, keep waiting. */
    data class ConfirmationAdvanced(val postPin: Boolean) : UssdDialogEvent()
}

/**
 * Shared state between [PayoutRunner] and [PayoutAccessibilityService]
 * (port of Dalab's ExchangeUssdBridge). The service only ever acts while a
 * payout is [armed]; the PIN is held here only between "carrier asked for
 * it" and "typed into the dialog", then cleared.
 */
object PayoutUssdBridge {
    @Volatile var armed: Boolean = false
        private set

    @Volatile private var pendingPin: String? = null
    @Volatile private var pinSubmitted = false
    @Volatile private var postPinConfirmTapped = false
    @Volatile private var lastPreConfirmText: String? = null
    @Volatile private var lastPostConfirmText: String? = null
    @Volatile private var lockedPackageName: String? = null
    @Volatile private var lockedWindowId: Int? = null
    @Volatile private var recoveryAttempts = 0
    @Volatile private var recoveryInProgress = false
    private const val MAX_RECOVERY_ATTEMPTS = 4
    private const val PIN_POLL_INTERVAL_MS = 500L

    /** Conflated like Dalab's Channel: only the newest event is kept. */
    private val events = LinkedBlockingQueue<UssdDialogEvent>(1)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pinPoll: Runnable? = null

    fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val expected = "${context.packageName}/${PayoutAccessibilityService::class.java.name}"
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    fun arm() {
        reset()
        armed = true
    }

    fun disarm() {
        armed = false
        reset()
    }

    private fun reset() {
        events.clear()
        pendingPin = null
        pinSubmitted = false
        postPinConfirmTapped = false
        lastPreConfirmText = null
        lastPostConfirmText = null
        lockedPackageName = null
        lockedWindowId = null
        recoveryAttempts = 0
        recoveryInProgress = false
        stopPinPolling()
    }

    /** The carrier asked for the PIN: inject it on the next scan, polling
     * every 500 ms in case no accessibility event fires (Dalab). */
    fun armPinInjection(pin: String) {
        pendingPin = pin
        stopPinPolling()
        val runnable = object : Runnable {
            override fun run() {
                if (!armed || pendingPin == null) return
                PayoutAccessibilityService.instance?.scanAndAct()
                if (armed && pendingPin != null) mainHandler.postDelayed(this, PIN_POLL_INTERVAL_MS)
            }
        }
        pinPoll = runnable
        mainHandler.post(runnable)
    }

    private fun stopPinPolling() {
        pinPoll?.let(mainHandler::removeCallbacks)
        pinPoll = null
    }

    internal fun consumePendingPin(): String? {
        val pin = pendingPin
        pendingPin = null
        return pin
    }

    internal fun restorePendingPin(pin: String) {
        pendingPin = pin
    }

    /** Each distinct confirmation screen is tapped once per stage (Dalab). */
    internal fun shouldAutoConfirm(text: String): Boolean =
        if (pinSubmitted) {
            if (text == lastPostConfirmText) false else { lastPostConfirmText = text; true }
        } else {
            if (text == lastPreConfirmText) false else { lastPreConfirmText = text; true }
        }

    internal fun isPinSubmitted() = pinSubmitted

    internal fun isEligibleForPostPinConfirmTap() = pinSubmitted && !postPinConfirmTapped

    /** Locks onto the first window that looks like the carrier dialog; every
     * later scan only acts on that same window (package or window id), never
     * on this app or anything else that comes to the front. */
    internal fun isWindowAllowed(packageName: String?, windowId: Int?, looksLikeUssdDialog: Boolean, ownPackage: String?): Boolean {
        val locked = lockedPackageName
        if (locked == null) {
            if (!looksLikeUssdDialog) return false
            if (ownPackage != null && packageName == ownPackage) return false
            lockedPackageName = packageName
            lockedWindowId = windowId
            return true
        }
        if (packageName != null && packageName == locked) return true
        val id = lockedWindowId
        return id != null && windowId != null && id == windowId
    }

    internal fun lockedPackage(): String? = lockedPackageName
    internal fun lockedWindow(): Int? = lockedWindowId

    internal fun shouldAttemptWindowRecovery(): Boolean {
        if (recoveryInProgress || recoveryAttempts >= MAX_RECOVERY_ATTEMPTS) return false
        recoveryAttempts++
        recoveryInProgress = true
        return true
    }

    internal fun recoveryFinished() {
        recoveryInProgress = false
    }

    internal fun emit(event: UssdDialogEvent) {
        if (event is UssdDialogEvent.PinSubmitted) pinSubmitted = true
        if (event is UssdDialogEvent.ConfirmationAdvanced && event.postPin) postPinConfirmTapped = true
        synchronized(events) {
            events.clear()
            events.offer(event)
        }
    }

    fun drainStaleEvents() = events.clear()

    fun awaitNextEvent(timeoutMs: Long): UssdDialogEvent? = events.poll(timeoutMs, TimeUnit.MILLISECONDS)
}
