package com.skybridge.compass.filetransfer.webrtc.resume

import kotlinx.serialization.Serializable

@Serializable
data class BatchManifestEntry(
    val transferId: String,
    val batchIndex: Int? = null,
    val relativePath: String? = null,
    val fileName: String? = null,
    val fileSize: Long? = null,
    val status: Status = Status.PENDING,
    val updatedAtMs: Long = System.currentTimeMillis()
) {
    @Serializable
    enum class Status {
        PENDING,
        IN_PROGRESS,
        COMPLETED,
        FAILED,
        CANCELLED
    }
}

@Serializable
data class BatchManifest(
    val batchId: String,
    val batchTotal: Int? = null,
    val entries: List<BatchManifestEntry> = emptyList(),
    val createdAtMs: Long = System.currentTimeMillis(),
    val updatedAtMs: Long = System.currentTimeMillis()
)


