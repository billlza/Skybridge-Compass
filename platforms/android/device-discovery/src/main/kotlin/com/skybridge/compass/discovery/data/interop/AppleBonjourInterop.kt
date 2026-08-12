package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import java.util.Locale

/**
 * Apple-side Bonjour interoperability profile shared by Android discovery and advertising.
 *
 * The Pro release relies on a handful of TXT aliases and explicit capability records. Keeping
 * them in one place avoids subtle drift between discovery, connection routing, and handshake UX.
 */
object AppleBonjourInterop {

    const val MAIN_SERVICE_TYPE = ProductRouteBindingProtocol.CONTROL_SERVICE_TYPE
    const val REMOTE_SERVICE_TYPE = ProductRouteBindingProtocol.REMOTE_DESKTOP_SERVICE_TYPE
    const val FILE_TRANSFER_SERVICE_TYPE = ProductRouteBindingProtocol.FILE_TRANSFER_SERVICE_TYPE
    const val LEGACY_REMOTE_SERVICE_TYPE =
        ProductRouteBindingProtocol.LEGACY_REMOTE_DESKTOP_SERVICE_TYPE
    const val LEGACY_FILE_TRANSFER_SERVICE_TYPE =
        ProductRouteBindingProtocol.LEGACY_FILE_TRANSFER_SERVICE_TYPE

    val DISCOVERY_SERVICE_TYPES: List<String> = listOf(
        MAIN_SERVICE_TYPE,
        REMOTE_SERVICE_TYPE,
        FILE_TRANSFER_SERVICE_TYPE,
        LEGACY_REMOTE_SERVICE_TYPE,
        LEGACY_FILE_TRANSFER_SERVICE_TYPE
    )

    fun canonicalServiceType(raw: String?): String? =
        raw?.trim()
            ?.removePrefix(".")
            ?.let(ProductRouteBindingProtocol::canonicalServiceType)

    fun canonicalDnsSdInstanceName(serviceName: String, observedServiceType: String?): String? {
        val canonicalServiceType = canonicalServiceType(observedServiceType) ?: return null
        val normalizedServiceName = serviceName.trim().removeSuffix(".")
        if (normalizedServiceName.isEmpty()) return null

        val acceptedSuffixes = ProductRouteBindingProtocol
            .acceptedServiceTypes(canonicalServiceType)
            .map { ".$it.local" }
        val matchedSuffix = acceptedSuffixes.firstOrNull { suffix ->
            normalizedServiceName.endsWith(suffix, ignoreCase = true)
        }
        val instance = if (matchedSuffix == null) {
            normalizedServiceName
        } else {
            normalizedServiceName.dropLast(matchedSuffix.length).trim()
        }
        return instance
            .takeIf { it.isNotEmpty() }
            ?.let { "$it.$canonicalServiceType.local" }
    }

    const val HS_SOA_KEY = "hs_soa"
    const val REMOTE_VIDEO_FORMATS_KEY = "remoteVideoFormats"
    private const val REMOTE_VIDEO_FORMATS_LEGACY_TYPO_KEY = "remotevideformats"
    const val REMOTE_VIDEO_FORMATS_FALLBACK_KEY = "remoteformats"

    val DEVICE_IDENTITY_TXT_KEYS: List<String> = listOf(
        "deviceId",
        "id",
        "deviceID",
        "device_id",
        "uuid",
        "uniqueId",
        "unique_id"
    )

    val PUB_KEY_FINGERPRINT_TXT_KEYS: List<String> = listOf(
        "pubKeyFP",
        "pubKeyFp",
        "pub_key_fp",
        "identityFingerprint",
        "publicKeyFingerprint"
    )

    val FILE_TRANSFER_PORT_TXT_KEYS: List<String> = listOf(
        "transferPort",
        "fileTransferPort",
        "file_transfer_port",
        "port"
    )

    val REMOTE_CONTROL_PORT_TXT_KEYS: List<String> = listOf(
        "remotePort",
        "remoteControlPort",
        "remote_port",
        "port"
    )

    val REMOTE_VIDEO_FORMAT_TXT_KEYS: List<String> = listOf(
        REMOTE_VIDEO_FORMATS_KEY,
        "remote_video_formats",
        REMOTE_VIDEO_FORMATS_FALLBACK_KEY,
        "remotevideoformats",
        REMOTE_VIDEO_FORMATS_LEGACY_TYPO_KEY
    )

    val JPEG_ONLY_REMOTE_VIDEO_FORMATS: Set<String> = linkedSetOf("jpeg")
    private val PUB_KEY_FINGERPRINT_REGEX = Regex("^[0-9a-f]{64}$")
    fun normalizeTxtRecords(records: Map<String, String>): Map<String, String> = buildMap(records.size) {
        records.forEach { (key, value) ->
            val normalizedKey = key.trim().lowercase(Locale.ROOT)
            if (normalizedKey.isNotEmpty()) {
                put(normalizedKey, value.trim())
            }
        }
    }

