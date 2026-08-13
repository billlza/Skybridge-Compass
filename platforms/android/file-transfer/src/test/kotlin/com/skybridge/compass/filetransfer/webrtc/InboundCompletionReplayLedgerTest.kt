package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class InboundCompletionReplayLedgerTest {
    @Test
    fun completedWitnessReplaysExactRequestAndRejectsConflict() {
        val owner = owner()
        val ledger = InboundCompletionReplayLedger()
        val transferId = UUID.randomUUID().toString()
        val fingerprint = fingerprint(transferId)
        val acknowledgement = acknowledgement(fingerprint)

        ledger.rotateTo(owner)
        assertEquals(
            InboundCompletionReplayLedger.Reservation.RESERVED,
            ledger.reserve(owner, transferId),
        )
        assertEquals(
            InboundCompletionReplayLedger.CompletionLookup.Active,
            ledger.bindOrLookup(owner, fingerprint),
        )
        val prepared = ledger.prepareCompletion(owner, fingerprint, acknowledgement)
        assertTrue(ledger.commitPrepared(prepared))

        val replay = ledger.bindOrLookup(owner, fingerprint)
            as InboundCompletionReplayLedger.CompletionLookup.Replay
        assertArrayEquals(acknowledgement.fileSha256, replay.acknowledgement.fileSha256)
        assertEquals(
            InboundCompletionReplayLedger.CompletionLookup.Conflict,
            ledger.bindOrLookup(
                owner,
                fingerprint(transferId, fileSha256 = ByteArray(32) { 7 }),
            ),
        )
        assertEquals(
            InboundCompletionReplayLedger.Reservation.ALREADY_USED,
            ledger.reserve(owner, transferId),
        )
    }

    @Test
    fun fingerprintOwnsDefensiveCopiesOfEveryByteArray() {
        val hash = ByteArray(32) { 1 }
        val root = ByteArray(32) { 2 }
        val signature = ByteArray(32) { 3 }
        val fingerprint = InboundCompletionFingerprint(
            version = 1,
            transferId = UUID.randomUUID().toString(),
            receivedBytes = 8,
            fileSha256 = hash,
            merkleRoot = root,
            merkleRootSignature = signature,
            merkleRootSignatureAlgorithm = "hmac-sha256-session-v1",
        )
        val equal = InboundCompletionFingerprint(
            version = fingerprint.version,
            transferId = fingerprint.transferId,
            receivedBytes = fingerprint.receivedBytes,
            fileSha256 = hash.copyOf(),
            merkleRoot = root.copyOf(),
            merkleRootSignature = signature.copyOf(),
            merkleRootSignatureAlgorithm = fingerprint.merkleRootSignatureAlgorithm,
        )

        hash.fill(9)
        root.fill(9)
        signature.fill(9)

        assertEquals(equal, fingerprint)
        assertEquals(equal.hashCode(), fingerprint.hashCode())
        val returned = fingerprint.fileSha256()
        returned.fill(8)
        assertNotEquals(returned.toList(), fingerprint.fileSha256().toList())
    }

    @Test
    fun capacityIsFailClosedAndTombstonesAreNotEvicted() {
        val owner = owner()
        val ledger = InboundCompletionReplayLedger(capacity = 2)
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val third = UUID.randomUUID().toString()

        ledger.rotateTo(owner)
        assertEquals(InboundCompletionReplayLedger.Reservation.RESERVED, ledger.reserve(owner, first))
        ledger.tombstoneActive(owner, first)
        assertEquals(InboundCompletionReplayLedger.Reservation.RESERVED, ledger.reserve(owner, second))
        assertEquals(
            InboundCompletionReplayLedger.Reservation.CAPACITY_EXCEEDED,
            ledger.reserve(owner, third),
        )
        assertEquals(InboundCompletionReplayLedger.Reservation.ALREADY_USED, ledger.reserve(owner, first))
        assertEquals(2, ledger.size)
    }

    @Test
    fun completedPayloadExpiresToTombstoneAndOwnerRotationClearsNamespace() {
        var now = 100L
        val ownerA = owner()
        val ownerB = owner()
        val ledger = InboundCompletionReplayLedger(
            capacity = 2,
            completedPayloadTtlMs = 50L,
            clockMs = { now },
        )
        val transferId = UUID.randomUUID().toString()
        val fingerprint = fingerprint(transferId)

        ledger.rotateTo(ownerA)
        assertEquals(InboundCompletionReplayLedger.Reservation.RESERVED, ledger.reserve(ownerA, transferId))
        assertEquals(InboundCompletionReplayLedger.CompletionLookup.Active, ledger.bindOrLookup(ownerA, fingerprint))
        assertTrue(
            ledger.commitPrepared(
                ledger.prepareCompletion(ownerA, fingerprint, acknowledgement(fingerprint)),
            ),
        )

        now += 50L
        assertEquals(
            InboundCompletionReplayLedger.CompletionLookup.Tombstone,
            ledger.bindOrLookup(ownerA, fingerprint),
        )
        ledger.rotateTo(ownerB)
        assertEquals(0, ledger.size)
        assertEquals(InboundCompletionReplayLedger.Reservation.RESERVED, ledger.reserve(ownerB, transferId))
    }

    @Test
    fun preparedFinalizerCannotBeTombstonedAndOnlyItsTokenCanAbort() {
        val owner = owner()
        val ledger = InboundCompletionReplayLedger()
        val transferId = UUID.randomUUID().toString()
        val fingerprint = fingerprint(transferId)
        ledger.rotateTo(owner)
        assertEquals(InboundCompletionReplayLedger.Reservation.RESERVED, ledger.reserve(owner, transferId))
        assertEquals(InboundCompletionReplayLedger.CompletionLookup.Active, ledger.bindOrLookup(owner, fingerprint))
        val prepared = ledger.prepareCompletion(owner, fingerprint, acknowledgement(fingerprint))

        ledger.tombstoneActive(owner, transferId)
        assertEquals(
            InboundCompletionReplayLedger.CompletionLookup.Active,
            ledger.bindOrLookup(owner, fingerprint),
            "a concurrent terminal observer cannot destroy a claimed finalizer's witness slot",
        )
        assertEquals(
            InboundCompletionReplayLedger.PreparedAbortResult.ABORTED,
            ledger.abortPrepared(prepared),
        )
        assertEquals(
            InboundCompletionReplayLedger.CompletionLookup.Tombstone,
            ledger.bindOrLookup(owner, fingerprint),
        )
        assertEquals(false, ledger.commitPrepared(prepared))
    }

    private fun fingerprint(
        transferId: String,
        fileSha256: ByteArray = ByteArray(32) { 1 },
    ) = InboundCompletionFingerprint(
        version = 1,
        transferId = transferId,
        receivedBytes = 8,
        fileSha256 = fileSha256,
        merkleRoot = ByteArray(32) { 2 },
        merkleRootSignature = ByteArray(32) { 3 },
        merkleRootSignatureAlgorithm = "hmac-sha256-session-v1",
    )

    private fun acknowledgement(fingerprint: InboundCompletionFingerprint) =
        CrossNetworkFileTransferMessage(
            version = fingerprint.version,
            op = CrossNetworkFileTransferOp.completeAck,
            transferId = fingerprint.transferId,
            receivedBytes = fingerprint.receivedBytes,
            fileSha256 = fingerprint.fileSha256(),
        )

    private fun owner(): WebRtcSecureOperationOwner = object : WebRtcSecureOperationOwner {}
}
