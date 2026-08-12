package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.WebRtcSelectedRoute
import com.skybridge.compass.core.webrtc.WebRtcSelectedRouteWitness
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

internal object TestWebRtcSecureOperationOwner : WebRtcSecureOperationOwner

/** Test-source compatibility helper; production has no ownerless receive entry point. */
internal fun WebRtcFileTransferController.handleIncoming(bytes: ByteArray) {
    handleIncoming(TestWebRtcSecureOperationOwner, bytes)
}

/**
 * Test-only fail-closed implementation of the exact-owner surface.
 *
 * Existing file-transfer unit fakes exercise the legacy single-session controller contract. They
 * intentionally expose no established owner until those tests are migrated to owner-bound
 * transfers; calling an exact-owner operation therefore returns false rather than selecting a
 * replacement implicitly.
 */
abstract class TestCrossNetworkWebRtcTransportAdapter : CrossNetworkWebRtcTransportAdapter {
    private val secureOwnerLock = Any()
    @Volatile
    private var secureOwner: WebRtcSecureOperationOwner = TestWebRtcSecureOperationOwner
    private val secureOwnerFlow = MutableStateFlow<WebRtcSecureOperationOwner?>(secureOwner)

    internal fun currentTestSecureOwner(): WebRtcSecureOperationOwner =
        synchronized(secureOwnerLock) { secureOwner }

    internal fun replaceTestSecureOwner(): WebRtcSecureOperationOwner =
        synchronized(secureOwnerLock) {
            val replacement = object : WebRtcSecureOperationOwner {}
            secureOwner = replacement
            secureOwnerFlow.value = replacement
            replacement
        }

    final override val selectedRouteWitness: StateFlow<WebRtcSelectedRouteWitness?> =
        MutableStateFlow(null)
    final override val secureOperationOwner: StateFlow<WebRtcSecureOperationOwner?> =
        secureOwnerFlow

    final override var onOwnedData: ((ProductSessionOwner, ByteArray) -> Unit)? = null
    final override var onOwnedPacketData:
        ((ProductSessionOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
    final override var onSecurePacketData:
        ((WebRtcSecureOperationOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null

    final override fun currentEstablishedOwner(): ProductSessionOwner? = null

    final override fun currentSecureOperationOwner(): WebRtcSecureOperationOwner? =
        secureOwner.takeIf { hasSessionKeys() }

    final override fun isCurrentSecureOperationOwner(owner: WebRtcSecureOperationOwner): Boolean =
        synchronized(secureOwnerLock) {
            owner === secureOwner && hasSessionKeys()
        }

    final override fun hasSessionKeys(owner: ProductSessionOwner): Boolean = false

    final override fun hasSessionKeys(owner: WebRtcSecureOperationOwner): Boolean =
        isCurrentSecureOperationOwner(owner)

    final override fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute? = null

    final override fun selectedRoute(owner: WebRtcSecureOperationOwner): WebRtcSelectedRoute? = null

    final override fun hasDirectRoute(owner: ProductSessionOwner): Boolean = false

    final override fun hasDirectRoute(owner: WebRtcSecureOperationOwner): Boolean = false

    final override fun computeOutboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray
    ): ByteArray? = null

    final override fun computeOutboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray
    ): ByteArray? = if (isCurrentSecureOperationOwner(owner)) {
        computeOutboundHmacSha256(preimage)
    } else {
        null
    }

    final override fun verifyInboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = false

    final override fun verifyInboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = isCurrentSecureOperationOwner(owner) &&
        verifyInboundHmacSha256(preimage, mac)

    final override fun send(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean = false

    final override fun send(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean = isCurrentSecureOperationOwner(owner) && send(bytes, packetType)

    final override fun failSecureOperation(
        owner: WebRtcSecureOperationOwner,
        reason: String
    ): Boolean = isCurrentSecureOperationOwner(owner)

    final override fun runIfCurrentSecureOperationOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean = synchronized(secureOwnerLock) {
        if (owner !== secureOwner || !hasSessionKeys()) {
            return@synchronized false
        }
        commit()
        true
    }
}
