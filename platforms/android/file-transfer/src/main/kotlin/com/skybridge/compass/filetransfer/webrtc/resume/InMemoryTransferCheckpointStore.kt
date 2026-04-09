package com.skybridge.compass.filetransfer.webrtc.resume

import java.util.concurrent.ConcurrentHashMap

class InMemoryTransferCheckpointStore : TransferCheckpointStore {
    private val map = ConcurrentHashMap<String, TransferCheckpoint>()

    override suspend fun load(transferId: String): TransferCheckpoint? = map[transferId]

    override suspend fun save(checkpoint: TransferCheckpoint) {
        map[checkpoint.transferId] = checkpoint.copy(updatedAtMs = System.currentTimeMillis())
    }

    override suspend fun delete(transferId: String) {
        map.remove(transferId)
    }

    override suspend fun list(): List<TransferCheckpoint> = map.values.sortedByDescending { it.updatedAtMs }
}


