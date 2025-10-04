package com.yunqiao.sinan.manager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PerformanceHintManager
import android.os.PowerManager
import android.os.Process
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.TimeUnit

enum class PerformanceProfile {
    POWER_SAVE,
    AUTOMATIC,
    HIGH_PERFORMANCE
}

class PerformanceProfileController(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("performance_profile", Context.MODE_PRIVATE)
    private val keyProfile = "profile"

    private val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
    private val performanceHintManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        appContext.getSystemService(PerformanceHintManager::class.java)
    } else {
        null
    }

    private val _profile = MutableStateFlow(loadProfile())
    val profile: StateFlow<PerformanceProfile> = _profile.asStateFlow()

    private val _targetDurationNanos = MutableStateFlow<Long?>(null)
    val targetDurationNanos: StateFlow<Long?> = _targetDurationNanos.asStateFlow()

    private val _thermalStatus = MutableStateFlow(fetchThermalStatus())
    val thermalStatus: StateFlow<Int> = _thermalStatus.asStateFlow()

    private val _powerSaveActive = MutableStateFlow(isSystemPowerSave())
    val powerSaveActive: StateFlow<Boolean> = _powerSaveActive.asStateFlow()

    private var hintSession: PerformanceHintManager.Session? = null
    private val wakeLock: PowerManager.WakeLock? = powerManager?.newWakeLock(
        PowerManager.PARTIAL_WAKE_LOCK,
        "SkybridgeCompass:PerformanceMode"
    )

    private val thermalListener: PowerManager.OnThermalStatusChangedListener? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        PowerManager.OnThermalStatusChangedListener { status ->
            _thermalStatus.value = status
            if (_profile.value == PerformanceProfile.AUTOMATIC) {
                updateHintSession(PerformanceProfile.AUTOMATIC)
            }
        }
    } else {
        null
    }

    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            _powerSaveActive.value = isSystemPowerSave()
            if (_profile.value == PerformanceProfile.AUTOMATIC) {
                updateHintSession(PerformanceProfile.AUTOMATIC)
            }
        }
    }

    init {
        registerThermalListener()
        appContext.registerReceiver(
            powerSaveReceiver,
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        )
        applyProfile(_profile.value)
    }

    fun setProfile(profile: PerformanceProfile) {
        if (_profile.value == profile) return
        preferences.edit { putString(keyProfile, profile.name) }
        _profile.value = profile
        applyProfile(profile)
    }

    fun cycleProfile() {
        val next = when (_profile.value) {
            PerformanceProfile.POWER_SAVE -> PerformanceProfile.AUTOMATIC
            PerformanceProfile.AUTOMATIC -> PerformanceProfile.HIGH_PERFORMANCE
            PerformanceProfile.HIGH_PERFORMANCE -> PerformanceProfile.POWER_SAVE
        }
        setProfile(next)
    }

    fun dispose() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val listener = thermalListener
            if (listener != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    runCatching { powerManager?.removeThermalStatusListener(listener) }
                } else {
                    @Suppress("DEPRECATION")
                    runCatching { powerManager?.removeThermalStatusListener(listener) }
                }
            }
        }
        runCatching { appContext.unregisterReceiver(powerSaveReceiver) }
        if (wakeLock?.isHeld == true) {
            runCatching { wakeLock.release() }
        }
        hintSession?.close()
        hintSession = null
    }

    private fun loadProfile(): PerformanceProfile {
        val stored = preferences.getString(keyProfile, PerformanceProfile.AUTOMATIC.name)
        return runCatching { PerformanceProfile.valueOf(stored ?: PerformanceProfile.AUTOMATIC.name) }
            .getOrDefault(PerformanceProfile.AUTOMATIC)
    }

    private fun applyProfile(profile: PerformanceProfile) {
        manageWakeLock(profile)
        updateHintSession(profile)
    }

    private fun manageWakeLock(profile: PerformanceProfile) {
        val lock = wakeLock ?: return
        when (profile) {
            PerformanceProfile.HIGH_PERFORMANCE -> if (!lock.isHeld) {
                runCatching { lock.acquire() }
            }
            PerformanceProfile.AUTOMATIC, PerformanceProfile.POWER_SAVE -> if (lock.isHeld) {
                runCatching { lock.release() }
            }
        }
    }

    private fun updateHintSession(profile: PerformanceProfile) {
        val session = ensureHintSession()
        if (session == null) {
            _targetDurationNanos.value = null
            return
        }

        val target = when (profile) {
            PerformanceProfile.POWER_SAVE -> TimeUnit.MILLISECONDS.toNanos(33)
            PerformanceProfile.HIGH_PERFORMANCE -> TimeUnit.MILLISECONDS.toNanos(8)
            PerformanceProfile.AUTOMATIC -> resolveAutomaticTarget()
        }

        runCatching {
            session.updateTargetWorkDuration(target)
            session.reportActualWorkDuration(target)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                session.setPreferPowerEfficiency(profile == PerformanceProfile.POWER_SAVE)
            }
        }

        _targetDurationNanos.value = target
    }

    private fun resolveAutomaticTarget(): Long {
        val thermal = _thermalStatus.value
        val base = TimeUnit.MILLISECONDS.toNanos(16)
        val adjusted = when {
            thermal >= PowerManager.THERMAL_STATUS_SEVERE -> TimeUnit.MILLISECONDS.toNanos(24)
            _powerSaveActive.value -> TimeUnit.MILLISECONDS.toNanos(20)
            else -> base
        }
        return adjusted
    }

    private fun ensureHintSession(): PerformanceHintManager.Session? {
        if (performanceHintManager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val existing = hintSession
        if (existing != null) return existing

        return runCatching {
            performanceHintManager.createHintSession(intArrayOf(Process.myTid()), TimeUnit.MILLISECONDS.toNanos(16))
        }.onFailure {
            it.printStackTrace()
        }.getOrNull().also { session ->
            hintSession = session
        }
    }

    private fun registerThermalListener() {
        if (thermalListener == null || powerManager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            powerManager.addThermalStatusListener(ContextCompat.getMainExecutor(appContext), thermalListener)
        } else {
            @Suppress("DEPRECATION")
            powerManager.addThermalStatusListener(thermalListener)
        }
    }

    private fun fetchThermalStatus(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        } else {
            PowerManager.THERMAL_STATUS_NONE
        }
    }

    private fun isSystemPowerSave(): Boolean {
        return powerManager?.isPowerSaveMode == true
    }
}
