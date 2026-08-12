package com.skybridge.compass.android.monitoring

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Process
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
 * ANR Watchdog：检测主线程"真正卡死"并记录日志。
 *
 * 设计要点（避免在低配/模拟器上误报）：
 *  - 心跳：后台线程定期 `post` 一个 runnable 到主线程，并记录主线程"最后一次回执"的时刻。
 *  - 真实卡顿的判定 = 同时满足两点：
 *      (a) 心跳回执已迟到 >= [timeoutMs]（用看门狗线程自己的单调时钟测量，不信任 sleep 时长）；
 *      (b) 主线程在这段时间里**确实在消耗 CPU**（说明它在跑代码却没回到 Looper），
 *         通过读取 /proc/self/task/<mainTid>/stat 的 utime+stime 判断。
 *  - 若 (a) 成立但 (b) 不成立（主线程 CPU 没推进），说明主线程其实是**空闲/未被调度**
 *    （典型于软件 GPU 模拟器的 CPU 饥饿），此时只记录一条降级诊断，**不上报 ANR**，
 *    既不掩盖真实 ANR，也不在饥饿环境里刷假阳性。
 *
 * 真实 ANR 路径完全保留：主线程忙于跑代码且不回 Looper 时，CPU 会推进 → 正常上报。
 */
class AnrWatchdog(
    private val context: Context,
    private val timeoutMs: Long = 5000L,
    private val startupGraceMs: Long = 15_000L,
    private val notifyCooldownMs: Long = 10 * 60_000L,
    private val pollIntervalMs: Long = 1000L
) : Thread("SkyBridge-ANR") {

    private val handler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(true)
    private val startedAt = SystemClock.uptimeMillis()
    private val lastNotifiedAt = AtomicLong(0L)

    /** 主线程最后一次执行心跳 runnable 的时刻（uptime ms）。由主线程写入。 */
    private val lastBeatAt = AtomicLong(SystemClock.uptimeMillis())

    /** 主线程 tid（由主线程自身填入；用于读取其每线程 CPU 时间）。 */
    @Volatile private var mainTid: Int = -1

    /** 一次卡顿事件只上报一次，回执恢复后复位。 */
    private val reportedForCurrentStall = AtomicBoolean(false)

    override fun run() {
        // 拿到主线程 tid（在主线程上执行才能取到正确的 tid），顺便打一次心跳。
        handler.post {
            mainTid = Process.myTid()
            lastBeatAt.set(SystemClock.uptimeMillis())
        }

        while (running.get() && !isInterrupted) {
            val now = SystemClock.uptimeMillis()

            // 派发一次心跳：主线程执行到它时，记录回执时刻。
            handler.post { lastBeatAt.set(SystemClock.uptimeMillis()) }

            // 卡顿前后主线程 CPU 时间（jiffies），用于判断主线程是否真的在跑代码。
            val cpuBefore = readMainThreadCpuJiffies()
            val tWaitStart = SystemClock.uptimeMillis()

            SystemClock.sleep(pollIntervalMs)

            // 用单调时钟实测本轮真实等待时长（饥饿时 sleep 可能远超 pollIntervalMs）。
            val waited = SystemClock.uptimeMillis() - tWaitStart
            val sinceBeat = SystemClock.uptimeMillis() - lastBeatAt.get()

            // (a) 心跳是否迟到 >= 阈值？
            if (sinceBeat < timeoutMs) {
                // 主线程在按时回执 → 健康，复位本次卡顿标志。
                reportedForCurrentStall.set(false)
                continue
            }

            // 已经迟到。还在启动宽限期内则跳过。
            if (now - startedAt < startupGraceMs) {
                Log.w("SkyBridgeANR", "ANR skipped during startup grace window")
                continue
            }

            // (b) 在我们刚刚的等待窗口里，主线程是否消耗了 CPU？
            //     若主线程根本没被调度（CPU 没推进），那是饥饿/空闲，而非真正卡死。
            val cpuAfter = readMainThreadCpuJiffies()
            val cpuAdvancedJiffies = if (cpuBefore >= 0 && cpuAfter >= 0) cpuAfter - cpuBefore else -1L

            // 阈值：本轮等待期间主线程至少要烧掉相当于"等待时长一半"的 CPU 才算"在忙"。
            // jiffies 单位约 10ms（HZ=100），换算成 ms 比较；取 50% 的等待时长作为下限。
            val cpuAdvancedMs = if (cpuAdvancedJiffies >= 0) cpuAdvancedJiffies * 10L else -1L
            val busyThresholdMs = (waited / 2).coerceAtLeast(50L)
            val mainThreadWasBusy = cpuAdvancedMs >= busyThresholdMs

            if (cpuAdvancedJiffies < 0) {
                // 无法读取主线程 CPU（极少见）。保守起见仍上报，但标注不确定。
                if (reportedForCurrentStall.compareAndSet(false, true)) {
                    reportAnr(sinceBeat, cpuNote = "cpu=unknown")
                }
            } else if (mainThreadWasBusy) {
                // 真正的 ANR：主线程在跑代码却 >= timeoutMs 没回 Looper。
                if (reportedForCurrentStall.compareAndSet(false, true)) {
                    reportAnr(sinceBeat, cpuNote = "mainCpu+${cpuAdvancedMs}ms/${waited}ms")
                }
            } else {
                // 心跳迟到，但主线程没在烧 CPU → 它没被调度（饥饿/空闲），不是真卡死。
                // 仅在每次卡顿事件首次出现时打一条降级日志，避免日志风暴，也不发通知。
                if (reportedForCurrentStall.compareAndSet(false, true)) {
                    Log.w(
                        "SkyBridgeANR",
                        "Heartbeat late ${sinceBeat}ms but main thread idle/starved " +
                            "(mainCpu+${cpuAdvancedMs}ms in ${waited}ms wait) — not a real ANR, " +
                            "likely CPU starvation (slow emulator/host). Skipping report."
                    )
                }
            }
        }
    }

    /**
     * 读取主线程的累计 CPU 时间（utime+stime，单位 jiffies）。
     * 取自 /proc/self/task/<mainTid>/stat 的第 14、15 字段。失败返回 -1。
     */
    private fun readMainThreadCpuJiffies(): Long {
        val tid = mainTid
        if (tid <= 0) return -1L
        return try {
            val stat = File("/proc/self/task/$tid/stat").readText()
            // comm 字段可能含空格且被括号包裹，从右括号之后开始解析后续字段。
            val rparen = stat.lastIndexOf(')')
            if (rparen < 0) return -1L
            val rest = stat.substring(rparen + 2).trim().split(" ")
            // rest[0] = state(第3字段)。utime=第14、stime=第15 → rest 下标 11、12。
            val utime = rest.getOrNull(11)?.toLongOrNull() ?: return -1L
            val stime = rest.getOrNull(12)?.toLongOrNull() ?: return -1L
            utime + stime
        } catch (_: Throwable) {
            -1L
        }
    }

    fun stopWatchdog() {
        running.set(false)
        interrupt()
    }

    private fun reportAnr(stalledMs: Long, cpuNote: String) {
        val logText = "==== SkyBridge ANR ====\n" +
            "Main thread blocked for >= ${timeoutMs}ms (stalled ${stalledMs}ms, $cpuNote)"
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
