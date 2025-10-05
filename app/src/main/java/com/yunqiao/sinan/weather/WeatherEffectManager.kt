package com.yunqiao.sinan.weather

import android.view.Display
import com.yunqiao.sinan.manager.LocationInfo
import com.yunqiao.sinan.manager.WeatherInfo
import com.yunqiao.sinan.shared.WeatherSystemStatus
import com.yunqiao.sinan.shared.WeatherEffectConfig
import com.yunqiao.sinan.shared.WeatherEffectType
import com.yunqiao.sinan.shared.WeatherMode
import com.yunqiao.sinan.shared.WeatherRenderTier
import com.yunqiao.sinan.shared.WeatherRenderingInfo
import com.yunqiao.sinan.shared.WeatherVisualState
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.flow.update
import java.util.Locale
import kotlin.math.roundToInt

/**
 * 天气效果管理器
 * 负责管理所有天气相关的视觉效果和数据处理
 */
class WeatherEffectManager {
    private val _weatherStatus = MutableStateFlow(WeatherSystemStatus())
    val weatherStatus: StateFlow<WeatherSystemStatus> = _weatherStatus.asStateFlow()

    private val _effectConfig = MutableStateFlow(WeatherEffectConfig())
    val effectConfig: StateFlow<WeatherEffectConfig> = _effectConfig.asStateFlow()

    private val _visualState = MutableStateFlow(WeatherVisualState())
    val visualState: StateFlow<WeatherVisualState> = _visualState.asStateFlow()

    private val _renderingProfile = MutableStateFlow(WeatherRenderingProfile())
    val renderingProfile: StateFlow<WeatherRenderingProfile> = _renderingProfile.asStateFlow()
    
    private var managerScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var lastWeatherInfo: WeatherInfo? = null
    private var lastLocationInfo: LocationInfo? = null
    
    /**
     * 初始化天气系统
     */
    fun initialize() {
        println("WeatherEffectManager 初始化完成")
        updateWeatherStatus(WeatherSystemStatus(isActive = true))
    }
    
    /**
     * 更新天气状态
     */
    fun updateWeatherStatus(status: WeatherSystemStatus) {
        _weatherStatus.value = status
    }
    
    /**
     * 更新效果配置
     */
    fun updateEffectConfig(config: WeatherEffectConfig) {
        _effectConfig.value = config
    }

    fun updateRenderingProfile(profile: WeatherRenderingProfile) {
        _renderingProfile.value = profile
        _visualState.update { current ->
            current.copy(renderingInfo = renderingInfoFor(profile))
        }
    }
    
    /**
     * 设置天气模式
     */
    fun setWeatherMode(mode: WeatherMode) {
        val currentStatus = _weatherStatus.value
        _weatherStatus.value = currentStatus.copy(currentMode = mode)
    }

