package com.skybridge.compass.filetransfer.webrtc.resume

import android.content.Context
import com.skybridge.compass.filetransfer.webrtc.CrossNetworkFileTransferValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * Disk-backed store for batch manifests (grouping multiple file transfers).
 *
 * This does NOT change the wire protocol. It only improves resume/UI robustness.
 */
class AndroidBatchManifestStore private constructor(
    private val directory: File,
    private val json: Json,
) : BatchManifestStore {

    constructor(appContext: Context, json: Json) : this(
        directory = File(appContext.applicationContext.filesDir, DIRECTORY_NAME),
        json = json,
    )

    override val coordinationNamespace: String = directory.absoluteFile.normalize().path

    private val dir: File by lazy {
        directory.apply {
            check(exists() || mkdirs()) { "failed to create batch manifest directory" }
            val staleBeforeMs = System.currentTimeMillis() - STALE_STAGING_MAX_AGE_MS
            listFiles { candidate ->
                candidate.isFile && candidate.name.endsWith(STAGING_SUFFIX) &&
                    candidate.lastModified() < staleBeforeMs
            }?.forEach { stale -> Files.deleteIfExists(stale.toPath()) }
        }
    }

    private fun file(batchId: String): File {
        val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
        return File(dir, "$canonicalBatchId.json")
    }

    override suspend fun save(
        manifest: BatchManifest,
        runAuthorizedCommit: (commit: () -> Unit) -> Boolean,
    ) = withContext(Dispatchers.IO) {
        val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(manifest.batchId)
        val target = file(canonicalBatchId)
        val staging = File(
            dir,
            ".$canonicalBatchId.${UUID.randomUUID()}$STAGING_SUFFIX",
        )
        try {
            val encoded = json.encodeToString(manifest.copy(batchId = canonicalBatchId))
                .toByteArray(Charsets.UTF_8)
            FileOutputStream(staging).use { output ->
                output.write(encoded)
                output.fd.sync()
            }

            // Only this short same-filesystem move enters the caller's exact-owner commit gate.
            val committed = runAuthorizedCommit {
                Files.move(
                    staging.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            if (!committed) throw BatchManifestCommitRejectedException(canonicalBatchId)
        } catch (cause: Throwable) {
            // Preserve the primary failure while making cleanup failure explicitly observable.
            try {
                Files.deleteIfExists(staging.toPath())
            } catch (cleanupFailure: Throwable) {
                cause.addSuppressed(cleanupFailure)
            }
            throw cause
        }
        Unit
    }

    override suspend fun load(batchId: String): BatchManifest? = withContext(Dispatchers.IO) {
        val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
        val f = file(canonicalBatchId)
        if (!f.exists()) return@withContext null
        val manifest = json.decodeFromString<BatchManifest>(f.readText())
        require(CrossNetworkFileTransferValidator.canonicalBatchId(manifest.batchId) == canonicalBatchId) {
            "batch manifest id does not match requested batch"
        }
        return@withContext manifest.copy(batchId = canonicalBatchId)
    }

    override suspend fun delete(batchId: String) = withContext(Dispatchers.IO) {
        Files.deleteIfExists(file(batchId).toPath())
        Unit
    }

    override suspend fun list(): List<BatchManifest> = withContext(Dispatchers.IO) {
        dir.listFiles { ff -> ff.extension == "json" }
            ?.map { ff ->
                val manifest = json.decodeFromString<BatchManifest>(ff.readText())
                val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(manifest.batchId)
                manifest.copy(batchId = canonicalBatchId)
            }
            ?: emptyList()
    }

    internal companion object {
        private const val DIRECTORY_NAME = "skybridge_batch_manifests"
        private const val STAGING_SUFFIX = ".staging.tmp"
        private const val STALE_STAGING_MAX_AGE_MS = 24L * 60L * 60L * 1_000L

        fun forFilesDirectory(filesDirectory: File, json: Json): AndroidBatchManifestStore =
            AndroidBatchManifestStore(File(filesDirectory, DIRECTORY_NAME), json)
    }
}
