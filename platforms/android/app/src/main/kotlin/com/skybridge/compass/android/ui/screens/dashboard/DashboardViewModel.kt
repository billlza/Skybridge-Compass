package com.skybridge.compass.android.ui.screens.dashboard

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.i18n.currentAppLocale
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.i18n.resolveLocalizedTextForSetting
import com.skybridge.compass.android.weather.WeatherCondition
import com.skybridge.compass.android.weather.WeatherError
import com.skybridge.compass.android.weather.WeatherRepository
import com.skybridge.compass.android.weather.WeatherState
import com.skybridge.compass.core.data.model.Connection
import com.skybridge.compass.core.data.model.ConnectionProtocol
import com.skybridge.compass.core.data.model.ConnectionStatus
import com.skybridge.compass.core.repository.ConnectionRepository
import com.skybridge.compass.core.services.HardwareMonitorService
import com.skybridge.compass.core.services.NetworkQuality
import com.skybridge.compass.core.services.NetworkState
import com.skybridge.compass.core.services.QualityLevel
import com.skybridge.compass.core.services.TransferStatistics
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import kotlin.math.roundToInt
import javax.inject.Inject

@HiltViewModel
class DashboardViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val hardwareMonitor: HardwareMonitorService,
    private val startDeviceDiscoveryUseCase: StartDeviceDiscoveryUseCase,
    private val connectionRepository: ConnectionRepository,
    private val weatherRepository: WeatherRepository
) : ViewModel() {

    private var latestDiscoveredDevices: List<DiscoveredDevice> = emptyList()
    private var latestActiveConnections: List<Connection> = emptyList()
    private var latestConnectedDeviceCount: Int = 0
    private var latestTransferStats = TransferStatistics(0L, 0L, 0, 0)
    private var latestNetworkState = NetworkState(
        isConnected = false,
        isWifi = false,
        isCellular = false,
        isEthernet = false
    )
    private var latestNetworkQuality = NetworkQuality.offline()
    private var latestWeatherState = WeatherState()
    private var latestAppLanguage: String = APP_LANGUAGE_SYSTEM

    var uiState by mutableStateOf(DashboardUiState())
        private set

    init {
        observeAppLanguage()
        observeHardwareState()
        observeWeatherState()
        observeRecentDevices()
        observeActiveConnections()
        measureNetworkQuality()
        weatherRepository.refreshWeather()
    }

    private fun t(zh: String, en: String, ja: String): String =
        resolveLocalizedTextForSetting(latestAppLanguage, zh, en, ja)

    private fun observeAppLanguage() {
        AppSettingsStore.observeAppLanguage(context)
            .onEach { language ->
                latestAppLanguage = language
                renderOverviewState()
                refreshPeerSections()
            }
            .launchIn(viewModelScope)
    }

    /**
     * 观察硬件状态变化
     */
    private fun observeHardwareState() {
        // 组合多个 Flow 来更新 UI 状态
        combine(
            hardwareMonitor.getConnectedDeviceCount(),
            hardwareMonitor.getTransferStatistics(),
            hardwareMonitor.observeNetworkState(),
            hardwareMonitor.observeNetworkQuality()
        ) { deviceCount, transferStats, networkState, networkQuality ->
            latestConnectedDeviceCount = deviceCount
            latestTransferStats = transferStats
            latestNetworkState = networkState
            latestNetworkQuality = networkQuality
            renderOverviewState()
        }.launchIn(viewModelScope)
    }

    private fun observeWeatherState() {
        weatherRepository.observeWeather()
            .onEach { weatherState ->
                latestWeatherState = weatherState
                renderOverviewState()
            }
            .launchIn(viewModelScope)
    }

    private fun observeRecentDevices() {
        viewModelScope.launch {
            runCatching {
                startDeviceDiscoveryUseCase(
                    protocols = DiscoveryProtocolProfiles.appleInteropDefaults,
                    enableQuantumOptimization = false
                )
            }.onSuccess { flow ->
                flow
                    .catch { throwable ->
                        uiState = uiState.copy(
                            error = throwable.message ?: t("设备发现失败", "Device discovery failed", "デバイス検出に失敗しました")
                        )
                    }
                    .collect { devices ->
                        latestDiscoveredDevices = devices
                        refreshPeerSections()
                    }
            }
        }
    }

    private fun observeActiveConnections() {
        connectionRepository.getActiveConnections()
            .onEach { connections ->
                latestActiveConnections = connections
                refreshPeerSections()
            }
            .catch { throwable ->
                uiState = uiState.copy(
                    error = throwable.message ?: t("连接状态读取失败", "Failed to read connection status", "接続状態の読み取りに失敗しました")
                )
            }
            .launchIn(viewModelScope)
    }

    private fun refreshPeerSections() {
        val recentDevices = latestDiscoveredDevices
            .sortedByDescending { it.lastSeen }
            .take(3)
            .map { device ->
                DashboardRecentDevice(
                    id = device.id,
                    name = device.name.ifBlank { t("未知设备", "Unknown Device", "不明なデバイス") },
                    platformLabel = device.type.toDisplayLabel(latestAppLanguage),
                    address = "${device.connectionInfo.address}:${device.connectionInfo.port}",
                    signalStrength = device.signalStrength,
                    isConnected = device.isConnected
                )
            }

        val devicesById = latestDiscoveredDevices.associateBy { it.id }
        val activeConnections = latestActiveConnections
            .sortedByDescending { it.lastActivity }
            .take(3)
            .map { connection ->
                val peer = devicesById[connection.deviceId]
                DashboardActiveConnection(
                    id = connection.id,
                    deviceName = peer?.name
                        ?: connection.metadata["deviceName"]
                        ?: connection.deviceId.take(8),
                    platformLabel = peer?.type?.toDisplayLabel(latestAppLanguage)
                        ?: t("未知平台", "Unknown Platform", "不明なプラットフォーム"),
                    statusLabel = connection.status.toDisplayLabel(latestAppLanguage),
                    protocolLabel = connection.protocol.toDisplayLabel(),
                    latencyMs = connection.latency.coerceAtLeast(0)
                )
            }

        uiState = uiState.copy(
            recentDevices = recentDevices,
            activeConnections = activeConnections,
            connectedDevices = recentDevices.size.takeIf { it > 0 } ?: uiState.connectedDevices,
            activeSessions = activeConnections.size.takeIf { it > 0 } ?: uiState.activeSessions
        )
    }

    private fun renderOverviewState() {
        val qualityLabel = when (latestNetworkQuality.level) {
            QualityLevel.EXCELLENT -> t("优秀", "Excellent", "優秀")
            QualityLevel.GOOD -> t("良好", "Good", "良好")
            QualityLevel.FAIR -> t("一般", "Fair", "普通")
            QualityLevel.POOR -> t("较差", "Poor", "不良")
            QualityLevel.OFFLINE -> t("离线", "Offline", "オフライン")
        }

        val totalBytes = latestTransferStats.totalBytesSent + latestTransferStats.totalBytesReceived
        val transferredMb = totalBytes / (1024 * 1024)
        val discoveredCount = latestDiscoveredDevices.size.takeIf { it > 0 } ?: latestConnectedDeviceCount
        val connectionCount = latestActiveConnections.size.takeIf { it > 0 } ?: latestTransferStats.activeTransfers

        uiState = uiState.copy(
            connectedDevices = discoveredCount,
            activeSessions = connectionCount,
            networkQuality = qualityLabel,
            dataTransferredLabel = "$transferredMb MB",
            networkLatencyMs = latestNetworkQuality.latencyMs.coerceAtLeast(0),
            isOffline = !latestNetworkState.isConnected,
            weather = buildWeatherCardState(),
            isLoading = latestWeatherState.isLoading,
            error = uiState.error
        )
    }

    private fun buildWeatherCardState(): DashboardWeatherCardState {
        val weather = latestWeatherState.weather
        if (weather == null) {
            val conditionText = when (latestWeatherState.error) {
                WeatherError.NETWORK_UNAVAILABLE ->
                    t("实时天气暂不可用", "Live weather unavailable", "リアル天気を利用できません")
                WeatherError.WEATHER_UNAVAILABLE ->
                    t("天气未同步", "Weather not synced", "天気は未同期です")
                null -> if (latestWeatherState.isLoading) {
                    t("正在同步天气", "Syncing weather", "天気を同期しています")
                } else {
                    t("天气未同步", "Weather not synced", "天気は未同期です")
                }
            }
            val updatedText = when {
                latestWeatherState.isLoading ->
                    t("正在获取实时天气", "Fetching live weather", "天気を取得しています")
                latestWeatherState.error == WeatherError.NETWORK_UNAVAILABLE ->
                    t("请检查网络后重试", "Check your network and try again", "ネットワークを確認して再試行してください")
                else -> t("等待更新", "Waiting for update", "更新待ち")
            }
            return DashboardWeatherCardState(
                icon = if (latestNetworkState.isConnected) DashboardWeatherIcon.Cloudy else DashboardWeatherIcon.Offline,
                temperatureText = "--°",
                conditionText = conditionText,
                locationText = t("当前位置", "Current Area", "現在地"),
                humidityText = "--",
                windText = "--",
                sourceText = t("实时天气", "Live Weather", "リアル天気"),
                updatedText = updatedText
            )
        }

        val formatter = SimpleDateFormat("HH:mm", currentAppLocale())
        val timeLabel = formatter.format(Date(weather.updatedAtEpochMillis))
        val sourceLabel = if (weather.isFromCache) {
            "${t("缓存", "Cache", "キャッシュ")} · ${weather.sourceName}"
        } else {
            weather.sourceName
        }

        return DashboardWeatherCardState(
            icon = weather.condition.toDashboardWeatherIcon(),
            temperatureText = "${weather.temperatureCelsius.roundToInt()}°",
            conditionText = weather.condition.toDisplayText(latestAppLanguage),
            locationText = weather.locationName.ifBlank { t("当前位置", "Current Area", "現在地") },
            humidityText = weather.humidityPercent?.let { "$it%" } ?: "--",
            windText = weather.windSpeedKmh?.let { "${it.roundToInt()} km/h" } ?: "--",
            sourceText = sourceLabel,
            updatedText = t(
                "更新于 $timeLabel",
                "Updated at $timeLabel",
                "$timeLabel 更新"
            )
        )
    }

    /**
     * 测量网络质量
     */
    fun measureNetworkQuality() {
        viewModelScope.launch {
            uiState = uiState.copy(isLoading = true)
            
            // 测量到常用服务器的延迟
            val latency = hardwareMonitor.measureNetworkLatency("8.8.8.8", 53)
            
            // 获取估算带宽（如果实现支持）
            val bandwidth = (hardwareMonitor as? com.skybridge.compass.core.services.HardwareMonitorServiceImpl)
                ?.estimateBandwidth() ?: 10f
            
            // 简化的丢包率（实际应用中可以更精确测量）
            val packetLoss = if (latency < 0) 100f else 0f
            
            val quality = hardwareMonitor.calculateNetworkQuality(latency, bandwidth, packetLoss)
            
            // 更新网络质量（如果实现支持）
            (hardwareMonitor as? com.skybridge.compass.core.services.HardwareMonitorServiceImpl)
                ?.updateNetworkQuality(quality)
            
            uiState = uiState.copy(isLoading = false)
        }
    }

    /**
     * 刷新所有数据
     */
    fun refresh() {
        measureNetworkQuality()
        weatherRepository.refreshWeather(forceCurrentLocation = true)
    }
}

