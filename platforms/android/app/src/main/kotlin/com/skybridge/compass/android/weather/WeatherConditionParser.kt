package com.skybridge.compass.android.weather

import java.util.Locale

/**
 * Maps provider weather codes onto [WeatherCondition], mirroring macOS `parseWeatherCondition`.
 *
 * Two disjoint code spaces share this function: wttr.in uses World Weather Online codes (113..395)
 * and Open-Meteo uses WMO codes (0..99). They do not collide, so a single table serves both. The
 * English description is consulted first because it disambiguates cases the numeric code flattens
 * (WWO reports mist and haze under the same code as fog).
 */
object WeatherConditionParser {

    fun parse(code: Int?, description: String?): WeatherCondition {
        fromDescription(description)?.let { return it }
        return code?.let(::fromCode) ?: WeatherCondition.UNKNOWN
    }

    fun fromDescription(description: String?): WeatherCondition? {
        val normalized = description?.lowercase(Locale.ROOT)?.trim()
        if (normalized.isNullOrEmpty()) return null
        return when {
            normalized.contains("thunder") || normalized.contains("storm") -> WeatherCondition.STORMY
            normalized.contains("haze") || normalized.contains("smoke") -> WeatherCondition.HAZE
            normalized.contains("fog") || normalized.contains("mist") -> WeatherCondition.FOGGY
            normalized.contains("snow") ||
                normalized.contains("sleet") ||
                normalized.contains("blizzard") ||
                normalized.contains("ice pellets") -> WeatherCondition.SNOWY
            normalized.contains("rain") ||
                normalized.contains("drizzle") ||
                normalized.contains("shower") -> WeatherCondition.RAINY
            normalized.contains("partly") -> WeatherCondition.PARTLY_CLOUDY
            normalized.contains("cloud") || normalized.contains("overcast") -> WeatherCondition.CLOUDY
            normalized.contains("clear") ||
                normalized.contains("sunny") ||
                normalized.contains("fair") -> WeatherCondition.CLEAR
            else -> null
        }
    }

    fun fromCode(code: Int): WeatherCondition = when (code) {
        // WMO (Open-Meteo)
        0 -> WeatherCondition.CLEAR
        1, 2 -> WeatherCondition.PARTLY_CLOUDY
        3 -> WeatherCondition.CLOUDY
        45, 48 -> WeatherCondition.FOGGY
        in 51..67, in 80..82 -> WeatherCondition.RAINY
        in 71..77, 85, 86 -> WeatherCondition.SNOWY
        in 95..99 -> WeatherCondition.STORMY

        // World Weather Online (wttr.in)
        113 -> WeatherCondition.CLEAR
        116 -> WeatherCondition.PARTLY_CLOUDY
        119, 122 -> WeatherCondition.CLOUDY
        143 -> WeatherCondition.HAZE
        248, 260 -> WeatherCondition.FOGGY
        176, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314, 353, 356, 359 ->
            WeatherCondition.RAINY
        179, 227, 230, 320, 323, 326, 329, 332, 335, 338, 350, 368, 371, 374, 377 ->
            WeatherCondition.SNOWY
        200, 386, 389, 392, 395 -> WeatherCondition.STORMY

        else -> WeatherCondition.UNKNOWN
    }
}
