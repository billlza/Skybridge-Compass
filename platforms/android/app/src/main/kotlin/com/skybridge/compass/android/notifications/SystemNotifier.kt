package com.skybridge.compass.android.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * `notifications_enabled` 的桥接门判定（R7.2）。
 *
 * [SystemNotifier] 订阅 `AppSettingsStore.observeNotifications`，并用该值决定是否把应用内通知
 * 事件桥接为安卓系统通知。判定提取为纯函数，使「关闭开关后不再发布系统通知」可被单元测试证明。
 */
internal fun shouldPostBridgedNotification(notificationsEnabled: Boolean): Boolean =
    notificationsEnabled

/**
 * 系统通知发布器
 * - 创建通知渠道
 * - 将应用内通知桥接到安卓系统通知
 */
object SystemNotifier {
    private const val CHANNEL_INFO = "skybridge_info"
    private const val CHANNEL_SUCCESS = "skybridge_success"
    private const val CHANNEL_WARNING = "skybridge_warning"
    private const val CHANNEL_ERROR = "skybridge_error"

    private var initialized = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile
    private var notificationsEnabled: Boolean = true

    fun init(context: Context) {
        if (initialized) return
        val appContext = context.applicationContext
        createChannels(appContext)
        // Observe "Notifications" setting and gate non-security system notifications.
        scope.launch {
            AppSettingsStore.observeNotifications(appContext).collect { enabled ->
                notificationsEnabled = enabled
            }
        }
        NotificationCenter.systemNotifier = { event ->
            try {
                if (shouldPostBridgedNotification(notificationsEnabled)) {
                    postSystemNotification(appContext, event)
                }
            } catch (t: Throwable) {
                Log.w("SystemNotifier", "Failed to post bridged system notification", t)
            }
        }
        initialized = true
    }

    private fun createChannels(context: Context) {
        val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channels = listOf(
            NotificationChannel(
                CHANNEL_INFO,
                resolveLocalizedText("SkyBridge 信息", "SkyBridge Info", "SkyBridge 情報"),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = resolveLocalizedText("一般信息提示", "General information", "一般情報")
                enableLights(true); lightColor = Color.BLUE
            },
            NotificationChannel(
                CHANNEL_SUCCESS,
                resolveLocalizedText("SkyBridge 成功", "SkyBridge Success", "SkyBridge 成功"),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = resolveLocalizedText("成功提示", "Success messages", "成功メッセージ")
                enableLights(true); lightColor = Color.GREEN
            },
            NotificationChannel(
                CHANNEL_WARNING,
                resolveLocalizedText("SkyBridge 警告", "SkyBridge Warning", "SkyBridge 警告"),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = resolveLocalizedText("警告与注意事项", "Warnings and cautions", "警告と注意事項")
                enableLights(true); lightColor = Color.YELLOW
            },
            NotificationChannel(
                CHANNEL_ERROR,
                resolveLocalizedText("SkyBridge 错误", "SkyBridge Error", "SkyBridge エラー"),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = resolveLocalizedText("错误与异常", "Errors and exceptions", "エラーと例外")
                enableLights(true); lightColor = Color.RED
            }
        )
        mgr.createNotificationChannels(channels)
    }

    private fun channelFor(severity: NotificationSeverity): String = when (severity) {
        NotificationSeverity.INFO -> CHANNEL_INFO
        NotificationSeverity.SUCCESS -> CHANNEL_SUCCESS
        NotificationSeverity.WARNING -> CHANNEL_WARNING
        NotificationSeverity.ERROR -> CHANNEL_ERROR
    }

    private fun priorityFor(severity: NotificationSeverity): Int = when (severity) {
        NotificationSeverity.INFO -> NotificationCompat.PRIORITY_DEFAULT
        NotificationSeverity.SUCCESS -> NotificationCompat.PRIORITY_DEFAULT
        NotificationSeverity.WARNING -> NotificationCompat.PRIORITY_HIGH
        NotificationSeverity.ERROR -> NotificationCompat.PRIORITY_HIGH
    }

    private fun smallIconFor(module: NotificationModule): Int {
        // 使用系统默认图标以避免资源缺失
        return android.R.drawable.stat_notify_more
    }

    private fun postSystemNotification(context: Context, event: NotificationEvent) {
        if (
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val builder = NotificationCompat.Builder(context, channelFor(event.severity))
            .setSmallIcon(smallIconFor(event.module))
            .setContentTitle(event.title)
            .setContentText(event.message)
            .setPriority(priorityFor(event.severity))
            .setAutoCancel(true)

        val id = event.id.hashCode()
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }
}
