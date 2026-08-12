package com.skybridge.compass.android.weather

import java.util.Locale
import kotlin.math.abs
import kotlinx.serialization.Serializable

@Serializable
enum class WeatherCondition {
    CLEAR,
    PARTLY_CLOUDY,
    CLOUDY,
    RAINY,
    SNOWY,
    FOGGY,
    HAZE,
    STORMY,
    UNKNOWN
}

/**
 * One observation of the current conditions, mirroring macOS `WeatherInfo`.
 *
 * Every optional field is genuinely provider-dependent: wttr.in reports visibility and PM2.5 while
 * Open-Meteo reports apparent temperature and pressure, so the card has to render whatever subset
 * the winning provider returned.
 */
@Serializable
data class WeatherSnapshot(
    val temperatureCelsius: Double,
    val condition: WeatherCondition,
    val description: String? = null,
    val feelsLikeCelsius: Double? = null,
    val humidityPercent: Int? = null,
    val windSpeedKmh: Double? = null,
    val visibilityKm: Double? = null,
    val pressureHpa: Double? = null,
    val airQualityIndex: Int? = null,
    val locationName: String,
    val sourceName: String,
    val updatedAtEpochMillis: Long,
    val isFromCache: Boolean = false
)

enum class WeatherError {
    /** Every live provider failed; a stale cached observation may still be present. */
    NETWORK_UNAVAILABLE,

    /** No live data and no usable cache. */
    WEATHER_UNAVAILABLE,

    /** Neither device location nor IP geolocation produced coordinates. */
    LOCATION_UNAVAILABLE
}

/**
 * Whether the real-time weather subsystem may run at all.
 *
 * [RESOLVING] exists so the card does not flash the "disabled" state during the first DataStore
 * read of `enableRealTimeWeather`.
 */
enum class WeatherAvailability {
    RESOLVING,
    DISABLED,
    ENABLED
}

data class WeatherState(
    val availability: WeatherAvailability = WeatherAvailability.RESOLVING,
    val weather: WeatherSnapshot? = null,
    val isLoading: Boolean = false,
    val error: WeatherError? = null,
    /**
     * True when the app holds no location permission. Weather still resolves through IP
     * geolocation, so this drives an optional "improve accuracy" prompt rather than an error.
     */
    val locationPermissionMissing: Boolean = false
)

/** Coordinates plus a human-readable label, resolved from GPS, IP geolocation, or cache. */
@Serializable
data class WeatherLocation(
    val latitude: Double,
    val longitude: Double,
    val label: String? = null,
    val source: WeatherLocationSource,
    val resolvedAtEpochMillis: Long
)

@Serializable
enum class WeatherLocationSource {
    DEVICE,
    IP_GEOLOCATION,
    CACHE
}

/** Fallback display label when neither reverse geocoding nor the provider names the place. */
fun WeatherLocation.formattedCoordinates(): String = String.format(
    Locale.US,
    "%.2f°%s %.2f°%s",
    abs(latitude),
    if (latitude >= 0) "N" else "S",
    abs(longitude),
    if (longitude >= 0) "E" else "W"
)
