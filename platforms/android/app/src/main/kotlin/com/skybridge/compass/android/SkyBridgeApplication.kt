package com.skybridge.compass.android

import android.app.Application
import android.util.Log
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager
import com.skybridge.compass.android.discovery.AndroidLocalNodeBootstrap
import com.skybridge.compass.android.monitoring.AnrWatchdog
import com.skybridge.compass.android.monitoring.CrashReporter
import com.skybridge.compass.android.monitoring.FrameMetricsSampler
import com.skybridge.compass.android.monitoring.PerformanceSampler
import com.skybridge.compass.android.securityprompts.AndroidPairingTrustApprovalProvider
import com.skybridge.compass.android.weather.WeatherAutoRefreshScheduler
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSource
import com.skybridge.compass.core.p2p.PairingTrustManager
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

/**
 * SkyBridge Compass Android Application
 * 
 * 主应用类，配置Hilt依赖注入和全局应用设置
 */
@HiltAndroidApp
class SkyBridgeApplication : Application() {

    @Inject lateinit var cloudSettingsSyncManager: CloudUserSettingsSyncManager
    @Inject lateinit var androidLocalNodeBootstrap: AndroidLocalNodeBootstrap
    @Inject lateinit var pairingApprovalParametersSource: RuntimePairingApprovalParametersSource
    @Inject lateinit var weatherAutoRefreshScheduler: WeatherAutoRefreshScheduler

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
        } catch (t: Throwable) {
            Log.w("SkyBridgeApp", "Failed to initialize system notifier", t)
        }
        PairingTrustManager.approvalProvider = AndroidPairingTrustApprovalProvider(applicationContext)
        // R7.5：把 `auto_trust_known_devices` 的读取面交给配对判定，使开关真正改变运行时行为。
        PairingTrustManager.approvalParametersSource = pairingApprovalParametersSource
        cloudSettingsSyncManager.start()
        weatherAutoRefreshScheduler.start()
        startLocalNodeDiscovery()
    }

    /** Starts Bonjour presence only when the platform local-network gate is satisfied. */
    fun startLocalNodeDiscovery(): Boolean = androidLocalNodeBootstrap.start()

    /** Stops Bonjour publication and inbound LAN sessions after local-network access is revoked. */
    fun stopLocalNodeDiscovery() = androidLocalNodeBootstrap.stop()
    
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
        stopApplicationService("anrWatchdog") { anrWatchdog?.stopWatchdog() }
        stopApplicationService("performanceSampler") { performanceSampler?.stop() }
        stopApplicationService("frameMetricsSampler") { frameMetricsSampler?.uninstall() }
        stopApplicationService("cloudSettingsSync") { cloudSettingsSyncManager.stop() }
        stopApplicationService("androidLocalNode") { androidLocalNodeBootstrap.close() }
    }

    private fun stopApplicationService(name: String, stop: () -> Unit) {
        runCatching(stop).onFailure { error ->
            Log.w("SkyBridgeApp", "Failed to stop $name", error)
        }
    }
}
