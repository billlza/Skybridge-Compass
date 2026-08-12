package com.skybridge.compass.android.remote.mac

import android.content.Context
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.PeerKemPublicKeySource
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import kotlinx.coroutines.CancellationException

/**
 * Remote trust material consumed by one LAN remote-control client.
 *
 * Production binds these narrow contracts to the existing encrypted stores. Debug-only callers can
 * instead supply an activity-scoped implementation without changing the handshake or creating a
 * second session ledger.
 */
internal class MacRemoteControlTrustContext(
    val peerKemPublicKeys: PeerKemPublicKeySource,
    val peerSigningFingerprints: P2PHandshakeWire.TrustStore,
    val fallbackCooldowns: P2PHandshakeWire.FallbackCooldownStore,
    val mode: MacRemoteControlTrustMode
)

internal enum class MacRemoteControlTrustMode {
    PERSISTENT_PRODUCT,
    FORMAL_ACCEPTANCE_READ_ONLY,
    EPHEMERAL_DIAGNOSTIC
}

/**
 * Exact formal-route lease. Product issuers bind the current immutable Bonjour snapshot and any
 * ProductSession owner authorization; debug issuers may only bind a single nonce-scoped discovered
 * snapshot and are not product-session or peer-identity authority.
 */
internal fun interface MacRemoteFormalRouteAuthorizationLease {
    fun isCurrent(): Boolean
}

internal object MacRemoteFormalRouteAuthorizationPolicy {
    fun isCurrent(
        mode: MacRemoteControlTrustMode,
        lease: MacRemoteFormalRouteAuthorizationLease?
    ): Boolean =
        mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY || lease?.isCurrent() == true

    fun requireCurrent(
        mode: MacRemoteControlTrustMode,
        lease: MacRemoteFormalRouteAuthorizationLease?
    ) {
        if (mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) return
        val requiredLease = requireNotNull(lease) {
            "formal LAN route authorization lease is required"
        }
        require(isCurrent(mode, requiredLease)) {
            "formal LAN route authorization lease is no longer current"
        }
    }
}

internal object MacRemoteFormalLanSecurityPolicy {
    fun requireStrict(
        enableHandshake: Boolean,
        config: MacRemoteControlClient.SecurityConfig
    ) {
        require(enableHandshake) { "formal LAN acceptance requires the authenticated handshake" }
        require(config.encryptionRequired) { "formal LAN acceptance requires encrypted transport" }
        require(!config.allowPlaintextFallback) { "formal LAN acceptance forbids plaintext fallback" }
        require(!config.allowTrustOnFirstUse) { "formal LAN acceptance forbids trust on first use" }
        val policy = requireNotNull(config.handshakePolicyOverride) {
            "formal LAN acceptance requires an explicit strict PQC policy"
        }
        require(policy.requirePqc) { "formal LAN acceptance requires PQC" }
        require(!policy.allowClassicFallback) { "formal LAN acceptance forbids classic fallback" }
        require(policy.minimumTierRaw == "nativePQC") {
            "formal LAN acceptance requires the X-Wing nativePQC tier"
        }
    }
}

internal object MacRemoteFormalKemPolicy {
    fun requireStartReady(
        mode: MacRemoteControlTrustMode,
        localXWingAvailable: Boolean,
        peerXWingPublicKey: ByteArray?
    ) {
        if (mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) return
        require(localXWingAvailable) { "formal LAN acceptance requires local X-Wing capability" }
        require(peerXWingPublicKey?.size == P2PXWingKem.XWING_PUBLIC_KEY_SIZE) {
            "formal LAN acceptance requires a verified peer X-Wing key"
        }
    }

    fun requireNegotiatedSuite(
        mode: MacRemoteControlTrustMode,
        negotiatedSuite: P2PCryptoSuite
    ) {
        if (mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) return
        require(negotiatedSuite == P2PCryptoSuite.X_WING) {
            "formal LAN acceptance requires an X-Wing handshake"
        }
    }
}

