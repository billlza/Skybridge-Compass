package com.skybridge.compass.android.monitoring

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * ANR Watchdog：检测主线程卡死并记录日志。
 */
class AnrWatchdog(
    private val context: Context,
    private val timeoutMs: Long = 5000L,
    private val startupGraceMs: Long = 15_000L,
    private val notifyCooldownMs: Long = 10 * 60_000L
) : Thread("SkyBridge-ANR") {

    private val handler = Handler(Looper.getMainLooper())
    private val tick = AtomicLong(0L)
    private val reported = AtomicBoolean(false)
    private val running = AtomicBoolean(true)
    private val startedAt = SystemClock.uptimeMillis()
    private val lastNotifiedAt = AtomicLong(0L)

    override fun run() {
        while (running.get() && !isInterrupted) {
            val marker = SystemClock.uptimeMillis()
            tick.set(marker)
            handler.post { tick.compareAndSet(marker, SystemClock.uptimeMillis()) }
            SystemClock.sleep(timeoutMs)

            val last = tick.get()
            if (last == marker && reported.compareAndSet(false, true)) {
                // Avoid noisy false positives during cold start / heavy initialization.
                if (SystemClock.uptimeMillis() - startedAt >= startupGraceMs) {
                    reportAnr()
                } else {
                    Log.w("SkyBridgeANR", "ANR skipped during startup grace window")
                }
            } else if (last != marker) {
                reported.set(false)
            }
        }
    }

    fun stopWatchdog() {
        running.set(false)
        interrupt()
    }

    private fun reportAnr() {
        val logText = "==== SkyBridge ANR ====\nMain thread blocked for >= ${timeoutMs}ms"
        Log.e("SkyBridgeANR", logText)
        try {
            val f = File(context.filesDir, "anr.log")
            val stamp = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", java.util.Locale.US)
                .format(java.util.Date())
            f.appendText("\n[$stamp] $logText\n")
        } catch (_: Exception) {}
        val now = SystemClock.uptimeMillis()
        val last = lastNotifiedAt.get()
        if (now - last >= notifyCooldownMs && lastNotifiedAt.compareAndSet(last, now)) {
            NotificationCenter.post(
                NotificationEvent(
                    title = resolveLocalizedText("检测到 ANR", "ANR Detected", "ANR を検出"),
                    message = resolveLocalizedText(
                        "主线程卡顿超过 ${timeoutMs}ms",
                        "Main thread stalled for over ${timeoutMs}ms",
                        "メインスレッドの停止が ${timeoutMs}ms を超えました"
                    ),
                    module = NotificationModule.PERFORMANCE,
                    severity = NotificationSeverity.ERROR
                )
            )
        } else {
            Log.w("SkyBridgeANR", "ANR notification throttled")
        }
    }
}