    /**
     * 根据实时天气与定位刷新视觉效果
     */
    fun refreshVisuals(weatherInfo: WeatherInfo?, locationInfo: LocationInfo?) {
        weatherInfo?.let { lastWeatherInfo = it }
        locationInfo?.let { lastLocationInfo = it }

        val resolvedInfo = lastWeatherInfo ?: return
        val resolvedLocation = lastLocationInfo ?: LocationInfo()
        val profile = _renderingProfile.value
        val hdrEnabled = profile.hdrSupported && _effectConfig.value.enabled
        val rayTracingEnabled = profile.rayTracingSupported && profile.rayTracingLevel != WeatherRayTracingLevel.NONE

        val effectType = determineEffectType(resolvedInfo.condition, resolvedInfo.conditionCode)
        val nightMode = isNight(resolvedInfo)
        val effectLabel = effectLabel(effectType, nightMode)
        val baseGradient = gradientFor(effectType, nightMode)
        val gradient = if (hdrEnabled) adjustGradientForHdr(baseGradient, profile.toneMappingCurve) else baseGradient
        val density = (particleDensityFor(effectType, resolvedInfo) * if (rayTracingEnabled) profile.shadingDetailBoost else 1f)
            .coerceIn(0.1f, 2.2f)
        val mist = mistAlphaFor(effectType, resolvedInfo)
        val puddle = (puddleLevelFor(effectType) * if (rayTracingEnabled) profile.reflectionIntensity else 1f)
            .coerceIn(0f, 1f)
        val highlight = (highlightStrengthFor(effectType, nightMode) * if (hdrEnabled) profile.hdrHighlightBoost else 1f)
            .coerceIn(0f, 1f)
        val accent = if (hdrEnabled) adjustColorForHdr(accentColorFor(effectType, nightMode), profile.toneMappingCurve) else accentColorFor(effectType, nightMode)
        val renderingInfo = renderingInfoFor(profile, hdrEnabled, rayTracingEnabled)

        _visualState.value = WeatherVisualState(
            cityName = if (resolvedLocation.city.isNotBlank()) resolvedLocation.city else resolvedInfo.cityName,
            country = if (resolvedLocation.country.isNotBlank()) resolvedLocation.country else resolvedInfo.country,
            conditionLabel = resolvedInfo.condition,
            effectType = effectType,
            backgroundColors = gradient,
            particleDensity = density,
            mistAlpha = mist,
            puddleLevel = puddle,
            highlightStrength = highlight,
            accentColor = accent,
            isNight = nightMode,
            temperature = resolvedInfo.temperature,
            lastUpdated = System.currentTimeMillis(),
            effectLabel = effectLabel,
            renderingInfo = renderingInfo
        )

        _weatherStatus.update { current ->
            current.copy(
                isActive = true,
                temperature = resolvedInfo.temperature,
                humidity = resolvedInfo.humidity.toFloat(),
                pressure = resolvedInfo.pressure,
                visibility = resolvedInfo.visibility,
                timestamp = System.currentTimeMillis(),
                cityName = if (resolvedLocation.city.isNotBlank()) resolvedLocation.city else resolvedInfo.cityName,
                country = if (resolvedLocation.country.isNotBlank()) resolvedLocation.country else resolvedInfo.country,
                conditionLabel = resolvedInfo.condition,
                effectLabel = effectLabel
            )
        }
    }

    /**
     * 获取当前天气数据
     */
    fun getCurrentWeatherData(): WeatherSystemStatus {
        return _weatherStatus.value
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        managerScope.cancel()
        managerScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
        lastWeatherInfo = null
        lastLocationInfo = null
    }

    private fun renderingInfoFor(
        profile: WeatherRenderingProfile,
        hdrActive: Boolean = _visualState.value.renderingInfo.hdrEnabled,
        rayTracingActive: Boolean = _visualState.value.renderingInfo.rayTracingEnabled
    ): WeatherRenderingInfo {
        val tier = renderTierFor(profile)
        val colorSpace = hdrColorSpaceLabel(profile.hdrTypes)
        val optimization = optimizationHint(profile)
        val vendor = vendorLabel(profile.vendor)
        val pipeline = rayTracingPipelineLabel(profile, rayTracingActive)
        return WeatherRenderingInfo(
            hdrEnabled = hdrActive,
            hdrTargetNits = profile.maxHdrNits,
            hdrColorSpace = colorSpace,
            toneMapping = profile.toneMappingCurve,
            rayTracingEnabled = rayTracingActive,
            rayTracingPipeline = pipeline,
            reflectionStrength = if (rayTracingActive) profile.reflectionIntensity else 1f,
            shadingBoost = profile.shadingDetailBoost,
            deviceTier = tier,
            socVendor = vendor,
            optimizationHint = optimization
        )
    }

    private fun determineEffectType(condition: String, code: Int): WeatherEffectType {
        val lowered = condition.lowercase(Locale.ROOT)
        return when {
            lowered.contains("snow") || lowered.contains("sleet") || lowered.contains("ice") -> WeatherEffectType.SNOW
            lowered.contains("thunder") || lowered.contains("storm") -> WeatherEffectType.STORM
            lowered.contains("rain") || lowered.contains("shower") || lowered.contains("drizzle") -> WeatherEffectType.RAIN
            lowered.contains("fog") || lowered.contains("mist") || lowered.contains("haze") -> WeatherEffectType.FOG
            lowered.contains("cloud") || lowered.contains("overcast") -> WeatherEffectType.CLOUDY
            code in 200..299 -> WeatherEffectType.STORM
            code in 600..699 -> WeatherEffectType.SNOW
            code in 500..599 -> WeatherEffectType.RAIN
            code in 700..799 -> WeatherEffectType.FOG
            code in 801..899 -> WeatherEffectType.CLOUDY
            else -> WeatherEffectType.CLEAR
        }
    }

