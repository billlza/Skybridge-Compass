package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.shared.p2p.filetransfer.Base64ByteArraySerializer
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encodeToString
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.Locale
import java.util.UUID

/**
 * Wire-compatible models for SkyBridge Compass Pro (macOS) RemoteControlServer:
 * - TCP port: 5901
 * - Service: _skybridge-rd._tcp
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
        STREAM_CONFIGURATION,
        @SerialName("streamConfigurationAck")
        STREAM_CONFIGURATION_ACK,
        @SerialName("damageReport")
        DAMAGE_REPORT,
        @SerialName("cursorUpdate")
        CURSOR_UPDATE,
        @SerialName("overlayUpdate")
        OVERLAY_UPDATE
    }
}

internal object RemoteControlWireCodec {
    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
    private val strictAcknowledgementJson: Json = Json {
        ignoreUnknownKeys = false
        explicitNulls = false
    }

    fun encodeMessage(message: RemoteMessage): ByteArray =
        json.encodeToString(RemoteMessage.serializer(), message).encodeToByteArray()

    fun decodeMessage(bytes: ByteArray): RemoteMessage =
        json.decodeFromString(RemoteMessage.serializer(), bytes.decodeToString())

    fun decodeScreenData(message: RemoteMessage): ScreenData {
        require(message.type == RemoteMessage.MessageType.SCREEN_DATA) {
            "remote control message is not screenData"
        }
        val screen = json.decodeFromString(ScreenData.serializer(), message.payload.decodeToString())
        require(screen.imageData.isNotEmpty()) { "screenData imageData is empty" }
        return screen
    }

    fun decodeStreamConfiguration(message: RemoteMessage): RemoteDesktopStreamConfiguration {
        require(message.type == RemoteMessage.MessageType.STREAM_CONFIGURATION) {
            "remote control message is not streamConfiguration"
        }
        return json.decodeFromString(
            RemoteDesktopStreamConfiguration.serializer(),
            message.payload.decodeToString()
        )
    }

    fun decodeStreamConfigurationAcknowledgement(
        message: RemoteMessage
    ): RemoteDesktopStreamConfigurationAcknowledgement {
        require(message.type == RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK) {
            "remote control message is not streamConfigurationAck"
        }
        return strictAcknowledgementJson.decodeFromString(
            RemoteDesktopStreamConfigurationAcknowledgement.serializer(),
            message.payload.decodeToString()
        )
    }

    fun decodeMouseEvent(message: RemoteMessage): RemoteMouseEvent {
        require(message.type == RemoteMessage.MessageType.MOUSE_EVENT) {
            "remote control message is not mouseEvent"
        }
        return json.decodeFromString(RemoteMouseEvent.serializer(), message.payload.decodeToString())
    }

    fun decodeKeyboardEvent(message: RemoteMessage): RemoteKeyboardEvent {
        require(message.type == RemoteMessage.MessageType.KEYBOARD_EVENT) {
            "remote control message is not keyboardEvent"
        }
        return json.decodeFromString(RemoteKeyboardEvent.serializer(), message.payload.decodeToString())
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

/**
 * Wire-compatible mirror of macOS `RemoteClipboardPayload`
 * (Sources/SkyBridgeCore/RemoteControl/RemoteDesktopControlPayloads.swift:4-18).
 * Carried as the payload of a [RemoteMessage] with type [RemoteMessage.MessageType.CLIPBOARD].
 * `data` is base64 in JSON (Swift `Data`), `sentAt` is Unix seconds (host uses `Date().timeIntervalSince1970`).
 */
@Serializable
data class RemoteClipboardPayload(
    val mimeType: String,
    @Serializable(with = Base64ByteArraySerializer::class)
    val data: ByteArray,
    val sentAt: Double
)

@Serializable
data class RemoteControlSecurityIdentity(
    val accountDisplayName: String? = null,
    val nebulaId: String? = null,
    val deviceId: String? = null,
    val deviceName: String? = null
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
    val videoCompressionLevel: Int? = null,
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
    val screenFrameTransport: String? = null,
    val remoteControlSecurityIdentity: RemoteControlSecurityIdentity? = null,
    val streamRefreshToken: ULong? = null,
    val streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction? = null,
    val sentAt: Double
)

