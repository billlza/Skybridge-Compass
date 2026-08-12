package com.skybridge.compass.android.weather

import android.content.Context
import androidx.datastore.preferences.SharedPreferencesMigration
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json

private const val LEGACY_WEATHER_PREFERENCES = "skybridge_weather_cache"

private val Context.weatherDataStore by preferencesDataStore(
    name = "weather_cache",
    produceMigrations = { context ->
        listOf(SharedPreferencesMigration(context, LEGACY_WEATHER_PREFERENCES))
    }
)

/**
 * Durable state for the weather subsystem: the last observation, the last resolved location, and
 * the wttr.in cooldown deadline.
 *
 * Replaces the previous raw `SharedPreferences` usage so weather persistence matches the rest of
 * the app (transactional writes, no main-thread disk I/O). The legacy preferences file is migrated
 * on first read and then deleted.
 */
@Singleton
class WeatherCacheStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val json: Json
) {

    suspend fun readWeather(): WeatherSnapshot? {
        val payload = read(KEY_CACHED_WEATHER) ?: return null
        val snapshot = decode<WeatherSnapshot>(payload) ?: return null
        val age = System.currentTimeMillis() - snapshot.updatedAtEpochMillis
        if (age !in 0..WEATHER_CACHE_VALIDITY_MILLIS) return null
        return snapshot.copy(isFromCache = true)
    }

    suspend fun writeWeather(snapshot: WeatherSnapshot) {
        write(KEY_CACHED_WEATHER, json.encodeToString(snapshot.copy(isFromCache = false)))
    }

    suspend fun readLocation(): WeatherLocation? {
        val payload = read(KEY_CACHED_LOCATION) ?: return null
        val location = decode<WeatherLocation>(payload) ?: return null
        val age = System.currentTimeMillis() - location.resolvedAtEpochMillis
        if (age !in 0..LOCATION_CACHE_VALIDITY_MILLIS) return null
        return location.copy(source = WeatherLocationSource.CACHE)
    }

    suspend fun writeLocation(location: WeatherLocation) {
        write(KEY_CACHED_LOCATION, json.encodeToString(location))
    }

    /** Epoch millis before which wttr.in should not be contacted again. */
    suspend fun readWttrCooldownUntil(): Long =
        runCatching { context.weatherDataStore.data.first()[KEY_WTTR_COOLDOWN_UNTIL] }
            .getOrNull() ?: 0L

    suspend fun writeWttrCooldownUntil(epochMillis: Long) {
        runCatching {
            context.weatherDataStore.edit { preferences ->
                preferences[KEY_WTTR_COOLDOWN_UNTIL] = epochMillis
            }
        }
    }

    private suspend fun read(key: androidx.datastore.preferences.core.Preferences.Key<String>): String? =
        runCatching { context.weatherDataStore.data.first()[key] }.getOrNull()

    private suspend fun write(
        key: androidx.datastore.preferences.core.Preferences.Key<String>,
        value: String
    ) {
        runCatching { context.weatherDataStore.edit { preferences -> preferences[key] = value } }
    }

    private inline fun <reified T> decode(payload: String): T? = try {
        json.decodeFromString<T>(payload)
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (_: Exception) {
        null
    }

    private companion object {
        val KEY_CACHED_WEATHER = stringPreferencesKey("cached_weather")
        val KEY_CACHED_LOCATION = stringPreferencesKey("cached_location")
        val KEY_WTTR_COOLDOWN_UNTIL = longPreferencesKey("wttr_cooldown_until")

        const val WEATHER_CACHE_VALIDITY_MILLIS = 30 * 60 * 1000L
        const val LOCATION_CACHE_VALIDITY_MILLIS = 60 * 60 * 1000L
    }
}
