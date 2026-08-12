package com.skybridge.compass.android.ui.screens.settings

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.RemoteDesktopCodec
import com.skybridge.compass.android.data.RemoteDesktopFrameRate
import com.skybridge.compass.android.data.RemoteDesktopQualityPreset
import com.skybridge.compass.android.data.RemoteDesktopResolution
import com.skybridge.compass.android.data.RemoteDesktopStreamSettings
import com.skybridge.compass.android.data.RemoteDesktopStreamSettingsStore
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Owns the remote-desktop stream-configuration settings state + intents, backed by
 * [RemoteDesktopStreamSettingsStore]. The same DataStore is read by
 * `RemoteControlViewModel.sendStreamConfiguration()`, so changes here take effect on the next
 * stream-config push to the Mac host.
 */
@HiltViewModel
class RemoteDesktopStreamSettingsViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context
) : ViewModel() {

    val settings: StateFlow<RemoteDesktopStreamSettings> =
        RemoteDesktopStreamSettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, RemoteDesktopStreamSettings())

    fun setQualityPreset(preset: RemoteDesktopQualityPreset) {
        viewModelScope.launch { RemoteDesktopStreamSettingsStore.setQualityPreset(appContext, preset) }
    }

    fun setResolution(resolution: RemoteDesktopResolution) {
        viewModelScope.launch { RemoteDesktopStreamSettingsStore.setResolution(appContext, resolution) }
    }

    fun setFrameRate(frameRate: RemoteDesktopFrameRate) {
        viewModelScope.launch { RemoteDesktopStreamSettingsStore.setFrameRate(appContext, frameRate) }
    }

    fun setPreferredCodec(codec: RemoteDesktopCodec) {
        viewModelScope.launch { RemoteDesktopStreamSettingsStore.setPreferredCodec(appContext, codec) }
    }

    fun setLowLatencyMode(enabled: Boolean) {
        viewModelScope.launch { RemoteDesktopStreamSettingsStore.setLowLatencyMode(appContext, enabled) }
    }

    fun setEnableHardwareAcceleration(enabled: Boolean) {
        viewModelScope.launch {
            RemoteDesktopStreamSettingsStore.setEnableHardwareAcceleration(appContext, enabled)
        }
    }
}
