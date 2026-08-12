package com.skybridge.compass.remotecontrol.service

import android.accessibilityservice.AccessibilityService
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.view.accessibility.AccessibilityEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.execution.InputExecutionManager
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.*
import javax.inject.Inject

/**
 * 远程控制无障碍服务
 * 提供系统级输入事件执行能力
 *
 * Canonical wiring only: this service exists to hand the live [AccessibilityService] instance to the
 * shared singleton [InputExecutionManager]. The actual remote-control wire (P2P handshake + framed
 * RemoteMessage transport) is owned by AndroidRemoteControlHostService, which drives the same
 * InputExecutionManager singleton. The former network-transmission path (RemoteControlTransmissionManager,
 * a non-canonical NetworkClient JSON schema that no real iOS/Mac peer speaks) was removed.
 *
 * Local stop entry (R6.7): while injection is active this service keeps a persistent, ongoing
 * notification carrying a "stop injection" action, and simultaneously listens for the
 * [ACTION_STOP_REMOTE_INJECTION] broadcast that the RemoteControlViewModel teardown hook already
 * sends. Either trigger calls [InputExecutionManager.stopAllInjectionNow], which closes the admission
 * gate synchronously and cancels in-flight injection — well inside the 1 second budget. Both entries
 * exist because the notification can be suppressed when the user has not granted POST_NOTIFICATIONS,
 * and the stop affordance must stay continuously available regardless.
 */
@AndroidEntryPoint
class RemoteControlAccessibilityService : AccessibilityService() {

    @Inject
    lateinit var inputExecutionManager: InputExecutionManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** Local stop entry receiver: honours the existing injection-stop broadcast action. */
    private val stopInjectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_REMOTE_INJECTION) {
                Logger.remoteControl("收到本地停止注入广播")
                stopRemoteControlNow()
            }
        }
    }

    private var receiverRegistered = false

    override fun onServiceConnected() {
        super.onServiceConnected()

        try {
            Logger.remoteControl("远程控制无障碍服务已连接")

            // 设置无障碍服务引用（供 AndroidRemoteControlHostService 执行输入事件）
            inputExecutionManager.setAccessibilityService(this)

            registerStopEntryReceiver()

            Logger.remoteControl("远程控制服务初始化完成")

        } catch (e: Exception) {
            Logger.remoteControl("远程控制无障碍服务连接失败", e)
        }
    }
    
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 这里可以监听系统的无障碍事件，用于调试或其他用途
        // 对于远程控制功能，我们主要关注输入事件的执行，而不是监听
    }
    
    override fun onInterrupt() {
        Logger.remoteControl("远程控制无障碍服务被中断")
    }
    
    override fun onDestroy() {
        super.onDestroy()
        
        try {
            Logger.remoteControl("远程控制无障碍服务正在销毁")

            // R6.7: 服务销毁即刻停止全部注入并撤下本地停止入口
            inputExecutionManager.stopAllInjectionNow()
            unregisterStopEntryReceiver()
            removeStopEntryNotification()

            // 清理资源
            inputExecutionManager.cleanup()

            // 取消协程作用域
            serviceScope.cancel()

            Logger.remoteControl("远程控制无障碍服务已销毁")

        } catch (e: Exception) {
            Logger.remoteControl("销毁远程控制无障碍服务失败", e)
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Logger.remoteControl("远程控制无障碍服务启动命令: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START_REMOTE_CONTROL -> {
                startRemoteControl()
            }
            ACTION_STOP_REMOTE_CONTROL,
            ACTION_STOP_REMOTE_INJECTION -> {
                stopRemoteControlNow()
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 启动远程控制
     */
    private fun startRemoteControl() {
        serviceScope.launch {
            try {
                Logger.remoteControl("启动远程控制")
                
                // 启动输入执行
                inputExecutionManager.startExecution()

                // R6.7: 注入生效期间持续提供本地停止入口
                showStopEntryNotification()
                
                Logger.remoteControl("远程控制已启动")
                
            } catch (e: Exception) {
                Logger.remoteControl("启动远程控制失败", e)
            }
        }
    }
    
    /**
     * 停止远程控制（本地停止入口的落点）。
     *
     * 同步执行，使触发后全部注入立即停止（R6.7 的 1 秒预算）；不经协程调度，避免主线程繁忙时延迟。
     */
    private fun stopRemoteControlNow() {
        try {
            Logger.remoteControl("停止远程控制（本地停止入口）")

            inputExecutionManager.stopAllInjectionNow()
            removeStopEntryNotification()

            Logger.remoteControl("远程控制已停止")

        } catch (e: Exception) {
            Logger.remoteControl("停止远程控制失败", e)
        }
    }

    private fun registerStopEntryReceiver() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(
            this,
            stopInjectionReceiver,
            IntentFilter(ACTION_STOP_REMOTE_INJECTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    private fun unregisterStopEntryReceiver() {
        if (!receiverRegistered) return
        runCatching { unregisterReceiver(stopInjectionReceiver) }
        receiverRegistered = false
    }

    /** Persistent local stop affordance shown for as long as injection may run. */
    private fun showStopEntryNotification() {
        ensureNotificationChannel()
        val stopIntent = Intent(ACTION_STOP_REMOTE_INJECTION).setPackage(packageName)
        val stopPendingIntent = PendingIntent.getBroadcast(
            this,
            STOP_REQUEST_CODE,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(TEXT_TITLE)
            .setContentText(TEXT_INJECTION_ACTIVE)
            .setSmallIcon(android.R.drawable.ic_menu_close_clear_cancel)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                TEXT_STOP_ACTION,
                stopPendingIntent,
            )
            .build()

        runCatching {
            notificationManager().notify(NOTIFICATION_ID, notification)
        }.onFailure { Logger.remoteControl("展示本地停止入口通知失败", it) }
    }

    private fun removeStopEntryNotification() {
        runCatching { notificationManager().cancel(NOTIFICATION_ID) }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureNotificationChannel() {
        val manager = notificationManager()
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "远程输入注入",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "远程输入注入生效期间的本地停止入口"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
    
    companion object {
        const val ACTION_START_REMOTE_CONTROL = "com.skybridge.compass.remotecontrol.START"
        const val ACTION_STOP_REMOTE_CONTROL = "com.skybridge.compass.remotecontrol.STOP"

        /**
         * Local stop entry action. Must stay byte-identical to the action the RemoteControlViewModel
         * teardown hook broadcasts, so that hook now actually stops injection.
         */
        const val ACTION_STOP_REMOTE_INJECTION =
            "com.skybridge.compass.action.STOP_REMOTE_INJECTION"

        const val NOTIFICATION_CHANNEL_ID = "skybridge_remote_input_injection"
        const val NOTIFICATION_ID = 0x5B11
        private const val STOP_REQUEST_CODE = 0x5B11

        private const val TEXT_TITLE = "SkyBridge Compass"
        private const val TEXT_INJECTION_ACTIVE = "远程输入注入进行中"
        private const val TEXT_STOP_ACTION = "停止注入"
    }
}
