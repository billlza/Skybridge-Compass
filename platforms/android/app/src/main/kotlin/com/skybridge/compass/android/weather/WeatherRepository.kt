package com.skybridge.compass.android.weather

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import androidx.core.content.ContextCompat
import com.skybridge.compass.android.i18n.currentAppLocale
import dagger.hilt.android.qualifiers.ApplicationContext
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.util.Locale

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

@Serializable
data class WeatherSnapshot(
    val temperatureCelsius: Double,
    val condition: WeatherCondition,
    val humidityPercent: Int? = null,
    val windSpeedKmh: Double? = null,
    val locationName: String,
    val sourceName: String,
    val updatedAtEpochMillis: Long,
    val isFromCache: Boolean = false
)

enum class WeatherError {
    NETWORK_UNAVAILABLE,
    WEATHER_UNAVAILABLE
}

data class WeatherState(
    val weather: WeatherSnapshot? = null,
    val isLoading: Boolean = false,
    val error: WeatherError? = null
)

private data class DeviceLocation(
    val latitude: Double,
    val longitude: Double,
    val cityName: String? = null
)

@Singleton
class WeatherRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val httpClient: HttpClient,
    private val json: Json
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val refreshMutex = Mutex()
    private val preferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }
    private val locationManager by lazy {
        context.getSystemService(LocationManager::class.java)
    }

    private val _weatherState = MutableStateFlow(
        WeatherState(weather = loadCachedWeather())
    )

    fun observeWeather(): StateFlow<WeatherState> = _weatherState.asStateFlow()

    fun refreshWeather(forceCurrentLocation: Boolean = false) {
        scope.launch {
            refreshNow(forceCurrentLocation)
        }
    }

    suspend fun refreshNow(forceCurrentLocation: Boolean = false) {
        refreshMutex.withLock {
            val existingState = _weatherState.value
            _weatherState.value = existingState.copy(isLoading = true, error = null)

            val deviceLocation = resolveLocation(forceCurrentLocation)
            val liveWeather = fetchFromWttr(deviceLocation)
                ?: fetchFromOpenMeteo(deviceLocation)

            if (liveWeather != null) {
                cacheWeather(liveWeather.copy(isFromCache = false))
                _weatherState.value = WeatherState(
                    weather = liveWeather.copy(isFromCache = false),
                    isLoading = false,
                    error = null
                )
                return
            }

            val cachedWeather = loadCachedWeather()
            if (cachedWeather != null) {
                _weatherState.value = WeatherState(
                    weather = cachedWeather,
                    isLoading = false,
                    error = WeatherError.NETWORK_UNAVAILABLE
                )
                return
            }

            _weatherState.value = WeatherState(
                weather = null,
                isLoading = false,
                error = WeatherError.WEATHER_UNAVAILABLE
            )
        }
    }

    private suspend fun resolveLocation(forceCurrentLocation: Boolean): DeviceLocation? {
        val lastKnownLocation = if (forceCurrentLocation) {
            null
        } else {
            getBestLastKnownLocation()?.takeIf(::isFreshEnough)
        }

        val chosenLocation = lastKnownLocation
            ?: getCurrentLocation()
            ?: getBestLastKnownLocation()
            ?: return null

        return DeviceLocation(
            latitude = chosenLocation.latitude,
            longitude = chosenLocation.longitude,
            cityName = reverseGeocode(chosenLocation.latitude, chosenLocation.longitude)
        )
    }

    private suspend fun getCurrentLocation(): Location? {
        if (!hasLocationPermission()) {
            return null
        }
        val providers = listOf(
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER
        ).filter { provider ->
            runCatching { locationManager.isProviderEnabled(provider) }.getOrDefault(false)
        }
        if (providers.isEmpty()) {
            return null
        }

        for (provider in providers) {
            val location = withTimeoutOrNull(4_000L) {
                suspendCancellableCoroutine { continuation ->
                    val cancellationSignal = CancellationSignal()
                    continuation.invokeOnCancellation { cancellationSignal.cancel() }

                    runCatching {
                        locationManager.getCurrentLocation(
                            provider,
                            cancellationSignal,
                            ContextCompat.getMainExecutor(context)
                        ) { currentLocation ->
                            if (continuation.isActive) {
                                continuation.resume(currentLocation)
                            }
                        }
                    }.onFailure {
                        if (continuation.isActive) {
                            continuation.resume(null)
                        }
                    }
                }
            }
            if (location != null) {
                return location
            }
        }
        return null
    }

    private fun getBestLastKnownLocation(): Location? {
        if (!hasLocationPermission()) {
            return null
        }
        val providers = listOf(
            LocationManager.PASSIVE_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER
        )
        return providers
            .mapNotNull { provider ->
                runCatching { locationManager.getLastKnownLocation(provider) }.getOrNull()
            }
            .maxByOrNull { location -> location.time }
    }

    private fun hasLocationPermission(): Boolean {
        val coarseGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val fineGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        return coarseGranted || fineGranted
    }

    private fun isFreshEnough(location: Location): Boolean {
        val ageMillis = System.currentTimeMillis() - location.time
        return ageMillis in 0..LAST_KNOWN_LOCATION_MAX_AGE_MILLIS
    }

    private suspend fun reverseGeocode(latitude: Double, longitude: Double): String? {
        if (!Geocoder.isPresent()) {
            return null
        }
        val geocoder = Geocoder(context, currentAppLocale())
        return suspendCancellableCoroutine { continuation ->
            runCatching {
                geocoder.getFromLocation(latitude, longitude, 1) { addresses ->
                    if (continuation.isActive) {
                        continuation.resume(addresses.firstOrNull()?.toLocationLabel())
                    }
                }
            }.onFailure {
                if (continuation.isActive) {
                    continuation.resume(null)
                }
            }
        }
    }

    private suspend fun fetchFromWttr(deviceLocation: DeviceLocation?): WeatherSnapshot? {
        val url = if (deviceLocation == null) {
            "https://wttr.in/?format=j1"
        } else {
            "https://wttr.in/${deviceLocation.latitude},${deviceLocation.longitude}?format=j1"
        }
        val response = try {
            withTimeoutOrNull(5_000L) {
                httpClient.get(url).body<WttrResponse>()
            }
        } catch (_: Exception) {
            null
        } ?: return null

        val current = response.currentCondition.firstOrNull() ?: return null
        val description = current.weatherDesc.firstOrNull()?.value
        val locationName = deviceLocation?.cityName
            ?.takeIf { it.isNotBlank() }
            ?: response.nearestArea.firstOrNull()
                ?.areaName
                ?.firstOrNull()
                ?.value
                ?.takeIf { it.isNotBlank() }
            ?: deviceLocation?.formattedCoordinates()
            ?: ""

        return WeatherSnapshot(
            temperatureCelsius = current.temperatureCelsius.toDoubleOrNull() ?: return null,
            condition = parseWeatherCondition(
                code = current.weatherCode.toIntOrNull() ?: return null,
                description = description
            ),
            humidityPercent = current.humidity.toIntOrNull(),
            windSpeedKmh = current.windSpeedKmph.toDoubleOrNull(),
            locationName = locationName,
            sourceName = "wttr.in",
            updatedAtEpochMillis = System.currentTimeMillis()
        )
    }

    private suspend fun fetchFromOpenMeteo(deviceLocation: DeviceLocation?): WeatherSnapshot? {
        deviceLocation ?: return null
        val url = "https://api.open-meteo.com/v1/forecast?" +
            "latitude=${deviceLocation.latitude}" +
            "&longitude=${deviceLocation.longitude}" +
            "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m" +
            "&timezone=auto"

        val response = try {
            withTimeoutOrNull(5_000L) {
                httpClient.get(url).body<OpenMeteoResponse>()
            }
        } catch (_: Exception) {
            null
        } ?: return null

        val locationName = deviceLocation.cityName
            ?.takeIf { it.isNotBlank() }
            ?: deviceLocation.formattedCoordinates()

        return WeatherSnapshot(
            temperatureCelsius = response.current.temperatureCelsius,
            condition = parseWeatherCondition(
                code = response.current.weatherCode,
                description = null
            ),
            humidityPercent = response.current.relativeHumidity.roundToInt(),
            windSpeedKmh = response.current.windSpeedKmh,
            locationName = locationName,
            sourceName = "Open-Meteo",
            updatedAtEpochMillis = System.currentTimeMillis()
        )
    }

    private fun parseWeatherCondition(code: Int, description: String?): WeatherCondition {
        val normalizedDescription = description?.lowercase(Locale.ROOT)
        if (!normalizedDescription.isNullOrBlank()) {
            when {
                normalizedDescription.contains("thunder") -> return WeatherCondition.STORMY
                normalizedDescription.contains("haze") || normalizedDescription.contains("smoke") -> return WeatherCondition.HAZE
                normalizedDescription.contains("fog") || normalizedDescription.contains("mist") -> return WeatherCondition.FOGGY
                normalizedDescription.contains("snow") || normalizedDescription.contains("sleet") || normalizedDescription.contains("blizzard") ->
                    return WeatherCondition.SNOWY
                normalizedDescription.contains("rain") || normalizedDescription.contains("drizzle") || normalizedDescription.contains("shower") ->
                    return WeatherCondition.RAINY
                normalizedDescription.contains("partly") -> return WeatherCondition.PARTLY_CLOUDY
                normalizedDescription.contains("cloud") || normalizedDescription.contains("overcast") -> return WeatherCondition.CLOUDY
                normalizedDescription.contains("clear") || normalizedDescription.contains("sunny") || normalizedDescription.contains("fair") ->
                    return WeatherCondition.CLEAR
            }
        }

        return when (code) {
            0, 113 -> WeatherCondition.CLEAR
            1, 2, 116 -> WeatherCondition.PARTLY_CLOUDY
            3, 119, 122 -> WeatherCondition.CLOUDY
            143 -> WeatherCondition.HAZE
            45, 48, 248, 260 -> WeatherCondition.FOGGY
            176, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314, 353, 356, 359,
            in 51..67, 80, 81, 82 -> WeatherCondition.RAINY
            179, 227, 230, 320, 323, 326, 329, 332, 335, 338, 350, 368, 371, 374, 377,
            in 71..77, 85, 86 -> WeatherCondition.SNOWY
            200, 386, 389, 392, 395, in 95..99 -> WeatherCondition.STORMY
            else -> WeatherCondition.UNKNOWN
        }
    }

    private fun cacheWeather(weather: WeatherSnapshot) {
        val payload = json.encodeToString(weather.copy(isFromCache = false))
        preferences.edit()
            .putString(KEY_CACHED_WEATHER, payload)
            .apply()
    }

    private fun loadCachedWeather(): WeatherSnapshot? {
        val payload = preferences.getString(KEY_CACHED_WEATHER, null) ?: return null
        val weather = runCatching {
            json.decodeFromString<WeatherSnapshot>(payload)
        }.getOrNull() ?: return null

        if (System.currentTimeMillis() - weather.updatedAtEpochMillis > CACHE_VALIDITY_MILLIS) {
            return null
        }

        return weather.copy(isFromCache = true)
    }

    private fun DeviceLocation.formattedCoordinates(): String =
        formatCoordinates(latitude, longitude)

    private fun formatCoordinates(latitude: Double, longitude: Double): String {
        val latDirection = if (latitude >= 0) "N" else "S"
        val lonDirection = if (longitude >= 0) "E" else "W"
        return String.format(
            Locale.US,
            "%.2f°%s %.2f°%s",
            kotlin.math.abs(latitude),
            latDirection,
            kotlin.math.abs(longitude),
            lonDirection
        )
    }

    private fun Address.toLocationLabel(): String? = listOf(
        locality,
        subAdminArea,
        adminArea,
        featureName,
        countryName
    ).firstOrNull { !it.isNullOrBlank() }

    companion object {
        private const val PREFS_NAME = "skybridge_weather_cache"
        private const val KEY_CACHED_WEATHER = "cached_weather"
        private const val CACHE_VALIDITY_MILLIS = 30 * 60 * 1000L
        private const val LAST_KNOWN_LOCATION_MAX_AGE_MILLIS = 2 * 60 * 60 * 1000L
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
    val humidity: String,
    @SerialName("windspeedKmph")
    val windSpeedKmph: String,
    @SerialName("weatherCode")
    val weatherCode: String,
    @SerialName("weatherDesc")
    val weatherDesc: List<WttrValue> = emptyList()
)

@Serializable
private data class WttrNearestArea(
    @SerialName("areaName")
    val areaName: List<WttrValue> = emptyList()
)

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
    val relativeHumidity: Double,
    @SerialName("weather_code")
    val weatherCode: Int,
    @SerialName("wind_speed_10m")
    val windSpeedKmh: Double
)
