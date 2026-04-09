package com.skybridge.compass.android.ui.performance

import android.app.ActivityManager
import android.content.Context
import android.os.Debug
import android.util.Log
import androidx.compose.runtime.*
import com.skybridge.compass.android.i18n.resolveLocalizedText
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity

/**
 * 性能监控工具类
 * 用于监控内存使用、检测内存泄漏和性能问题
 */
object PerformanceMonitor {
    
    private const val TAG = "PerformanceMonitor"
    private const val MEMORY_CHECK_INTERVAL = 5000L // 5秒检查一次
    
    private val activityReferences = mutableSetOf<WeakReference<Any>>()
    private var isMonitoring = false
    private var monitorJob: Job? = null
    private var monitorScope: CoroutineScope? = null
    
    /**
     * 开始性能监控
     */
    fun startMonitoring(context: Context) {
        if (isMonitoring) return
        
        isMonitoring = true
        Log.d(TAG, "开始性能监控")
        
        // 启动内存监控
        startMemoryMonitoring(context)
    }
    
    /**
     * 停止性能监控
     */
    fun stopMonitoring() {
        isMonitoring = false
        Log.d(TAG, "停止性能监控")
        try { monitorJob?.cancel() } catch (_: Throwable) {}
        monitorJob = null
    }
    
    /**
     * 注册Activity引用以检测内存泄漏
     */
    fun registerActivity(activity: Any) {
        activityReferences.add(WeakReference(activity))
        Log.d(TAG, "注册Activity: ${activity.javaClass.simpleName}")
    }
    
    /**
     * 检查内存泄漏
     */
    fun checkMemoryLeaks() {
        System.gc() // 强制垃圾回收
        
        val leakedActivities = activityReferences.filter { it.get() != null }
        if (leakedActivities.isNotEmpty()) {
            Log.w(TAG, "检测到可能的内存泄漏: ${leakedActivities.size} 个Activity未被回收")
        }
        
        // 清理已回收的引用
        activityReferences.removeAll { it.get() == null }
    }
    
    /**
     * 获取内存使用信息
     */
    fun getMemoryInfo(context: Context): MemoryInfo {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)
        
        val runtime = Runtime.getRuntime()
        val usedMemory = runtime.totalMemory() - runtime.freeMemory()
        val maxMemory = runtime.maxMemory()
        
        return MemoryInfo(
            usedMemory = usedMemory,
            totalMemory = runtime.totalMemory(),
            maxMemory = maxMemory,
            availableMemory = memoryInfo.availMem,
            isLowMemory = memoryInfo.lowMemory,
            memoryUsagePercentage = (usedMemory.toFloat() / maxMemory * 100).toInt()
        )
    }
    
    /**
     * 启动内存监控
     */
    private fun startMemoryMonitoring(context: Context) {
        monitorScope = monitorScope ?: CoroutineScope(Dispatchers.Default)
        monitorJob = monitorScope?.launch {
            while (isMonitoring) {
                val memoryInfo = getMemoryInfo(context)

                if (memoryInfo.isLowMemory) {
                    NotificationCenter.post(
                        NotificationEvent(
                            title = resolveLocalizedText("系统内存紧张", "System Memory Low", "システムメモリ不足"),
                            message = resolveLocalizedText(
                                "设备报告低内存状态，建议关闭部分页面",
                                "The device reports low memory. Consider closing some pages.",
                                "端末が低メモリ状態です。一部の画面を閉じてください。"
                            ),
                            module = NotificationModule.PERFORMANCE,
                            severity = NotificationSeverity.ERROR
                        )
                    )
                } else if (memoryInfo.memoryUsagePercentage > 90) {
                    NotificationCenter.post(
                        NotificationEvent(
                            title = resolveLocalizedText("内存使用率过高", "High Memory Usage", "メモリ使用率が高い"),
                            message = resolveLocalizedText(
                                "当前内存使用率 ${memoryInfo.memoryUsagePercentage}%",
                                "Current memory usage: ${memoryInfo.memoryUsagePercentage}%",
                                "現在のメモリ使用率: ${memoryInfo.memoryUsagePercentage}%"
                            ),
                            module = NotificationModule.PERFORMANCE,
                            severity = NotificationSeverity.ERROR
                        )
                    )
                } else if (memoryInfo.memoryUsagePercentage > 80) {
                    NotificationCenter.post(
                        NotificationEvent(
                            title = resolveLocalizedText("内存压力较大", "Memory Pressure Rising", "メモリ負荷が高まっています"),
                            message = resolveLocalizedText(
                                "当前内存使用率 ${memoryInfo.memoryUsagePercentage}%",
                                "Current memory usage: ${memoryInfo.memoryUsagePercentage}%",
                                "現在のメモリ使用率: ${memoryInfo.memoryUsagePercentage}%"
                            ),
                            module = NotificationModule.PERFORMANCE,
                            severity = NotificationSeverity.WARNING
                        )
                    )
                }

                // 简化的UI卡顿提示：如有需要可替换为Choreographer统计
                checkUIThreadBlocking()
                
                delay(MEMORY_CHECK_INTERVAL)
            }
        }
    }
    
    /**
     * 记录性能指标
     */
    fun logPerformanceMetrics(tag: String, startTime: Long) {
        val endTime = System.currentTimeMillis()
        val duration = endTime - startTime
        
        if (duration > 100) { // 超过100ms的操作记录警告
            Log.w(TAG, "$tag 执行时间过长: ${duration}ms")
        } else {
            Log.d(TAG, "$tag 执行时间: ${duration}ms")
        }
    }
    
    /**
     * 检查UI线程阻塞
     */
    fun checkUIThreadBlocking(threshold: Long = 16L) {
        val startTime = System.currentTimeMillis()
        // 模拟检查UI线程响应时间
        val responseTime = System.currentTimeMillis() - startTime
        
        if (responseTime > threshold) {
            Log.w(TAG, "UI线程可能被阻塞: ${responseTime}ms")
        }
    }
}

