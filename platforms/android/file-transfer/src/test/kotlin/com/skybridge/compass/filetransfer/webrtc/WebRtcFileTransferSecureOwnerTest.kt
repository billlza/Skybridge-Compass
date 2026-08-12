package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.UUID

class WebRtcFileTransferSecureOwnerTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun sameSessionIdReplacement_oldAckAndCancelCannotMutateOrSendThroughReplacement() = runTest {
        val transport = RotatingTransport(json)
        val controller = WebRtcFileTransferController(transport, json = json)
        val transferA = UUID.randomUUID().toString()

        controller.sendBytesAsFile(
            transferId = transferA,
            fileName = "a.txt",
            bytes = "alpha".encodeToByteArray(),
            chunkSize = 5,
        )
        val ownerA = transport.currentTestSecureOwner()
        val sendsBeforeReplacement = transport.messages.size

        val ownerB = transport.replaceTestSecureOwner()
        assertFalse(ownerA === ownerB)

        controller.handleIncoming(ownerA, message(CrossNetworkFileTransferOp.completeAck, transferA))
        controller.handleIncoming(
            ownerA,
            message(
                op = CrossNetworkFileTransferOp.chunkAck,
                transferId = transferA,
                missingChunks = intArrayOf(0),
            ),
        )
        controller.cancel(transferA)

        assertEquals(sendsBeforeReplacement, transport.messages.size)
        assertTrue(controller.progress.value.lastStatus?.contains("secure session replaced or rekeyed") == true)

