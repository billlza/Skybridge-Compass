package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.StateFlow

/**
 * Thin adapter layer for Android cross-network WebRTC.
 *
 * Purpose:
 * - keep UI / feature modules independent from the concrete manager implementation
 * - expose the same high-level concepts used by macOS / iOS / Ubuntu:
 *   state, signaling status, DataChannel config status, send/receive
 */
interface CrossNetworkWebRtcTransportAdapter {
    val state: StateFlow<SkyBridgeWebRtcConnectionManager.State>
    val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus>
    val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus>
    val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?>
    val selectedRouteWitness: StateFlow<WebRtcSelectedRouteWitness?>
    val secureOperationOwner: StateFlow<WebRtcSecureOperationOwner?>

    var onData: ((ByteArray) -> Unit)?
    var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
    var onOwnedData: ((ProductSessionOwner, ByteArray) -> Unit)?
    var onOwnedPacketData: ((ProductSessionOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
    var onSecurePacketData: ((WebRtcSecureOperationOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?

    fun hasSessionKeys(): Boolean
    fun currentEstablishedOwner(): ProductSessionOwner?
    fun currentSecureOperationOwner(): WebRtcSecureOperationOwner?
    fun isCurrentSecureOperationOwner(owner: WebRtcSecureOperationOwner): Boolean
    fun hasSessionKeys(owner: ProductSessionOwner): Boolean
    fun hasSessionKeys(owner: WebRtcSecureOperationOwner): Boolean
    fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute?
    fun selectedRoute(owner: WebRtcSecureOperationOwner): WebRtcSelectedRoute?
    fun hasDirectRoute(owner: ProductSessionOwner): Boolean
    fun hasDirectRoute(owner: WebRtcSecureOperationOwner): Boolean
    fun authenticatedPeerDeviceId(): String?
    fun negotiatedSuiteName(): String?
    fun negotiatedSuiteWireId(): Int?
    fun hasPqcSessionKeys(): Boolean
    fun hasQPeriaptSessionKeys(): Boolean
    fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray?
    fun computeOutboundHmacSha256(owner: ProductSessionOwner, preimage: ByteArray): ByteArray?
    fun computeOutboundHmacSha256(owner: WebRtcSecureOperationOwner, preimage: ByteArray): ByteArray?
    fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean
    fun verifyInboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean
    fun verifyInboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean
    fun setLocalDeviceId(id: String)
    fun setPqcEnabled(enabled: Boolean)
    fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?)
    suspend fun generateConnectionCode(): String
    fun startOfferer(code: String)
    fun startAnswerer(code: String)

    /**
     * Send an application payload, sealed in the SBWC application-secure envelope so the macOS
     * peer can decrypt it. [packetType] selects the SBWC packet type the Mac validates: app-control
     * payloads (PIB pairing, clipboard, heartbeat, stream config) use the default APP_CONTROL;
     * file transfer and remote control pass FILE_TRANSFER / REMOTE_CONTROL respectively.
     */
    fun send(
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean

    fun send(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean

    fun send(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean

    /**
     * Terminalize only the exact application-secure key epoch that reported a protocol failure.
     * A capability invalidated by rekey or session replacement is rejected without affecting the
     * current connection.
     */
    fun failSecureOperation(owner: WebRtcSecureOperationOwner, reason: String): Boolean

    /**
     * Execute one short, non-suspending commit while the exact session and key-epoch capability
     * remain current. Callers must prepare expensive work before entering this boundary.
     */
    fun runIfCurrentSecureOperationOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean

    fun disconnect()
    fun release()
}

class AndroidCrossNetworkWebRtcTransportAdapter(
    private val manager: SkyBridgeWebRtcConnectionManager
) : CrossNetworkWebRtcTransportAdapter {
    override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> = manager.state
    override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> = manager.signalingStatus
    override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> = manager.dataChannelConfigStatus
    override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> = manager.authenticatedPeerMetadata
    override val selectedRouteWitness: StateFlow<WebRtcSelectedRouteWitness?> = manager.selectedRouteWitness
    override val secureOperationOwner: StateFlow<WebRtcSecureOperationOwner?> =
        manager.secureOperationOwner

    override var onData: ((ByteArray) -> Unit)?
        get() = manager.onData
        set(value) {
            manager.onData = value
        }

    override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = manager.onPacketData
        set(value) {
            manager.onPacketData = value
        }

    override var onOwnedData: ((ProductSessionOwner, ByteArray) -> Unit)?
        get() = manager.onOwnedData
        set(value) {
            manager.onOwnedData = value
        }

    override var onOwnedPacketData: ((ProductSessionOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = manager.onOwnedPacketData
        set(value) {
            manager.onOwnedPacketData = value
        }

    override var onSecurePacketData:
        ((WebRtcSecureOperationOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = manager.onSecurePacketData
        set(value) {
            manager.onSecurePacketData = value
        }

    override fun hasSessionKeys(): Boolean = manager.hasSessionKeys()

    override fun currentEstablishedOwner(): ProductSessionOwner? = manager.currentEstablishedOwner()

    override fun currentSecureOperationOwner(): WebRtcSecureOperationOwner? =
        manager.currentSecureOperationOwner()

    override fun isCurrentSecureOperationOwner(owner: WebRtcSecureOperationOwner): Boolean =
        manager.isCurrentSecureOperationOwner(owner)

    override fun hasSessionKeys(owner: ProductSessionOwner): Boolean = manager.hasSessionKeys(owner)

    override fun hasSessionKeys(owner: WebRtcSecureOperationOwner): Boolean = manager.hasSessionKeys(owner)

    override fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute? = manager.selectedRoute(owner)

    override fun selectedRoute(owner: WebRtcSecureOperationOwner): WebRtcSelectedRoute? =
        manager.selectedRoute(owner)

    override fun hasDirectRoute(owner: ProductSessionOwner): Boolean = manager.hasDirectRoute(owner)

    override fun hasDirectRoute(owner: WebRtcSecureOperationOwner): Boolean = manager.hasDirectRoute(owner)

    override fun authenticatedPeerDeviceId(): String? = manager.authenticatedPeerDeviceId()

    override fun negotiatedSuiteName(): String? = manager.negotiatedSuiteName()

    override fun negotiatedSuiteWireId(): Int? = manager.negotiatedSuiteWireId()

    override fun hasPqcSessionKeys(): Boolean = manager.hasPqcSessionKeys()

    override fun hasQPeriaptSessionKeys(): Boolean = manager.hasQPeriaptSessionKeys()

    override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? =
        manager.computeOutboundHmacSha256(preimage)

    override fun computeOutboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray
    ): ByteArray? = manager.computeOutboundHmacSha256(owner, preimage)

    override fun computeOutboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray
    ): ByteArray? = manager.computeOutboundHmacSha256(owner, preimage)

    override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
        manager.verifyInboundHmacSha256(preimage, mac)

    override fun verifyInboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = manager.verifyInboundHmacSha256(owner, preimage, mac)

    override fun verifyInboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = manager.verifyInboundHmacSha256(owner, preimage, mac)

    override fun setLocalDeviceId(id: String) = manager.setLocalDeviceId(id)

    override fun setPqcEnabled(enabled: Boolean) = manager.setPqcEnabled(enabled)

    override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) =
        manager.setHandshakePolicyOverride(policy)

    override suspend fun generateConnectionCode(): String = manager.generateConnectionCode()

    override fun startOfferer(code: String) = manager.startOfferer(code)

    override fun startAnswerer(code: String) = manager.startAnswerer(code)

    override fun send(
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean = manager.send(bytes, packetType)

    override fun send(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean = manager.send(owner, bytes, packetType)

    override fun send(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean = manager.send(owner, bytes, packetType)

    override fun failSecureOperation(
        owner: WebRtcSecureOperationOwner,
        reason: String
    ): Boolean = manager.failSecureOperation(owner, reason)

    override fun runIfCurrentSecureOperationOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean = manager.runIfCurrentSecureOperationOwner(owner, commit)

    override fun disconnect() = manager.disconnect()

    override fun release() = manager.release()
}
