package com.skybridge.compass.android.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AndroidCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSelectedRoute
import com.skybridge.compass.core.webrtc.WebRtcSelectedRouteWitness
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.Collections

internal class RecordingFileTransferTransport(
    private val delegate: CrossNetworkWebRtcTransportAdapter,
    private val json: Json,
    private val expectedTransferId: String,
    private val preflightOwner: WebRtcSecureOperationOwner
) : CrossNetworkWebRtcTransportAdapter {
    constructor(
        manager: SkyBridgeWebRtcConnectionManager,
        json: Json,
        expectedTransferId: String,
        preflightOwner: WebRtcSecureOperationOwner
    ) : this(
        delegate = AndroidCrossNetworkWebRtcTransportAdapter(manager),
        json = json,
        expectedTransferId = expectedTransferId,
        preflightOwner = preflightOwner
    )

    private val outboundOps = Collections.synchronizedList(mutableListOf<CrossNetworkFileTransferOp>())
    private val inboundOps = Collections.synchronizedList(mutableListOf<CrossNetworkFileTransferOp>())
    private val transferOwnerLock = Any()
    private var transferOwner: WebRtcSecureOperationOwner? = null
    val completeAck = CompletableDeferred<CrossNetworkFileTransferMessage>()
    val peerError = CompletableDeferred<CrossNetworkFileTransferMessage>()

    override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> = delegate.state
    override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
        delegate.signalingStatus
    override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
        delegate.dataChannelConfigStatus
    override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> =
        delegate.authenticatedPeerMetadata
    override val selectedRouteWitness: StateFlow<WebRtcSelectedRouteWitness?> =
        delegate.selectedRouteWitness
    override val secureOperationOwner: StateFlow<WebRtcSecureOperationOwner?> =
        delegate.secureOperationOwner

    override var onData: ((ByteArray) -> Unit)? = null
    override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
    override var onOwnedData: ((ProductSessionOwner, ByteArray) -> Unit)?
        get() = delegate.onOwnedData
        set(value) {
            delegate.onOwnedData = value
        }
    override var onOwnedPacketData:
        ((ProductSessionOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = delegate.onOwnedPacketData
        set(value) {
            delegate.onOwnedPacketData = value
        }
    override var onSecurePacketData:
        ((WebRtcSecureOperationOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = delegate.onSecurePacketData
        set(value) {
            delegate.onSecurePacketData = value
        }

    fun attach(handler: (WebRtcSecureOperationOwner, ByteArray) -> Unit) {
        delegate.onSecurePacketData = { owner, bytes, packetType ->
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                handler(owner, bytes)
                if (owner === exactFileTransferOwnerOrNull()) {
                    recordInbound(bytes)
                }
            }
        }
    }

    fun exactFileTransferOwner(): WebRtcSecureOperationOwner =
        checkNotNull(exactFileTransferOwnerOrNull()) {
            "File-transfer smoke has not sent metadata through a secure owner"
        }

    override fun hasSessionKeys(): Boolean = delegate.hasSessionKeys()
    override fun currentEstablishedOwner(): ProductSessionOwner? = delegate.currentEstablishedOwner()
    override fun currentSecureOperationOwner(): WebRtcSecureOperationOwner? =
        delegate.currentSecureOperationOwner()
    override fun isCurrentSecureOperationOwner(owner: WebRtcSecureOperationOwner): Boolean =
        delegate.isCurrentSecureOperationOwner(owner)
    override fun hasSessionKeys(owner: ProductSessionOwner): Boolean = delegate.hasSessionKeys(owner)
    override fun hasSessionKeys(owner: WebRtcSecureOperationOwner): Boolean = delegate.hasSessionKeys(owner)
    override fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute? =
        delegate.selectedRoute(owner)
    override fun selectedRoute(owner: WebRtcSecureOperationOwner): WebRtcSelectedRoute? =
        delegate.selectedRoute(owner)
    override fun hasDirectRoute(owner: ProductSessionOwner): Boolean = delegate.hasDirectRoute(owner)
    override fun hasDirectRoute(owner: WebRtcSecureOperationOwner): Boolean = delegate.hasDirectRoute(owner)
    override fun authenticatedPeerDeviceId(): String? = delegate.authenticatedPeerDeviceId()
    override fun negotiatedSuiteName(): String? = delegate.negotiatedSuiteName()
    override fun negotiatedSuiteWireId(): Int? = delegate.negotiatedSuiteWireId()
    override fun hasPqcSessionKeys(): Boolean = delegate.hasPqcSessionKeys()
    override fun hasQPeriaptSessionKeys(): Boolean = delegate.hasQPeriaptSessionKeys()
    override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? =
        error("File-transfer smoke forbids ownerless outbound HMAC")
    override fun computeOutboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray
    ): ByteArray? = error("File-transfer smoke forbids product-owner outbound HMAC")
    override fun computeOutboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray
    ): ByteArray? = delegate.computeOutboundHmacSha256(owner, preimage)

    override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
        error("File-transfer smoke forbids ownerless inbound HMAC verification")
    override fun verifyInboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = error("File-transfer smoke forbids product-owner inbound HMAC verification")
    override fun verifyInboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = delegate.verifyInboundHmacSha256(owner, preimage, mac)

    override fun setLocalDeviceId(id: String) = delegate.setLocalDeviceId(id)
    override fun setPqcEnabled(enabled: Boolean) = delegate.setPqcEnabled(enabled)
    override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) =
        delegate.setHandshakePolicyOverride(policy)

    override suspend fun generateConnectionCode(): String = delegate.generateConnectionCode()
    override fun startOfferer(code: String) = delegate.startOfferer(code)
    override fun startAnswerer(code: String) = delegate.startAnswerer(code)

    override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
        if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
            error("File-transfer smoke forbids ownerless send")
        }
        return delegate.send(bytes, packetType)
    }

    override fun send(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean {
        if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
            error("File-transfer smoke forbids product-owner send")
        }
        return delegate.send(owner, bytes, packetType)
    }

    override fun send(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean {
        if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
            recordOutbound(owner, bytes)
        }
        return delegate.send(owner, bytes, packetType)
    }

    override fun failSecureOperation(
        owner: WebRtcSecureOperationOwner,
        reason: String
    ): Boolean = delegate.failSecureOperation(owner, reason)

    override fun runIfCurrentSecureOperationOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean = delegate.runIfCurrentSecureOperationOwner(owner, commit)

    override fun disconnect() = delegate.disconnect()
    override fun release() = delegate.release()

    fun outboundOpsSnapshot(): List<CrossNetworkFileTransferOp> = synchronized(outboundOps) {
        outboundOps.toList()
    }

    fun inboundOpsSnapshot(): List<CrossNetworkFileTransferOp> = synchronized(inboundOps) {
        inboundOps.toList()
    }

    private fun recordInbound(bytes: ByteArray) {
        val message = decodeMessage(bytes) ?: return
        if (message.transferId != expectedTransferId) return
        inboundOps += message.op
        if (message.op == CrossNetworkFileTransferOp.completeAck) {
            completeAck.complete(message)
        }
        if (message.op == CrossNetworkFileTransferOp.error) {
            peerError.complete(message)
        }
    }

    private fun recordOutbound(owner: WebRtcSecureOperationOwner, bytes: ByteArray) {
        val message = checkNotNull(decodeMessage(bytes)) {
            "File-transfer smoke emitted an invalid outbound payload"
        }
        check(message.transferId == expectedTransferId) {
            "File-transfer smoke emitted a payload for an unexpected transfer"
        }
        synchronized(transferOwnerLock) {
            val currentOwner = transferOwner
            if (currentOwner == null) {
                check(message.op == CrossNetworkFileTransferOp.metadata) {
                    "File-transfer smoke must bind its secure owner on metadata"
                }
                check(owner === preflightOwner) {
                    "File-transfer secure owner changed after route preflight"
                }
                transferOwner = owner
            } else {
                check(owner === currentOwner) {
                    "File-transfer smoke cannot cross a secure-owner replacement"
                }
            }
        }
        outboundOps += message.op
    }

    private fun exactFileTransferOwnerOrNull(): WebRtcSecureOperationOwner? =
        synchronized(transferOwnerLock) { transferOwner }

    private fun decodeMessage(bytes: ByteArray): CrossNetworkFileTransferMessage? =
        runCatching {
            json.decodeFromString(
                CrossNetworkFileTransferMessage.serializer(),
                bytes.decodeToString()
            )
        }.getOrNull()
}

internal fun sha256(bytes: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").digest(bytes)

internal fun ByteArray.toHex(): String =
    joinToString(separator = "") { "%02x".format(it) }