/**
 * Wire-compatible mirror of the shared Apple stream-configuration transaction.
 *
 * Foundation encodes UUID values using uppercase hexadecimal while Java normally emits lowercase.
 * Keeping the identifier as a [UUID] makes acknowledgement correlation case-independent without
 * weakening it to an arbitrary string comparison.
 */
@Serializable
data class RemoteDesktopStreamConfigurationTransaction(
    @Serializable(with = CanonicalUuidSerializer::class)
    val id: UUID
) {
    companion object {
        fun fresh(): RemoteDesktopStreamConfigurationTransaction =
            RemoteDesktopStreamConfigurationTransaction(UUID.randomUUID())
    }
}

internal object CanonicalUuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("java.util.UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        // Match Foundation's JSONEncoder representation for cross-language golden fixtures.
        encoder.encodeString(value.toString().uppercase(Locale.ROOT))
    }

    override fun deserialize(decoder: Decoder): UUID {
        val raw = decoder.decodeString()
        val parsed = runCatching { UUID.fromString(raw) }
            .getOrElse { throw IllegalArgumentException("invalid stream configuration transaction UUID") }
        require(parsed.toString().equals(raw, ignoreCase = true)) {
            "stream configuration transaction UUID is not canonical"
        }
        return parsed
    }
}

/** Shared LAN/WebRTC acknowledgement contract defined by SkyBridgeProtocolCore on Apple. */
@Serializable
data class RemoteDesktopStreamConfigurationAcknowledgement(
    val acceptedAt: Double,
    val transaction: RemoteDesktopStreamConfigurationTransaction,
    val streamRefreshToken: ULong? = null,
    val audioEndpointPresent: Boolean,
    val screenFrameTransport: String? = null
) {
    init {
        require(acceptedAt.isFinite() && acceptedAt >= 0.0) {
            "stream configuration acknowledgement acceptedAt is invalid"
        }
    }
}

internal data class RemoteDesktopStreamConfigurationAcknowledgementExpectation(
    val transaction: RemoteDesktopStreamConfigurationTransaction,
    val streamRefreshToken: ULong?,
    val audioEndpointPresent: Boolean,
    val screenFrameTransport: String?
)

internal enum class RemoteDesktopStreamConfigurationAcknowledgementDecision {
    ACCEPT,
    IGNORE_DUPLICATE,
    REJECT_UNEXPECTED,
    REJECT_CONFLICTING
}

/**
 * Pure correlation policy used by the LAN client. Connection ownership remains the responsibility
 * of its existing `ConnectionContext`; this policy intentionally does not create a parallel session
 * ledger.
 */
internal object RemoteDesktopStreamConfigurationAcknowledgementPolicy {
    fun decide(
        acknowledgement: RemoteDesktopStreamConfigurationAcknowledgement,
        awaiting: RemoteDesktopStreamConfigurationAcknowledgementExpectation?,
        acknowledged: RemoteDesktopStreamConfigurationAcknowledgementExpectation?
    ): RemoteDesktopStreamConfigurationAcknowledgementDecision {
        require(awaiting == null || acknowledged == null) {
            "stream configuration cannot be awaiting and acknowledged simultaneously"
        }
        awaiting?.let {
            return if (acknowledgement.matches(it)) {
                RemoteDesktopStreamConfigurationAcknowledgementDecision.ACCEPT
            } else {
                RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_CONFLICTING
            }
        }
        acknowledged?.let {
            return if (acknowledgement.matches(it)) {
                RemoteDesktopStreamConfigurationAcknowledgementDecision.IGNORE_DUPLICATE
            } else {
                RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_CONFLICTING
            }
        }
        return RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_UNEXPECTED
    }

    private fun RemoteDesktopStreamConfigurationAcknowledgement.matches(
        expectation: RemoteDesktopStreamConfigurationAcknowledgementExpectation
    ): Boolean =
        transaction == expectation.transaction &&
            streamRefreshToken == expectation.streamRefreshToken &&
            audioEndpointPresent == expectation.audioEndpointPresent &&
            screenFrameTransport == expectation.screenFrameTransport
}

@Serializable
enum class KeyboardEventType {
    @SerialName("keyDown")
    KEY_DOWN,
    @SerialName("keyUp")
    KEY_UP
}
