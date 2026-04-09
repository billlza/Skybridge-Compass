package com.skybridge.compass.android.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

// 顶层扩展属性：DataStore 实例
private val Context.developerSettingsDataStore by preferencesDataStore(name = "developer_settings")

// 开发者设置数据结构
data class DeveloperSettings(
    val enableScreenMirroring: Boolean = true,
    val enableRemoteControl: Boolean = true,
    val enableFileTransfer: Boolean = true
)

object DeveloperSettingsStore {
    private val KEY_SCREEN_MIRRORING = booleanPreferencesKey("enable_screen_mirroring")
    private val KEY_REMOTE_CONTROL = booleanPreferencesKey("enable_remote_control")
    private val KEY_FILE_TRANSFER = booleanPreferencesKey("enable_file_transfer")

    fun observe(context: Context): Flow<DeveloperSettings> =
        context.developerSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { prefs ->
            DeveloperSettings(
                enableScreenMirroring = prefs[KEY_SCREEN_MIRRORING] ?: true,
                enableRemoteControl = prefs[KEY_REMOTE_CONTROL] ?: true,
                enableFileTransfer = prefs[KEY_FILE_TRANSFER] ?: true
            )
        }

    suspend fun setEnableScreenMirroring(context: Context, enabled: Boolean) {
        context.developerSettingsDataStore.edit { prefs -> prefs[KEY_SCREEN_MIRRORING] = enabled }
    }

    suspend fun setEnableRemoteControl(context: Context, enabled: Boolean) {
        context.developerSettingsDataStore.edit { prefs -> prefs[KEY_REMOTE_CONTROL] = enabled }
    }

    suspend fun setEnableFileTransfer(context: Context, enabled: Boolean) {
        context.developerSettingsDataStore.edit { prefs -> prefs[KEY_FILE_TRANSFER] = enabled }
    }
}