/**
 * 内存信息数据类
 */
data class MemoryInfo(
    val usedMemory: Long,
    val totalMemory: Long,
    val maxMemory: Long,
    val availableMemory: Long,
    val isLowMemory: Boolean,
    val memoryUsagePercentage: Int
)

/**
 * 性能监控Composable
 * 在Compose UI中使用的性能监控组件
 */
@Composable
fun PerformanceMonitorEffect(
    context: Context,
    lifecycleOwner: LifecycleOwner
) {
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    PerformanceMonitor.startMonitoring(context)
                }
                Lifecycle.Event.ON_STOP -> {
                    PerformanceMonitor.stopMonitoring()
                }
                Lifecycle.Event.ON_DESTROY -> {
                    PerformanceMonitor.checkMemoryLeaks()
                }
                else -> {}
            }
        }
        
        lifecycleOwner.lifecycle.addObserver(observer)
        
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }
}

/**
 * 性能测量装饰器
 */
@Composable
fun <T> MeasurePerformance(
    tag: String,
    content: @Composable () -> T
): T {
    val startTime = remember { System.currentTimeMillis() }
    
    DisposableEffect(Unit) {
        onDispose {
            PerformanceMonitor.logPerformanceMetrics(tag, startTime)
        }
    }
    
    return content()
}

/**
 * 内存使用监控Composable
 */
@Composable
fun MemoryUsageMonitor(
    context: Context,
    onMemoryUpdate: (MemoryInfo) -> Unit = {}
) {
    LaunchedEffect(Unit) {
        while (true) {
            val memoryInfo = PerformanceMonitor.getMemoryInfo(context)
            onMemoryUpdate(memoryInfo)
            
            if (memoryInfo.memoryUsagePercentage > 80) {
                Log.w("MemoryMonitor", "内存使用率过高: ${memoryInfo.memoryUsagePercentage}%")
                NotificationCenter.post(
                    NotificationEvent(
                        title = resolveLocalizedText("内存使用率过高", "High Memory Usage", "メモリ使用率が高い"),
                        message = resolveLocalizedText(
                            "Compose界面检测到内存使用率 ${memoryInfo.memoryUsagePercentage}%",
                            "Compose detected memory usage at ${memoryInfo.memoryUsagePercentage}%",
                            "Compose 画面でメモリ使用率 ${memoryInfo.memoryUsagePercentage}% を検出"
                        ),
                        module = NotificationModule.PERFORMANCE,
                        severity = NotificationSeverity.WARNING
                    )
                )
            }
            
            delay(5000) // 每5秒检查一次
        }
    }
}
