package com.skybridge.compass.android.monitoring

import android.content.Context
import android.os.Process
import android.util.Log
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
 * 轻量性能采样（CPU/内存），定期记录到本地文件。
 */
class PerformanceSampler(
    private val context: Context,
    private val intervalMs: Long = 30_000L
) {
    private val scope = CoroutineScope(Dispatchers.Default)
    private var job: Job? = null

    fun start() {
        if (job != null) return
        job = scope.launch {
            while (isActive) {
                val runtime = Runtime.getRuntime()
                val usedMem = runtime.totalMemory() - runtime.freeMemory()
                val maxMem = runtime.maxMemory()
                val cpuTimeMs = Process.getElapsedCpuTime()
                val usagePct = (usedMem.toDouble() / maxMem * 100).toInt()
                val logLine = "cpuMs=$cpuTimeMs, usedMem=$usedMem, maxMem=$maxMem, usagePct=$usagePct"
                Log.d("SkyBridgePerf", logLine)
                try {
                    File(context.filesDir, "perf-sample.log")
                        .appendText("${System.currentTimeMillis()} $logLine\n")
                } catch (_: Exception) {}

                if (usagePct >= 90) {
                    NotificationCenter.post(
                        NotificationEvent(
                            title = resolveLocalizedText("内存使用率过高", "High Memory Usage", "メモリ使用率が高い"),
                            message = resolveLocalizedText(
                                "当前内存使用率 ${usagePct}%",
                                "Current memory usage: ${usagePct}%",
                                "現在のメモリ使用率: ${usagePct}%"
                            ),
                            module = NotificationModule.PERFORMANCE,
                            severity = NotificationSeverity.WARNING
                        )
                    )
                }

                delay(intervalMs)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }
}
