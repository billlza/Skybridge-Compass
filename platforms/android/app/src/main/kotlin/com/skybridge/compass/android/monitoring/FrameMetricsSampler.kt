package com.skybridge.compass.android.monitoring

import android.app.Activity
import android.app.Application
import android.os.Build
import android.util.Log
import androidx.core.app.FrameMetricsAggregator
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * UI 帧耗时采样（Jank 统计）。
 */
class FrameMetricsSampler(
    private val application: Application,
    private val intervalMs: Long = 10_000L
) : Application.ActivityLifecycleCallbacks {

    private val scope = CoroutineScope(Dispatchers.Default)
    private val aggregator = FrameMetricsAggregator()
    private var currentActivity: Activity? = null
    private var job: Job? = null

    fun install() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        application.registerActivityLifecycleCallbacks(this)
        if (job == null) {
            job = scope.launch {
                while (isActive) {
                    sampleJank()
                    delay(intervalMs)
                }
            }
        }
    }

    fun uninstall() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        application.unregisterActivityLifecycleCallbacks(this)
        job?.cancel()
        job = null
    }

    private fun sampleJank() {
        val activity = currentActivity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val metrics = aggregator.remove(activity) ?: return
        aggregator.add(activity)

        val totalMetrics = metrics[FrameMetricsAggregator.TOTAL_DURATION] ?: return
        var total = 0
        var jank = 0
        for (i in 0 until totalMetrics.size()) {
            val durationMs = totalMetrics.keyAt(i)
            val count = totalMetrics.valueAt(i)
            total += count
            if (durationMs > 16) {
                jank += count
            }
        }
        if (total == 0) return
        val jankPct = (jank.toDouble() / total * 100).toInt()
        val logLine = "frames=$total, jank=$jank ($jankPct%)"
        Log.d("SkyBridgeJank", logLine)
        try {
            File(application.filesDir, "jank-sample.log")
                .appendText("${System.currentTimeMillis()} $logLine\n")
        } catch (_: Exception) {}

        if (jankPct >= 10) {
            NotificationCenter.post(
                NotificationEvent(
                    title = resolveLocalizedText("UI 掉帧偏高", "High UI Jank", "UI ジャンク率が高い"),
                    message = resolveLocalizedText(
                        "最近采样丢帧率 ${jankPct}%",
                        "Recent sampled jank rate: ${jankPct}%",
                        "直近サンプルのジャンク率: ${jankPct}%"
                    ),
                    module = NotificationModule.PERFORMANCE,
                    severity = NotificationSeverity.WARNING
                )
            )
        }
    }

    override fun onActivityResumed(activity: Activity) {
        currentActivity = activity
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            aggregator.add(activity)
        }
    }

    override fun onActivityPaused(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            aggregator.remove(activity)
        }
        if (currentActivity == activity) {
            currentActivity = null
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
