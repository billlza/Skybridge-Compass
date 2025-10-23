package com.yunqiao.sinan.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews
import com.yunqiao.sinan.R
import com.yunqiao.sinan.manager.SystemMetrics
import kotlin.math.pow
import kotlin.math.roundToInt

private const val PREF_WIDGET_STATUS = "widget_status_cache"
private const val KEY_CPU_USAGE = "cpu_usage"
private const val KEY_MEMORY_USAGE = "memory_usage"
private const val KEY_BATTERY_LEVEL = "battery_level"
private const val KEY_CPU_TEMPERATURE = "cpu_temperature"

object StatusWidgetUpdater {

    fun onMetricsUpdated(context: Context, metrics: SystemMetrics) {
        cacheMetrics(context, metrics)
        updateWidgets(context, metrics.toSnapshot())
    }

    fun updateWidgets(context: Context) {
        val snapshot = loadSnapshot(context)
        updateWidgets(context, snapshot)
    }

    private fun updateWidgets(context: Context, snapshot: WidgetMetricsSnapshot) {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val componentName = ComponentName(context, StatusWidgetProvider::class.java)
        val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
        if (widgetIds.isEmpty()) {
            return
        }
        val remoteViews = RemoteViews(context.packageName, R.layout.widget_status_summary).apply {
            setTextViewText(R.id.widget_title, "云桥司南")
            setTextViewText(
                R.id.widget_cpu_usage,
                "CPU ${snapshot.cpuUsage.roundTo(1)}% | ${snapshot.cpuTemperature.roundTo(1)}°C"
            )
            setTextViewText(
                R.id.widget_memory_usage,
                "内存 ${snapshot.memoryUsage.roundTo(1)}%"
            )
            setTextViewText(
                R.id.widget_battery_level,
                "电量 ${snapshot.batteryLevel}%"
            )
        }
        widgetIds.forEach { id ->
            appWidgetManager.updateAppWidget(id, remoteViews)
        }
    }

    private fun cacheMetrics(context: Context, metrics: SystemMetrics) {
        val prefs = context.getSharedPreferences(PREF_WIDGET_STATUS, Context.MODE_PRIVATE)
        prefs.edit()
            .putFloat(KEY_CPU_USAGE, metrics.cpuUsage)
            .putFloat(KEY_MEMORY_USAGE, metrics.memoryUsage)
            .putInt(KEY_BATTERY_LEVEL, metrics.batteryLevel)
            .putFloat(KEY_CPU_TEMPERATURE, metrics.cpuTemperature)
            .apply()
    }

    private fun loadSnapshot(context: Context): WidgetMetricsSnapshot {
        val prefs = context.getSharedPreferences(PREF_WIDGET_STATUS, Context.MODE_PRIVATE)
        return WidgetMetricsSnapshot(
            cpuUsage = prefs.getFloat(KEY_CPU_USAGE, 0f),
            memoryUsage = prefs.getFloat(KEY_MEMORY_USAGE, 0f),
            batteryLevel = prefs.getInt(KEY_BATTERY_LEVEL, 0),
            cpuTemperature = prefs.getFloat(KEY_CPU_TEMPERATURE, 0f)
        )
    }

    private fun SystemMetrics.toSnapshot(): WidgetMetricsSnapshot {
        return WidgetMetricsSnapshot(
            cpuUsage = cpuUsage,
            memoryUsage = memoryUsage,
            batteryLevel = batteryLevel,
            cpuTemperature = cpuTemperature
        )
    }

    private fun Float.roundTo(scale: Int): Float {
        val factor = 10.0.pow(scale).toFloat()
        return (this * factor).roundToInt() / factor
    }
}

private data class WidgetMetricsSnapshot(
    val cpuUsage: Float,
    val memoryUsage: Float,
    val batteryLevel: Int,
    val cpuTemperature: Float
)