    fun resolveTxtValue(records: Map<String, String>, vararg keys: String): String? {
        if (records.isEmpty()) return null
        val normalized = normalizeTxtRecords(records)
        return keys.asSequence()
            .map { it.trim().lowercase(Locale.ROOT) }
            .mapNotNull { normalized[it] }
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() }
    }

    fun appleCompatibleCapabilities(capabilities: Set<DeviceCapability>): String {
        val tokens = LinkedHashSet<String>()
        capabilities.forEach { capability ->
            when (capability) {
                DeviceCapability.SCREEN_SHARING -> {
                    tokens += "screen_sharing"
                    tokens += "remote_desktop"
                    tokens += "rdview"
                }

                DeviceCapability.FILE_TRANSFER -> {
                    tokens += "file_transfer"
                    tokens += "file"
                    tokens += "classic_resume"
                }

                DeviceCapability.REMOTE_CONTROL -> {
                    tokens += "remote_control"
                    tokens += "rdcontrol"
                }

                DeviceCapability.CLIPBOARD_SYNC -> {
                    tokens += "clipboard_sync"
                    tokens += "clipboard"
                }

                DeviceCapability.AUDIO_STREAMING -> tokens += "audio_streaming"
                DeviceCapability.VIDEO_STREAMING -> tokens += "video_streaming"
                DeviceCapability.NOTIFICATION_SYNC -> tokens += "notification_sync"
                DeviceCapability.CAMERA_ACCESS -> tokens += "camera_access"
                DeviceCapability.MICROPHONE_ACCESS -> tokens += "microphone_access"
            }
        }
        return tokens.joinToString(",")
    }

    fun parseCapabilities(rawCapabilities: String?): Set<DeviceCapability> {
        val tokens = rawCapabilities
            ?.split(",")
            ?.asSequence()
            ?.map { it.trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toList()
            ?: emptyList()
        val parsed = tokens
            .asSequence()
            .mapNotNull { capability ->
                when (capability) {
                    "screen_sharing", "remote_desktop", "rdview" -> DeviceCapability.SCREEN_SHARING
                    "file_transfer", "file", "classic_resume" -> DeviceCapability.FILE_TRANSFER
                    "remote_control", "rdcontrol" -> DeviceCapability.REMOTE_CONTROL
                    "audio_streaming" -> DeviceCapability.AUDIO_STREAMING
                    "video_streaming" -> DeviceCapability.VIDEO_STREAMING
                    "clipboard_sync", "clipboard" -> DeviceCapability.CLIPBOARD_SYNC
                    "notification_sync" -> DeviceCapability.NOTIFICATION_SYNC
                    "camera_access" -> DeviceCapability.CAMERA_ACCESS
                    "microphone_access" -> DeviceCapability.MICROPHONE_ACCESS
                    else -> null
                }
            }
            .toCollection(LinkedHashSet())

        if (tokens.isNotEmpty()) return parsed
        return emptySet()
    }

    fun canonicalRemoteVideoFormats(formats: Iterable<String>): Set<String> {
        val normalized = LinkedHashSet<String>()
        formats.forEach { format ->
            when (format.trim().lowercase(Locale.ROOT)) {
                "jpeg", "jpg", "mjpeg", "bgra" -> normalized += "jpeg"
                "h264", "avc" -> normalized += "h264"
                "h265", "hevc" -> normalized += "hevc"
            }
        }
        return normalized
    }

    fun remoteVideoFormatsCsv(formats: Iterable<String>): String? {
        val normalized = canonicalRemoteVideoFormats(formats)
        return normalized.takeIf { it.isNotEmpty() }?.joinToString(",")
    }

    fun extractRemoteVideoFormats(records: Map<String, String>): Set<String> {
        val raw = resolveTxtValue(
            records,
            *REMOTE_VIDEO_FORMAT_TXT_KEYS.toTypedArray()
        ) ?: return emptySet()
        return canonicalRemoteVideoFormats(raw.split(","))
    }

    fun supportsSoa(records: Map<String, String>): Boolean {
        val raw = resolveTxtValue(records, HS_SOA_KEY) ?: return false
        return when (raw.trim().lowercase(Locale.ROOT)) {
            "1", "true", "yes", "on" -> true
            else -> false
        }
    }

    fun normalizedPubKeyFingerprint(raw: String?): String? =
        raw
            ?.trim()
            ?.takeIf { PUB_KEY_FINGERPRINT_REGEX.matches(it) }

    /**
     * Maximum encoded byte length permitted for a single advertised identity fingerprint value,
     * matching the RFC 6763 per-pair TXT ceiling. A fingerprint whose UTF-8 encoding exceeds this
     * is treated as malformed and never presented as connectable (R3.14).
     */
    const val MAX_PUB_KEY_FINGERPRINT_BYTES = 255

    /**
     * Returns only a DNS-SD resolved SRV port. TXT-advertised port values are not authenticated
     * route evidence and are intentionally never promoted to a dialable endpoint.
     */
    fun preferredPort(resolvedPort: Int): Int = resolvedPort.takeIf { it in 1..65535 } ?: 0
}
