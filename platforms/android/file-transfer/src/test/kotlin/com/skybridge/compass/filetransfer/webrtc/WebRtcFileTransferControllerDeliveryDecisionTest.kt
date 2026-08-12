package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.UUID

/**
 * End-to-end delivery-decision tests for the sender (Requirements 5.1, 5.10):
 *  - chunks are sent in ascending index order;
 *  - overall delivery is declared ONLY on the receiver's `completeAck`, which the receiver emits
 *    solely after its integrity checks pass;
 *  - a chunk whose integrity fails at the receiver yields an `error`, never a `completeAck`, so the
 *    sender never treats the transfer as delivered.
 */
class WebRtcFileTransferControllerDeliveryDecisionTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun chunksAreSentInAscendingIndexOrder() = runTest {
        val transport = RecordingTransport() // no peer: capture the sender's outbound stream only
        val sender = WebRtcFileTransferController(transport, json = json)

        val payload = ByteArray(50) { it.toByte() }
        sender.sendBytesAsFile(
            transferId = UUID.randomUUID().toString(),
            fileName = "ordered.bin",
            mimeType = "application/octet-stream",
            bytes = payload,
            chunkSize = 8
        )

        val chunkIndices = transport.messages
            .filter { it.op == CrossNetworkFileTransferOp.chunk }
            .map { it.chunkIndex }

        val expectedChunkCount = (payload.size + 7) / 8
        assertEquals(List(expectedChunkCount) { it }, chunkIndices)
        // Ordering across the whole stream: metadata precedes every chunk, chunks precede complete.
        val ops = transport.ops
        assertEquals(CrossNetworkFileTransferOp.metadata, ops.first())
        assertEquals(CrossNetworkFileTransferOp.complete, ops.last())
    }

    @Test
    fun overallDeliveryDeclaredOnlyOnIntegrityGatedCompleteAck() = runTest {
        val senderTransport = RecordingTransport()
        val receiverTransport = RecordingTransport()
        senderTransport.peer = receiverTransport
        receiverTransport.peer = senderTransport

        val sender = WebRtcFileTransferController(senderTransport, json = json)
        val receiver = WebRtcFileTransferController(
            receiverTransport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider()
        )
        senderTransport.onData = { bytes -> sender.handleIncoming(bytes) }
        receiverTransport.onData = { bytes -> receiver.handleIncoming(bytes) }

        val payload = "delivery decision proof".encodeToByteArray()
        sender.sendBytesAsFile(
            transferId = UUID.randomUUID().toString(),
            fileName = "proof.txt",
            mimeType = "text/plain",
            bytes = payload,
            chunkSize = 8
        )

        withTimeout(2_000) {
            while (senderTransport.messages.none { it.op == CrossNetworkFileTransferOp.chunk }) yield()
            while (receiverTransport.messages.none { it.op == CrossNetworkFileTransferOp.completeAck }) yield()
        }

        // The receiver only emits completeAck AFTER integrity (size + sha256 + merkle) passes, and
        // it must come after every chunkAck (i.e., after all chunks were delivered).
        val receiverOps = receiverTransport.ops
        val lastChunkAckIdx = receiverOps.indexOfLast { it == CrossNetworkFileTransferOp.chunkAck }
        val completeAckIdx = receiverOps.indexOf(CrossNetworkFileTransferOp.completeAck)
        assertTrue(completeAckIdx > lastChunkAckIdx, "completeAck must follow all chunkAcks")

        // On completeAck the sender declares delivery (drops its send context) — no error was sent.
        assertFalse(senderTransport.messages.any { it.op == CrossNetworkFileTransferOp.error })
        assertTrue(receiverTransport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck })
    }

    @Test
    fun corruptChunkFailsIntegrity_soNoCompleteAckAndNoDelivery() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider()
        )
        val transferId = UUID.randomUUID().toString()
        val wholeFile = "abcdef".encodeToByteArray()
        val chunk0 = "abc".encodeToByteArray()
        val chunk1 = "def".encodeToByteArray()
        val tamperedChunk1 = "dez".encodeToByteArray() // wrong bytes -> file sha256 mismatch

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "corrupt.txt",
                    fileSize = wholeFile.size.toLong(),
                    chunkSize = 3,
                    totalChunks = 2,
                    mimeType = "text/plain"
                )
            )
        )
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 0,
                    chunkData = chunk0,
                    chunkSha256 = sha256(chunk0),
                    rawSize = chunk0.size
                )
            )
        )
        // Deliver a tampered chunk 1 whose bytes don't match the file the sender will attest to.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 1,
                    chunkData = tamperedChunk1,
                    chunkSha256 = sha256(tamperedChunk1),
                    rawSize = tamperedChunk1.size
                )
            )
        )
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    // Attest to the ORIGINAL (correct) file hash; received bytes won't match.
                    fileSha256 = sha256(chunk0 + chunk1)
                )
            )
        )

        withTimeout(2_000) {
            while (transport.messages.none { it.op == CrossNetworkFileTransferOp.error }) yield()
        }

        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "integrity failure must NOT produce a completeAck (no delivery)"
        )
        val error = transport.messages.last { it.op == CrossNetworkFileTransferOp.error }
        assertTrue(error.message?.contains("sha256 mismatch") == true)
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun acceptingApprovalProvider(): InboundFileTransferApprovalProvider =
        InboundFileTransferApprovalProvider { request ->
            InboundFileTransferDecision.Accept(
                downloadsDisplayName = request.fileName ?: "accepted-${request.transferId}",
                overwriteExisting = false
            )
        }

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
        var peer: RecordingTransport? = null
        val ops = mutableListOf<CrossNetworkFileTransferOp>()
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()

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
                val message = json.decodeFromString(
                    CrossNetworkFileTransferMessage.serializer(),
                    bytes.decodeToString()
                )
                messages += message
                ops += message.op
            }
            peer?.onData?.invoke(bytes)
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }
}
