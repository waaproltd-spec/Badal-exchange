package com.badalexchange.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Reads SMS while the app is closed.
 *
 * [SmsReceiver] runs for every SMS even when the app is not running, but there is no Dart code to hand it
 * to. For an SMS that looks like money or like Sahal's access code, this starts a small headless Flutter
 * engine that runs `smsBackgroundMain` (lib/sms/sms_background.dart): it takes the SMS kept here, sends
 * Sahal's access code to the server (which enters it into the Sahal sign-in) and uploads payment SMS, then
 * says `done` and the engine is shut down. Everything runs on the main thread.
 *
 * Limits of Android: a force-stopped app or a phone that blocks the app's background work gets nothing;
 * the inbox rescan on the next start picks those SMS up. The SMS text is never logged.
 */
object BackgroundSms {
    private const val TAG = "BaariBackgroundSms"
    private const val CHANNEL = "com.badalexchange.agent/sms_background"
    private const val ENGINE_TIMEOUT_MS = 90_000L
    /** A broadcast may be held (goAsync) only for a few seconds. */
    private const val RECEIVER_HOLD_MS = 8_000L

    private val handler = Handler(Looper.getMainLooper())
    private val queue = ConcurrentLinkedQueue<Map<String, Any?>>()
    private val held = mutableListOf<BroadcastReceiver.PendingResult>()
    private var engine: FlutterEngine? = null

    private val keywords = listOf(
        "sahal", "access code", "heshay", "dollar", "tix:", "aqanoosiga", "edahab", "evcplus", "evc plus", "haraag", "somnet",
    )

    /**
     * A short trail of what happened (never an SMS text), in the file the app's shared_preferences reads, so the
     * Sahal sign-in screen can show it on the phone itself.
     */
    fun note(context: Context, line: String) {
        try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val key = "flutter.baari_bg_sms_log"
            val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())
            val lines = (prefs.getString(key, "") ?: "").split("\n").filter { it.isNotEmpty() }.toMutableList()
            lines.add("$stamp native: $line")
            prefs.edit().putString(key, lines.takeLast(12).joinToString("\n")).apply()
        } catch (_: Exception) {
        }
    }

    /** A cheap check, so no engine is started for a personal SMS. */
    fun worthIt(body: String): Boolean {
        val b = body.lowercase()
        return b.contains("$") || keywords.any { b.contains(it) }
    }

    /** Main thread. [pending] is the receiver's goAsync result; it is finished at the latest after a few seconds. */
    fun handle(context: Context, payload: Map<String, Any?>, pending: BroadcastReceiver.PendingResult?) {
        note(context, "SMS received while the app was closed")
        queue.add(payload)
        if (pending != null) {
            held.add(pending)
            handler.postDelayed({ releaseHeld() }, RECEIVER_HOLD_MS)
        }
        if (engine == null) start(context.applicationContext)
    }

    private fun releaseHeld() {
        val all = held.toList()
        held.clear()
        for (p in all) {
            try {
                p.finish()
            } catch (_: Exception) {
            }
        }
    }

    private fun start(app: Context) {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val e = FlutterEngine(app)
            engine = e
            MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        val taken = mutableListOf<Map<String, Any?>>()
                        while (true) taken.add(queue.poll() ?: break)
                        result.success(taken)
                    }
                    "done" -> {
                        result.success(null)
                        stop()
                        // An SMS that came in while this engine worked gets a new one.
                        if (!queue.isEmpty()) start(app)
                    }
                    else -> result.notImplemented()
                }
            }
            note(app, "starting the background engine")
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:badal_agent_app/sms/sms_background.dart", "smsBackgroundMain"),
            )
            handler.postDelayed({
                if (engine === e) {
                    note(app, "the background engine took too long and was stopped")
                    stop()
                }
            }, ENGINE_TIMEOUT_MS)
        } catch (ex: Exception) {
            Log.w(TAG, "Could not start the background engine: ${ex.javaClass.simpleName}")
            note(app, "could not start the engine: ${ex.javaClass.simpleName}")
            stop()
        }
    }

    private fun stop() {
        releaseHeld()
        try {
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
    }
}