data class DashboardUiState(
    val connectedDevices: Int = 0,
    val activeSessions: Int = 0,
    val networkQuality: String = resolveLocalizedText("未知", "Unknown", "不明"),
    val dataTransferredLabel: String = "0 MB",
    val transferProgress: Float = 0f,
    val networkLatencyMs: Long = 0L,
    val weather: DashboardWeatherCardState = DashboardWeatherCardState(),
    val recentDevices: List<DashboardRecentDevice> = emptyList(),
    val activeConnections: List<DashboardActiveConnection> = emptyList(),
    val isLoading: Boolean = true,
    val isOffline: Boolean = false,
    val error: String? = null
)

data class DashboardWeatherCardState(
    val icon: DashboardWeatherIcon = DashboardWeatherIcon.Cloudy,
    val temperatureText: String = "--°",
    val conditionText: String = resolveLocalizedText("天气未同步", "Weather not synced", "天気は未同期です"),
    val locationText: String = resolveLocalizedText("当前位置", "Current Area", "現在地"),
    val humidityText: String = "--",
    val windText: String = "--",
    val sourceText: String = resolveLocalizedText("实时天气", "Live Weather", "リアル天気"),
    val updatedText: String = resolveLocalizedText("等待更新", "Waiting for update", "更新待ち")
)

