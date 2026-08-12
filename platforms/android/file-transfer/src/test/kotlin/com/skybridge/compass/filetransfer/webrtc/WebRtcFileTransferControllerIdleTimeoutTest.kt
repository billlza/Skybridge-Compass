package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.TransferDirection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Tests for the idle / interrupt timeout of an in-progress transfer (task 11.8 / Requirement 5.12).
 *
 * Key distinction from cancel/decline/corrupt cleanup (which PURGE the checkpoint): the idle /
 * interrupt timeout terminates THIS transfer but RETAINS its verified-bytes checkpoint so the
 * existing resume entry can pick it up. The timeout clock is injected so these tests are fully
 * deterministic — no wall-clock sleeps.
 */
class WebRtcFileTransferControllerIdleTimeoutTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun idle30s_terminatesTransferButRetainsResumableCheckpoint() = runTest {
        // No peer wired: acks never arrive, so the send stays in-progress and goes idle.
        val clock = AtomicLong(0L)
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val sender = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            checkpointStore = checkpointStore,
            idleInterruptTimeoutMs = 30_000L,
            // Keep the background poll dormant during the test; we drive the sweep explicitly.
            idleWatchdogPollMs = 1_000_000L,
            clockMs = { clock.get() }
        )

        val transferId = UUID.randomUUID().toString()
        sender.sendBytesAsFile(
            transferId = transferId,
            fileName = "idle.txt",
            mimeType = "text/plain",
            bytes = "idle timeout please".encodeToByteArray(),
            chunkSize = 4
        )

        // The transfer is tracked with a saved checkpoint before the idle timeout fires.
        withTimeout(2_000) { while (checkpointStore.load(transferId) == null) yield() }
        assertNotNull(checkpointStore.load(transferId), "send must persist a checkpoint")

        // Advance the clock past the idle threshold and run the sweep: THIS transfer times out.
        clock.set(30_000L)
        sender.runIdleInterruptSweep(clock.get())

        // The verified-bytes checkpoint is RETAINED (NOT deleted) so the transfer stays resumable.
        val retained = checkpointStore.load(transferId)
        assertNotNull(retained, "idle/interrupt timeout MUST retain the checkpoint for resume")
        assertEquals(TransferDirection.SEND, retained!!.direction)
        assertEquals(0, checkpointStore.deleteCount.get(), "idle timeout must not delete the checkpoint")

        // A truthful interrupt/timeout reason is presented.
        val status = sender.progress.value.lastStatus
        assertNotNull(status)
        assertTrue(status!!.contains("interrupted"), "must present an interrupt/timeout reason: $status")
        assertTrue(status.contains("resumable"), "reason must indicate the transfer is resumable: $status")

        // The send is terminated: a subsequent NACK does NOT resume/resend (context released).
        val opsBefore = transport.ops.toList()
        sender.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    missingChunks = intArrayOf(0),
                    message = "missingChunks"
                )
            )
        )
        yield()
        assertEquals(opsBefore, transport.ops.toList(), "no resend after idle/interrupt termination")
    }

    @Test
    fun activityWithinWindow_resetsIdleTimerAndAvoidsTimeout() = runTest {
        val clock = AtomicLong(0L)
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        // Receiver so inbound chunks (activity) refresh the idle timer.
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider(),
            idleInterruptTimeoutMs = 30_000L,
            idleWatchdogPollMs = 1_000_000L,
            clockMs = { clock.get() }
        )

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abcd".encodeToByteArray()

        // metadata @ t=0 seeds the watchdog.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "rx.bin",
                    fileSize = 8,
                    chunkSize = 4,
                    totalChunks = 2,
                    mimeType = "application/octet-stream"
                )
            )
        )
        withTimeout(2_000) { while (checkpointStore.load(transferId) == null) yield() }

        // Activity @ t=25s (a chunk arrives) refreshes last-activity.
        clock.set(25_000L)
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
        withTimeout(2_000) { while (transport.ops.none { it == CrossNetworkFileTransferOp.chunkAck }) yield() }

        // Sweep @ t=50s: only 25s since the last activity (t=25s) -> NOT timed out.
        clock.set(50_000L)
        receiver.runIdleInterruptSweep(clock.get())

        assertFalse(
            receiver.progress.value.lastStatus?.contains("interrupted") == true,
            "activity within the window must reset the idle timer and avoid a timeout"
        )

        // Sweep @ t=56s: now 31s since the last activity (t=25s) -> timed out, checkpoint retained.
        clock.set(56_000L)
        receiver.runIdleInterruptSweep(clock.get())
        assertNotNull(checkpointStore.load(transferId), "receive checkpoint retained on idle timeout")
        assertEquals(0, checkpointStore.deleteCount.get(), "idle timeout must not delete the checkpoint")
        assertTrue(receiver.progress.value.lastStatus?.contains("interrupted") == true)
    }

    @Test
    fun cancel_stillPurgesCheckpoint_unlikeIdleTimeout() = runTest {
        // Guards the distinction: cancel DELETES the checkpoint; idle timeout RETAINS it.
        val clock = AtomicLong(0L)
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val sender = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            checkpointStore = checkpointStore,
            idleWatchdogPollMs = 1_000_000L,
            clockMs = { clock.get() }
        )

        val transferId = UUID.randomUUID().toString()
        sender.sendBytesAsFile(transferId, "c.txt", "text/plain", "cccc".encodeToByteArray(), chunkSize = 4)
        withTimeout(2_000) { while (checkpointStore.load(transferId) == null) yield() }

        sender.cancel(transferId)
        withTimeout(2_000) { while (checkpointStore.load(transferId) != null) yield() }
        assertEquals(null, checkpointStore.load(transferId), "cancel MUST still purge the checkpoint")
    }

    /**
     * Direct in-session send (Requirement 5.4): the controller's send API drives the transfer over
     * the already-established transport session using only a transferId. It never asks for a
     * connection code (generateConnectionCode) or a host/port/address, and never re-initiates
     * offer/answer signaling — confirming the device-list → send path reaches the existing session
     * directly.
     */
    @Test
    fun directSessionSend_usesEstablishedSessionWithoutCodeOrAddressPrompt() = runTest {
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

        // Session is already Established (post-handshake); no code/address is provided.
        assertTrue(senderTransport.state.value is SkyBridgeWebRtcConnectionManager.State.Established)

        val payload = "direct in-session".encodeToByteArray()
        sender.sendBytesAsFile(
            transferId = UUID.randomUUID().toString(),
            fileName = "direct.txt",
            mimeType = "text/plain",
            bytes = payload,
            chunkSize = 8
        )

        withTimeout(2_000) {
            while (receiverTransport.ops.none { it == CrossNetworkFileTransferOp.completeAck }) yield()
        }

        // The transfer went straight over the existing session; no code/address negotiation.
        assertEquals(0, senderTransport.generateCodeCount.get(), "must not request a connection code")
        assertEquals(0, senderTransport.startOffererCount.get(), "must not (re)start offerer signaling")
        assertEquals(0, senderTransport.startAnswererCount.get(), "must not (re)start answerer signaling")
        assertTrue(
            senderTransport.packetTypes.all { it == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER },
            "all bytes must flow over the established file-transfer session"
        )
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
        val packetTypes = mutableListOf<WebRtcAppSecureEnvelope.PacketType>()
        val ops = mutableListOf<CrossNetworkFileTransferOp>()
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()
        val generateCodeCount = AtomicInteger()
        val startOffererCount = AtomicInteger()
        val startAnswererCount = AtomicInteger()

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
        override suspend fun generateConnectionCode(): String {
            generateCodeCount.incrementAndGet()
            return "test-session"
        }
        override fun startOfferer(code: String) { startOffererCount.incrementAndGet() }
        override fun startAnswerer(code: String) { startAnswererCount.incrementAndGet() }

        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            packetTypes += packetType
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

    private class RecordingCheckpointStore : TransferCheckpointStore {
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
        val saveCount = AtomicInteger()
        val deleteCount = AtomicInteger()

        override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            checkpoints[checkpoint.transferId] = checkpoint
            saveCount.incrementAndGet()
        }

        override suspend fun delete(transferId: String) {
            checkpoints.remove(transferId)
            deleteCount.incrementAndGet()
        }

        override suspend fun list(): List<TransferCheckpoint> = checkpoints.values.toList()
    }
}
