package com.skybridge.compass.android.weather

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.isSuccess
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Outcome of a single provider call.
 *
 * [NetworkFailure] and [InvalidData] are kept apart because only the former should arm the wttr.in
 * cooldown: a malformed payload is not a reason to stop talking to a reachable host.
 */
sealed interface WeatherFetchResult {
    data class Success(val snapshot: WeatherSnapshot) : WeatherFetchResult
    data object NetworkFailure : WeatherFetchResult
    data object InvalidData : WeatherFetchResult
}

/**
 * Keyless weather providers, mirroring the macOS fallback chain.
 *
 * All four endpoints are public and require no API key, which is why they were chosen over
 * OpenWeatherMap/WAQI (the macOS AQI path needs keys stored in UserDefaults and silently no-ops
 * without them).
 */
@Singleton
class WeatherRemoteDataSource @Inject constructor(
    private val httpClient: HttpClient
) {

    /**
     * wttr.in resolves the caller's own location when no coordinates are supplied, which keeps
     * weather working before any location permission is granted.
     */
    suspend fun fetchFromWttr(location: WeatherLocation?): WeatherFetchResult {
        val url = if (location == null) {
            "$WTTR_BASE_URL/?format=j1"
        } else {
            "$WTTR_BASE_URL/${location.latitude},${location.longitude}?format=j1"
        }

        val response = getOrNull<WttrResponse>(url) ?: return WeatherFetchResult.NetworkFailure
        val current = response.currentCondition.firstOrNull() ?: return WeatherFetchResult.InvalidData
        val temperature = current.temperatureCelsius.toDoubleOrNull()
            ?: return WeatherFetchResult.InvalidData

        val description = current.weatherDesc.firstOrNull()?.value
        val label = location?.label?.takeIf { it.isNotBlank() }
            ?: response.nearestArea.firstOrNull()?.displayLabel()
            ?: location?.formattedCoordinates()
            ?: ""

        return WeatherFetchResult.Success(
            WeatherSnapshot(
                temperatureCelsius = temperature,
                condition = WeatherConditionParser.parse(
                    code = current.weatherCode.toIntOrNull(),
                    description = description
                ),
                description = description,
                feelsLikeCelsius = current.feelsLikeCelsius?.toDoubleOrNull(),
                humidityPercent = current.humidity.toIntOrNull(),
                windSpeedKmh = current.windSpeedKmph.toDoubleOrNull(),
                visibilityKm = current.visibilityKm?.toDoubleOrNull(),
                pressureHpa = current.pressureMillibars?.toDoubleOrNull(),
                airQualityIndex = null,
                locationName = label,
                sourceName = SOURCE_WTTR,
                updatedAtEpochMillis = System.currentTimeMillis()
            )
        )
    }

    suspend fun fetchFromOpenMeteo(location: WeatherLocation): WeatherFetchResult {
        val url = "$OPEN_METEO_BASE_URL/v1/forecast" +
            "?latitude=${location.latitude}" +
            "&longitude=${location.longitude}" +
            "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code," +
            "wind_speed_10m,surface_pressure,visibility" +
            "&timezone=auto"

        val response = getOrNull<OpenMeteoResponse>(url) ?: return WeatherFetchResult.NetworkFailure
        val current = response.current

        return WeatherFetchResult.Success(
            WeatherSnapshot(
                temperatureCelsius = current.temperatureCelsius,
                condition = WeatherConditionParser.fromCode(current.weatherCode),
                description = null,
                feelsLikeCelsius = current.apparentTemperatureCelsius,
                humidityPercent = current.relativeHumidity?.roundToInt(),
                windSpeedKmh = current.windSpeedKmh,
                visibilityKm = current.visibilityMeters?.let { it / 1000.0 },
                pressureHpa = current.surfacePressureHpa,
                airQualityIndex = null,
                locationName = location.label?.takeIf { it.isNotBlank() }
                    ?: location.formattedCoordinates(),
                sourceName = SOURCE_OPEN_METEO,
                updatedAtEpochMillis = System.currentTimeMillis()
            )
        )
    }

    /**
     * Air quality is a separate request because neither weather endpoint carries particulates:
     * wttr.in's `pm2_5` field that macOS reads is absent from live `format=j1` responses.
     */
    suspend fun fetchAirQualityIndex(location: WeatherLocation): Int? {
        val url = "$OPEN_METEO_AIR_QUALITY_BASE_URL/v1/air-quality" +
            "?latitude=${location.latitude}" +
            "&longitude=${location.longitude}" +
            "&current=pm2_5,us_aqi" +
            "&timezone=auto"

        val current = getOrNull<OpenMeteoAirQualityResponse>(url)?.current ?: return null
        return AirQualityIndex.fromPm25(current.pm25) ?: current.usAqi?.roundToInt()
    }

    /** Coarse fallback used when the device refuses or cannot produce a fix. */
    suspend fun fetchIpLocation(): WeatherLocation? {
        val response = getOrNull<IpLocationResponse>(IP_LOCATION_URL) ?: return null
        val latitude = response.latitude ?: return null
        val longitude = response.longitude ?: return null
        return WeatherLocation(
            latitude = latitude,
            longitude = longitude,
            label = response.city?.takeIf { it.isNotBlank() }
                ?: response.region?.takeIf { it.isNotBlank() }
                ?: response.countryName?.takeIf { it.isNotBlank() },
            source = WeatherLocationSource.IP_GEOLOCATION,
            resolvedAtEpochMillis = System.currentTimeMillis()
        )
    }

    private suspend inline fun <reified T> getOrNull(url: String): T? =
        try {
            withTimeoutOrNull(REQUEST_TIMEOUT_MILLIS) {
                val response: HttpResponse = httpClient.get(url)
                if (response.status.isSuccess()) response.body<T>() else null
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            null
        }

    companion object {
        const val SOURCE_WTTR = "wttr.in"
        const val SOURCE_OPEN_METEO = "Open-Meteo"

        private const val WTTR_BASE_URL = "https://wttr.in"
        private const val OPEN_METEO_BASE_URL = "https://api.open-meteo.com"
        private const val OPEN_METEO_AIR_QUALITY_BASE_URL = "https://air-quality-api.open-meteo.com"
        private const val IP_LOCATION_URL = "https://ipapi.co/json/"
        private const val REQUEST_TIMEOUT_MILLIS = 5_000L
    }
}

@Serializable
private data class WttrResponse(
    @SerialName("current_condition")
    val currentCondition: List<WttrCurrentCondition> = emptyList(),
    @SerialName("nearest_area")
    val nearestArea: List<WttrNearestArea> = emptyList()
)

@Serializable
private data class WttrCurrentCondition(
    @SerialName("temp_C")
    val temperatureCelsius: String,
    @SerialName("FeelsLikeC")
    val feelsLikeCelsius: String? = null,
    val humidity: String = "",
    @SerialName("windspeedKmph")
    val windSpeedKmph: String = "",
    @SerialName("weatherCode")
    val weatherCode: String = "",
    @SerialName("visibility")
    val visibilityKm: String? = null,
    @SerialName("pressure")
    val pressureMillibars: String? = null,
    @SerialName("weatherDesc")
    val weatherDesc: List<WttrValue> = emptyList()
)

@Serializable
private data class WttrNearestArea(
    @SerialName("areaName")
    val areaName: List<WttrValue> = emptyList(),
    val region: List<WttrValue> = emptyList()
) {
    fun displayLabel(): String? = areaName.firstOrNull()?.value?.takeIf { it.isNotBlank() }
        ?: region.firstOrNull()?.value?.takeIf { it.isNotBlank() }
}

@Serializable
private data class WttrValue(
    val value: String = ""
)

@Serializable
private data class OpenMeteoResponse(
    val current: OpenMeteoCurrent
)

@Serializable
private data class OpenMeteoCurrent(
    @SerialName("temperature_2m")
    val temperatureCelsius: Double,
    @SerialName("relative_humidity_2m")
    val relativeHumidity: Double? = null,
    @SerialName("apparent_temperature")
    val apparentTemperatureCelsius: Double? = null,
    @SerialName("weather_code")
    val weatherCode: Int = -1,
    @SerialName("wind_speed_10m")
    val windSpeedKmh: Double? = null,
    @SerialName("surface_pressure")
    val surfacePressureHpa: Double? = null,
    @SerialName("visibility")
    val visibilityMeters: Double? = null
)

@Serializable
private data class OpenMeteoAirQualityResponse(
    val current: OpenMeteoAirQualityCurrent? = null
)

@Serializable
private data class OpenMeteoAirQualityCurrent(
    @SerialName("pm2_5")
    val pm25: Double? = null,
    @SerialName("us_aqi")
    val usAqi: Double? = null
)

@Serializable
private data class IpLocationResponse(
    val latitude: Double? = null,
    val longitude: Double? = null,
    val city: String? = null,
    val region: String? = null,
    @SerialName("country_name")
    val countryName: String? = null
)
