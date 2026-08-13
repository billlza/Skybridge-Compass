package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.UUID

class CrossNetworkFileTransferValidatorTest {

    @Test
    fun validatesCanonicalMetadataChunkAndComplete() {
        val transferId = UUID.randomUUID().toString()
        val batchId = UUID.randomUUID().toString()
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = "report.pdf",
                fileSize = 5,
                chunkSize = 5,
                totalChunks = 1,
                batchId = batchId,
                batchIndex = 0,
                batchTotal = 1,
                relativePath = "reports/report.pdf"
            )
        )
        val chunk = "hello".encodeToByteArray()

        val validatedChunk = CrossNetworkFileTransferValidator.validateChunk(
            message = CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.chunk,
                transferId = transferId,
                chunkIndex = 0,
                chunkData = chunk,
                chunkSha256 = sha256(chunk),
                rawSize = chunk.size
            ),
            metadata = metadata,
            actualSha256 = sha256(chunk)
        )
        CrossNetworkFileTransferValidator.validateComplete(
            message = CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.complete,
                transferId = transferId,
                receivedBytes = 5,
                fileSha256 = sha256(chunk),
                merkleRoot = ByteArray(32) { 7 }
            ),
            metadata = metadata
        )

        assertEquals("report.pdf", metadata.fileName)
        assertEquals(batchId, metadata.batchId)
        assertEquals("reports/report.pdf", metadata.relativePath)
        assertEquals(chunk.toList(), validatedChunk.toList())
    }

    @Test
    fun rejectsNonCanonicalTransferIdAndPathFileName() {
        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = "ft-${UUID.randomUUID()}",
                    fileName = "report.pdf",
                    fileSize = 1,
                    chunkSize = 1,
                    totalChunks = 1
                )
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "../secret.txt",
                    fileSize = 1,
                    chunkSize = 1,
                    totalChunks = 1
                )
            )
        }
    }

    @Test
    fun rejectsChunkWithoutValidIntegrityProof() {
        val transferId = UUID.randomUUID().toString()
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = "data.bin",
                fileSize = 4,
                chunkSize = 4,
                totalChunks = 1
            )
        )

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateChunk(
                message = CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 0,
                    chunkData = byteArrayOf(1, 2, 3, 4),
                    rawSize = 4
                ),
                metadata = metadata,
                actualSha256 = sha256(byteArrayOf(1, 2, 3, 4))
            )
        }
    }

    @Test
    fun rejectsInvalidBatchFieldsAndRelativePathTraversal() {
        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "data.bin",
                    fileSize = 4,
                    chunkSize = 4,
                    totalChunks = 1,
                    batchId = "../batch",
                    batchIndex = 0,
                    batchTotal = 1
                )
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "data.bin",
                    fileSize = 4,
                    chunkSize = 4,
                    totalChunks = 1,
                    batchIndex = 0,
                    batchTotal = 1
                )
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "data.bin",
                    fileSize = 4,
                    chunkSize = 4,
                    totalChunks = 1,
                    batchId = UUID.randomUUID().toString(),
                    batchIndex = 1,
                    batchTotal = 1,
                    relativePath = "../data.bin"
                )
            )
        }
    }

    @Test
    fun rejectsZeroLengthAndOutOfRangeMetadata() {
        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "empty.bin",
                    fileSize = 0,
                    chunkSize = 4,
                    totalChunks = 0
                )
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateMetadata(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = UUID.randomUUID().toString(),
                    fileName = "large.bin",
                    fileSize = CrossNetworkFileTransferValidator.MAX_FILE_BYTES + 1,
                    chunkSize = CrossNetworkFileTransferValidator.MAX_CHUNK_BYTES,
                    totalChunks = 4097
                )
            )
        }
    }

    @Test
    fun acceptsCompleteWithFileSha256WithoutMerkleRootForAppleInterop() {
        val transferId = UUID.randomUUID().toString()
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = "data.bin",
                fileSize = 4,
                chunkSize = 4,
                totalChunks = 1
            )
        )

        CrossNetworkFileTransferValidator.validateComplete(
            message = CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.complete,
                transferId = transferId,
                receivedBytes = 4,
                fileSha256 = sha256(byteArrayOf(1, 2, 3, 4))
            ),
            metadata = metadata
        )
    }

    @Test
    fun rejectsCompleteWithoutFileSha256() {
        val transferId = UUID.randomUUID().toString()
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = "data.bin",
                fileSize = 4,
                chunkSize = 4,
                totalChunks = 1
            )
        )

        assertThrows(IllegalArgumentException::class.java) {
            CrossNetworkFileTransferValidator.validateComplete(
                message = CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = 4,
                    merkleRoot = ByteArray(32) { 7 }
                ),
                metadata = metadata
            )
        }
    }

    @Test
    fun rejectsCompleteWithoutExactVersionAndReceivedBytes() {
        val transferId = UUID.randomUUID().toString()
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = "data.bin",
                fileSize = 4,
                chunkSize = 4,
                totalChunks = 1,
            ),
        )
        val digest = sha256(byteArrayOf(1, 2, 3, 4))

        listOf(
            CrossNetworkFileTransferMessage(
                version = 2,
                op = CrossNetworkFileTransferOp.complete,
                transferId = transferId,
                receivedBytes = 4,
                fileSha256 = digest,
            ),
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.complete,
                transferId = transferId,
                fileSha256 = digest,
            ),
        ).forEach { complete ->
            assertThrows(IllegalArgumentException::class.java) {
                CrossNetworkFileTransferValidator.validateComplete(complete, metadata)
            }
        }
    }

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)
}