enum class DashboardWeatherIcon {
    Sunny,
    Cloudy,
    Rainy,
    Offline
}

data class DashboardRecentDevice(
    val id: String,
    val name: String,
    val platformLabel: String,
    val address: String,
    val signalStrength: Int,
    val isConnected: Boolean
)

data class DashboardActiveConnection(
    val id: String,
    val deviceName: String,
    val platformLabel: String,
    val statusLabel: String,
    val protocolLabel: String,
    val latencyMs: Long
)

private fun WeatherCondition.toDashboardWeatherIcon(): DashboardWeatherIcon = when (this) {
    WeatherCondition.CLEAR -> DashboardWeatherIcon.Sunny
    WeatherCondition.PARTLY_CLOUDY,
    WeatherCondition.CLOUDY,
    WeatherCondition.FOGGY,
    WeatherCondition.HAZE,
    WeatherCondition.UNKNOWN -> DashboardWeatherIcon.Cloudy
    WeatherCondition.RAINY,
    WeatherCondition.SNOWY,
    WeatherCondition.STORMY -> DashboardWeatherIcon.Rainy
}

private fun WeatherCondition.toDisplayText(languageSetting: String): String = when (this) {
    WeatherCondition.CLEAR -> resolveLocalizedTextForSetting(languageSetting, "晴朗", "Clear", "晴れ")
    WeatherCondition.PARTLY_CLOUDY -> resolveLocalizedTextForSetting(languageSetting, "局部多云", "Partly Cloudy", "晴れ時々くもり")
    WeatherCondition.CLOUDY -> resolveLocalizedTextForSetting(languageSetting, "多云", "Cloudy", "くもり")
    WeatherCondition.RAINY -> resolveLocalizedTextForSetting(languageSetting, "降雨", "Rain", "雨")
    WeatherCondition.SNOWY -> resolveLocalizedTextForSetting(languageSetting, "降雪", "Snow", "雪")
    WeatherCondition.FOGGY -> resolveLocalizedTextForSetting(languageSetting, "有雾", "Fog", "霧")
    WeatherCondition.HAZE -> resolveLocalizedTextForSetting(languageSetting, "雾霾", "Haze", "もや")
    WeatherCondition.STORMY -> resolveLocalizedTextForSetting(languageSetting, "雷暴", "Storm", "雷雨")
    WeatherCondition.UNKNOWN -> resolveLocalizedTextForSetting(languageSetting, "天气未知", "Weather Unknown", "天気不明")
}

