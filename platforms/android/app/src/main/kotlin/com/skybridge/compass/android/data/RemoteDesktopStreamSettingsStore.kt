package com.skybridge.compass.android.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

private val Context.remoteDesktopStreamSettingsDataStore by
    preferencesDataStore(name = "remote_desktop_stream_settings")

/**
 * Resolution presets the viewer can request. Mirrors iOS `RemoteDesktopViewerResolution`
 * (SkyBridge Compass iOS/.../RemoteDesktop/RemoteDesktopViewerSettings.swift:3-38).
 *
 * `.auto` advertises `adaptiveResolutionEnabled = true` and sends no width/height, which the macOS
 * host honors in `RemoteControlStreamRequestPolicy.request()` (adaptiveResolutionEnabled branch);
 * the fixed sizes send explicit width/height that the host honors when not adaptive.
 */
enum class RemoteDesktopResolution(
    val storeValue: String,
    val displayName: String,
    val width: Int?,
    val height: Int?
) {
    AUTO("auto", "自动 / Auto", null, null),
    HD720("hd720", "1280 × 720", 1280, 720),
    FULL_HD_1080("fullHD1080", "1920 × 1080", 1920, 1080),
    QHD_1440("qhd1440", "2560 × 1440", 2560, 1440),
    UHD_4K("uhd4k", "3840 × 2160", 3840, 2160),
    UHD_5K("uhd5k", "5120 × 2880", 5120, 2880);

    val isAdaptive: Boolean get() = this == AUTO

    companion object {
        fun fromStore(value: String?): RemoteDesktopResolution =
            entries.firstOrNull { it.storeValue == value } ?: AUTO
    }
}

/**
 * Target frame rate. Mirrors iOS `RemoteDesktopViewerFrameRate`. `.adaptive` resolves to 60 fps on
 * the wire (same as iOS `targetFPS`), the rest are explicit. The host clamps to 12..120 in
 * `RemoteControlStreamRequestPolicy.request()`.
 */
enum class RemoteDesktopFrameRate(
    val storeValue: String,
    val displayName: String,
    val targetFps: Int
) {
    ADAPTIVE("adaptive", "自适应 / Adaptive", 60),
    FPS30("fps30", "30 FPS", 30),
    FPS60("fps60", "60 FPS", 60),
    FPS120("fps120", "120 FPS", 120);

    companion object {
        fun fromStore(value: String?): RemoteDesktopFrameRate =
            entries.firstOrNull { it.storeValue == value } ?: ADAPTIVE
    }
}

/**
 * Preferred codec. Mirrors iOS `RemoteDesktopViewerCodec`. The resolved wire value is intersected
 * with the device's actually-supported decode formats before being advertised, so we never request a
 * codec the Android decoder cannot play back. The host honors `preferredCodec` in
 * `RemoteControlStreamRequestPolicy.preferredCodec(from:)`.
 */
enum class RemoteDesktopCodec(
    val storeValue: String,
    val displayName: String,
    val wireValue: String?
) {
    AUTOMATIC("automatic", "自动 / Auto", null),
    HEVC("hevc", "HEVC", "hevc"),
    H264("h264", "H.264", "h264"),
    JPEG("jpeg", "JPEG", "jpeg");

    companion object {
        fun fromStore(value: String?): RemoteDesktopCodec =
            entries.firstOrNull { it.storeValue == value } ?: AUTOMATIC
    }
}

/**
 * Quality preset. Mirrors iOS `RemoteDesktopViewerPreset` wire values and the per-preset
 * `RemoteDesktopTransportTuning` (damage tracking / refresh strategy / jitter buffer / loss
 * recovery). Selecting a preset other than [CUSTOM] applies a canonical resolution/frameRate/codec/
 * lowLatency template (matching iOS `applyPreset`).
 *
 * `qualityPresetWireValue` is what the host carries through change-detection
 * (RemoteControlStreamRequestPolicy.swift:188) and the WebRTC streaming policy
 * (WebRTCScreenStreamingPolicy.swift). The transport-tuning fields (damageTracking / refreshStrategy
 * / jitterBufferFrames / lossRecoveryMode) are honored by the outbound frame pump
 * (RemoteControlOutboundFramePump.swift:344 reads damageTrackingEnabled) and carried in the request
 * change-detection (RemoteControlStreamRequestPolicy.swift:197-202).
 */
