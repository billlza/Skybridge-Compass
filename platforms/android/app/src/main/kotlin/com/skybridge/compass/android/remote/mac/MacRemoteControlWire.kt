package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.shared.p2p.filetransfer.Base64ByteArraySerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-compatible models for SkyBridge Compass Pro (macOS) RemoteControlServer:
 * - TCP port: 5901
 * - Service: _skybridge-remote._tcp
 * - Frame: u32 length (big-endian) + JSON(RemoteMessage)
 * - RemoteMessage.payload is base64 (Swift Data JSON encoding)
 */
@Serializable
data class RemoteMessage(
    val type: MessageType,
    @Serializable(with = Base64ByteArraySerializer::class)
    val payload: ByteArray
) {
    @Serializable
    enum class MessageType {
        @SerialName("screenData")
        SCREEN_DATA,
        @SerialName("mouseEvent")
        MOUSE_EVENT,
        @SerialName("keyboardEvent")
        KEYBOARD_EVENT,
        @SerialName("clipboard")
        CLIPBOARD,
        @SerialName("streamConfiguration")
        STREAM_CONFIGURATION
    }
}

@Serializable
data class ScreenData(
    val width: Int,
    val height: Int,
    @Serializable(with = Base64ByteArraySerializer::class)
    val imageData: ByteArray,
    val timestamp: Double,
    val format: String? = null // "hevc" / "h264" / "bgra" / "jpeg"
)

@Serializable
data class RemoteMouseEvent(
    val type: MouseEventType,
    val x: Double,
    val y: Double,
    val timestamp: Double
)

@Serializable
enum class MouseEventType {
    @SerialName("leftMouseDown")
    LEFT_MOUSE_DOWN,
    @SerialName("leftMouseUp")
    LEFT_MOUSE_UP,
    @SerialName("rightMouseDown")
    RIGHT_MOUSE_DOWN,
    @SerialName("rightMouseUp")
    RIGHT_MOUSE_UP,
    @SerialName("mouseMoved")
    MOUSE_MOVED,
    @SerialName("scrollUp")
    SCROLL_UP,
    @SerialName("scrollDown")
    SCROLL_DOWN
}

@Serializable
data class RemoteKeyboardEvent(
    val type: KeyboardEventType,
    val keyCode: Int,
    val timestamp: Double
)

@Serializable
data class RemoteDesktopStreamConfiguration(
    val width: Int? = null,
    val height: Int? = null,
    val preferredCodec: String? = null,
    val supportedVideoFormats: List<String> = emptyList(),
    val qualityPreset: String? = null,
    val adaptiveResolutionEnabled: Boolean? = null,
    val targetFrameRate: Int,
    val keyFrameInterval: Int,
    val lowLatencyMode: Boolean,
    val enableHardwareAcceleration: Boolean,
    val enableAppleSiliconOptimization: Boolean,
    val clipboardSyncEnabled: Boolean,
    val damageTrackingEnabled: Boolean? = null,
    val separateCursorChannelEnabled: Boolean? = null,
    val interactionOverlayChannelEnabled: Boolean? = null,
    val refreshStrategy: String? = null,
    val jitterBufferFrames: Int? = null,
    val lossRecoveryMode: String? = null,
    val streamRefreshToken: Long? = null,
    val sentAt: Double
)

@Serializable
enum class KeyboardEventType {
    @SerialName("keyDown")
    KEY_DOWN,
    @SerialName("keyUp")
    KEY_UP
}