        val transferB = UUID.randomUUID().toString()
        controller.sendBytesAsFile(
            transferId = transferB,
            fileName = "b.txt",
            bytes = "bravo".encodeToByteArray(),
            chunkSize = 5,
        )
        controller.handleIncoming(
            ownerB,
            message(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = transferB,
                receivedBytes = 5,
            ),
        )

        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
        assertEquals(transferB, controller.progress.value.transferId)
    }

    @Test
    fun sameSessionRekey_staleTimeoutSweepCannotStopOrResendCurrentOwnerTransfer() = runTest {
        var nowMs = 0L
        val transport = RotatingTransport(json)
        val controller = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            idleInterruptTimeoutMs = 10,
            idleWatchdogPollMs = 1_000,
            clockMs = { nowMs },
        )

        val transferA = UUID.randomUUID().toString()
        controller.sendBytesAsFile(
            transferId = transferA,
            fileName = "old.txt",
            bytes = "old!!".encodeToByteArray(),
            chunkSize = 5,
        )
        val ownerA = transport.currentTestSecureOwner()

        nowMs = 5
        val ownerB = transport.replaceTestSecureOwner()
        val retainedCheckpoint = controller.listPendingCheckpoints().single {
            it.transferId == transferA
        }
        val sendsBeforeCrossOwnerResume = transport.messages.size
        val crossOwnerResume = runCatching {
            controller.resumeSendFromCheckpoint(
                checkpoint = retainedCheckpoint,
                owner = ownerB,
                mimeType = "text/plain",
                openStream = { ByteArrayInputStream("old!!".encodeToByteArray()) },
            )
        }
        assertTrue(crossOwnerResume.exceptionOrNull() is StaleWebRtcFileTransferOwnerException)
        assertEquals(sendsBeforeCrossOwnerResume, transport.messages.size)

        val transferB = UUID.randomUUID().toString()
        controller.sendBytesAsFile(
            transferId = transferB,
            fileName = "current.txt",
            bytes = "new!!".encodeToByteArray(),
            chunkSize = 5,
        )

        val sendsBeforeSweep = transport.messages.size
        controller.runIdleInterruptSweep(nowMs = 6)
        controller.handleIncoming(ownerA, message(CrossNetworkFileTransferOp.cancel, transferA))
        controller.handleIncoming(
            ownerB,
            message(
                op = CrossNetworkFileTransferOp.chunkAck,
                transferId = transferB,
                missingChunks = intArrayOf(0),
            ),
        )

        assertEquals(sendsBeforeSweep + 2, transport.messages.size)
        assertEquals(
            listOf(CrossNetworkFileTransferOp.chunk, CrossNetworkFileTransferOp.complete),
            transport.messages.takeLast(2).map { it.op },
        )
        assertTrue(controller.isCurrentOperation(transferB))

        controller.handleIncoming(
            ownerB,
            message(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = transferB,
                receivedBytes = 5,
            ),
        )
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun staleInboundApprovalContinuationCannotCommitAfterRekey_butCurrentOwnerCanComplete() = runTest {
        val approval = CompletableDeferred<InboundFileTransferDecision>()
        val transport = RotatingTransport(json)
        val controller = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = InboundFileTransferApprovalProvider { approval.await() },
        )
        val ownerA = transport.currentTestSecureOwner()
        val transferA = UUID.randomUUID().toString()
        val payloadA = "owner-a".encodeToByteArray()

        controller.handleIncoming(ownerA, metadata(transferA, "a.txt", payloadA))
        controller.handleIncoming(ownerA, chunk(transferA, payloadA))
        controller.handleIncoming(ownerA, complete(transferA, payloadA))

        val ownerB = transport.replaceTestSecureOwner()
        approval.complete(
            InboundFileTransferDecision.Accept(
                downloadsDisplayName = "accepted.txt",
                overwriteExisting = false,
            ),
        )

        val transferB = UUID.randomUUID().toString()
        val payloadB = "owner-b".encodeToByteArray()
        val received = async { controller.receivedFiles.first() }
        yield()
        controller.handleIncoming(ownerB, metadata(transferB, "b.txt", payloadB))
        controller.handleIncoming(ownerB, chunk(transferB, payloadB))
        controller.handleIncoming(ownerB, complete(transferB, payloadB))

        val file = withTimeout(2_000) { received.await() }
        assertEquals(transferB, file.transferId)
        assertFalse(
            transport.messages.any {
                it.transferId == transferA && it.op == CrossNetworkFileTransferOp.completeAck
            },
        )
        assertTrue(
            transport.messages.any {
                it.transferId == transferB && it.op == CrossNetworkFileTransferOp.completeAck
            },
        )
    }

    private fun message(
        op: CrossNetworkFileTransferOp,
        transferId: String,
        missingChunks: IntArray? = null,
        receivedBytes: Long? = null,
    ): ByteArray = json.encodeToString(
        CrossNetworkFileTransferMessage.serializer(),
        CrossNetworkFileTransferMessage(
            op = op,
            transferId = transferId,
            missingChunks = missingChunks,
            receivedBytes = receivedBytes,
        ),
    ).encodeToByteArray()

    private fun metadata(transferId: String, fileName: String, bytes: ByteArray): ByteArray =
        json.encodeToString(
            CrossNetworkFileTransferMessage.serializer(),
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                fileName = fileName,
                fileSize = bytes.size.toLong(),
                chunkSize = bytes.size,
                totalChunks = 1,
                mimeType = "text/plain",
            ),
        ).encodeToByteArray()

    private fun chunk(transferId: String, bytes: ByteArray): ByteArray = json.encodeToString(
        CrossNetworkFileTransferMessage.serializer(),
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.chunk,
            transferId = transferId,
            chunkIndex = 0,
            chunkData = bytes,
            chunkSha256 = MessageDigest.getInstance("SHA-256").digest(bytes),
            rawSize = bytes.size,
        ),
    ).encodeToByteArray()

    private fun complete(transferId: String, bytes: ByteArray): ByteArray = json.encodeToString(
        CrossNetworkFileTransferMessage.serializer(),
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.complete,
            transferId = transferId,
            receivedBytes = bytes.size.toLong(),
            fileSha256 = MessageDigest.getInstance("SHA-256").digest(bytes),
        ),
    ).encodeToByteArray()

    private class RotatingTransport(
        private val json: Json,
    ) : TestCrossNetworkWebRtcTransportAdapter() {
        override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("same-session-id"))
        override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
        override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
            MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
        override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> = MutableStateFlow(null)

        override var onData: ((ByteArray) -> Unit)? = null
        override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null

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
        override suspend fun generateConnectionCode(): String = "same-session-id"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit

        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                messages += json.decodeFromString(
                    CrossNetworkFileTransferMessage.serializer(),
                    bytes.decodeToString(),
                )
            }
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit

        private fun sha256(bytes: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(bytes)
    }
}
