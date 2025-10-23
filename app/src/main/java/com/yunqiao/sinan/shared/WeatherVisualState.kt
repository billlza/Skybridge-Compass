package com.yunqiao.sinan.shared

import kotlinx.serialization.Serializable

/**
 * 用于描述天气驱动的视觉效果状态
 */
@Serializable
data class WeatherVisualState(
    val cityName: String = "",
    val country: String = "",
    val conditionLabel: String = "",
    val effectType: WeatherEffectType = WeatherEffectType.CLEAR,
    val backgroundColors: List<Long> = listOf(0xFF1E3C72, 0xFF2A5298),
    val particleDensity: Float = 0f,
    val mistAlpha: Float = 0f,
    val puddleLevel: Float = 0f,
    val highlightStrength: Float = 0.3f,
    val accentColor: Long = 0xFF5AC8FA,
    val isNight: Boolean = false,
    val temperature: Float = 0f,
    val lastUpdated: Long = 0L,
    val effectLabel: String = "",
    val renderingInfo: WeatherRenderingInfo = WeatherRenderingInfo()
)

/**
 * 天气效果类型
 */
@Serializable
enum class WeatherEffectType {
    CLEAR,
    CLOUDY,
    RAIN,
    STORM,
    SNOW,
    FOG
}

@Serializable
data class WeatherRenderingInfo(
    val hdrEnabled: Boolean = false,
    val hdrTargetNits: Float = 600f,
    val hdrColorSpace: String = "SDR",
    val toneMapping: Float = 1f,
    val rayTracingEnabled: Boolean = false,
    val rayTracingPipeline: String = "None",
    val reflectionStrength: Float = 1f,
    val shadingBoost: Float = 1f,
    val deviceTier: WeatherRenderTier = WeatherRenderTier.STANDARD,
    val socVendor: String = "",
    val optimizationHint: String = ""
)

@Serializable
enum class WeatherRenderTier {
    STANDARD,
    ADVANCED,
    ELITE
}
