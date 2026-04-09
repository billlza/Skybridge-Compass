package com.skybridge.compass.filetransfer.webrtc.resume

/**
 * Storage interface for resumable transfer checkpoints.
 *
 * This is intentionally minimal: implementations can be in-memory, file-based, Room, DataStore, etc.
 */
interface TransferCheckpointStore {
    suspend fun load(transferId: String): TransferCheckpoint?
    suspend fun save(checkpoint: TransferCheckpoint)
    suspend fun delete(transferId: String)
    suspend fun list(): List<TransferCheckpoint>
}


