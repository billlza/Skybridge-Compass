package com.skybridge.compass.android.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

// 顶层扩展属性：DataStore 实例
private val Context.appSettingsDataStore by preferencesDataStore(name = "app_settings")

const val APP_LANGUAGE_SYSTEM = "system"
const val APP_LANGUAGE_ZH = "zh"
const val APP_LANGUAGE_EN = "en"
const val APP_LANGUAGE_JA = "ja"

/**
 * 应用通用设置数据结构
 */
data class AppSettings(
    val darkMode: Boolean = true,
    val autoConnect: Boolean = true,
    val notificationsEnabled: Boolean = true,
    val rememberLogin: Boolean = false,
    val appLanguage: String = APP_LANGUAGE_SYSTEM,
    val useDynamicColor: Boolean = false,
    val hapticFeedback: Boolean = true,
    val keepScreenOn: Boolean = false,
    val showBatteryOptimizationWarning: Boolean = true,
    /**
     * Mirrors macOS/iOS `SettingsManager.enableRealTimeWeather`. Opt-in on every platform because
     * turning it on starts location resolution and periodic network calls.
     */
    val realTimeWeatherEnabled: Boolean = false
)

/**
 * 应用设置持久化存储
 * 
 * 使用 DataStore Preferences 实现持久化，符合 Android 最佳实践
 */
object AppSettingsStore {
    // 设置键定义
    private val KEY_DARK_MODE = booleanPreferencesKey("dark_mode")
    private val KEY_AUTO_CONNECT = booleanPreferencesKey("auto_connect")
    private val KEY_NOTIFICATIONS = booleanPreferencesKey("notifications_enabled")
    private val KEY_REMEMBER_LOGIN = booleanPreferencesKey("remember_login")
    private val KEY_APP_LANGUAGE = stringPreferencesKey("app_language")
    private val KEY_DYNAMIC_COLOR = booleanPreferencesKey("use_dynamic_color")
    private val KEY_HAPTIC_FEEDBACK = booleanPreferencesKey("haptic_feedback")
    private val KEY_KEEP_SCREEN_ON = booleanPreferencesKey("keep_screen_on")
    private val KEY_BATTERY_OPT_WARNING = booleanPreferencesKey("battery_opt_warning")
    private val KEY_REAL_TIME_WEATHER = booleanPreferencesKey("real_time_weather_enabled")

    /**
     * 观察所有应用设置
     */
    fun observe(context: Context): Flow<AppSettings> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { prefs ->
                AppSettings(
                    darkMode = prefs[KEY_DARK_MODE] ?: true,
                    autoConnect = prefs[KEY_AUTO_CONNECT] ?: true,
                    notificationsEnabled = prefs[KEY_NOTIFICATIONS] ?: true,
                    rememberLogin = prefs[KEY_REMEMBER_LOGIN] ?: false,
                    appLanguage = prefs[KEY_APP_LANGUAGE] ?: APP_LANGUAGE_SYSTEM,
                    useDynamicColor = prefs[KEY_DYNAMIC_COLOR] ?: false,
                    hapticFeedback = prefs[KEY_HAPTIC_FEEDBACK] ?: true,
                    keepScreenOn = prefs[KEY_KEEP_SCREEN_ON] ?: false,
                    showBatteryOptimizationWarning = prefs[KEY_BATTERY_OPT_WARNING] ?: true,
                    realTimeWeatherEnabled = prefs[KEY_REAL_TIME_WEATHER] ?: false
                )
            }

    /**
     * 观察深色模式设置
     */
    fun observeDarkMode(context: Context): Flow<Boolean> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_DARK_MODE] ?: true }

    /**
     * 设置深色模式
     */
    suspend fun setDarkMode(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_DARK_MODE] = enabled
        }
    }

    /**
     * 观察自动连接设置
     */
    fun observeAutoConnect(context: Context): Flow<Boolean> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_AUTO_CONNECT] ?: true }

    /**
     * 设置自动连接
     */
    suspend fun setAutoConnect(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_AUTO_CONNECT] = enabled
        }
    }

    /**
     * 观察通知设置
     */
    fun observeNotifications(context: Context): Flow<Boolean> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_NOTIFICATIONS] ?: true }

    /**
     * 观察记住登录设置
     */
    fun observeRememberLogin(context: Context): Flow<Boolean> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_REMEMBER_LOGIN] ?: false }

    fun observeAppLanguage(context: Context): Flow<String> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_APP_LANGUAGE] ?: APP_LANGUAGE_SYSTEM }

    /**
     * 设置通知
     */
    suspend fun setNotifications(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_NOTIFICATIONS] = enabled
        }
    }

    /**
     * 设置记住登录
     */
    suspend fun setRememberLogin(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_REMEMBER_LOGIN] = enabled
        }
    }

    suspend fun setAppLanguage(context: Context, language: String) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_APP_LANGUAGE] = when (language) {
                APP_LANGUAGE_ZH, APP_LANGUAGE_EN, APP_LANGUAGE_JA -> language
                else -> APP_LANGUAGE_SYSTEM
            }
        }
    }

    /**
     * 设置动态颜色
     */
    suspend fun setUseDynamicColor(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_DYNAMIC_COLOR] = enabled
        }
    }

    /**
     * 设置触觉反馈
     */
    suspend fun setHapticFeedback(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_HAPTIC_FEEDBACK] = enabled
        }
    }

    /**
     * 设置保持屏幕常亮
     */
    suspend fun setKeepScreenOn(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_KEEP_SCREEN_ON] = enabled
        }
    }

    /**
     * 设置电池优化警告
     */
    suspend fun setBatteryOptimizationWarning(context: Context, show: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_BATTERY_OPT_WARNING] = show
        }
    }

    /**
     * 观察实时天气开关（对齐 macOS/iOS 的 enableRealTimeWeather）
     */
    fun observeRealTimeWeatherEnabled(context: Context): Flow<Boolean> =
        context.appSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_REAL_TIME_WEATHER] ?: false }

    /**
     * 设置实时天气开关
     */
    suspend fun setRealTimeWeatherEnabled(context: Context, enabled: Boolean) {
        context.appSettingsDataStore.edit { prefs ->
            prefs[KEY_REAL_TIME_WEATHER] = enabled
        }
    }

    /**
     * 重置所有设置为默认值
     */
    suspend fun resetToDefaults(context: Context) {
        context.appSettingsDataStore.edit { prefs ->
            prefs.clear()
        }
    }

    private suspend fun kotlinx.coroutines.flow.FlowCollector<androidx.datastore.preferences.core.Preferences>.rethrowPreferenceReadFailure(
        error: Throwable
    ) {
        throw error
    }
}
