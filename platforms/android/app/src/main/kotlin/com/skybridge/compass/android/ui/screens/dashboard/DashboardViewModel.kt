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
import com.skybridge.compass.android.weather.AirQualityIndex
import com.skybridge.compass.android.weather.AirQualityLevel
import com.skybridge.compass.android.weather.WeatherAvailability
import com.skybridge.compass.android.weather.WeatherCondition
import com.skybridge.compass.android.weather.WeatherError
import com.skybridge.compass.android.weather.WeatherRepository
import com.skybridge.compass.android.weather.WeatherSnapshot
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
import com.skybridge.compass.android.ui.theme.IOSParityTokens.SecurityBadgeTone
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
        // No explicit refresh here: WeatherRepository starts itself off the persisted
        // `enableRealTimeWeather` preference, so kicking it from every observer would only
        // duplicate the first fetch.
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
            activeSessions = activeConnections.size.takeIf { it > 0 } ?: uiState.activeSessions,
            securityBadge = buildSecurityBadge()
        )
    }

    /**
     * Derive the 4-state security badge purely from already-observed state — network
     * reachability and the active connection set. No new data source is wired; the suite
     * evidence is read from connection metadata when the handshake layer has populated it.
     */
    private fun buildSecurityBadge(): DashboardSecurityBadge {
        if (!latestNetworkState.isConnected) {
            return DashboardSecurityBadge(
                tone = SecurityBadgeTone.Offline,
                label = t("离线", "Offline", "オフライン")
            )
        }

        val connected = latestActiveConnections.filter { it.status == ConnectionStatus.CONNECTED }
        if (connected.isEmpty()) {
            // Reachable network, but no established secure session to vouch for yet.
            return DashboardSecurityBadge(
                tone = SecurityBadgeTone.Pending,
                label = t("待确认", "Pending", "確認待ち")
            )
        }

        // Read negotiated suite/security evidence from connection metadata when present.
        val evidence = connected.firstNotNullOfOrNull { it.securityEvidenceTier() }
        return when (evidence) {
            SecurityEvidenceTier.PQC -> DashboardSecurityBadge(
                tone = SecurityBadgeTone.VerifiedPqc,
                label = "PQC"
            )
            SecurityEvidenceTier.CLASSIC -> DashboardSecurityBadge(
                tone = SecurityBadgeTone.Classic,
                label = "Classic"
            )
            null -> DashboardSecurityBadge(
                tone = SecurityBadgeTone.Pending,
                label = t("待确认", "Pending", "確認待ち")
            )
        }
    }

    /**
     * Read-only live-transfer banner state from the aggregate transfer statistics.
     * We have aggregate (not per-file) telemetry, so an in-flight banner is indeterminate
     * and reports session count + an estimated throughput from the measured bandwidth.
     */
    private fun buildLiveTransfer(): DashboardLiveTransfer? {
        val active = latestTransferStats.activeTransfers
        if (active > 0) {
            val mbps = latestNetworkQuality.bandwidthMbps.takeIf { it > 0f }
            val speedText = mbps?.let { "${"%.1f".format(it)} MB/s" }
                ?: t("传输中", "Transferring", "転送中")
            return DashboardLiveTransfer(
                isActive = true,
                title = t("正在传输 $active 个文件", "Transferring $active files", "$active 件のファイルを転送中"),
                detail = t(
                    "累计 ${dataTransferredLabel()} · 网络 ${networkQualityLabel()}",
                    "Total ${dataTransferredLabel()} · Network ${networkQualityLabel()}",
                    "合計 ${dataTransferredLabel()} ・ ネットワーク ${networkQualityLabel()}"
                ),
                progress = 0f,
                speedText = speedText,
                succeeded = true
            )
        }
        if (latestTransferStats.completedTransfers > 0) {
            return DashboardLiveTransfer(
                isActive = false,
                title = t("最近传输完成", "Last transfer completed", "最近の転送が完了"),
                detail = t(
                    "已完成 ${latestTransferStats.completedTransfers} 个 · 累计 ${dataTransferredLabel()}",
                    "${latestTransferStats.completedTransfers} completed · Total ${dataTransferredLabel()}",
                    "${latestTransferStats.completedTransfers} 件完了 ・ 合計 ${dataTransferredLabel()}"
                ),
                progress = 1f,
                speedText = "",
                succeeded = true
            )
        }
        return null
    }

    private fun dataTransferredLabel(): String {
        val totalBytes = latestTransferStats.totalBytesSent + latestTransferStats.totalBytesReceived
        return "${totalBytes / (1024 * 1024)} MB"
    }

    private fun networkQualityLabel(): String = when (latestNetworkQuality.level) {
        QualityLevel.EXCELLENT -> t("优秀", "Excellent", "優秀")
        QualityLevel.GOOD -> t("良好", "Good", "良好")
        QualityLevel.FAIR -> t("一般", "Fair", "普通")
        QualityLevel.POOR -> t("较差", "Poor", "不良")
        QualityLevel.OFFLINE -> t("离线", "Offline", "オフライン")
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
            securityBadge = buildSecurityBadge(),
            liveTransfer = buildLiveTransfer(),
            isLoading = latestWeatherState.isLoading,
            error = uiState.error
        )
    }

    private fun buildWeatherCardState(): DashboardWeatherCardState =
        when (latestWeatherState.availability) {
            // The very first DataStore read has not landed yet; rendering "off" here would make
            // the card flicker on every cold start.
            WeatherAvailability.RESOLVING -> DashboardWeatherCardState.Resolving

            WeatherAvailability.DISABLED -> DashboardWeatherCardState.Disabled(
                title = t("实时天气未启用", "Real-time weather is off", "リアルタイム天気はオフです"),
                message = t(
                    "开启后按需读取粗略位置与天气数据；关闭时不会有任何后台请求。",
                    "When on, it resolves an approximate location on demand. Nothing runs in the background while it is off.",
                    "オンにすると必要なときだけおおよその位置と天気を取得します。オフの間はバックグラウンド通信を行いません。"
                ),
                actionLabel = t("启用天气", "Enable Weather", "天気を有効化")
            )

            WeatherAvailability.ENABLED -> buildEnabledWeatherCardState()
        }

    private fun buildEnabledWeatherCardState(): DashboardWeatherCardState {
        val weather = latestWeatherState.weather
            ?: return buildWeatherPlaceholderState()

        val timeLabel = SimpleDateFormat("HH:mm", currentAppLocale())
            .format(Date(weather.updatedAtEpochMillis))

        return DashboardWeatherCardState.Ready(
            icon = weather.condition.toDashboardWeatherIcon(),
            temperatureText = "${weather.temperatureCelsius.roundToInt()}°",
            feelsLikeText = weather.feelsLikeCelsius?.let {
                t("体感 ${it.roundToInt()}°", "Feels ${it.roundToInt()}°", "体感 ${it.roundToInt()}°")
            },
            conditionText = weather.condition.toDisplayText(latestAppLanguage),
            locationText = weather.locationName.ifBlank {
                t("当前位置", "Current Area", "現在地")
            },
            metrics = buildWeatherMetrics(weather),
            sourceText = if (weather.isFromCache) {
                "${t("缓存", "Cache", "キャッシュ")} · ${weather.sourceName}"
            } else {
                weather.sourceName
            },
            updatedText = t("更新于 $timeLabel", "Updated at $timeLabel", "$timeLabel 更新"),
            isRefreshing = latestWeatherState.isLoading,
            // A stale reading is worth showing, but the user should know why it is not moving.
            staleNotice = if (latestWeatherState.error == WeatherError.NETWORK_UNAVAILABLE) {
                t("网络不可用，显示上次结果", "Offline — showing the last result", "オフラインのため前回の結果を表示中")
            } else {
                null
            },
            locationUpgradeLabel = locationUpgradeLabel()
        )
    }

    private fun buildWeatherPlaceholderState(): DashboardWeatherCardState {
        if (latestWeatherState.isLoading) {
            return DashboardWeatherCardState.Loading(
                title = t("正在获取实时天气", "Fetching live weather", "天気を取得しています"),
                message = t("首次加载需要几秒钟", "The first load takes a few seconds", "初回の読み込みには数秒かかります")
            )
        }

        val message = when (latestWeatherState.error) {
            WeatherError.LOCATION_UNAVAILABLE -> t(
                "无法确定所在位置，请检查定位服务或网络连接。",
                "Could not determine your location. Check location services or your network.",
                "現在地を特定できません。位置情報サービスまたはネットワークを確認してください。"
            )
            WeatherError.NETWORK_UNAVAILABLE, WeatherError.WEATHER_UNAVAILABLE, null -> t(
                "天气服务暂时不可达，请检查网络后重试。",
                "Weather providers are unreachable. Check your network and try again.",
                "天気サービスに接続できません。ネットワークを確認して再試行してください。"
            )
        }

        return DashboardWeatherCardState.Error(
            title = t("天气数据获取失败", "Weather is unavailable", "天気を取得できませんでした"),
            message = message,
            actionLabel = t("重试", "Retry", "再試行")
        )
    }

    private fun buildWeatherMetrics(weather: WeatherSnapshot): List<DashboardWeatherMetric> =
        buildList {
            weather.humidityPercent?.let {
                add(
                    DashboardWeatherMetric(
                        kind = DashboardWeatherMetricKind.HUMIDITY,
                        label = t("湿度", "Humidity", "湿度"),
                        value = "$it%"
                    )
                )
            }
            weather.windSpeedKmh?.let {
                add(
                    DashboardWeatherMetric(
                        kind = DashboardWeatherMetricKind.WIND,
                        label = t("风速", "Wind", "風速"),
                        value = "${it.roundToInt()} km/h"
                    )
                )
            }
            weather.visibilityKm?.let {
                add(
                    DashboardWeatherMetric(
                        kind = DashboardWeatherMetricKind.VISIBILITY,
                        label = t("能见度", "Visibility", "視程"),
                        value = "${it.roundToInt()} km"
                    )
                )
            }
            weather.airQualityIndex?.let {
                add(
                    DashboardWeatherMetric(
                        kind = DashboardWeatherMetricKind.AIR_QUALITY,
                        label = "AQI",
                        value = "$it",
                        airQualityLevel = AirQualityIndex.levelOf(it)
                    )
                )
            }
        }

    /**
     * Only offered while weather is running on an IP-derived guess; granting coarse location is
     * what upgrades the reading from country/ISP level to the actual city.
     */
    private fun locationUpgradeLabel(): String? =
        if (latestWeatherState.locationPermissionMissing) {
            t("使用当前位置", "Use my location", "現在地を使う")
        } else {
            null
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
        weatherRepository.refreshWeather(forceFreshFix = true)
    }

    /** Backs the "启用天气" action on the disabled weather card. */
    fun enableRealTimeWeather() {
        viewModelScope.launch {
            AppSettingsStore.setRealTimeWeatherEnabled(context, true)
        }
    }

    /** Called once the user has answered the coarse-location prompt. */
    fun onLocationPermissionChanged() {
        weatherRepository.onLocationPermissionChanged()
    }
}

