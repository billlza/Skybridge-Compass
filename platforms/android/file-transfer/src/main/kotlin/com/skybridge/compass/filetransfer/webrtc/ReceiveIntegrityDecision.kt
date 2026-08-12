package com.skybridge.compass.filetransfer.webrtc

/**
 * Pure, side-effect-free integrity decision for an inbound file transfer at finalize time
 * (Requirements 5.2, 5.3).
 *
 * This captures the single invariant behind "verify-before-deliver, zero-residue-on-failure":
 * given the expected verification material (declared by the sender) and the actual material
 * computed from the received bytes, [evaluate] returns whether the received bytes MAY be
 * delivered/committed.
 *
 * The caller MUST honor the contract:
 *  - On [Outcome.Pass]: the received bytes are intact and may be emitted / committed to Downloads.
 *  - On [Outcome.Fail]: the caller MUST NOT emit the received file and MUST NOT commit it to
 *    Downloads; it MUST delete the temporary partial file and any persisted checkpoint so no
 *    residue and no corrupted file is left behind.
 *
 * Keeping the decision pure (no IO, no crypto, no coroutines) means the ordering of checks and the
 * "no delivery on any failure branch" property can be exhaustively unit-tested without a live
 * transport, filesystem, or Android context. All crypto/IO (hashing the partial file, computing the
 * Merkle root, verifying the session MAC) is performed by the caller and passed in as already
 * computed values; a value that could not be computed is passed as `null` and mapped to the
 * corresponding failure here.
 *
 * The check order mirrors Requirement 5.2 (per-file size, whole-file SHA-256, Merkle root, then the
 * optional session signature) and must not be reordered — earlier, cheaper/stronger checks fail
 * first so a later check never observes partially-validated state.
 */
internal object ReceiveIntegrityDecision {

    sealed interface Outcome {
        /** Every integrity check passed; the received bytes are safe to deliver/commit. */
        data object Pass : Outcome

        /**
         * At least one integrity check failed. [status] is the user-facing progress status and
         * [peerMessage] is the `op=error` message sent to the peer. The caller must clean up and
         * must not deliver.
         */
        data class Fail(val status: String, val peerMessage: String) : Outcome
    }

    /**
     * @param expectedSize sender-declared total file size (from validated metadata).
     * @param actualSize bytes actually received (partial file length or in-memory buffer size).
     * @param expectedFileSha256 sender-declared whole-file SHA-256 (required; `null` => missing).
     * @param actualFileSha256 SHA-256 computed over the received bytes; `null` => could not be
     *   computed (e.g. hashing threw). Only meaningful once size matches.
     * @param expectedMerkleRoot sender-declared Merkle root; `null` => Merkle not enforced.
     * @param actualMerkleRoot Merkle root computed from the received chunk hashes; `null` => could
     *   not be reconstructed from the received chunks. Only consulted when [expectedMerkleRoot] is
     *   non-null; treated as a root mismatch (cannot prove integrity => refuse delivery).
     * @param merkleChunkHashesMissing true when Merkle was enforced but at least one chunk hash
     *   needed to recompute the root is missing (distinct from a compute failure).
     * @param merkleSigProvided whether the sender attached a Merkle-root signature.
     * @param merkleSigAlgRecognized whether the signature algorithm is the supported one.
     * @param merkleSigValid whether the signature verified against the session key.
     */
    fun evaluate(
        expectedSize: Long,
        actualSize: Long,
        expectedFileSha256: ByteArray?,
        actualFileSha256: ByteArray?,
        expectedMerkleRoot: ByteArray?,
        actualMerkleRoot: ByteArray?,
        merkleChunkHashesMissing: Boolean,
        merkleSigProvided: Boolean,
        merkleSigAlgRecognized: Boolean,
        merkleSigValid: Boolean
    ): Outcome {
        // 1) Whole-file size must match exactly.
        if (expectedSize != actualSize) {
            return Outcome.Fail("received complete (size mismatch)", "size mismatch")
        }

        // 2) Whole-file SHA-256 must be present and match.
        if (expectedFileSha256 == null) {
            return Outcome.Fail("received complete (missing file sha256)", "missing file sha256")
        }
        if (actualFileSha256 == null) {
            return Outcome.Fail("received complete (file sha256 unavailable)", "file sha256 unavailable")
        }
        if (!actualFileSha256.contentEquals(expectedFileSha256)) {
            return Outcome.Fail("received complete (file sha256 mismatch)", "file sha256 mismatch")
        }

        // 3) Merkle root (enforced only when the sender provided one).
        if (expectedMerkleRoot != null) {
            if (merkleChunkHashesMissing) {
                return Outcome.Fail(
                    "received complete (missing chunk hashes for merkle)",
                    "missing chunk hashes for merkle"
                )
            }
            if (actualMerkleRoot == null || !actualMerkleRoot.contentEquals(expectedMerkleRoot)) {
                return Outcome.Fail("received complete (merkle root mismatch)", "merkle root mismatch")
            }

            // 4) Optional session signature over the Merkle root.
            if (merkleSigProvided) {
                if (!merkleSigAlgRecognized) {
                    return Outcome.Fail("received complete (unknown merkle sig alg)", "unknown merkle sig alg")
                }
                if (!merkleSigValid) {
                    return Outcome.Fail("received complete (merkle signature mismatch)", "merkle signature mismatch")
                }
            }
        }

        return Outcome.Pass
    }
}
