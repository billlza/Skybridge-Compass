package com.yunqiao.sinan.config

import android.content.Context
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object ConfigurationManager {
    private const val PREFERENCES_NAME = "app_configuration"
    private const val KEY_CONFIGURATION = "configuration_json"
    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableConfiguration = MutableStateFlow(AppConfiguration())
    private val initialized = AtomicBoolean(false)
    private lateinit var appContext: Context

    val configuration: StateFlow<AppConfiguration> = mutableConfiguration.asStateFlow()

    fun initialize(context: Context) {
        if (initialized.compareAndSet(false, true)) {
            appContext = context.applicationContext
            scope.launch { loadConfiguration() }
        }
    }

    fun configurationSnapshot(): AppConfiguration = mutableConfiguration.value

    fun update(block: (AppConfiguration) -> AppConfiguration) {
        if (!initialized.get()) {
            throw IllegalStateException("ConfigurationManager not initialized")
        }
        scope.launch {
            val updated = block(mutableConfiguration.value)
            mutableConfiguration.value = updated
            persistConfiguration(updated)
        }
    }

    private suspend fun loadConfiguration() {
        runCatching {
            val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            val stored = preferences.getString(KEY_CONFIGURATION, null) ?: return
            val decoded = json.decodeFromString(AppConfiguration.serializer(), stored)
            mutableConfiguration.value = decoded
        }.onFailure {
            Log.e(TAG, "Failed to load configuration", it)
        }
    }

    private suspend fun persistConfiguration(configuration: AppConfiguration) {
        runCatching {
            val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            preferences.edit().putString(KEY_CONFIGURATION, json.encodeToString(configuration)).apply()
        }.onFailure {
            Log.e(TAG, "Failed to persist configuration", it)
        }
    }

    private const val TAG = "ConfigurationManager"
}