data class DashboardUiState(
    val connectedDevices: Int = 0,
    val activeSessions: Int = 0,
    val networkQuality: String = resolveLocalizedText("未知", "Unknown", "不明"),
    val dataTransferredLabel: String = "0 MB",
    val transferProgress: Float = 0f,
    val networkLatencyMs: Long = 0L,
    val weather: DashboardWeatherCardState = DashboardWeatherCardState.Resolving,
    val recentDevices: List<DashboardRecentDevice> = emptyList(),
    val activeConnections: List<DashboardActiveConnection> = emptyList(),
    val securityBadge: DashboardSecurityBadge = DashboardSecurityBadge(),
    val liveTransfer: DashboardLiveTransfer? = null,
    val isLoading: Boolean = true,
    val isOffline: Boolean = false,
    val error: String? = null
)

/**
 * Read-only presentation of the connection security posture for the welcome-card badge.
 * Mirrors the iOS `securityBadgePresentation` 4-state contract (PQC / Classic / 待确认 / 离线).
 * Derived purely from already-observed state (network reachability + active connections),
 * not from any new data source.
 */
data class DashboardSecurityBadge(
    val tone: SecurityBadgeTone = SecurityBadgeTone.Offline,
    val label: String = resolveLocalizedText("离线", "Offline", "オフライン")
)

