package com.skybridge.compass.filetransfer.webrtc.resume

import kotlinx.serialization.Serializable

@Serializable
enum class TransferDirection {
    SEND,
    RECEIVE
}

/**
 * Persistable (or in-memory) checkpoint for resumable CrossNetwork(WebRTC DataChannel) file transfers.
 *
 * IMPORTANT: This does NOT change the wire protocol. It only tracks local progress so we can:
 * - Resume sending un-acked chunks after reconnect/app restart (when possible)
 * - Avoid saving partial files on receive until complete
 */
@Serializable
data class TransferCheckpoint(
    val transferId: String,
    val direction: TransferDirection,

    // For SEND resume (persistable URI string)
    val sourceUri: String? = null,
    // For RECEIVE resume (partial file path in app-private storage)
    val partialPath: String? = null,

    val fileName: String? = null,
    val mimeType: String? = null,
    val fileSize: Long? = null,
    val chunkSize: Int? = null,
    val totalChunks: Int? = null,

    val ackedChunks: IntArray = intArrayOf(),
    val receivedChunks: IntArray = intArrayOf(),

    val completeReceived: Boolean = false,
    val lastStatus: String? = null,

    val createdAtMs: Long = System.currentTimeMillis(),
    val updatedAtMs: Long = System.currentTimeMillis()
) {
    companion object {
        fun newSend(
            transferId: String,
            sourceUri: String?,
            fileName: String?,
            mimeType: String?,
            fileSize: Long?,
            chunkSize: Int?,
            totalChunks: Int?
        ): TransferCheckpoint = TransferCheckpoint(
            transferId = transferId,
            direction = TransferDirection.SEND,
            sourceUri = sourceUri,
            fileName = fileName,
            mimeType = mimeType,
            fileSize = fileSize,
            chunkSize = chunkSize,
            totalChunks = totalChunks
        )

        fun newReceive(
            transferId: String,
            partialPath: String?,
            fileName: String?,
            mimeType: String?,
            fileSize: Long?,
            chunkSize: Int?,
            totalChunks: Int?
        ): TransferCheckpoint = TransferCheckpoint(
            transferId = transferId,
            direction = TransferDirection.RECEIVE,
            partialPath = partialPath,
            fileName = fileName,
            mimeType = mimeType,
            fileSize = fileSize,
            chunkSize = chunkSize,
            totalChunks = totalChunks
        )
    }
}