internal object MacRemoteFormalPreDialPolicy {
    fun requireReady(
        mode: MacRemoteControlTrustMode,
        target: MacRemoteControlClient.ConnectionTarget,
        trustContext: MacRemoteControlTrustContext,
        localXWingAvailable: Boolean
    ) {
        if (mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) return
        val peerId = target.deviceIdHint?.trim()?.takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("formal LAN peer identity is unavailable before dial")
        val expectedFingerprint = normalizedMacRemoteProtocolFingerprint(
            target.advertisedFingerprint
        ) ?: throw IllegalStateException("formal LAN target fingerprint is invalid before dial")
        val pinnedFingerprint = normalizedMacRemoteProtocolFingerprint(
            trustContext.peerSigningFingerprints.loadPeerSigningFingerprint(peerId)
        )
        if (pinnedFingerprint != expectedFingerprint) {
            throw IllegalStateException("formal LAN authority changed before dial")
        }
        val peerKem = trustContext.peerKemPublicKeys.load(peerId)
        MacRemoteFormalKemPolicy.requireStartReady(
            mode = mode,
            localXWingAvailable = localXWingAvailable,
            peerXWingPublicKey = peerKem.xWingPublicKey
        )
    }
}

internal object MacRemoteFormalTrustCommitPolicy {
    fun requireUnchangedAuthority(
        mode: MacRemoteControlTrustMode,
        trustStore: P2PHandshakeWire.TrustStore,
        peerId: String,
        observedFingerprint: String
    ) {
        if (mode != MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) return
        require(peerId.isNotBlank() && peerId == peerId.trim()) {
            "formal LAN peer identity is unavailable at session commit"
        }
        val observed = normalizedMacRemoteProtocolFingerprint(observedFingerprint)
            ?: throw IllegalStateException("formal LAN observed authority is invalid at session commit")
        val current = try {
            trustStore.loadPeerSigningFingerprint(peerId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            throw IllegalStateException("formal LAN authority could not be revalidated at session commit", error)
        }
        if (normalizedMacRemoteProtocolFingerprint(current) != observed) {
            throw IllegalStateException("formal LAN authority changed before session commit")
        }
    }
}

internal fun normalizedMacRemoteProtocolFingerprint(raw: String?): String? =
    raw?.trim()?.lowercase()?.takeIf { value ->
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
    }

internal object MacRemoteFormalFailurePolicy {
    fun reason(
        mode: MacRemoteControlTrustMode,
        reasonCode: String,
        error: Throwable,
        diagnosticReason: String
    ): String {
        if (mode == MacRemoteControlTrustMode.EPHEMERAL_DIAGNOSTIC) return diagnosticReason
        val safeCode = reasonCode.takeIf { code ->
            code.isNotEmpty() && code.length <= 64 && code.all { it.isLowerCase() || it == '_' }
        } ?: "formal_lan_failure"
        val safeType = error.javaClass.simpleName
            .filter { it.isLetterOrDigit() || it == '_' }
            .take(64)
            .ifEmpty { "RuntimeException" }
        return "reasonCode=$safeCode exception=$safeType"
    }
}

internal object MacRemoteControlTrustContextFactory {
    fun persistentReadWrite(
        appContext: Context,
        localIdentity: LocalP2PIdentity
    ): MacRemoteControlTrustContext = MacRemoteControlTrustContext(
        peerKemPublicKeys = PeerKemKeyStore(appContext.applicationContext),
        peerSigningFingerprints = localIdentity.trustStore(),
        fallbackCooldowns = localIdentity.fallbackCooldownStore(),
        mode = MacRemoteControlTrustMode.PERSISTENT_PRODUCT
    )

    fun persistentReadOnly(
        appContext: Context,
        localIdentity: LocalP2PIdentity
    ): MacRemoteControlTrustContext {
        val peerKemStore = PeerKemKeyStore(appContext.applicationContext)
        return MacRemoteControlTrustContext(
            peerKemPublicKeys = PeerKemPublicKeySource(peerKemStore::loadVerifiedReadOnly),
            peerSigningFingerprints = localIdentity.formalAcceptanceTrustStore(),
            fallbackCooldowns = ReadOnlyFallbackCooldownStore(localIdentity.fallbackCooldownStore()),
            mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
        )
    }
}

internal class ReadOnlyFallbackCooldownStore(
    private val delegate: P2PHandshakeWire.FallbackCooldownStore
) : P2PHandshakeWire.FallbackCooldownStore {
    override fun loadLastClassicFallbackAtMillis(peerId: String): Long? =
        delegate.loadLastClassicFallbackAtMillis(peerId)

    override fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long) {
        error("read-only LAN acceptance probe cannot persist fallback migration state")
    }
}
