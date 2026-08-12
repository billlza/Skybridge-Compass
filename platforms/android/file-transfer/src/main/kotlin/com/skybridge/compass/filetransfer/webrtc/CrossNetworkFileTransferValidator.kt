package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import java.util.UUID

internal object CrossNetworkFileTransferValidator {
    internal const val MAX_CHUNK_BYTES = 4 * 1024 * 1024
    internal const val MAX_FILE_BYTES = 16L * 1024 * 1024 * 1024
    internal const val MAX_TOTAL_CHUNKS = 1_000_000
    private const val SHA256_BYTES = 32

    data class Metadata(
        val transferId: String,
        val fileName: String,
        val fileSize: Long,
        val chunkSize: Int,
        val totalChunks: Int,
        val batchId: String?,
        val batchIndex: Int?,
        val batchTotal: Int?,
        val relativePath: String?
    )

    data class BatchReference(
        val batchId: String,
        val batchIndex: Int?,
        val batchTotal: Int?,
        val relativePath: String?
    )

    fun validateMetadata(message: CrossNetworkFileTransferMessage): Metadata {
        val transferId = canonicalTransferId(message.transferId)
        val fileName = requireSafeFileName(message.fileName)
        val fileSize = requireNotNull(message.fileSize) { "file transfer metadata missing fileSize" }
        val chunkSize = requireNotNull(message.chunkSize) { "file transfer metadata missing chunkSize" }
        val totalChunks = requireNotNull(message.totalChunks) { "file transfer metadata missing totalChunks" }
        val expectedChunks = validatedExpectedChunkCount(fileSize, chunkSize)
        require(totalChunks == expectedChunks) { "file transfer metadata totalChunks does not match fileSize/chunkSize" }
        val batch = validateBatchReference(
            batchId = message.batchId,
            batchIndex = message.batchIndex,
            batchTotal = message.batchTotal,
            relativePath = message.relativePath
        )
        return Metadata(
            transferId = transferId,
            fileName = fileName,
            fileSize = fileSize,
            chunkSize = chunkSize,
            totalChunks = totalChunks,
            batchId = batch?.batchId,
            batchIndex = batch?.batchIndex,
            batchTotal = batch?.batchTotal,
            relativePath = batch?.relativePath
        )
    }

    fun validateBatchReference(
        batchId: String?,
        batchIndex: Int?,
        batchTotal: Int?,
        relativePath: String?
    ): BatchReference? {
        val hasBatchFields = batchIndex != null || batchTotal != null || !relativePath.isNullOrBlank()
        if (batchId == null) {
            require(!hasBatchFields) { "file transfer batch fields require batchId" }
            return null
        }

        val canonicalBatchId = canonicalBatchId(batchId)
        batchIndex?.let {
            require(it >= 0) { "file transfer batchIndex must be non-negative" }
        }
        batchTotal?.let {
            require(it in 1..MAX_TOTAL_CHUNKS) { "file transfer batchTotal out of range" }
        }
        if (batchIndex != null && batchTotal != null) {
            require(batchIndex < batchTotal) { "file transfer batchIndex must be less than batchTotal" }
        }
        return BatchReference(
            batchId = canonicalBatchId,
            batchIndex = batchIndex,
            batchTotal = batchTotal,
            relativePath = requireSafeRelativePath(relativePath)
        )
    }

    fun validateChunk(
        message: CrossNetworkFileTransferMessage,
        metadata: Metadata,
        actualSha256: ByteArray?
    ): ByteArray {
        require(canonicalTransferId(message.transferId) == metadata.transferId) { "file transfer chunk transferId mismatch" }
        val chunkIndex = requireNotNull(message.chunkIndex) { "file transfer chunk missing chunkIndex" }
        require(chunkIndex in 0 until metadata.totalChunks) { "file transfer chunk index out of range" }
        val chunkData = requireNotNull(message.chunkData) { "file transfer chunk missing data" }
        require(chunkData.isNotEmpty()) { "file transfer chunk data must not be empty" }
        require(chunkData.size <= metadata.chunkSize) { "file transfer chunk exceeds negotiated chunkSize" }
        message.rawSize?.let {
            require(it == chunkData.size) { "file transfer chunk rawSize mismatch" }
        }
        val expectedSize = expectedChunkSize(metadata, chunkIndex)
        require(chunkData.size == expectedSize) { "file transfer chunk size mismatch" }
        val expectedHash = requireSha256(message.chunkSha256, "chunkSha256")
        requireNotNull(actualSha256) { "file transfer chunk hash was not computed" }
        require(actualSha256.contentEquals(expectedHash)) { "file transfer chunk sha256 mismatch" }
        return chunkData
    }