    private fun isNight(weatherInfo: WeatherInfo): Boolean {
        val time = weatherInfo.localTime
        if (time.isBlank()) {
            return false
        }
        return try {
            val hourPart = time.takeLast(5).take(2)
            val hour = hourPart.toInt()
            hour < 6 || hour >= 18
        } catch (_: Exception) {
            false
        }
    }

    private fun gradientFor(effectType: WeatherEffectType, night: Boolean): List<Long> {
        return when (effectType) {
            WeatherEffectType.SNOW -> if (night) {
                listOf(0xFF2C3E50, 0xFF4CA1AF)
            } else {
                listOf(0xFFE0EAFC, 0xFFCFDEF3)
            }
            WeatherEffectType.RAIN -> if (night) {
                listOf(0xFF141E30, 0xFF243B55)
            } else {
                listOf(0xFF4B79A1, 0xFF283E51)
            }
            WeatherEffectType.STORM -> listOf(0xFF232526, 0xFF414345)
            WeatherEffectType.FOG -> listOf(0xFFE6E9F0, 0xFFEEF1F5)
            WeatherEffectType.CLOUDY -> if (night) {
                listOf(0xFF0F2027, 0xFF2C5364)
            } else {
                listOf(0xFF8E9EAB, 0xFFEEF2F3)
            }
            WeatherEffectType.CLEAR -> if (night) {
                listOf(0xFF020111, 0xFF20202C)
            } else {
                listOf(0xFF56CCF2, 0xFF2F80ED)
            }
        }
    }

    private fun particleDensityFor(effectType: WeatherEffectType, weatherInfo: WeatherInfo): Float {
        val precipitation = weatherInfo.forecast.firstOrNull()?.chanceOfRain ?: 0
        return when (effectType) {
            WeatherEffectType.SNOW -> 0.8f + (weatherInfo.humidity / 100f) * 0.4f
            WeatherEffectType.RAIN -> 0.6f + (precipitation / 100f)
            WeatherEffectType.STORM -> 1.2f
            WeatherEffectType.FOG -> 0.2f
            WeatherEffectType.CLOUDY, WeatherEffectType.CLEAR -> 0.1f
        }.coerceIn(0.1f, 1.6f)
    }

    private fun mistAlphaFor(effectType: WeatherEffectType, weatherInfo: WeatherInfo): Float {
        return when (effectType) {
            WeatherEffectType.SNOW -> 0.15f
            WeatherEffectType.RAIN -> 0.35f
            WeatherEffectType.STORM -> 0.45f
            WeatherEffectType.FOG -> 0.6f
            WeatherEffectType.CLOUDY -> 0.2f
            WeatherEffectType.CLEAR -> if (weatherInfo.humidity > 70) 0.1f else 0f
        }.coerceIn(0f, 0.75f)
    }

    private fun puddleLevelFor(effectType: WeatherEffectType): Float {
        return when (effectType) {
            WeatherEffectType.RAIN -> 0.35f
            WeatherEffectType.STORM -> 0.55f
            WeatherEffectType.SNOW -> 0.2f
            else -> 0f
        }
    }

    private fun highlightStrengthFor(effectType: WeatherEffectType, night: Boolean): Float {
        return when (effectType) {
            WeatherEffectType.CLEAR -> if (night) 0.2f else 0.65f
            WeatherEffectType.CLOUDY -> 0.35f
            WeatherEffectType.RAIN -> 0.25f
            WeatherEffectType.STORM -> 0.2f
            WeatherEffectType.SNOW -> 0.45f
            WeatherEffectType.FOG -> 0.15f
        }
    }

    private fun accentColorFor(effectType: WeatherEffectType, night: Boolean): Long {
        return when (effectType) {
            WeatherEffectType.CLEAR -> if (night) 0xFF5AC8FA else 0xFFFFC371
            WeatherEffectType.CLOUDY -> 0xFFA1B5D8
            WeatherEffectType.RAIN -> 0xFF4A90E2
            WeatherEffectType.STORM -> 0xFF9FA4C4
            WeatherEffectType.SNOW -> 0xFFB3E5FC
            WeatherEffectType.FOG -> if (night) 0xFFB0BEC5 else 0xFFD7E3FC
        }
    }

