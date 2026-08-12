package com.skybridge.compass.filetransfer.webrtc.resume

/**
 * Pure, Android-free logic for computing where a RECEIVE transfer must resume from.
 *
 * The invariant it enforces (Requirement 5.6/5.7): a resumed receive must start from the last
 * verified chunk boundary that is actually backed by the on-disk partial file, and it must never
 * trust checkpoint state that is inconsistent with that partial file. Non-contiguous chunks that
 * were only buffered in memory (never flushed to the partial file) are intentionally dropped so the
 * receiver re-requests exactly the missing suffix instead of re-writing already-persisted chunks or
 * restarting from zero.
 *
 * This holds no wire-protocol surface; it only interprets local checkpoint + partial-file state.
 */
object ResumeReceivePlanner {

    const val SHA256_BYTES = 32

    /**
     * The trusted, contiguous receive prefix recovered from the partial file + checkpoint.
     *
     * @param prefixChunks number of contiguous chunks (0-based indices 0 until prefixChunks) that
     *   are proven present on disk and hash-verified by the checkpoint.
     * @param restoredBytes byte length of that contiguous prefix (equals the partial file length).
     * @param chunkHashesByIndex verified SHA-256 hash for each restored chunk index.
     */
    data class RestoredPrefix(
        val prefixChunks: Int,
        val restoredBytes: Long,
        val chunkHashesByIndex: Map<Int, ByteArray>
    )

    /**
     * Validate that the checkpoint's stored file dimensions are consistent with the freshly
     * validated metadata. A null stored dimension means "not yet known" and is accepted; a stored
     * dimension that disagrees with metadata rejects the checkpoint.
     */
    fun validateMetadataConsistency(
        checkpointFileName: String?,
        checkpointFileSize: Long?,
        checkpointChunkSize: Int?,
        checkpointTotalChunks: Int?,
        metadataFileName: String,
        metadataFileSize: Long,
        metadataChunkSize: Int,
        metadataTotalChunks: Int
    ) {
        require(checkpointFileName == null || checkpointFileName == metadataFileName) {
            "checkpoint fileName mismatch"
        }
        require(checkpointFileSize == null || checkpointFileSize == metadataFileSize) {
            "checkpoint fileSize mismatch"
        }
        require(checkpointChunkSize == null || checkpointChunkSize == metadataChunkSize) {
            "checkpoint chunkSize mismatch"
        }
        require(checkpointTotalChunks == null || checkpointTotalChunks == metadataTotalChunks) {
            "checkpoint totalChunks mismatch"
        }
    }

    /**
     * How many whole, contiguous chunks a partial file of [partialLength] bytes represents.
     *
     * The partial file must be chunk-aligned (every flush writes whole contiguous chunks) except at
     * exactly the full file size. Anything else is treated as an inconsistent checkpoint.
     */
    fun prefixChunksForPartialLength(
        fileSize: Long,
        chunkSize: Int,
        totalChunks: Int,
        partialLength: Long
    ): Int {
        require(partialLength in 0..fileSize) { "checkpoint partial length out of range" }
        if (partialLength == 0L) return 0
        if (partialLength == fileSize) return totalChunks
        require(partialLength % chunkSize.toLong() == 0L) {
            "checkpoint partial length is not chunk-aligned"
        }
        val prefix = partialLength / chunkSize.toLong()
        require(prefix <= totalChunks) { "checkpoint partial length exceeds total chunks" }
        return prefix.toInt()
    }

    /**
     * Recover the contiguous, hash-verified prefix that the resumed receive can trust.
     *
     * @throws IllegalArgumentException / IllegalStateException when the checkpoint is inconsistent
     *   with the partial file (missing a contiguous chunk, missing/invalid chunk hash, unaligned
     *   partial length). A rejected checkpoint must NOT be used to resume.
     */
    fun restoreContiguousPrefix(
        fileSize: Long,
        chunkSize: Int,
        totalChunks: Int,
        partialLength: Long,
        receivedChunks: Set<Int>,
        receivedChunkSha256HexByIndex: Map<Int, String>
    ): RestoredPrefix {
        val prefixChunks = prefixChunksForPartialLength(fileSize, chunkSize, totalChunks, partialLength)
        val hashes = LinkedHashMap<Int, ByteArray>(prefixChunks)
        for (index in 0 until prefixChunks) {
            require(index in receivedChunks) { "checkpoint missing contiguous chunk#$index" }
            val hash = receivedChunkSha256HexByIndex[index]
                ?.let { hexToBytes(it) }
                ?: error("checkpoint missing chunk hash#$index")
            require(hash.size == SHA256_BYTES) { "checkpoint chunk hash#$index is invalid" }
            hashes[index] = hash
        }
        return RestoredPrefix(
            prefixChunks = prefixChunks,
            restoredBytes = partialLength,
            chunkHashesByIndex = hashes
        )
    }

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "hex string length must be even" }
        return ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }
}
