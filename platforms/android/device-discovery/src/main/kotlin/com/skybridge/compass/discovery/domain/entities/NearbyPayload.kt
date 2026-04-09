package com.skybridge.compass.discovery.domain.entities

import android.os.ParcelFileDescriptor
import java.io.InputStream

/**
 * Nearby 负载统一包装，支持 BYTES / FILE / STREAM。
 */
sealed class NearbyPayload {
    data class Bytes(val data: ByteArray) : NearbyPayload()
    data class FilePayload(val payloadId: Long, val pfd: ParcelFileDescriptor?) : NearbyPayload()
    data class StreamPayload(val payloadId: Long, val input: InputStream) : NearbyPayload()
}