    private fun effectLabel(effectType: WeatherEffectType, night: Boolean): String {
        return when (effectType) {
            WeatherEffectType.CLEAR -> if (night) "晴朗夜空" else "晴朗透亮"
            WeatherEffectType.CLOUDY -> if (night) "夜间多云" else "云层变幻"
            WeatherEffectType.RAIN -> "细雨氤氲"
            WeatherEffectType.STORM -> "暴风雷霆"
            WeatherEffectType.SNOW -> "雪落晶莹"
            WeatherEffectType.FOG -> "薄雾缭绕"
        }
    }

    private fun adjustGradientForHdr(colors: List<Long>, toneMapping: Float): List<Long> {
        return colors.map { adjustColorForHdr(it, toneMapping) }
    }

    private fun adjustColorForHdr(color: Long, toneMapping: Float): Long {
        val factor = toneMapping.coerceIn(1f, 2.5f)
        val a = ((color shr 24) and 0xFF).toInt()
        val r = ((color shr 16) and 0xFF).toInt()
        val g = ((color shr 8) and 0xFF).toInt()
        val b = (color and 0xFF).toInt()
        val newR = (r * factor).roundToInt().coerceIn(0, 255)
        val newG = (g * factor).roundToInt().coerceIn(0, 255)
        val newB = (b * factor).roundToInt().coerceIn(0, 255)
        return (a.toLong() shl 24) or (newR.toLong() shl 16) or (newG.toLong() shl 8) or newB.toLong()
    }

    private fun hdrColorSpaceLabel(types: List<Int>): String {
        if (types.isEmpty()) return "SDR"
        val labels = types.mapNotNull {
            when (it) {
                Display.HdrCapabilities.HDR_TYPE_HDR10 -> "HDR10"
                Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "HDR10+"
                Display.HdrCapabilities.HDR_TYPE_HLG -> "HLG"
                Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "Dolby Vision"
                else -> null
            }
        }
        return labels.joinToString(separator = "/").ifBlank { "HDR" }
    }

    private fun renderTierFor(profile: WeatherRenderingProfile): WeatherRenderTier {
        return when {
            profile.hdrSupported && profile.rayTracingLevel == WeatherRayTracingLevel.ENHANCED -> WeatherRenderTier.ELITE
            profile.hdrSupported || profile.rayTracingSupported -> WeatherRenderTier.ADVANCED
            else -> WeatherRenderTier.STANDARD
        }
    }

    private fun optimizationHint(profile: WeatherRenderingProfile): String {
        return when (profile.vendor) {
            WeatherSocVendor.QUALCOMM -> if (profile.rayTracingSupported) "骁龙光追增强" else "骁龙HDR优化"
            WeatherSocVendor.MEDIATEK -> if (profile.rayTracingSupported) "天玑光追增强" else "天玑HDR调校"
            WeatherSocVendor.SAMSUNG -> "Exynos渲染调优"
            WeatherSocVendor.GOOGLE -> "Tensor视觉优化"
            WeatherSocVendor.UNKNOWN -> if (profile.hdrSupported) "通用HDR增强" else "标准渲染"
        }
    }

    private fun vendorLabel(vendor: WeatherSocVendor): String {
        return when (vendor) {
            WeatherSocVendor.QUALCOMM -> "骁龙"
            WeatherSocVendor.MEDIATEK -> "天玑"
            WeatherSocVendor.SAMSUNG -> "Exynos"
            WeatherSocVendor.GOOGLE -> "Tensor"
            WeatherSocVendor.UNKNOWN -> "通用"
        }
    }

    private fun rayTracingPipelineLabel(profile: WeatherRenderingProfile, active: Boolean): String {
        if (!active) return "关闭"
        return when (profile.rayTracingLevel) {
            WeatherRayTracingLevel.NONE -> "关闭"
            WeatherRayTracingLevel.BASELINE -> "基础光追"
            WeatherRayTracingLevel.ENHANCED -> "增强光追"
        }
    }

    companion object {
        @Volatile
        private var INSTANCE: WeatherEffectManager? = null
        
        fun getInstance(): WeatherEffectManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: WeatherEffectManager().also { INSTANCE = it }
            }
        }
    }
}