/**
 * Read-only live-transfer banner state derived from the existing transfer statistics.
 * `null` means there is no in-flight transfer and no recent result to surface.
 */
data class DashboardLiveTransfer(
    val isActive: Boolean,
    val title: String,
    val detail: String,
    val progress: Float,
    val speedText: String,
    val succeeded: Boolean
)

/**
 * The five states the dashboard weather card can be in, mirroring the macOS
 * `WeatherDashboardCard` branches (disabled / loading / error / data) plus a [Resolving] state for
 * the window before the `enableRealTimeWeather` preference has been read.
 */
sealed interface DashboardWeatherCardState {

    data object Resolving : DashboardWeatherCardState

    data class Disabled(
        val title: String,
        val message: String,
        val actionLabel: String
    ) : DashboardWeatherCardState

    data class Loading(
        val title: String,
        val message: String
    ) : DashboardWeatherCardState

    data class Error(
        val title: String,
        val message: String,
        val actionLabel: String
    ) : DashboardWeatherCardState

    data class Ready(
        val icon: DashboardWeatherIcon,
        val temperatureText: String,
        val feelsLikeText: String?,
        val conditionText: String,
        val locationText: String,
        val metrics: List<DashboardWeatherMetric>,
        val sourceText: String,
        val updatedText: String,
        val isRefreshing: Boolean,
        val staleNotice: String?,
        val locationUpgradeLabel: String?
    ) : DashboardWeatherCardState
}