private fun DeviceType.toDisplayLabel(languageSetting: String): String = when (this) {
    DeviceType.IOS -> "iOS"
    DeviceType.MACOS -> "macOS"
    DeviceType.ANDROID -> "Android"
    DeviceType.WINDOWS -> "Windows"
    DeviceType.LINUX -> "Linux"
    DeviceType.UNKNOWN -> resolveLocalizedTextForSetting(languageSetting, "未知", "Unknown", "不明")
}

private fun ConnectionStatus.toDisplayLabel(languageSetting: String): String = when (this) {
    ConnectionStatus.CONNECTING -> resolveLocalizedTextForSetting(languageSetting, "连接中", "Connecting", "接続中")
    ConnectionStatus.CONNECTED -> resolveLocalizedTextForSetting(languageSetting, "已连接", "Connected", "接続済み")
    ConnectionStatus.DISCONNECTING -> resolveLocalizedTextForSetting(languageSetting, "断开中", "Disconnecting", "切断中")
    ConnectionStatus.DISCONNECTED -> resolveLocalizedTextForSetting(languageSetting, "已断开", "Disconnected", "切断済み")
    ConnectionStatus.ERROR -> resolveLocalizedTextForSetting(languageSetting, "错误", "Error", "エラー")
    ConnectionStatus.TIMEOUT -> resolveLocalizedTextForSetting(languageSetting, "超时", "Timed Out", "タイムアウト")
}

private fun ConnectionProtocol.toDisplayLabel(): String = when (this) {
    ConnectionProtocol.TCP -> "TCP"
    ConnectionProtocol.UDP -> "UDP"
    ConnectionProtocol.WEBSOCKET -> "WebSocket"
    ConnectionProtocol.HTTP -> "HTTP"
    ConnectionProtocol.HTTPS -> "HTTPS"
}
