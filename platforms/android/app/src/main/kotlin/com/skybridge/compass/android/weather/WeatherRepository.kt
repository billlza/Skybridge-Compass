package com.skybridge.compass.android.weather

import android.content.Context
import com.skybridge.compass.android.data.AppSettingsStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Single source of truth for real-time weather, ported from the macOS
 * `WeatherIntegrationManager` + `SkyBridgeWeatherService` pair.
 *
 * The subsystem is gated on the `enableRealTimeWeather` setting: while it is off nothing here
 * touches location services or the network, matching the desktop behaviour where the card renders
 * an explicit "not enabled" state instead of spinning.
 *
 * Provider ladder for a refresh:
 *  1. wttr.in (skipped while its failure cooldown is armed)
 *  2. Open-Meteo
 *  3. the cached observation, surfaced with [WeatherError.NETWORK_UNAVAILABLE]
 *
 * Air quality is fetched separately and folded in afterwards so a slow particulate lookup never
 * delays the temperature reaching the card.
 */
@Singleton
class WeatherRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val remoteDataSource: WeatherRemoteDataSource,
    private val locationProvider: WeatherLocationProvider,
    private val cacheStore: WeatherCacheStore
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val refreshMutex = Mutex()
    private val _weatherState = MutableStateFlow(WeatherState())

    private var activationJob: Job? = null
    private var lastFetchAtMillis = 0L

    init {
        AppSettingsStore.observeRealTimeWeatherEnabled(context)
            .distinctUntilChanged()
            .catch { emit(false) }
            .onEach(::applyEnabledState)
            .launchIn(scope)
    }

    fun observeWeather(): StateFlow<WeatherState> = _weatherState.asStateFlow()

    fun refreshWeather(forceFreshFix: Boolean = false) {
        scope.launch { refreshNow(forceFreshFix) }
    }

    /** Called after the user answers the location prompt so the card upgrades from IP accuracy. */
    fun onLocationPermissionChanged() {
        refreshWeather(forceFreshFix = true)
    }

    /** Foreground auto-refresh entry point; no-op while the current observation is still fresh. */
    suspend fun refreshIfStale() {
        if (_weatherState.value.availability != WeatherAvailability.ENABLED) return
        val updatedAt = _weatherState.value.weather?.updatedAtEpochMillis
        if (updatedAt != null &&
            System.currentTimeMillis() - updatedAt < AUTO_REFRESH_INTERVAL_MILLIS
        ) {
            return
        }
        refreshNow(forceFreshFix = false)
    }

    suspend fun refreshNow(forceFreshFix: Boolean = false) {
        if (_weatherState.value.availability != WeatherAvailability.ENABLED) return

        refreshMutex.withLock {
            val now = System.currentTimeMillis()
            // Both the dashboard and the animated background observe this repository; without a
            // debounce their simultaneous first composition would fire two identical fetches.
            if (!forceFreshFix && now - lastFetchAtMillis < FETCH_DEBOUNCE_MILLIS) return
            lastFetchAtMillis = now

            val permissionMissing = !locationProvider.hasLocationPermission()
            _weatherState.update { state ->
                state.copy(
                    isLoading = true,
                    error = null,
                    locationPermissionMissing = permissionMissing
                )
            }

            val location = locationProvider.resolve(forceFreshFix)
            val liveWeather = fetchLiveWeather(location)

            if (liveWeather != null) {
                cacheStore.writeWeather(liveWeather)
                _weatherState.value = WeatherState(
                    availability = WeatherAvailability.ENABLED,
                    weather = liveWeather,
                    isLoading = false,
                    error = null,
                    locationPermissionMissing = permissionMissing
                )
                enrichAirQuality(location, liveWeather)
                return
            }

            val cachedWeather = cacheStore.readWeather()
            _weatherState.value = WeatherState(
                availability = WeatherAvailability.ENABLED,
                weather = cachedWeather,
                isLoading = false,
                error = when {
                    cachedWeather != null -> WeatherError.NETWORK_UNAVAILABLE
                    location == null -> WeatherError.LOCATION_UNAVAILABLE
                    else -> WeatherError.WEATHER_UNAVAILABLE
                },
                locationPermissionMissing = permissionMissing
            )
        }
    }

    private fun applyEnabledState(enabled: Boolean) {
        activationJob?.cancel()

        if (!enabled) {
            _weatherState.value = WeatherState(availability = WeatherAvailability.DISABLED)
            return
        }

        activationJob = scope.launch {
            // Show the last observation immediately; a cold start would otherwise sit on a
            // spinner for as long as location resolution takes.
            val cached = cacheStore.readWeather()
            _weatherState.update { state ->
                state.copy(
                    availability = WeatherAvailability.ENABLED,
                    weather = state.weather ?: cached,
                    locationPermissionMissing = !locationProvider.hasLocationPermission()
                )
            }
            refreshNow(forceFreshFix = false)
        }
    }

    private suspend fun fetchLiveWeather(location: WeatherLocation?): WeatherSnapshot? {
        if (shouldAttemptWttr()) {
            when (val result = remoteDataSource.fetchFromWttr(location)) {
                is WeatherFetchResult.Success -> return result.snapshot
                // A reachable host returning junk is a data problem, not a connectivity one, so
                // only transport failures arm the cooldown.
                WeatherFetchResult.NetworkFailure -> armWttrCooldown()
                WeatherFetchResult.InvalidData -> Unit
            }
        }

        val fallbackLocation = location ?: return null
        val result = remoteDataSource.fetchFromOpenMeteo(fallbackLocation)
        return (result as? WeatherFetchResult.Success)?.snapshot
    }

    private fun enrichAirQuality(location: WeatherLocation?, baseline: WeatherSnapshot) {
        if (baseline.airQualityIndex != null) return
        val target = location ?: return

        scope.launch {
            val aqi = remoteDataSource.fetchAirQualityIndex(target)
                ?: AirQualityIndex.estimateFromVisibilityKm(baseline.visibilityKm)
                ?: return@launch

            val current = _weatherState.value.weather ?: return@launch
            // A newer refresh may have landed while the particulate lookup was in flight.
            if (current.updatedAtEpochMillis != baseline.updatedAtEpochMillis) return@launch

            val enriched = current.copy(airQualityIndex = aqi)
            _weatherState.update { state ->
                if (state.weather?.updatedAtEpochMillis == baseline.updatedAtEpochMillis) {
                    state.copy(weather = enriched)
                } else {
                    state
                }
            }
            cacheStore.writeWeather(enriched)
        }
    }

    private suspend fun shouldAttemptWttr(): Boolean =
        System.currentTimeMillis() >= cacheStore.readWttrCooldownUntil()

    private suspend fun armWttrCooldown() {
        cacheStore.writeWttrCooldownUntil(System.currentTimeMillis() + WTTR_COOLDOWN_MILLIS)
    }

    companion object {
        /** Matches the macOS 30-minute auto-refresh cadence. */
        const val AUTO_REFRESH_INTERVAL_MILLIS = 30 * 60 * 1000L

        private const val WTTR_COOLDOWN_MILLIS = 30 * 60 * 1000L
        private const val FETCH_DEBOUNCE_MILLIS = 2_500L
    }
}
