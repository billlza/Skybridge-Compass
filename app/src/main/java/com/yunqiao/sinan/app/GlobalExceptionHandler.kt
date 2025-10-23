package com.yunqiao.sinan.app

import android.content.Context
import android.os.Process
import android.util.Log
import java.lang.Thread.UncaughtExceptionHandler
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

class GlobalExceptionHandler(
    private val context: Context,
    private val delegate: UncaughtExceptionHandler? = Thread.getDefaultUncaughtExceptionHandler()
) : UncaughtExceptionHandler {
    private val crashReporter = CrashReporter(context)
    private val isInstalled = AtomicBoolean(false)

    fun install() {
        if (isInstalled.compareAndSet(false, true)) {
            Thread.setDefaultUncaughtExceptionHandler(this)
        }
    }

    override fun uncaughtException(thread: Thread, throwable: Throwable) {
        Log.e(TAG, "Uncaught exception on ${thread.name}", throwable)
        crashReporter.record(thread, throwable)
        delegate?.uncaughtException(thread, throwable) ?: run {
            Process.killProcess(Process.myPid())
            exitProcess(10)
        }
    }

    private companion object {
        const val TAG = "GlobalExceptionHandler"
    }
}
