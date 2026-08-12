package com.skybridge.compass.filetransfer.webrtc.resume

class BatchManifestCommitRejectedException(
    val batchId: String,
) : IllegalStateException("batch manifest commit authorization expired for $batchId")

interface BatchManifestStore {
    /** Stable namespace for coordinating multiple controllers that mutate the same backing store. */
    val coordinationNamespace: String

    /**
     * Stage [manifest] and atomically replace the live file only while [runAuthorizedCommit] still
     * authorizes the operation. The validator is deliberately mandatory: remote-driven callers
     * bind it to their exact secure owner, while explicit local maintenance supplies its own
     * serialized local-operation authority.
     */
    suspend fun save(
        manifest: BatchManifest,
        runAuthorizedCommit: (commit: () -> Unit) -> Boolean,
    )

    suspend fun load(batchId: String): BatchManifest?
    suspend fun delete(batchId: String)
    suspend fun list(): List<BatchManifest>
}
