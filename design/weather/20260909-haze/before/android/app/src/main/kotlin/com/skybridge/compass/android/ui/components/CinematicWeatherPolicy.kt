package com.skybridge.compass.android.ui.components

import android.content.Context
import android.os.PowerManager
import android.provider.Settings
import kotlin.math.max
import kotlin.math.min

/**
 * Frame-rate, quality and intensity policy for the cinematic weather overlay.
 *
 * Mac drives rain/snow with thousands of CPU particles plus Metal. On Android the overlay is a
 * single AGSL pass, so the expensive knob is fragment rate, not particle count. This policy keeps
 * rain/snow/storm at display refresh (capped at 60) while quieter conditions and thermal/power
 * events drop the tick rate instead of switching back to placeholder geometry. Cloud volumes
 * additionally cap their offscreen resolution and ray steps independently of display density.
 */
internal data class WeatherEffectsRuntimeHints(
    val powerSave: Boolean,
    val thermalStatus: Int,
    val animatorDurationScale: Float,
    val refreshRate: Float,
)

internal object CinematicWeatherPolicy {
    const val THERMAL_STATUS_MODERATE = 2
    const val THERMAL_STATUS_SEVERE = 3

    const val MODE_CLEAR = 0f
    const val MODE_CLOUDY = 1f
    const val MODE_RAIN = 2f
    const val MODE_SNOW = 3f
    const val MODE_FOG = 4f
    const val MODE_HAZE = 5f
    const val MODE_STORM = 6f
    const val MODE_NONE = -1f

    val requiredUniforms = listOf(
        "iResolution",
        "iTime",
        "weatherMode",
        "quality",
        "intensity",
        "wind",
        "allowFlash",
        "cloudNoiseAtlas",
    )

    fun shaderMode(condition: IOSWeatherCondition): Float = when (condition) {
        IOSWeatherCondition.Clear -> MODE_CLEAR
        IOSWeatherCondition.Cloudy -> MODE_CLOUDY
        IOSWeatherCondition.Rainy -> MODE_RAIN
        IOSWeatherCondition.Snowy -> MODE_SNOW
        IOSWeatherCondition.Foggy -> MODE_FOG
        IOSWeatherCondition.Haze -> MODE_HAZE
        IOSWeatherCondition.Stormy -> MODE_STORM
        IOSWeatherCondition.Unknown -> MODE_NONE
    }

    fun shouldAnimate(hints: WeatherEffectsRuntimeHints): Boolean {
        if (hints.animatorDurationScale <= 0.01f) return false
        if (hints.thermalStatus >= THERMAL_STATUS_SEVERE) return false
        return true
    }

    fun allowsStormFlash(hints: WeatherEffectsRuntimeHints): Boolean {
        if (!shouldAnimate(hints)) return false
        if (hints.powerSave) return false
        if (hints.thermalStatus >= THERMAL_STATUS_MODERATE) return false
        return true
    }

    fun quality(hints: WeatherEffectsRuntimeHints): Float = when {
        hints.thermalStatus >= THERMAL_STATUS_SEVERE -> 0f
        hints.powerSave || hints.thermalStatus >= THERMAL_STATUS_MODERATE -> 0.45f
        else -> 1f
    }

    /** Bound the cloud volume's fragment cost independently of display pixel density. */
    fun cloudRenderScale(widthPx: Int, heightPx: Int, quality: Float): Float {
        require(widthPx > 0 && heightPx > 0) { "Cloud viewport must have positive dimensions" }
        val detailScale = if (quality > 0.65f) 1f else 0.75f
        val shortEdge = min(widthPx, heightPx).toFloat()
        val longEdge = max(widthPx, heightPx).toFloat()
        return min(1f, min(600f / shortEdge, 1300f / longEdge)) * detailScale
    }

    fun targetFps(condition: IOSWeatherCondition, hints: WeatherEffectsRuntimeHints): Double {
        if (!shouldAnimate(hints)) return 0.0
        val cap = min(60.0, max(24.0, hints.refreshRate.toDouble()))
        val desired = when {
            hints.powerSave -> 24.0
            hints.thermalStatus >= THERMAL_STATUS_MODERATE -> 30.0
            condition == IOSWeatherCondition.Rainy ||
                condition == IOSWeatherCondition.Snowy ||
                condition == IOSWeatherCondition.Stormy -> 60.0
            condition == IOSWeatherCondition.Unknown -> 24.0
            else -> 45.0
        }
        return min(cap, desired)
    }

    fun minimumIntervalSeconds(condition: IOSWeatherCondition, hints: WeatherEffectsRuntimeHints): Double {
        val fps = targetFps(condition, hints)
        if (fps <= 0.0) return 1.0
        return 1.0 / max(10.0, fps)
    }

    fun overlayWind(windSpeedKmh: Double): Float =
        (windSpeedKmh / 60.0).toFloat().coerceIn(0f, 1f)

    fun overlayIntensity(
        condition: IOSWeatherCondition,
        windSpeedKmh: Double,
        humidityPercent: Int?,
        visibilityKm: Double?,
    ): Float {
        val wind = overlayWind(windSpeedKmh).toDouble()
        val humidity = ((humidityPercent ?: 55) / 100.0).coerceIn(0.0, 1.0)
        val haze = if (visibilityKm != null) {
            (1.0 - visibilityKm / 10.0).coerceIn(0.0, 1.0)
        } else {
            when (condition) {
                IOSWeatherCondition.Haze, IOSWeatherCondition.Foggy -> 0.72
                else -> 0.18
            }
        }
        val base = when (condition) {
            IOSWeatherCondition.Clear -> 0.48
            IOSWeatherCondition.Cloudy -> 0.62
            IOSWeatherCondition.Rainy -> 0.78
            IOSWeatherCondition.Snowy -> 0.70
            IOSWeatherCondition.Foggy -> 0.66 + haze * 0.22
            IOSWeatherCondition.Haze -> 0.58 + haze * 0.30
            IOSWeatherCondition.Stormy -> 0.96
            IOSWeatherCondition.Unknown -> 0.0
        }
        return (base + wind * 0.12 + humidity * 0.08).toFloat().coerceIn(0.28f, 1f)
    }

    fun readHints(context: Context, refreshRate: Float): WeatherEffectsRuntimeHints {
        val pm = context.getSystemService(PowerManager::class.java)
        val animatorScale = try {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            )
        } catch (_: Throwable) {
            1f
        }
        return WeatherEffectsRuntimeHints(
            powerSave = pm?.isPowerSaveMode == true,
            thermalStatus = pm?.currentThermalStatus ?: 0,
            animatorDurationScale = animatorScale,
            refreshRate = refreshRate.coerceAtLeast(24f),
        )
    }
}
