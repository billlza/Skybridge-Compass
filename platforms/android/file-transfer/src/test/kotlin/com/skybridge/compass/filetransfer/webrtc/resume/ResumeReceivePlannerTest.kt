package com.skybridge.compass.filetransfer.webrtc.resume

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

/**
 * Tests for RECEIVE-side resume planning (task 11.3 / Requirement 5.6, 5.7).
 *
 * A resumed receive must restore ONLY the contiguous, hash-verified prefix that is actually backed
 * by the on-disk partial file, must resume from that boundary (never zero, never re-writing an
 * already-received chunk), and must reject any checkpoint that is inconsistent with the partial
 * file or the transfer metadata.
 */
class ResumeReceivePlannerTest {

    private fun hex(byte: Int): String = "%02x".format(byte)

    /** A valid 32-byte SHA-256 hex string, deterministic per index for the test. */
    private fun hashHex(index: Int): String = (0 until 32).joinToString("") { hex((index + it) and 0xFF) }

    @Test
    fun restoresContiguousPrefixFromConsistentCheckpointAndResumesFromThatBoundary() {
        // 10-byte file, chunkSize 4 -> chunks: [0]=4, [1]=4, [2]=2, totalChunks=3.
        // Partial file holds the first two whole chunks (8 bytes) = contiguous prefix of 2 chunks.
        val restored = ResumeReceivePlanner.restoreContiguousPrefix(
            fileSize = 10,
            chunkSize = 4,
            totalChunks = 3,
            partialLength = 8,
            receivedChunks = setOf(0, 1),
            receivedChunkSha256HexByIndex = mapOf(0 to hashHex(0), 1 to hashHex(1))
        )

        assertEquals(2, restored.prefixChunks, "the resume start point is the last verified chunk boundary")
        assertEquals(8L, restored.restoredBytes, "restored bytes equal the on-disk partial length")
        assertEquals(setOf(0, 1), restored.chunkHashesByIndex.keys)
        assertArrayEquals(
            (0 until 32).map { ((0 + it) and 0xFF).toByte() }.toByteArray(),
            restored.chunkHashesByIndex[0]
        )
        // The receiver will resume by requesting only [prefixChunks, totalChunks) = {2}.
        val missing = (0 until 3).filter { it !in restored.chunkHashesByIndex.keys }
        assertEquals(listOf(2), missing, "only the missing suffix is re-requested; nothing is re-received")
    }

    @Test
    fun emptyPartialResumesFromZero() {
        val restored = ResumeReceivePlanner.restoreContiguousPrefix(
            fileSize = 10,
            chunkSize = 4,
            totalChunks = 3,
            partialLength = 0,
            receivedChunks = emptySet(),
            receivedChunkSha256HexByIndex = emptyMap()
        )
        assertEquals(0, restored.prefixChunks)
        assertEquals(0L, restored.restoredBytes)
        assertEquals(emptyMap<Int, ByteArray>(), restored.chunkHashesByIndex)
    }

