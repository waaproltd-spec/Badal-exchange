package com.badalexchange.agent.payout

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.badalexchange.agent.MainActivity

/**
 * Reads and drives the carrier's native USSD reply dialog during an exchange
 * payout (port of Dalab's ExchangeUssdAccessibilityService). Does nothing
 * unless [PayoutUssdBridge.armed] (a live payout on this phone). Never
 * logs the PIN or the dialog text.
 *
 * The agent turns it on once in Settings > Accessibility; Android does not
 * allow an app to do that itself.
 */
class PayoutAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || !PayoutUssdBridge.armed) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) return
        scanAndAct()
    }

    internal fun scanAndAct() {
        if (!PayoutUssdBridge.armed) return
        val root = findRelevantRoot() ?: return
        try {
            val messageText = findDialogMessageText(root) ?: return
            val windowPackage = root.packageName?.toString()
            val windowId = root.windowId
            val inputNode = findEditableNode(root)
            val looksLikeUssdDialog = inputNode != null || isTransientLoadingDialog(messageText) || findPositiveButton(root) != null
            if (!PayoutUssdBridge.isWindowAllowed(windowPackage, windowId, looksLikeUssdDialog, packageName)) return

            val pin = PayoutUssdBridge.consumePendingPin()
            if (pin != null) {
                if (inputNode == null) {
                    // Not the PIN prompt yet: keep the PIN for the next poll.
                    PayoutUssdBridge.restorePendingPin(pin)
                    return
                }
                val args = Bundle()
                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, pin)
                inputNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                (findPositiveButton(root) ?: inputNode).performAction(AccessibilityNodeInfo.ACTION_CLICK)
                PayoutUssdBridge.emit(UssdDialogEvent.PinSubmitted)
                return
            }

            if (isTransientLoadingDialog(messageText)) return

            if (inputNode == null || PayoutUssdBridge.isEligibleForPostPinConfirmTap()) {
                val confirm = findPositiveButton(root)
                if (confirm != null) {
                    if (PayoutUssdBridge.shouldAutoConfirm(messageText)) {
                        confirm.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        PayoutUssdBridge.emit(UssdDialogEvent.ConfirmationAdvanced(PayoutUssdBridge.isPinSubmitted()))
                    }
                    return
                }
            }
            PayoutUssdBridge.emit(UssdDialogEvent.DialogSeen(messageText, hasInput = inputNode != null))
        } catch (e: Exception) {
            Log.w(TAG, "scanAndAct failed: ${e.javaClass.simpleName}")
        }
    }

    /** The locked carrier window among all windows (it may not be the active
     * one); before locking, the active window. If the dialog fell behind
     * another window, bring this app forward so the system dialog is shown
     * again (Dalab's foreground recovery). */
    private fun findRelevantRoot(): AccessibilityNodeInfo? {
        val locked = PayoutUssdBridge.lockedPackage() ?: return rootInActiveWindow
        val lockedId = PayoutUssdBridge.lockedWindow()
        for (window in windows) {
            val windowRoot = window.root ?: continue
            if (windowRoot.packageName?.toString() == locked || (lockedId != null && window.id == lockedId)) return windowRoot
        }
        if (PayoutUssdBridge.shouldAttemptWindowRecovery()) {
            try {
                startActivity(Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                })
            } catch (_: Exception) {
            }
            Handler(Looper.getMainLooper()).postDelayed({
                PayoutUssdBridge.recoveryFinished()
                if (PayoutUssdBridge.armed) scanAndAct()
            }, 600)
        }
        return null
    }

    private fun isTransientLoadingDialog(text: String): Boolean {
        val n = text.trim().lowercase()
        return n.contains("ussd code running") || n.contains("running ussd code")
    }

    /** The longest text in the dialog is the carrier's message. */
    private fun findDialogMessageText(node: AccessibilityNodeInfo): String? {
        var best: String? = null
        fun walk(n: AccessibilityNodeInfo) {
            val text = n.text?.toString()
            if (!text.isNullOrBlank() && !n.isEditable && (best == null || text.length > best!!.length)) best = text
            for (i in 0 until n.childCount) n.getChild(i)?.let { walk(it) }
        }
        walk(node)
        return best
    }

    private fun findEditableNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable) return node
        for (i in 0 until node.childCount) {
            val found = node.getChild(i)?.let { findEditableNode(it) }
            if (found != null) return found
        }
        return null
    }

    private fun isButton(node: AccessibilityNodeInfo) = node.isClickable && node.className?.contains("Button") == true

    private fun findPositiveButton(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        findPositiveButtonByText(node)?.let { return it }
        // A single unlabeled button is the dialog's only action (Dalab).
        val buttons = mutableListOf<AccessibilityNodeInfo>()
        collectButtons(node, buttons)
        return if (buttons.size == 1 && buttons[0].text?.toString().isNullOrBlank()) buttons[0] else null
    }

    private fun findPositiveButtonByText(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (isButton(node)) {
            val text = node.text?.toString()?.lowercase()
            if (text != null && (text.contains("ok") || text.contains("send") || text.contains("dial") || text.contains("yes"))) return node
        }
        for (i in 0 until node.childCount) {
            val found = node.getChild(i)?.let { findPositiveButtonByText(it) }
            if (found != null) return found
        }
        return null
    }

    private fun collectButtons(node: AccessibilityNodeInfo, out: MutableList<AccessibilityNodeInfo>) {
        if (isButton(node)) out.add(node)
        for (i in 0 until node.childCount) node.getChild(i)?.let { collectButtons(it, out) }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
    }

    companion object {
        private const val TAG = "BaariPayoutA11y"

        @Volatile
        var instance: PayoutAccessibilityService? = null
            private set
    }
}
