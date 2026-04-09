package com.skybridge.compass.discovery.domain.entities

/**
 * Nearby 传输进度包装，避免上层依赖 Play Services 类型。
 */
data class NearbyTransferUpdate(
    val payloadId: Long,
    val status: Status,
    val bytesTransferred: Long,
    val totalBytes: Long
) {
    enum class Status {
        IN_PROGRESS,
        SUCCESS,
        FAILURE
    }
}