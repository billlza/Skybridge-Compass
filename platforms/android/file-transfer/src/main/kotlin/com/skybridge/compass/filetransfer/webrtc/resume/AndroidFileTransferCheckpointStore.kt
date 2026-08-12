package com.skybridge.compass.filetransfer.webrtc.resume

import android.content.Context
import com.skybridge.compass.filetransfer.webrtc.CrossNetworkFileTransferValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException

/**
 * Simple file-backed checkpoint store (JSON per transferId) for true resume across app restarts.
 *
 * Location: context.filesDir/skybridge_transfer_checkpoints/<transferId>.json
 */
class AndroidFileTransferCheckpointStore(
    context: Context,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }
) : TransferCheckpointStore {

    private val dir: File = File(context.applicationContext.filesDir, "skybridge_transfer_checkpoints").apply {
        mkdirs()
    }

    private fun fileFor(id: String): File {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(id)
        return File(dir, "$canonicalTransferId.json")
    }

    override suspend fun load(transferId: String): TransferCheckpoint? = withContext(Dispatchers.IO) {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(transferId)
        val f = fileFor(canonicalTransferId)
        if (!f.exists()) return@withContext null
        val checkpoint = json.decodeFromString(TransferCheckpoint.serializer(), f.readText())
        require(CrossNetworkFileTransferValidator.canonicalTransferId(checkpoint.transferId) == canonicalTransferId) {
            "checkpoint transferId does not match requested transfer"
        }
        checkpoint.copy(transferId = canonicalTransferId)
    }

    override suspend fun save(checkpoint: TransferCheckpoint) = withContext(Dispatchers.IO) {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(checkpoint.transferId)
        val f = fileFor(canonicalTransferId)
        val updated = checkpoint.copy(
            transferId = canonicalTransferId,
            updatedAtMs = System.currentTimeMillis()
        )
        f.writeText(json.encodeToString(TransferCheckpoint.serializer(), updated))
    }

    override suspend fun delete(transferId: String) = withContext(Dispatchers.IO) {
        val checkpointFile = fileFor(transferId)
        if (checkpointFile.exists() && !checkpointFile.delete()) {
            throw IOException("failed to delete checkpoint file: ${checkpointFile.absolutePath}")
        }
    }

    override suspend fun list(): List<TransferCheckpoint> = withContext(Dispatchers.IO) {
        val files = dir.listFiles()?.toList().orEmpty().filter { it.isFile && it.name.endsWith(".json") }
        files.map { f ->
            val checkpoint = json.decodeFromString(TransferCheckpoint.serializer(), f.readText())
            checkpoint.copy(
                transferId = CrossNetworkFileTransferValidator.canonicalTransferId(checkpoint.transferId)
            )
        }.sortedByDescending { it.updatedAtMs }
    }
}
