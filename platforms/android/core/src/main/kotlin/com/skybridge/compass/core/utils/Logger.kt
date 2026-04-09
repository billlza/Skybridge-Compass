package com.skybridge.compass.core.utils

import com.skybridge.compass.core.BuildConfig

/**
 * 统一日志管理工具
 */
object Logger {
    
    private const val DEFAULT_TAG = "SkyBridge"
    private var isDebugMode = BuildConfig.DEBUG
    private var logLevel = LogLevel.DEBUG
    
    // Flag to detect if we're running in a unit test environment (no Android framework)
    private val isAndroidAvailable: Boolean by lazy {
        try {
            Class.forName("android.util.Log")
            // Touch the logging backend so unit-test shims are filtered out.
            android.util.Log.isLoggable("test", android.util.Log.DEBUG)
            true
        } catch (e: Throwable) {
            false
        }
    }
    
    enum class LogLevel(val priority: Int) {
        VERBOSE(2),
        DEBUG(3),
        INFO(4),
        WARN(5),
        ERROR(6)
    }
    
    /**
     * 设置日志级别
     */
    fun setLogLevel(level: LogLevel) {
        logLevel = level
    }
    
    /**
     * 设置调试模式
     */
    fun setDebugMode(debug: Boolean) {
        isDebugMode = debug
    }
    
    /**
     * Verbose 日志
     */
    fun v(tag: String = DEFAULT_TAG, message: String, throwable: Throwable? = null) {
        if (shouldLog(LogLevel.VERBOSE)) {
            logInternal(LogLevel.VERBOSE, tag, message, throwable)
        }
    }
    
    /**
     * Debug 日志
     */
    fun d(tag: String = DEFAULT_TAG, message: String, throwable: Throwable? = null) {
        if (shouldLog(LogLevel.DEBUG)) {
            logInternal(LogLevel.DEBUG, tag, message, throwable)
        }
    }
    
    /**
     * Info 日志
     */
    fun i(tag: String = DEFAULT_TAG, message: String, throwable: Throwable? = null) {
        if (shouldLog(LogLevel.INFO)) {
            logInternal(LogLevel.INFO, tag, message, throwable)
        }
    }
    
    /**
     * Warning 日志
     */
    fun w(tag: String = DEFAULT_TAG, message: String, throwable: Throwable? = null) {
        if (shouldLog(LogLevel.WARN)) {
            logInternal(LogLevel.WARN, tag, message, throwable)
        }
    }
    
    /**
     * Error 日志
     */
    fun e(tag: String = DEFAULT_TAG, message: String, throwable: Throwable? = null) {
        if (shouldLog(LogLevel.ERROR)) {
            logInternal(LogLevel.ERROR, tag, message, throwable)
        }
    }
    
    /**
     * Internal logging that handles both Android and JVM environments
     */
    private fun logInternal(level: LogLevel, tag: String, message: String, throwable: Throwable?) {
        if (isAndroidAvailable) {
            when (level) {
                LogLevel.VERBOSE -> if (throwable != null) android.util.Log.v(tag, message, throwable) else android.util.Log.v(tag, message)
                LogLevel.DEBUG -> if (throwable != null) android.util.Log.d(tag, message, throwable) else android.util.Log.d(tag, message)
                LogLevel.INFO -> if (throwable != null) android.util.Log.i(tag, message, throwable) else android.util.Log.i(tag, message)
                LogLevel.WARN -> if (throwable != null) android.util.Log.w(tag, message, throwable) else android.util.Log.w(tag, message)
                LogLevel.ERROR -> if (throwable != null) android.util.Log.e(tag, message, throwable) else android.util.Log.e(tag, message)
            }
        } else {
            // Fallback for JVM unit tests - print to console
            val levelName = level.name.first()
            val logMessage = "$levelName/$tag: $message"
            if (level == LogLevel.ERROR || level == LogLevel.WARN) {
                System.err.println(logMessage)
                throwable?.printStackTrace(System.err)
            } else {
                println(logMessage)
                throwable?.printStackTrace()
            }
        }
    }
    
    /**
     * 网络日志
     */
    fun network(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.NETWORK, message, throwable)
    }
    
    /**
     * 设备发现日志
     */
    fun discovery(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.DISCOVERY, message, throwable)
    }
    
    /**
     * 连接日志
     */
    fun connection(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.CONNECTION, message, throwable)
    }
    
    /**
     * 屏幕镜像日志
     */
    fun screenMirroring(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.SCREEN_MIRRORING, message, throwable)
    }
    
    /**
     * 文件传输日志
     */
    fun fileTransfer(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.FILE_TRANSFER, message, throwable)
    }
    
    /**
     * 远程控制日志
     */
    fun remoteControl(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.REMOTE_CONTROL, message, throwable)
    }
    
    /**
     * 数据库日志
     */
    fun database(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.DATABASE, message, throwable)
    }
    
    /**
     * UI 日志
     */
    fun ui(message: String, throwable: Throwable? = null) {
        d(Constants.LogTags.UI, message, throwable)
    }
    
    /**
     * 判断是否应该输出日志
     */
    private fun shouldLog(level: LogLevel): Boolean {
        return isDebugMode && level.priority >= logLevel.priority
    }
    
    /**
     * 格式化日志消息
     */
    private fun formatMessage(message: String): String {
        val stackTrace = Thread.currentThread().stackTrace
        val caller = stackTrace.getOrNull(4)
        return if (caller != null) {
            "[${caller.className.substringAfterLast('.')}:${caller.methodName}:${caller.lineNumber}] $message"
        } else {
            message
        }
    }
    
    /**
     * 性能监控日志
     */
    inline fun <T> measureTime(tag: String = "SkyBridge", operation: String, block: () -> T): T {
        val startTime = System.currentTimeMillis()
        val result = block()
        val endTime = System.currentTimeMillis()
        d(tag, "$operation 耗时: ${endTime - startTime}ms")
        return result
    }
    
    /**
     * 方法进入日志
     */
    fun enter(tag: String = "SkyBridge", methodName: String, vararg params: Any?) {
        if (shouldLog(LogLevel.DEBUG)) {
            val paramString = params.joinToString(", ") { it.toString() }
            d(tag, "进入方法: $methodName($paramString)")
        }
    }
    
    /**
     * 方法退出日志
     */
    fun exit(tag: String = "SkyBridge", methodName: String, result: Any? = null) {
        if (shouldLog(LogLevel.DEBUG)) {
            val resultString = result?.toString() ?: "void"
            d(tag, "退出方法: $methodName -> $resultString")
        }
    }
}