    fun validateComplete(
        message: CrossNetworkFileTransferMessage,
        metadata: Metadata
    ) {
        require(canonicalTransferId(message.transferId) == metadata.transferId) { "file transfer complete transferId mismatch" }
        message.receivedBytes?.let {
            require(it == metadata.fileSize) { "file transfer complete receivedBytes mismatch" }
        }
        requireSha256(message.fileSha256, "fileSha256")
        message.merkleRoot?.let { root ->
            require(root.size == SHA256_BYTES) { "file transfer merkleRoot must be 32 bytes" }
        }
        message.merkleRootSignature?.let { sig ->
            require(message.merkleRoot != null) { "file transfer complete merkleRootSignature requires merkleRoot" }
            require(sig.size == SHA256_BYTES) { "file transfer complete merkleRootSignature must be 32 bytes" }
            require(message.merkleRootSignatureAlg == "hmac-sha256-session-v1") {
                "file transfer complete merkleRootSignatureAlg unsupported"
            }
        }
        require(message.merkleRootSignatureAlg == null || message.merkleRootSignature != null) {
            "file transfer complete merkleRootSignatureAlg requires merkleRootSignature"
        }
    }

    fun canonicalTransferId(raw: String): String {
        return canonicalUuid("transferId", raw)
    }

    fun canonicalBatchId(raw: String): String {
        return canonicalUuid("batchId", raw)
    }

    fun validatedExpectedChunkCount(fileSize: Long, chunkSize: Int): Int {
        require(fileSize > 0L) { "file transfer metadata fileSize must be positive" }
        require(fileSize <= MAX_FILE_BYTES) { "file transfer metadata fileSize exceeds supported range" }
        require(chunkSize in 1..MAX_CHUNK_BYTES) { "file transfer metadata chunkSize out of range" }
        return expectedChunkCount(fileSize, chunkSize)
    }

    private fun canonicalUuid(fieldName: String, raw: String): String {
        val trimmed = raw.trim()
        require(trimmed == raw && trimmed.isNotEmpty()) { "file transfer $fieldName must be canonical UUID" }
        val parsed = runCatching { UUID.fromString(trimmed) }
            .getOrElse { throw IllegalArgumentException("file transfer $fieldName must be canonical UUID") }
        val canonical = parsed.toString()
        require(canonical == trimmed) { "file transfer $fieldName must be canonical UUID" }
        return canonical
    }

    private fun requireSafeFileName(raw: String?): String {
        val fileName = raw?.trim().orEmpty()
        require(fileName.isNotEmpty()) { "file transfer metadata missing fileName" }
        require(fileName == raw) { "file transfer fileName contains surrounding whitespace" }
        require(fileName.none { it == '/' || it == '\\' || it == '\u0000' }) {
            "file transfer fileName must be a display name, not a path"
        }
        require(fileName != "." && fileName != "..") { "file transfer fileName is not safe" }
        return fileName
    }

    private fun requireSafeRelativePath(raw: String?): String? {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return null
        require(value == raw) { "file transfer relativePath contains surrounding whitespace" }
        require(!value.startsWith("/") && !value.startsWith("\\")) { "file transfer relativePath must be relative" }
        require(value.none { it == '\u0000' }) { "file transfer relativePath contains NUL" }
        val parts = value.split('/', '\\').filter { it.isNotEmpty() }
        require(parts.isNotEmpty()) { "file transfer relativePath is empty" }
        require(parts.none { it == "." || it == ".." }) { "file transfer relativePath contains traversal" }
        return value
    }

    private fun requireSha256(raw: ByteArray?, fieldName: String): ByteArray {
        val bytes = requireNotNull(raw) { "file transfer $fieldName is required" }
        require(bytes.size == SHA256_BYTES) { "file transfer $fieldName must be 32 bytes" }
        return bytes
    }

    private fun expectedChunkCount(fileSize: Long, chunkSize: Int): Int {
        if (fileSize == 0L) return 0
        val count = (fileSize + chunkSize - 1L) / chunkSize
        require(count <= Int.MAX_VALUE) { "file transfer totalChunks exceeds supported range" }
        require(count <= MAX_TOTAL_CHUNKS) { "file transfer totalChunks exceeds supported range" }
        return count.toInt()
    }

    private fun expectedChunkSize(metadata: Metadata, chunkIndex: Int): Int {
        if (metadata.totalChunks == 0) return 0
        val isLast = chunkIndex == metadata.totalChunks - 1
        if (!isLast) return metadata.chunkSize
        val consumedBeforeLast = chunkIndex.toLong() * metadata.chunkSize.toLong()
        return (metadata.fileSize - consumedBeforeLast).toInt()
    }

}
