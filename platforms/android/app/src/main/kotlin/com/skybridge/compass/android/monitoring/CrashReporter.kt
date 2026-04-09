package com.skybridge.compass.android.monitoring

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * 轻量级 Crash 追踪：记录崩溃到本地文件，便于后续上传或问题定位。
 */
object CrashReporter {
    private const val TAG = "SkyBridgeCrash"
    private const val CRASH_LOG_FILE = "crash.log"

    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrash(context, thread, throwable)
            } catch (e: Exception) {
                Log.e(TAG, "Crash logger failed: ${e.message}")
            } finally {
                previous?.uncaughtException(thread, throwable)
            }
        }
    }

    private fun writeCrash(context: Context, thread: Thread, throwable: Throwable) {
        val sw = StringWriter()
        throwable.printStackTrace(PrintWriter(sw))
        val stack = sw.toString()
        val info = buildString {
            append("OS=").append(Build.VERSION.RELEASE)
            append(" (SDK ").append(Build.VERSION.SDK_INT).append(")")
            append(", Device=").append(Build.MODEL)
            append(", Brand=").append(Build.BRAND)
            append(", Thread=").append(thread.name)
            append('\n')
        }
        val logText = "==== SkyBridge Crash ====\n$info$stack"
        Log.e(TAG, logText)
        File(context.filesDir, CRASH_LOG_FILE).writeText(logText)
    }
}

