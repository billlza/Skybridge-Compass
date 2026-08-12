package com.skybridge.compass.android.weather

/**
 * Air quality index derived from PM2.5, matching the macOS `calculateAQI` breakpoints (China
 * HJ 633-2012). Every provider we query reports PM2.5 in µg/m³, so converting locally keeps a
 * single scale across sources instead of mixing each provider's own index.
 */
object AirQualityIndex {

    /** Concentration/index breakpoint pairs; AQI is piecewise-linear between them. */
    private val breakpoints = listOf(
        Breakpoint(concentrationLow = 0.0, concentrationHigh = 35.0, indexLow = 0, indexHigh = 50),
        Breakpoint(concentrationLow = 35.0, concentrationHigh = 75.0, indexLow = 50, indexHigh = 100),
        Breakpoint(concentrationLow = 75.0, concentrationHigh = 115.0, indexLow = 100, indexHigh = 150),
        Breakpoint(concentrationLow = 115.0, concentrationHigh = 150.0, indexLow = 150, indexHigh = 200),
        Breakpoint(concentrationLow = 150.0, concentrationHigh = 250.0, indexLow = 200, indexHigh = 300),
        Breakpoint(concentrationLow = 250.0, concentrationHigh = 500.0, indexLow = 300, indexHigh = 500)
    )

    fun fromPm25(pm25: Double?): Int? {
        if (pm25 == null || pm25 <= 0.0 || pm25.isNaN()) return null
        val segment = breakpoints.firstOrNull { pm25 < it.concentrationHigh } ?: breakpoints.last()
        val span = segment.concentrationHigh - segment.concentrationLow
        val ratio = ((pm25 - segment.concentrationLow) / span).coerceIn(0.0, 1.0)
        val index = segment.indexLow + ratio * (segment.indexHigh - segment.indexLow)
        return index.toInt().coerceIn(0, 500)
    }

    /**
     * Last-resort estimate when no station data is reachable. Visibility correlates with
     * particulate load strongly enough to place the reading in the right band, which is all the
     * card's colour coding needs.
     */
    fun estimateFromVisibilityKm(visibilityKm: Double?): Int? = when {
        visibilityKm == null || visibilityKm < 0.0 -> null
        visibilityKm >= 10.0 -> 50
        visibilityKm >= 7.0 -> 100
        visibilityKm >= 4.0 -> 150
        visibilityKm >= 2.0 -> 200
        visibilityKm >= 1.0 -> 250
        else -> 300
    }

    fun levelOf(aqi: Int): AirQualityLevel = when {
        aqi < 50 -> AirQualityLevel.GOOD
        aqi < 100 -> AirQualityLevel.MODERATE
        aqi < 150 -> AirQualityLevel.SENSITIVE
        aqi < 200 -> AirQualityLevel.UNHEALTHY
        aqi < 300 -> AirQualityLevel.VERY_UNHEALTHY
        else -> AirQualityLevel.HAZARDOUS
    }

    private data class Breakpoint(
        val concentrationLow: Double,
        val concentrationHigh: Double,
        val indexLow: Int,
        val indexHigh: Int
    )
}

enum class AirQualityLevel {
    GOOD,
    MODERATE,
    SENSITIVE,
    UNHEALTHY,
    VERY_UNHEALTHY,
    HAZARDOUS
}
