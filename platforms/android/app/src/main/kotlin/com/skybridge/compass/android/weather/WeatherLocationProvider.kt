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
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Resolves the coordinates weather is fetched for, mirroring the macOS `LocationManager` ladder:
 * device fix → IP geolocation → cached fix.
 *
 * Only [Manifest.permission.ACCESS_COARSE_LOCATION] is ever required. City-level accuracy is all a
 * weather lookup needs, so the app never asks for a precise fix it would immediately round off.
 */
@Singleton
class WeatherLocationProvider @Inject constructor(
    @ApplicationContext private val context: Context,
    private val remoteDataSource: WeatherRemoteDataSource,
    private val cacheStore: WeatherCacheStore
) {

    private val locationManager by lazy { context.getSystemService(LocationManager::class.java) }

    fun hasLocationPermission(): Boolean = LOCATION_PERMISSIONS.any { permission ->
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * @param forceFreshFix skips the cached device fix so an explicit pull-to-refresh actually
     *   re-locates the user instead of replaying the previous coordinates.
     */
    suspend fun resolve(forceFreshFix: Boolean): WeatherLocation? {
        deviceLocation(forceFreshFix)?.let { location ->
            val resolved = WeatherLocation(
                latitude = location.latitude,
                longitude = location.longitude,
                label = reverseGeocode(location.latitude, location.longitude),
                source = WeatherLocationSource.DEVICE,
                resolvedAtEpochMillis = System.currentTimeMillis()
            )
            cacheStore.writeLocation(resolved)
            return resolved
        }

        remoteDataSource.fetchIpLocation()?.let { ipLocation ->
            cacheStore.writeLocation(ipLocation)
            return ipLocation
        }

        return cacheStore.readLocation()
    }

    private suspend fun deviceLocation(forceFreshFix: Boolean): Location? {
        if (!hasLocationPermission()) return null

        if (!forceFreshFix) {
            lastKnownLocation()?.takeIf(::isFreshEnough)?.let { return it }
        }
        return currentLocation() ?: lastKnownLocation()
    }

    private suspend fun currentLocation(): Location? {
        val manager = locationManager ?: return null
        val providers = CURRENT_FIX_PROVIDERS.filter { provider ->
            try {
                manager.isProviderEnabled(provider)
            } catch (_: SecurityException) {
                false
            }
        }

        for (provider in providers) {
            val location = withTimeoutOrNull(CURRENT_FIX_TIMEOUT_MILLIS) {
                suspendCancellableCoroutine { continuation ->
                    val cancellationSignal = CancellationSignal()
                    continuation.invokeOnCancellation { cancellationSignal.cancel() }
                    if (!hasLocationPermission()) {
                        if (continuation.isActive) continuation.resume(null)
                        return@suspendCancellableCoroutine
                    }
                    try {
                        manager.getCurrentLocation(
                            provider,
                            cancellationSignal,
                            ContextCompat.getMainExecutor(context)
                        ) { fix ->
                            if (continuation.isActive) continuation.resume(fix)
                        }
                    } catch (_: SecurityException) {
                        if (continuation.isActive) continuation.resume(null)
                    }
                }
            }
            if (location != null) return location
        }
        return null
    }

    private fun lastKnownLocation(): Location? {
        val manager = locationManager ?: return null
        return LAST_KNOWN_PROVIDERS
            .mapNotNull { provider ->
                if (!hasLocationPermission()) return@mapNotNull null
                try {
                    manager.getLastKnownLocation(provider)
                } catch (_: SecurityException) {
                    null
                }
            }
            .maxByOrNull(Location::getTime)
    }

    private fun isFreshEnough(location: Location): Boolean =
        (System.currentTimeMillis() - location.time) in 0..LAST_KNOWN_MAX_AGE_MILLIS

    private suspend fun reverseGeocode(latitude: Double, longitude: Double): String? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(context, currentAppLocale())
        return withTimeoutOrNull(GEOCODE_TIMEOUT_MILLIS) {
            suspendCancellableCoroutine { continuation ->
                try {
                    geocoder.getFromLocation(latitude, longitude, 1) { addresses ->
                        if (continuation.isActive) {
                            continuation.resume(addresses.firstOrNull()?.toDisplayLabel())
                        }
                    }
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (_: Exception) {
                    if (continuation.isActive) continuation.resume(null)
                }
            }
        }
    }

    /**
     * Joins city and district the way macOS does ("北京市 朝阳区") so the card reads like the
     * desktop one rather than showing a bare administrative area.
     */
    private fun Address.toDisplayLabel(): String? {
        val city = locality?.takeIf { it.isNotBlank() } ?: adminArea?.takeIf { it.isNotBlank() }
        val district = subAdminArea?.takeIf { it.isNotBlank() }
            ?: subLocality?.takeIf { it.isNotBlank() }
        val parts = listOfNotNull(city, district.takeIf { it != city })
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" ")
            ?: featureName?.takeIf { it.isNotBlank() }
            ?: countryName?.takeIf { it.isNotBlank() }
    }

    companion object {
        val LOCATION_PERMISSIONS = listOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION
        )

        private val CURRENT_FIX_PROVIDERS = listOf(
            LocationManager.FUSED_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER
        )

        private val LAST_KNOWN_PROVIDERS = listOf(
            LocationManager.FUSED_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER
        )

        private const val CURRENT_FIX_TIMEOUT_MILLIS = 4_000L
        private const val GEOCODE_TIMEOUT_MILLIS = 4_000L
        private const val LAST_KNOWN_MAX_AGE_MILLIS = 2 * 60 * 60 * 1000L
    }
}