data class DashboardWeatherMetric(
    val kind: DashboardWeatherMetricKind,
    val label: String,
    val value: String,
    val airQualityLevel: AirQualityLevel? = null
)

enum class DashboardWeatherMetricKind {
    HUMIDITY,
    WIND,
    VISIBILITY,
    AIR_QUALITY
}

enum class DashboardWeatherIcon {
    Sunny,
    PartlyCloudy,
    Cloudy,
    Rainy,
    Snowy,
    Foggy,
    Haze,
    Stormy,
    Unknown
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
    WeatherCondition.PARTLY_CLOUDY -> DashboardWeatherIcon.PartlyCloudy
    WeatherCondition.CLOUDY -> DashboardWeatherIcon.Cloudy
    WeatherCondition.RAINY -> DashboardWeatherIcon.Rainy
    WeatherCondition.SNOWY -> DashboardWeatherIcon.Snowy
    WeatherCondition.FOGGY -> DashboardWeatherIcon.Foggy
    WeatherCondition.HAZE -> DashboardWeatherIcon.Haze
    WeatherCondition.STORMY -> DashboardWeatherIcon.Stormy
    WeatherCondition.UNKNOWN -> DashboardWeatherIcon.Unknown
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

/** Negotiated security tier as evidenced by the connection (read-only, from metadata). */
private enum class SecurityEvidenceTier { PQC, CLASSIC }

/**
 * Best-effort read of the negotiated security suite from connection metadata. The handshake
 * layer stamps the selected suite under a "suite"/"security"/"pqc" key when available; this
 * only reads that evidence and never assumes a tier the connection has not reported.
 */
private fun Connection.securityEvidenceTier(): SecurityEvidenceTier? {
    val raw = (metadata["suite"]
        ?: metadata["security"]
        ?: metadata["securityEvidence"]
        ?: metadata["pqc"]
        ?: metadata["tier"])
        ?.lowercase()
        ?: return null
    return when {
        raw == "true" -> SecurityEvidenceTier.PQC
        raw == "false" -> SecurityEvidenceTier.CLASSIC
        raw.contains("pqc") || raw.contains("mlkem") || raw.contains("ml-kem") ||
            raw.contains("kyber") || raw.contains("liboqs") || raw.contains("hybrid") ->
            SecurityEvidenceTier.PQC
        raw.contains("classic") || raw.contains("x25519") || raw.contains("ecdh") ||
            raw.contains("rsa") || raw.contains("p256") ->
            SecurityEvidenceTier.CLASSIC
        else -> null
    }
}
