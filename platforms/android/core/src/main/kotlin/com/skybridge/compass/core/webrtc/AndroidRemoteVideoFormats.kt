package com.skybridge.compass.core.webrtc

import android.media.MediaCodecList
import java.util.Locale

/**
 * Centralizes Android-side remote video capability detection so discovery, pairing,
 * and viewer stream-configuration all advertise the same receive formats.
 */
object AndroidRemoteVideoFormats {
    const val JPEG: String = "jpeg"
    const val H264: String = "h264"
    const val HEVC: String = "hevc"

    private val cachedStreamingFormats by lazy(LazyThreadSafetyMode.PUBLICATION) {
        videoFormatsForMimeTypes(availableMimeTypes(encoders = false))
    }

    private val cachedEncodingFormats by lazy(LazyThreadSafetyMode.PUBLICATION) {
        videoFormatsForMimeTypes(availableMimeTypes(encoders = true))
    }

    fun supportedStreamingFormats(): List<String> =
        cachedStreamingFormats

    fun supportedEncodingFormats(): List<String> =
        cachedEncodingFormats

    fun supportsEncoding(format: String): Boolean =
        format in supportedEncodingFormats()

    fun preferredStreamingCodec(): String =
        supportedStreamingFormats().firstOrNull() ?: JPEG

    fun preferredEncodingCodec(): String =
        supportedEncodingFormats().firstOrNull() ?: JPEG

    fun normalizeIncomingFormat(format: String?, payload: ByteArray): String? {
        val normalized = format
            ?.trim()
            ?.lowercase(Locale.ROOT)
            ?.takeIf { it.isNotEmpty() }

        when (normalized) {
            HEVC, "h265" -> return HEVC
            H264, "avc" -> return H264
            JPEG, "jpg", "mjpeg" -> return JPEG
            "png" -> return "png"
            "webp" -> return "webp"
            "heic", "heif" -> return "heif"
            "avif" -> return "avif"
            "bgra" -> {
                if (looksLikeJpeg(payload)) {
                    return JPEG
                }
                return null
            }
        }

        return sniffStaticImageFormat(payload)
    }

    fun isVideoFormat(format: String?): Boolean =
        format == H264 || format == HEVC

    fun isStaticImageFormat(format: String?): Boolean =
        when (format) {
            JPEG, "png", "webp", "heif", "avif" -> true
            else -> false
        }

    internal fun videoFormatsForMimeTypes(mimeTypes: Set<String>): List<String> {
        val formats = LinkedHashSet<String>()
        if ("video/hevc" in mimeTypes) {
            formats += HEVC
        }
        if ("video/avc" in mimeTypes) {
            formats += H264
        }
        formats += JPEG
        return formats.toList()
    }

    internal fun sniffStaticImageFormat(payload: ByteArray): String? {
        if (looksLikeJpeg(payload)) return JPEG
        if (looksLikePng(payload)) return "png"
        if (looksLikeWebP(payload)) return "webp"
        return sniffIsoBmffImageFormat(payload)
    }

    private fun availableMimeTypes(encoders: Boolean): Set<String> =
        buildSet {
            val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            codecList.codecInfos.forEach { codecInfo ->
                if (codecInfo.isEncoder != encoders) return@forEach
                codecInfo.supportedTypes.forEach { type ->
                    add(type.lowercase(Locale.ROOT))
                }
            }
        }

    private fun looksLikeJpeg(payload: ByteArray): Boolean =
        payload.size >= 3 &&
            payload[0] == 0xFF.toByte() &&
            payload[1] == 0xD8.toByte() &&
            payload[2] == 0xFF.toByte()

    private fun looksLikePng(payload: ByteArray): Boolean =
        payload.size >= 8 &&
            payload[0] == 0x89.toByte() &&
            payload[1] == 0x50.toByte() &&
            payload[2] == 0x4E.toByte() &&
            payload[3] == 0x47.toByte() &&
            payload[4] == 0x0D.toByte() &&
            payload[5] == 0x0A.toByte() &&
            payload[6] == 0x1A.toByte() &&
            payload[7] == 0x0A.toByte()

    private fun looksLikeWebP(payload: ByteArray): Boolean =
        payload.size >= 12 &&
            payload.copyOfRange(0, 4).contentEquals("RIFF".encodeToByteArray()) &&
            payload.copyOfRange(8, 12).contentEquals("WEBP".encodeToByteArray())

    private fun sniffIsoBmffImageFormat(payload: ByteArray): String? {
        if (payload.size < 12) return null
        if (!payload.copyOfRange(4, 8).contentEquals("ftyp".encodeToByteArray())) {
            return null
        }

        val majorBrand = payload.copyOfRange(8, 12).decodeToString()
            .trim()
            .lowercase(Locale.ROOT)

        return when (majorBrand) {
            "heic", "heix", "hevc", "hevx", "mif1", "msf1" -> "heif"
            "avif", "avis" -> "avif"
            else -> null
        }
    }
}
