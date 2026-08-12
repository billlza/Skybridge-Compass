package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.UUID

/**
 * Tests for SEND-side resume from a persisted checkpoint (task 11.3 / Requirement 5.6, 5.7).
 *
 * Resume must continue from the last acked chunk boundary: already-confirmed chunks are NOT
 * retransmitted, only the remaining suffix is sent, and a registered send context still allows a
 * peer NACK to trigger a targeted resend after resume. None of this changes the wire protocol.
 */
class WebRtcFileTransferControllerResumeSendTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun resumeSend_skipsAckedChunksAndOnlySendsRemainder() = runTest {
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)

        val transferId = UUID.randomUUID().toString()
        // 16 bytes, chunkSize 4 -> 4 chunks (indices 0..3), all full-size.
        val payload = "0123456789abcdef".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "resume.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4
        ).copy(ackedChunks = intArrayOf(0, 1)) // chunks 0 and 1 already confirmed by the peer

        controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) }
        )

        // The resume pass re-sends metadata and complete, but ONLY the un-acked chunks (2, 3).
        val chunkIndices = transport.messages
            .filter { it.op == CrossNetworkFileTransferOp.chunk }
            .mapNotNull { it.chunkIndex }
            .toSet()
        assertEquals(setOf(2, 3), chunkIndices, "resume must skip already-acked chunks 0,1 and send only 2,3")

        assertTrue(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.metadata && it.transferId == transferId },
            "resume must (re)send metadata"
        )
        assertTrue(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.complete && it.transferId == transferId },
            "resume must send complete"
        )
    }

    @Test
    fun resumeSend_registersSendContextSoPeerNackResendsOnlyTheMissingChunk() = runTest {
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)

        val transferId = UUID.randomUUID().toString()
        val payload = "0123456789abcdef".encodeToByteArray() // 4 chunks of 4 bytes
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "resume.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4
        ).copy(ackedChunks = intArrayOf(0, 1, 2, 3)) // everything acked: initial pass sends no chunks

        controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) }
        )

        // Initial resume pass sends no chunks (all acked), only metadata + complete.
        assertTrue(
            transport.messages.none { it.op == CrossNetworkFileTransferOp.chunk },
            "fully-acked resume must not retransmit any chunk on the initial pass"
        )

        transport.clear()

        // Peer NACKs chunk 2. Because resume registered a send context (with the buffered chunk),
        // the NACK must trigger a targeted resend of exactly chunk 2.
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    missingChunks = intArrayOf(2),
                    message = "missingChunks"
                )
            )
        )
        yield()

        val resent = transport.messages.filter { it.op == CrossNetworkFileTransferOp.chunk }
        assertEquals(1, resent.size, "exactly one chunk should be resent for a single-chunk NACK")
        assertEquals(2, resent.single().chunkIndex, "the resent chunk must be the NACKed chunk 2")
        assertFalse(
            resent.any { it.chunkIndex == 0 || it.chunkIndex == 1 },
            "a targeted NACK must not resend other already-acked chunks"
        )
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private inner class RecordingTransport : TestCrossNetworkWebRtcTransportAdapter() {
        override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("test-session"))
        override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
        override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
            MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
        override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> =
            MutableStateFlow(null)

        override var onData: ((ByteArray) -> Unit)? = null
        override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()

        fun clear() = messages.clear()

        override fun hasSessionKeys(): Boolean = true
        override fun authenticatedPeerDeviceId(): String = "trusted-peer"
        override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
        override fun negotiatedSuiteWireId(): Int = 0x0011
        override fun hasPqcSessionKeys(): Boolean = true
        override fun hasQPeriaptSessionKeys(): Boolean = true
        override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray = sha256(preimage)
        override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
            mac.contentEquals(sha256(preimage))
        override fun setLocalDeviceId(id: String) = Unit
        override fun setPqcEnabled(enabled: Boolean) = Unit
        override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) = Unit
        override suspend fun generateConnectionCode(): String = "test-session"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit

        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                messages += json.decodeFromString(
                    CrossNetworkFileTransferMessage.serializer(),
                    bytes.decodeToString()
                )
            }
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }
}
