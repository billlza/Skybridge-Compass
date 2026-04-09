package com.skybridge.compass.filetransfer.webrtc.resume

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

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

    private fun fileFor(id: String): File = File(dir, "$id.json")

    override suspend fun load(transferId: String): TransferCheckpoint? = withContext(Dispatchers.IO) {
        val f = fileFor(transferId)
        if (!f.exists()) return@withContext null
        runCatching {
            json.decodeFromString(TransferCheckpoint.serializer(), f.readText())
        }.getOrNull()
    }

    override suspend fun save(checkpoint: TransferCheckpoint) = withContext(Dispatchers.IO) {
        val f = fileFor(checkpoint.transferId)
        val updated = checkpoint.copy(updatedAtMs = System.currentTimeMillis())
        f.writeText(json.encodeToString(TransferCheckpoint.serializer(), updated))
    }

    override suspend fun delete(transferId: String) = withContext(Dispatchers.IO) {
        runCatching { fileFor(transferId).delete() }
        Unit
    }

    override suspend fun list(): List<TransferCheckpoint> = withContext(Dispatchers.IO) {
        val files = dir.listFiles()?.toList().orEmpty().filter { it.isFile && it.name.endsWith(".json") }
        files.mapNotNull { f ->
            runCatching { json.decodeFromString(TransferCheckpoint.serializer(), f.readText()) }.getOrNull()
        }.sortedByDescending { it.updatedAtMs }
    }
}


