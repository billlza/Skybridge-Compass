package com.yunqiao.sinan.weather

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import java.util.Locale
import kotlin.math.coerceIn

data class WeatherRenderingProfile(
    val hdrSupported: Boolean = false,
    val hdrTypes: List<Int> = emptyList(),
    val maxHdrNits: Float = 600f,
    val hdrHighlightBoost: Float = 1f,
    val toneMappingCurve: Float = 1f,
    val rayTracingSupported: Boolean = false,
    val rayTracingLevel: WeatherRayTracingLevel = WeatherRayTracingLevel.NONE,
    val reflectionIntensity: Float = 1f,
    val shadingDetailBoost: Float = 1f,
    val vendor: WeatherSocVendor = WeatherSocVendor.UNKNOWN
)

enum class WeatherRayTracingLevel {
    NONE,
    BASELINE,
    ENHANCED
}

enum class WeatherSocVendor {
    QUALCOMM,
    MEDIATEK,
    SAMSUNG,
    GOOGLE,
    UNKNOWN
}

class WeatherRenderingOptimizer(private val context: Context) {
    private val packageManager = context.packageManager
    private val displayManager = context.getSystemService(DisplayManager::class.java)

    fun detect(): WeatherRenderingProfile {
        val display = displayManager?.getDisplay(Display.DEFAULT_DISPLAY)
        val hdrCapabilities = display?.hdrCapabilities
        val hdrTypes = hdrCapabilities?.supportedHdrTypes?.toList().orEmpty()
        val hdrSupported = hdrTypes.isNotEmpty()
        val maxNits = hdrCapabilities?.maximumMasteringLuminance ?: 600f
        val vendor = detectVendor()
        val rayTracingLevel = detectRayTracingLevel()
        val rayTracingSupported = rayTracingLevel != WeatherRayTracingLevel.NONE
        val highlightBoost = when (vendor) {
            WeatherSocVendor.QUALCOMM -> if (hdrSupported) 1.28f else 1.12f
            WeatherSocVendor.MEDIATEK -> if (hdrSupported) 1.24f else 1.1f
            WeatherSocVendor.SAMSUNG -> if (hdrSupported) 1.22f else 1.08f
            WeatherSocVendor.GOOGLE -> 1.15f
            WeatherSocVendor.UNKNOWN -> if (hdrSupported) 1.18f else 1.05f
        }
        val shadingBoost = when (vendor) {
            WeatherSocVendor.QUALCOMM -> if (rayTracingSupported) 1.35f else 1.18f
            WeatherSocVendor.MEDIATEK -> if (rayTracingSupported) 1.3f else 1.16f
            WeatherSocVendor.SAMSUNG -> 1.22f
            WeatherSocVendor.GOOGLE -> 1.2f
            WeatherSocVendor.UNKNOWN -> 1.15f
        }
        val reflectionIntensity = when (rayTracingLevel) {
            WeatherRayTracingLevel.NONE -> if (hdrSupported) 1.12f else 1f
            WeatherRayTracingLevel.BASELINE -> 1.32f
            WeatherRayTracingLevel.ENHANCED -> 1.48f
        }
        val toneMappingCurve = (maxNits / 600f).coerceIn(1f, 2.4f)
        return WeatherRenderingProfile(
            hdrSupported = hdrSupported,
            hdrTypes = hdrTypes,
            maxHdrNits = maxNits,
            hdrHighlightBoost = highlightBoost,
            toneMappingCurve = toneMappingCurve,
            rayTracingSupported = rayTracingSupported,
            rayTracingLevel = rayTracingLevel,
            reflectionIntensity = reflectionIntensity,
            shadingDetailBoost = shadingBoost,
            vendor = vendor
        )
    }

    private fun detectVendor(): WeatherSocVendor {
        val manufacturer = (if (Build.SOC_MANUFACTURER.isNullOrBlank()) Build.MANUFACTURER else Build.SOC_MANUFACTURER).orEmpty()
        val lower = manufacturer.lowercase(Locale.ROOT)
        return when {
            lower.contains("qualcomm") || lower.contains("snapdragon") -> WeatherSocVendor.QUALCOMM
            lower.contains("mediatek") || lower.contains("mt") -> WeatherSocVendor.MEDIATEK
            lower.contains("samsung") || lower.contains("exynos") -> WeatherSocVendor.SAMSUNG
            lower.contains("google") || lower.contains("tensor") -> WeatherSocVendor.GOOGLE
            else -> WeatherSocVendor.UNKNOWN
        }
    }

    private fun detectRayTracingLevel(): WeatherRayTracingLevel {
        val featureName = if (Build.VERSION.SDK_INT >= 34) PackageManager.FEATURE_RAY_TRACING else "android.hardware.ray_tracing"
        if (!packageManager.hasSystemFeature(featureName)) {
            return WeatherRayTracingLevel.NONE
        }
        val supportsVulkan13 = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_LEVEL, 3)
        } else {
            false
        }
        return if (supportsVulkan13) WeatherRayTracingLevel.ENHANCED else WeatherRayTracingLevel.BASELINE
    }
}
