package com.skybridge.compass.android

import android.app.Application
import android.util.Log
import com.skybridge.compass.android.monitoring.AnrWatchdog
import com.skybridge.compass.android.monitoring.CrashReporter
import com.skybridge.compass.android.monitoring.FrameMetricsSampler
import com.skybridge.compass.android.monitoring.PerformanceSampler
import com.skybridge.compass.android.securityprompts.AndroidPairingTrustApprovalProvider
import com.skybridge.compass.core.p2p.PairingTrustManager
import dagger.hilt.android.HiltAndroidApp

/**
 * SkyBridge Compass Android Application
 * 
 * 主应用类，配置Hilt依赖注入和全局应用设置
 */
@HiltAndroidApp
class SkyBridgeApplication : Application() {

    private var anrWatchdog: AnrWatchdog? = null
    private var performanceSampler: PerformanceSampler? = null
    private var frameMetricsSampler: FrameMetricsSampler? = null
    
    override fun onCreate() {
        super.onCreate()
        
        // 初始化应用级别的配置
        initializeApp()

        // 初始化系统通知桥接（保证通知渠道创建与桥接注册）
        try {
            com.skybridge.compass.android.notifications.SystemNotifier.init(this)
        } catch (_: Throwable) {}
        PairingTrustManager.approvalProvider = AndroidPairingTrustApprovalProvider(applicationContext)
    }
    
    private fun initializeApp() {
        // Crash/ANR 追踪 + 性能采样
        CrashReporter.install(this)

        anrWatchdog = AnrWatchdog(this).also { it.start() }
        performanceSampler = PerformanceSampler(this).also { it.start() }
        frameMetricsSampler = FrameMetricsSampler(this).also { it.install() }

        Log.d("SkyBridgeApp", "Monitoring initialized")
    }

    override fun onTerminate() {
        super.onTerminate()
        try {
            anrWatchdog?.stopWatchdog()
            performanceSampler?.stop()
            frameMetricsSampler?.uninstall()
        } catch (_: Throwable) {}
    }
}
