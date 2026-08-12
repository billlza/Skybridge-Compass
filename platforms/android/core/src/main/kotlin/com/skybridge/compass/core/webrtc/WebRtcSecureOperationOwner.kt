package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Opaque capability for one exact application-secure WebRTC key epoch.
 *
 * Feature modules may retain and present this marker, but it exposes no session identifiers or key
 * material. The real connection manager accepts only the internal capability instance it issued;
 * external implementations are useful for isolated transport fakes but cannot authorize a real
 * manager operation.
 */
interface WebRtcSecureOperationOwner

internal class ManagerWebRtcSecureOperationOwner(
    private val productSessionOwner: ProductSessionOwner,
    keys: P2PHandshakeWire.DerivedSessionKeys
) : WebRtcSecureOperationOwner {
    private val sendKeySnapshot = keys.sendKey.copyOf()
    private val receiveKeySnapshot = keys.receiveKey.copyOf()
    private val transcriptHashSnapshot = keys.transcriptHash.copyOf()

    fun matches(
        owner: ProductSessionOwner,
        currentKeys: P2PHandshakeWire.DerivedSessionKeys
    ): Boolean = productSessionOwner == owner &&
        sendKeySnapshot.contentEquals(currentKeys.sendKey) &&
        receiveKeySnapshot.contentEquals(currentKeys.receiveKey) &&
        transcriptHashSnapshot.contentEquals(currentKeys.transcriptHash)

    fun invalidate() {
        sendKeySnapshot.fill(0)
        receiveKeySnapshot.fill(0)
        transcriptHashSnapshot.fill(0)
    }

    override fun toString(): String =
        "WebRtcSecureOperationOwner(productSession=$productSessionOwner, keyEpoch=<opaque>)"
}

/** Single-current-key-epoch state; this is a capability pointer, not an operation ledger. */
internal class WebRtcSecureOperationOwnerState {
    private val lock = Any()
    private var current: ManagerWebRtcSecureOperationOwner? = null
    private val _owner = MutableStateFlow<WebRtcSecureOperationOwner?>(null)

    /** Emits on every exact key-epoch replacement, even when the product session is unchanged. */
    val owner: StateFlow<WebRtcSecureOperationOwner?> = _owner.asStateFlow()

    fun replace(
        owner: ProductSessionOwner,
        keys: P2PHandshakeWire.DerivedSessionKeys
    ): WebRtcSecureOperationOwner = synchronized(lock) {
        current?.invalidate()
        ManagerWebRtcSecureOperationOwner(owner, keys).also {
            current = it
            _owner.value = it
        }
    }

    fun current(
        owner: ProductSessionOwner,
        keys: P2PHandshakeWire.DerivedSessionKeys
    ): WebRtcSecureOperationOwner? = synchronized(lock) {
        current?.takeIf { capability -> capability.matches(owner, keys) }
    }

    fun isCurrent(
        candidate: WebRtcSecureOperationOwner,
        owner: ProductSessionOwner,
        keys: P2PHandshakeWire.DerivedSessionKeys
    ): Boolean = synchronized(lock) {
        val exactCandidate = candidate as? ManagerWebRtcSecureOperationOwner ?: return@synchronized false
        current === exactCandidate && exactCandidate.matches(owner, keys)
    }

    fun clear() = synchronized(lock) {
        current?.invalidate()
        current = null
        _owner.value = null
    }
}
