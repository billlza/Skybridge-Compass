package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import java.util.Locale

/**
 * Apple-side Bonjour interoperability profile shared by Android discovery and advertising.
 *
 * The Pro release relies on a handful of TXT aliases and service-specific defaults. Keeping
 * them in one place avoids subtle drift between discovery, connection routing, and handshake UX.
 */
object AppleBonjourInterop {

    const val MAIN_SERVICE_TYPE = "_skybridge._tcp"
    const val REMOTE_SERVICE_TYPE = "_skybridge-remote._tcp"
    const val FILE_TRANSFER_SERVICE_TYPE = "_skybridge-transfer._tcp"

    val DISCOVERY_SERVICE_TYPES: List<String> = listOf(
        MAIN_SERVICE_TYPE,
        REMOTE_SERVICE_TYPE,
        FILE_TRANSFER_SERVICE_TYPE
    )

    const val HS_SOA_KEY = "hs_soa"
    const val REMOTE_VIDEO_FORMATS_KEY = "remotevideoformats"
    private const val REMOTE_VIDEO_FORMATS_LEGACY_TYPO_KEY = "remotevideformats"
    const val REMOTE_VIDEO_FORMATS_FALLBACK_KEY = "remoteformats"

    val JPEG_ONLY_REMOTE_VIDEO_FORMATS: Set<String> = linkedSetOf("jpeg")

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

    fun inferCapabilitiesFromServiceType(serviceType: String?): Set<DeviceCapability> =
        when (serviceType?.trim()?.lowercase(Locale.ROOT)) {
            REMOTE_SERVICE_TYPE -> linkedSetOf(
                DeviceCapability.SCREEN_SHARING,
                DeviceCapability.REMOTE_CONTROL
            )

            FILE_TRANSFER_SERVICE_TYPE -> linkedSetOf(DeviceCapability.FILE_TRANSFER)

            else -> linkedSetOf(
                DeviceCapability.SCREEN_SHARING,
                DeviceCapability.FILE_TRANSFER
            )
        }

    fun parseCapabilities(
        rawCapabilities: String?,
        serviceType: String? = null
    ): Set<DeviceCapability> {
        val parsed = rawCapabilities
            ?.split(",")
            ?.asSequence()
            ?.map { it.trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.mapNotNull { capability ->
                when (capability) {
                    "screen_sharing", "remote_desktop", "rdview" -> DeviceCapability.SCREEN_SHARING
                    "file_transfer", "file" -> DeviceCapability.FILE_TRANSFER
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
            ?.toCollection(LinkedHashSet())
            ?: linkedSetOf()

        if (parsed.isNotEmpty()) {
            parsed += inferCapabilitiesFromServiceType(serviceType)
            return parsed
        }
        return inferCapabilitiesFromServiceType(serviceType)
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
            REMOTE_VIDEO_FORMATS_KEY,
            REMOTE_VIDEO_FORMATS_LEGACY_TYPO_KEY,
            "remote_video_formats",
            REMOTE_VIDEO_FORMATS_FALLBACK_KEY
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

    fun preferredPort(
        serviceType: String?,
        resolvedPort: Int,
        txtRecords: Map<String, String>
    ): Int {
        if (resolvedPort > 0) return resolvedPort
        return when (serviceType?.trim()?.lowercase(Locale.ROOT)) {
            REMOTE_SERVICE_TYPE -> resolveTxtValue(txtRecords, "remotePort", "port")?.toIntOrNull() ?: resolvedPort
            FILE_TRANSFER_SERVICE_TYPE -> resolveTxtValue(
                txtRecords,
                "fileTransferPort",
                "transferPort",
                "port"
            )?.toIntOrNull() ?: resolvedPort

            else -> resolveTxtValue(txtRecords, "port", "remotePort", "transferPort")?.toIntOrNull() ?: resolvedPort
        }
    }
}