enum class RemoteDesktopQualityPreset(
    val storeValue: String,
    val wireValue: String,
    val displayName: String,
    val detail: String,
    // Template (null for CUSTOM = keep the user's manual combo).
    val templateResolution: RemoteDesktopResolution?,
    val templateFrameRate: RemoteDesktopFrameRate?,
    val templateCodec: RemoteDesktopCodec?,
    val templateLowLatency: Boolean?,
    // Transport tuning (mirrors iOS RemoteDesktopTransportTuning per preset).
    val damageTrackingEnabled: Boolean,
    val refreshStrategy: String,
    val jitterBufferFrames: Int,
    val lossRecoveryMode: String,
    // Suggested compression level (host change-detection + WebRTC policy carry this).
    val videoCompressionLevel: Int
) {
    AUTOMATIC(
        storeValue = "automatic",
        wireValue = "automatic",
        displayName = "自动 / Auto",
        detail = "稳定优先，自适应 60 FPS / Stable, adaptive 60 FPS",
        templateResolution = RemoteDesktopResolution.AUTO,
        templateFrameRate = RemoteDesktopFrameRate.ADAPTIVE,
        templateCodec = RemoteDesktopCodec.AUTOMATIC,
        templateLowLatency = false,
        damageTrackingEnabled = true,
        refreshStrategy = "balanced",
        jitterBufferFrames = 2,
        lossRecoveryMode = "balanced",
        videoCompressionLevel = 60
    ),
    CLARITY(
        storeValue = "clarity",
        wireValue = "clarity",
        displayName = "清晰优先 / Clarity",
        detail = "4K 60 HEVC，保住细节与文字锐度 / 4K 60 HEVC, sharper detail",
        templateResolution = RemoteDesktopResolution.UHD_4K,
        templateFrameRate = RemoteDesktopFrameRate.FPS60,
        templateCodec = RemoteDesktopCodec.HEVC,
        templateLowLatency = false,
        damageTrackingEnabled = true,
        refreshStrategy = "quality-biased",
        jitterBufferFrames = 2,
        lossRecoveryMode = "balanced",
        videoCompressionLevel = 80
    ),
    FLUID(
        storeValue = "fluid",
        wireValue = "fluid",
        displayName = "流畅优先 / Fluid",
        detail = "720p 60 H.264 低延迟，弱网更稳 / 720p 60 H.264 low-latency",
        templateResolution = RemoteDesktopResolution.HD720,
        templateFrameRate = RemoteDesktopFrameRate.FPS60,
        templateCodec = RemoteDesktopCodec.H264,
        templateLowLatency = true,
        damageTrackingEnabled = true,
        refreshStrategy = "aggressive",
        jitterBufferFrames = 3,
        lossRecoveryMode = "resilient",
        videoCompressionLevel = 40
    ),
    PRO_4K_120(
        storeValue = "pro4k120",
        wireValue = "geek4k120",
        displayName = "Pro 4K 120",
        detail = "4K 120 HEVC 低延迟，高刷直连 / 4K 120 HEVC low-latency",
        templateResolution = RemoteDesktopResolution.UHD_4K,
        templateFrameRate = RemoteDesktopFrameRate.FPS120,
        templateCodec = RemoteDesktopCodec.HEVC,
        templateLowLatency = true,
        damageTrackingEnabled = true,
        refreshStrategy = "instant",
        jitterBufferFrames = 1,
        lossRecoveryMode = "fast-retransmit",
        videoCompressionLevel = 70
    ),
    PRO_5K_120(
        storeValue = "pro5k120",
        wireValue = "geek5k120",
        displayName = "Pro 5K 120",
        detail = "5K 120 HEVC 低延迟，旗舰模式 / 5K 120 HEVC low-latency",
        templateResolution = RemoteDesktopResolution.UHD_5K,
        templateFrameRate = RemoteDesktopFrameRate.FPS120,
        templateCodec = RemoteDesktopCodec.HEVC,
        templateLowLatency = true,
        damageTrackingEnabled = true,
        refreshStrategy = "instant",
        jitterBufferFrames = 1,
        lossRecoveryMode = "fast-retransmit",
        videoCompressionLevel = 75
    ),
    CUSTOM(
        storeValue = "custom",
        wireValue = "custom",
        displayName = "自定义 / Custom",
        detail = "手动组合分辨率/帧率/编码/延迟 / Manual resolution, fps, codec, latency",
        templateResolution = null,
        templateFrameRate = null,
        templateCodec = null,
        templateLowLatency = null,
        damageTrackingEnabled = true,
        refreshStrategy = "balanced",
        jitterBufferFrames = 2,
        lossRecoveryMode = "balanced",
        videoCompressionLevel = 60
    );

    val hasTemplate: Boolean
        get() = templateResolution != null

    companion object {
        fun fromStore(value: String?): RemoteDesktopQualityPreset =
            entries.firstOrNull { it.storeValue == value } ?: AUTOMATIC
    }
}

/**
 * Persisted remote-desktop stream-configuration settings (the viewer's request to the host).
 *
 * Only fields the macOS host ACTUALLY honors are modeled here (verified against
 * Sources/SkyBridgeCore/RemoteControl/RemoteDesktopControlPayloads.swift:161-181 and
 * RemoteControlStreamRequestPolicy.request()):
 * - [resolution] -> width/height + adaptiveResolutionEnabled
 * - [frameRate]  -> targetFrameRate (host clamps 12..120)
 * - [preferredCodec] -> preferredCodec (intersected with device decode support)
 * - [qualityPreset]  -> qualityPreset + videoCompressionLevel + transport tuning
 * - [lowLatencyMode] -> lowLatencyMode (also affects keyFrameInterval derivation)
 * - [enableHardwareAcceleration] -> enableHardwareAcceleration
 *
 * `clipboardSyncEnabled` is intentionally NOT stored here: it is driven by the Security/Access-control
 * `allowClipboardSync` toggle so there is one source of truth for clipboard redirection.
 */
