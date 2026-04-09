package com.skybridge.compass.filetransfer.webrtc.resume

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Disk-backed store for batch manifests (grouping multiple file transfers).
 *
 * This does NOT change the wire protocol. It only improves resume/UI robustness.
 */
class AndroidBatchManifestStore(
    private val appContext: Context,
    private val json: Json
) : BatchManifestStore {

    private val dir: File by lazy {
        File(appContext.filesDir, "skybridge_batch_manifests").apply { mkdirs() }
    }

    private fun file(batchId: String): File = File(dir, "$batchId.json")

    override suspend fun save(manifest: BatchManifest) = withContext(Dispatchers.IO) {
        file(manifest.batchId).writeText(json.encodeToString(manifest))
    }

    override suspend fun load(batchId: String): BatchManifest? = withContext(Dispatchers.IO) {
        val f = file(batchId)
        if (!f.exists()) return@withContext null
        return@withContext runCatching { json.decodeFromString<BatchManifest>(f.readText()) }.getOrNull()
    }

    override suspend fun delete(batchId: String) = withContext(Dispatchers.IO) {
        file(batchId).delete()
        Unit
    }

    override suspend fun list(): List<BatchManifest> = withContext(Dispatchers.IO) {
        dir.listFiles { ff -> ff.extension == "json" }
            ?.mapNotNull { ff -> runCatching { json.decodeFromString<BatchManifest>(ff.readText()) }.getOrNull() }
            ?: emptyList()
    }
}


