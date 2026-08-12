package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Exhaustive unit tests for the pure integrity decision (Requirements 5.2, 5.3).
 *
 * The invariant under test: a received file is declared deliverable ([Outcome.Pass]) ONLY when
 * every enforced integrity check passes; every other combination MUST be [Outcome.Fail] so the
 * caller refuses delivery and cleans up (no residue, no corrupted delivery). Because the decision
 * is pure, we can cover every failure branch — including ones that are hard to reach through the
 * live transport (e.g. missing chunk hashes for the Merkle proof).
 */
class ReceiveIntegrityDecisionTest {

    private val fileHash = ByteArray(32) { 1 }
    private val merkleRoot = ByteArray(32) { 2 }

    private fun pass() = ReceiveIntegrityDecision.evaluate(
        expectedSize = 100,
        actualSize = 100,
        expectedFileSha256 = fileHash,
        actualFileSha256 = fileHash.copyOf(),
        expectedMerkleRoot = null,
        actualMerkleRoot = null,
        merkleChunkHashesMissing = false,
        merkleSigProvided = false,
        merkleSigAlgRecognized = false,
        merkleSigValid = false
    )

    @Test
    fun allChecksPass_withoutMerkle_isPass() {
        assertEquals(ReceiveIntegrityDecision.Outcome.Pass, pass())
    }

    @Test
    fun allChecksPass_withMerkleAndValidSignature_isPass() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = merkleRoot.copyOf(),
            merkleChunkHashesMissing = false,
            merkleSigProvided = true,
            merkleSigAlgRecognized = true,
            merkleSigValid = true
        )
        assertEquals(ReceiveIntegrityDecision.Outcome.Pass, outcome)
    }

    @Test
    fun allChecksPass_withMerkleAndNoSignature_isPass() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = merkleRoot.copyOf(),
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertEquals(ReceiveIntegrityDecision.Outcome.Pass, outcome)
    }

    @Test
    fun sizeMismatch_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 99,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = null,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "size mismatch")
    }

    @Test
    fun missingExpectedFileSha256_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = null,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = null,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "missing file sha256")
    }

    @Test
    fun uncomputableActualFileSha256_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = null,
            expectedMerkleRoot = null,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "file sha256 unavailable")
    }

    @Test
    fun fileSha256Mismatch_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = ByteArray(32) { 9 },
            expectedMerkleRoot = null,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "file sha256 mismatch")
    }

    @Test
    fun merkleEnforcedButChunkHashesMissing_isFail() {
        // This is the branch that previously leaked the partial file: even though the file-level
        // hash matched, the Merkle proof could not be reconstructed, so delivery MUST be refused.
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = true,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "missing chunk hashes for merkle")
    }

    @Test
    fun merkleEnforcedButRootUncomputable_isFailAsRootMismatch() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "merkle root mismatch")
    }

    @Test
    fun merkleRootMismatch_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = ByteArray(32) { 7 },
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "merkle root mismatch")
    }

    @Test
    fun unknownMerkleSignatureAlg_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = merkleRoot.copyOf(),
            merkleChunkHashesMissing = false,
            merkleSigProvided = true,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "unknown merkle sig alg")
    }

    @Test
    fun merkleSignatureInvalid_isFail() {
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 100,
            expectedFileSha256 = fileHash,
            actualFileSha256 = fileHash.copyOf(),
            expectedMerkleRoot = merkleRoot,
            actualMerkleRoot = merkleRoot.copyOf(),
            merkleChunkHashesMissing = false,
            merkleSigProvided = true,
            merkleSigAlgRecognized = true,
            merkleSigValid = false
        )
        assertFail(outcome, "merkle signature mismatch")
    }

    @Test
    fun sizeCheckedBeforeHash() {
        // A size mismatch must be reported even if the hash is also wrong (ordering guarantee):
        // the earliest failing check wins, so a later check never sees partially-validated state.
        val outcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = 100,
            actualSize = 50,
            expectedFileSha256 = fileHash,
            actualFileSha256 = ByteArray(32) { 9 },
            expectedMerkleRoot = null,
            actualMerkleRoot = null,
            merkleChunkHashesMissing = false,
            merkleSigProvided = false,
            merkleSigAlgRecognized = false,
            merkleSigValid = false
        )
        assertFail(outcome, "size mismatch")
    }

    private fun assertFail(outcome: ReceiveIntegrityDecision.Outcome, expectedPeerMessage: String) {
        assertTrue(outcome is ReceiveIntegrityDecision.Outcome.Fail, "expected Fail, got $outcome")
        outcome as ReceiveIntegrityDecision.Outcome.Fail
        assertEquals(expectedPeerMessage, outcome.peerMessage)
        assertTrue(
            outcome.status.contains(expectedPeerMessage),
            "status '${outcome.status}' should mention '$expectedPeerMessage'"
        )
    }
}