data class RemoteDesktopStreamSettings(
    val qualityPreset: RemoteDesktopQualityPreset = RemoteDesktopQualityPreset.AUTOMATIC,
    val resolution: RemoteDesktopResolution = RemoteDesktopResolution.AUTO,
    val frameRate: RemoteDesktopFrameRate = RemoteDesktopFrameRate.ADAPTIVE,
    val preferredCodec: RemoteDesktopCodec = RemoteDesktopCodec.AUTOMATIC,
    val lowLatencyMode: Boolean = false,
    val enableHardwareAcceleration: Boolean = true
) {
    /**
     * keyFrameInterval derived exactly like iOS `RemoteDesktopViewerSettings.keyFrameInterval`:
     * low-latency -> max(15, fps/2), otherwise max(30, fps). The host clamps to 10..240.
     */
    val keyFrameInterval: Int
        get() = if (lowLatencyMode) {
            maxOf(15, frameRate.targetFps / 2)
        } else {
            maxOf(30, frameRate.targetFps)
        }
}

object RemoteDesktopStreamSettingsStore {
    private val KEY_QUALITY_PRESET = stringPreferencesKey("rd_quality_preset")
    private val KEY_RESOLUTION = stringPreferencesKey("rd_resolution")
    private val KEY_FRAME_RATE = stringPreferencesKey("rd_frame_rate")
    private val KEY_PREFERRED_CODEC = stringPreferencesKey("rd_preferred_codec")
    private val KEY_LOW_LATENCY = booleanPreferencesKey("rd_low_latency_mode")
    private val KEY_HW_ACCEL = booleanPreferencesKey("rd_enable_hw_accel")

    // Reserved for future numeric tuning surfaced in the UI; declared so the key namespace is stable.
    @Suppress("unused")
    private val KEY_RESERVED_INT = intPreferencesKey("rd_reserved_int")

    fun observe(context: Context): Flow<RemoteDesktopStreamSettings> =
        context.remoteDesktopStreamSettingsDataStore.data
            .catch { e ->
                throw e
            }
            .map { prefs ->
                RemoteDesktopStreamSettings(
                    qualityPreset = RemoteDesktopQualityPreset.fromStore(prefs[KEY_QUALITY_PRESET]),
                    resolution = RemoteDesktopResolution.fromStore(prefs[KEY_RESOLUTION]),
                    frameRate = RemoteDesktopFrameRate.fromStore(prefs[KEY_FRAME_RATE]),
                    preferredCodec = RemoteDesktopCodec.fromStore(prefs[KEY_PREFERRED_CODEC]),
                    lowLatencyMode = prefs[KEY_LOW_LATENCY] ?: false,
                    enableHardwareAcceleration = prefs[KEY_HW_ACCEL] ?: true
                )
            }

    /**
     * Apply a preset. For a templated preset this writes the preset's canonical resolution/frameRate/
     * codec/lowLatency (matching iOS `applyPreset`). For [RemoteDesktopQualityPreset.CUSTOM] only the
     * preset id is stored; the existing manual fields are left untouched.
     */
    suspend fun setQualityPreset(context: Context, preset: RemoteDesktopQualityPreset) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_QUALITY_PRESET] = preset.storeValue
            if (preset.hasTemplate) {
                preset.templateResolution?.let { prefs[KEY_RESOLUTION] = it.storeValue }
                preset.templateFrameRate?.let { prefs[KEY_FRAME_RATE] = it.storeValue }
                preset.templateCodec?.let { prefs[KEY_PREFERRED_CODEC] = it.storeValue }
                preset.templateLowLatency?.let { prefs[KEY_LOW_LATENCY] = it }
            }
        }
    }

    suspend fun setResolution(context: Context, resolution: RemoteDesktopResolution) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_RESOLUTION] = resolution.storeValue
            prefs[KEY_QUALITY_PRESET] = RemoteDesktopQualityPreset.CUSTOM.storeValue
        }
    }

    suspend fun setFrameRate(context: Context, frameRate: RemoteDesktopFrameRate) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_FRAME_RATE] = frameRate.storeValue
            prefs[KEY_QUALITY_PRESET] = RemoteDesktopQualityPreset.CUSTOM.storeValue
        }
    }

    suspend fun setPreferredCodec(context: Context, codec: RemoteDesktopCodec) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_PREFERRED_CODEC] = codec.storeValue
            prefs[KEY_QUALITY_PRESET] = RemoteDesktopQualityPreset.CUSTOM.storeValue
        }
    }

    suspend fun setLowLatencyMode(context: Context, enabled: Boolean) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_LOW_LATENCY] = enabled
            prefs[KEY_QUALITY_PRESET] = RemoteDesktopQualityPreset.CUSTOM.storeValue
        }
    }

    suspend fun setEnableHardwareAcceleration(context: Context, enabled: Boolean) {
        context.remoteDesktopStreamSettingsDataStore.edit { prefs ->
            prefs[KEY_HW_ACCEL] = enabled
        }
    }
}
