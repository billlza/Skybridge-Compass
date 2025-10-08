package com.yunqiao.sinan.app

import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class CrashReporter(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US)

    fun record(thread: Thread, throwable: Throwable) {
        executor.execute {
            runCatching {
                val directory = File(context.filesDir, "crash_reports")
                if (!directory.exists()) {
                    directory.mkdirs()
                }
                val timestamp = dateFormat.format(Date())
                val file = File(directory, "crash_$timestamp.log")
                val writer = StringWriter()
                val printWriter = PrintWriter(writer)
                printWriter.println("thread=${thread.name}")
                throwable.printStackTrace(printWriter)
                printWriter.flush()
                file.writeText(writer.toString())
            }.onFailure {
                Log.e(TAG, "Failed to persist crash report", it)
            }
        }
    }

    private companion object {
        const val TAG = "CrashReporter"
    }
}
