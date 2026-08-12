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
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertDoesNotThrow
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class WebRtcFileTransferControllerSendFailureTest {

    @Test
    fun sendBytesAsFile_failsWhenTransportRejectsMetadataSend() {
        val controller = WebRtcFileTransferController(FailingTransport())

        val error = assertThrows(IllegalStateException::class.java) {
            runTest {
                controller.sendBytesAsFile(
                    transferId = UUID.randomUUID().toString(),
                    fileName = "hello.txt",
                    mimeType = "text/plain",
                    bytes = "hello".encodeToByteArray(),
                    chunkSize = 5
                )
            }
        }

        assertTrue(error.message?.contains("file transfer send failed") == true)
        assertTrue(controller.progress.value.lastStatus != "sent complete")
    }

    @Test
    fun missingChunkResendFailure_marksSendFailedInsteadOfThrowingFromInboundAck() = runTest {
        val transferId = UUID.randomUUID().toString()
        val transport = FailAfterInitialTransferTransport(initialSuccessfulSends = 3)
        val controller = WebRtcFileTransferController(transport)

        controller.sendBytesAsFile(
            transferId = transferId,
            fileName = "hello.txt",
            mimeType = "text/plain",
            bytes = "hello".encodeToByteArray(),
            chunkSize = 5
        )

        assertDoesNotThrow {
            controller.handleIncoming(
                Json.encodeToString(
                    CrossNetworkFileTransferMessage.serializer(),
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.chunkAck,
                        transferId = transferId,
                        missingChunks = intArrayOf(0),
                        message = "missingChunks"
                    )
                ).encodeToByteArray()
            )
        }

        assertEquals(4, transport.sendAttempts)
        assertTrue(controller.progress.value.lastStatus?.contains("send failed") == true)
    }

    @Test
    fun peerError_clearsOutboundTransferSoLaterMissingChunkAckDoesNotResend() = runTest {
        val transferId = UUID.randomUUID().toString()
        val transport = FailAfterInitialTransferTransport(initialSuccessfulSends = Int.MAX_VALUE)
        val controller = WebRtcFileTransferController(transport)

        controller.sendBytesAsFile(
            transferId = transferId,
            fileName = "hello.txt",
            mimeType = "text/plain",
            bytes = "hello".encodeToByteArray(),
            chunkSize = 5
        )
        assertEquals(3, transport.sendAttempts)

        controller.handleIncoming(
            Json.encodeToString(
                CrossNetworkFileTransferMessage.serializer(),
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.error,
                    transferId = transferId,
                    message = "remote_desktop_file_transfer_disabled_by_settings"
                )
            ).encodeToByteArray()
        )
        controller.handleIncoming(
            Json.encodeToString(
                CrossNetworkFileTransferMessage.serializer(),
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    missingChunks = intArrayOf(0),
                    message = "missingChunks"
                )
            ).encodeToByteArray()
        )

        assertEquals(3, transport.sendAttempts)
        assertEquals(transferId, controller.progress.value.transferId)
        assertTrue(controller.progress.value.lastStatus?.contains("peer error") == true)
    }

    private class FailingTransport : TestCrossNetworkWebRtcTransportAdapter() {
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

        override fun hasSessionKeys(): Boolean = true
        override fun authenticatedPeerDeviceId(): String = "trusted-peer"
        override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
        override fun negotiatedSuiteWireId(): Int = 0x0011
        override fun hasPqcSessionKeys(): Boolean = true
        override fun hasQPeriaptSessionKeys(): Boolean = true
        override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? = ByteArray(32)
        override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean = true
        override fun setLocalDeviceId(id: String) = Unit
        override fun setPqcEnabled(enabled: Boolean) = Unit
        override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) = Unit
        override suspend fun generateConnectionCode(): String = "test-session"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit
        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean = false
        override fun disconnect() = Unit
        override fun release() = Unit
    }

    private class FailAfterInitialTransferTransport(
        private val initialSuccessfulSends: Int
    ) : TestCrossNetworkWebRtcTransportAdapter() {
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
        var sendAttempts: Int = 0
            private set

        override fun hasSessionKeys(): Boolean = true
        override fun authenticatedPeerDeviceId(): String = "trusted-peer"
        override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
        override fun negotiatedSuiteWireId(): Int = 0x0011
        override fun hasPqcSessionKeys(): Boolean = true
        override fun hasQPeriaptSessionKeys(): Boolean = true
        override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? = ByteArray(32)
        override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean = true
        override fun setLocalDeviceId(id: String) = Unit
        override fun setPqcEnabled(enabled: Boolean) = Unit
        override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) = Unit
        override suspend fun generateConnectionCode(): String = "test-session"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit
        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            sendAttempts += 1
            return sendAttempts <= initialSuccessfulSends
        }
        override fun disconnect() = Unit
        override fun release() = Unit
    }
}