    @Test
    fun rejectsCheckpointMissingAContiguousChunk() {
        // Partial file claims 2 whole chunks on disk, but the checkpoint only recorded chunk 0.
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.restoreContiguousPrefix(
                fileSize = 10,
                chunkSize = 4,
                totalChunks = 3,
                partialLength = 8,
                receivedChunks = setOf(0),
                receivedChunkSha256HexByIndex = mapOf(0 to hashHex(0))
            )
        }
        assertEquals("checkpoint missing contiguous chunk#1", ex.message)
    }

    @Test
    fun rejectsCheckpointWithMissingChunkHash() {
        val ex = assertThrows(IllegalStateException::class.java) {
            ResumeReceivePlanner.restoreContiguousPrefix(
                fileSize = 10,
                chunkSize = 4,
                totalChunks = 3,
                partialLength = 8,
                receivedChunks = setOf(0, 1),
                receivedChunkSha256HexByIndex = mapOf(0 to hashHex(0)) // chunk 1 hash missing
            )
        }
        assertEquals("checkpoint missing chunk hash#1", ex.message)
    }

    @Test
    fun rejectsCheckpointWithInvalidChunkHashLength() {
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.restoreContiguousPrefix(
                fileSize = 10,
                chunkSize = 4,
                totalChunks = 3,
                partialLength = 8,
                receivedChunks = setOf(0, 1),
                receivedChunkSha256HexByIndex = mapOf(0 to hashHex(0), 1 to "abcd") // too short
            )
        }
        assertEquals("checkpoint chunk hash#1 is invalid", ex.message)
    }

    @Test
    fun rejectsPartialLengthNotChunkAligned() {
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.restoreContiguousPrefix(
                fileSize = 10,
                chunkSize = 4,
                totalChunks = 3,
                partialLength = 6, // not a multiple of chunkSize and not the full file size
                receivedChunks = setOf(0, 1),
                receivedChunkSha256HexByIndex = mapOf(0 to hashHex(0), 1 to hashHex(1))
            )
        }
        assertEquals("checkpoint partial length is not chunk-aligned", ex.message)
    }

    @Test
    fun rejectsPartialLengthOutOfRange() {
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.prefixChunksForPartialLength(
                fileSize = 10,
                chunkSize = 4,
                totalChunks = 3,
                partialLength = 12 // exceeds file size
            )
        }
        assertEquals("checkpoint partial length out of range", ex.message)
    }

    @Test
    fun fullPartialLengthMapsToAllChunks() {
        val prefix = ResumeReceivePlanner.prefixChunksForPartialLength(
            fileSize = 10,
            chunkSize = 4,
            totalChunks = 3,
            partialLength = 10
        )
        assertEquals(3, prefix, "a complete partial file maps to all chunks")
    }

    @Test
    fun metadataConsistencyAcceptsMatchingAndNullDimensions() {
        // null stored dimensions are accepted (not yet known)
        ResumeReceivePlanner.validateMetadataConsistency(
            checkpointFileName = null,
            checkpointFileSize = null,
            checkpointChunkSize = null,
            checkpointTotalChunks = null,
            metadataFileName = "f.bin",
            metadataFileSize = 10,
            metadataChunkSize = 4,
            metadataTotalChunks = 3
        )
        // matching stored dimensions are accepted
        ResumeReceivePlanner.validateMetadataConsistency(
            checkpointFileName = "f.bin",
            checkpointFileSize = 10,
            checkpointChunkSize = 4,
            checkpointTotalChunks = 3,
            metadataFileName = "f.bin",
            metadataFileSize = 10,
            metadataChunkSize = 4,
            metadataTotalChunks = 3
        )
    }

    @Test
    fun metadataConsistencyRejectsMismatchedFileSize() {
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.validateMetadataConsistency(
                checkpointFileName = "f.bin",
                checkpointFileSize = 999, // disagrees with metadata
                checkpointChunkSize = 4,
                checkpointTotalChunks = 3,
                metadataFileName = "f.bin",
                metadataFileSize = 10,
                metadataChunkSize = 4,
                metadataTotalChunks = 3
            )
        }
        assertEquals("checkpoint fileSize mismatch", ex.message)
    }

    @Test
    fun metadataConsistencyRejectsMismatchedChunkSize() {
        val ex = assertThrows(IllegalArgumentException::class.java) {
            ResumeReceivePlanner.validateMetadataConsistency(
                checkpointFileName = "f.bin",
                checkpointFileSize = 10,
                checkpointChunkSize = 8, // disagrees
                checkpointTotalChunks = 3,
                metadataFileName = "f.bin",
                metadataFileSize = 10,
                metadataChunkSize = 4,
                metadataTotalChunks = 3
            )
        }
        assertEquals("checkpoint chunkSize mismatch", ex.message)
    }
}
