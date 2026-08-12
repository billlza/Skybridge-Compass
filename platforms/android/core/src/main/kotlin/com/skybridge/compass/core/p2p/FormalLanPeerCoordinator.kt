package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.MessageDigest
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

/** One fully resolved DNS-SD service observation from a single discovery revision. */
data class FormalLanBonjourEndpoint(
    val serviceType: String,
    val instanceName: String,
    val hostAddress: String,
    val port: Int,
    val routeProvenance: String,
    val advertisedDeviceId: String,
    val advertisedProtocolFingerprint: String,
    val discoveryRevision: Long
) {
    init {
        require(serviceType == normalizedServiceType(serviceType)) {
            "formal LAN service type must be canonical"
        }
        require(instanceName == normalizedCanonicalField(instanceName)) {
            "formal LAN service instance is invalid"
        }
        require(hostAddress == hostAddress.trim()) {
            "formal LAN host address must be canonical"
        }
        ResolvedBootstrapControlEndpoint.fromResolvedBonjour(hostAddress, port)
        require(routeProvenance in RESOLVED_PROVENANCE) {
            "formal LAN route provenance is not resolved DNS-SD"
        }
        require(TrustedPeerDeviceIdValidation.isCanonical(advertisedDeviceId)) {
            "formal LAN advertised device id is invalid"
        }
        require(advertisedProtocolFingerprint == normalizedFingerprint(advertisedProtocolFingerprint)) {
            "formal LAN advertised protocol fingerprint is invalid"
        }
        require(discoveryRevision > 0L) { "formal LAN discovery revision is invalid" }
    }

    fun resolvedEndpoint(): ResolvedBootstrapControlEndpoint =
        ResolvedBootstrapControlEndpoint.fromResolvedBonjour(hostAddress, port)

    private companion object {
        val RESOLVED_PROVENANCE = setOf("DIRECT_SERVICE", "SERVICE_INDEX")
    }
}

/**
 * Immutable dual-route observation used by one PIB/SKR/remote-control attempt.
 *
 * The digest binds an attempt to this exact observation. It is not proof that the endpoint owns
 * the advertised identity; PIB/SKR signatures and the durable active pin provide that authority.
 */
data class FormalLanPeerSnapshot(
    val displayName: String,
    val handshake: FormalLanBonjourEndpoint,
    val remoteDesktop: FormalLanBonjourEndpoint
) {
    init {
        require(handshake.serviceType == ProductRouteBindingProtocol.CONTROL_SERVICE_TYPE) {
            "formal LAN handshake service type is invalid"
        }
        require(remoteDesktop.serviceType == ProductRouteBindingProtocol.REMOTE_DESKTOP_SERVICE_TYPE) {
            "formal LAN remote service type is invalid"
        }
        require(handshake.discoveryRevision == remoteDesktop.discoveryRevision) {
            "formal LAN routes are from different discovery revisions"
        }
        require(handshake.advertisedDeviceId == remoteDesktop.advertisedDeviceId) {
            "formal LAN routes advertise different device ids"
        }
        require(
            handshake.advertisedProtocolFingerprint ==
                remoteDesktop.advertisedProtocolFingerprint
        ) {
            "formal LAN routes advertise different protocol fingerprints"
        }
    }

    val deviceId: String get() = handshake.advertisedDeviceId
    val advertisedProtocolFingerprint: String
        get() = handshake.advertisedProtocolFingerprint
    val discoveryRevision: Long get() = handshake.discoveryRevision
    val endpointDigest: String by lazy(LazyThreadSafetyMode.PUBLICATION) {
        sha256Hex(canonicalEndpointBinding().toByteArray(Charsets.UTF_8))
    }

    fun sameSecuritySnapshot(other: FormalLanPeerSnapshot): Boolean =
        handshake == other.handshake &&
            remoteDesktop == other.remoteDesktop &&
            endpointDigest == other.endpointDigest

    private fun canonicalEndpointBinding(): String = listOf(
        "domain=SkyBridge-SKR-1-DualBonjourEndpoint",
        "revision=$discoveryRevision",
        handshake.canonicalLines("handshake"),
        remoteDesktop.canonicalLines("remoteDesktop")
    ).joinToString("\n")
}

private fun FormalLanBonjourEndpoint.canonicalLines(prefix: String): String = listOf(
    "$prefix.serviceType=$serviceType",
    "$prefix.instanceName=$instanceName",
    "$prefix.hostAddress=$hostAddress",
    "$prefix.port=$port",
    "$prefix.routeProvenance=$routeProvenance",
    "$prefix.deviceId=$advertisedDeviceId",
    "$prefix.protocolFingerprint=$advertisedProtocolFingerprint"
).joinToString("\n")

enum class FormalLanPeerAction {
    PAIR,
    REFRESH_AND_CONNECT,
    BLOCKED
}

data class FormalLanPeerInspection(
    val action: FormalLanPeerAction,
    val failureReason: FormalLanPeerFailureReason? = null
)

enum class FormalLanPeerFailureReason {
    INVALID_ROUTE_SNAPSHOT,
    DISCOVERY_ROUTE_CHANGED,
    ACTIVE_AUTHENTICATED_PIN_REQUIRED,
    CANONICAL_AUTHORITY_BLOCKED,
    ADVERTISED_PIN_MISMATCH,
    TRUST_STORE_CORRUPTED,
    PAIRING_ALREADY_TRUSTED,
    PAIRING_FAILED,
    LOCAL_TRUST_PERSISTENCE_FAILED,
    PAIRING_BINDING_MISMATCH,
    REFRESH_FAILED,
    KEM_PERSISTENCE_FAILED,
    X_WING_REQUIRED
}

class FormalLanPeerException(
    val reason: FormalLanPeerFailureReason,
    val durablePibReceiptObtained: Boolean = false,
    val pibFinalAckVerified: Boolean = false,
    val localTrustRollbackConfirmed: Boolean? = null,
    cause: Throwable? = null
) : Exception(reason.name, cause)

class FormalLanPairingCandidate internal constructor(
    val macName: String,
    val macDeviceId: String,
    /** Discovery-map key used to keep the PIB transaction bound to its original Bonjour alias. */
    val discoveryPeerKey: String,
    val sasCode: String,
    val macFingerprint: String,
    val macSigningAlgorithm: String,
    internal val expectedSnapshot: FormalLanPeerSnapshot,
    internal val transcript: PibPairingClient.PairingResult
)

data class FormalLanReadyAuthorization(
    val peer: FormalLanPeerSnapshot,
    val authorityDeviceIds: List<String>,
    val pinnedProtocolFingerprint: String
)

/** Durable authority required when an existing ProductSession already authorizes a remote route. */
data class FormalLanDurableRouteAuthorization(
    val authorityDeviceIds: List<String>,
    val pinnedProtocolFingerprint: String
)

internal data class FormalLanAuthoritySnapshot(
    val deviceId: String,
    val currentDeviceId: String,
    val knownDeviceIds: List<String>,
    val protocolSigningAlgorithm: String?,
    val protocolPublicKeyFingerprint: String
) {
    val allDeviceIds: List<String> =
        (knownDeviceIds + deviceId + currentDeviceId).distinct().sorted()

    companion object {
        fun from(record: TrustedPeerRecord): FormalLanAuthoritySnapshot {
            val deviceId = normalizedCanonicalField(record.deviceId)
            val currentDeviceId = normalizedCanonicalField(record.currentDeviceId)
            val knownDeviceIds = record.knownDeviceIds
                .map(::normalizedCanonicalField)
                .filter(String::isNotEmpty)
                .distinct()
                .sorted()
            val fingerprint = normalizedFingerprint(record.protocolPublicKeyFingerprint)
            require(deviceId.isNotEmpty() && currentDeviceId.isNotEmpty() && knownDeviceIds.isNotEmpty()) {
                "formal LAN authority identifiers are invalid"
            }
            require(fingerprint != null) { "formal LAN authority fingerprint is invalid" }
            return FormalLanAuthoritySnapshot(
                deviceId = deviceId,
                currentDeviceId = currentDeviceId,
                knownDeviceIds = knownDeviceIds,
                protocolSigningAlgorithm = record.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = fingerprint
            )
        }
    }
}

internal interface FormalLanAuthorityPort {
    fun lookupAuthority(deviceId: String): FormalLanAuthorityLookup
    fun readFormalKem(deviceId: String): PeerKemKeyStore.PeerKemPublicKeys
}

internal sealed interface FormalLanAuthorityLookup {
    data object Absent : FormalLanAuthorityLookup
    data class ActiveVerified(val authority: FormalLanAuthoritySnapshot) : FormalLanAuthorityLookup
    data class ActiveNeedsExplicitPairing(
        val protocolPublicKeyFingerprint: String
    ) : FormalLanAuthorityLookup
    data object InactiveBlocked : FormalLanAuthorityLookup
}

internal interface FormalLanPibPort {
    suspend fun request(snapshot: FormalLanPeerSnapshot): PibPairingClient.PairingResult
    suspend fun confirm(
        snapshot: FormalLanPeerSnapshot,
        result: PibPairingClient.PairingResult
    ): TrustedPeerRecord
}

internal fun interface FormalLanSkrPort {
    suspend fun refresh(
        snapshot: FormalLanPeerSnapshot,
        pinnedProtocolFingerprint: String
    ): SignedLanKemRefreshClient.RefreshResult
}

/** Product use-case boundary. UI/ViewModels only orchestrate immutable snapshots and typed results. */
@Singleton
class FormalLanPeerCoordinator internal constructor(
    private val authorityPort: FormalLanAuthorityPort,
    private val pibPort: FormalLanPibPort,
    private val skrPort: FormalLanSkrPort
) {
    @Inject
    constructor(
        identity: LocalP2PIdentity,
        peerKemKeyStore: PeerKemKeyStore
    ) : this(
        authorityPort = PersistentFormalLanAuthorityPort(identity, peerKemKeyStore),
        pibPort = ProductFormalLanPibPort(PibPairingClient(identity)),
        skrPort = ProductFormalLanSkrPort(
            SignedLanKemRefreshClient(identity, peerKemKeyStore)
        )
    )

    suspend fun inspect(peer: FormalLanPeerSnapshot): FormalLanPeerInspection =
        withContext(Dispatchers.IO) {
            val lookup = try {
                authorityPort.lookupAuthority(peer.deviceId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: TrustedPeerStoreCorruptionException) {
                return@withContext FormalLanPeerInspection(
                    FormalLanPeerAction.BLOCKED,
                    FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED
                )
            }
            when (lookup) {
                FormalLanAuthorityLookup.Absent ->
                    FormalLanPeerInspection(FormalLanPeerAction.PAIR)
                FormalLanAuthorityLookup.InactiveBlocked ->
                    FormalLanPeerInspection(
                        FormalLanPeerAction.BLOCKED,
                        FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED
                    )
                is FormalLanAuthorityLookup.ActiveNeedsExplicitPairing ->
                    if (
                        lookup.protocolPublicKeyFingerprint ==
                        peer.advertisedProtocolFingerprint
                    ) {
                        FormalLanPeerInspection(FormalLanPeerAction.PAIR)
                    } else {
                        FormalLanPeerInspection(
                            FormalLanPeerAction.BLOCKED,
                            FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH
                        )
                    }
                is FormalLanAuthorityLookup.ActiveVerified -> when {
                    lookup.authority.protocolPublicKeyFingerprint !=
                        peer.advertisedProtocolFingerprint ->
                    FormalLanPeerInspection(
                        FormalLanPeerAction.BLOCKED,
                        FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH
                    )
                    peer.deviceId !in lookup.authority.allDeviceIds ->
                    FormalLanPeerInspection(
                        FormalLanPeerAction.BLOCKED,
                        FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED
                    )
                    else -> FormalLanPeerInspection(FormalLanPeerAction.REFRESH_AND_CONNECT)
                }
            }
        }

    suspend fun requestPairing(
        expectedPeer: FormalLanPeerSnapshot,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanPairingCandidate = withContext(Dispatchers.IO) {
        when (val existing = lookupAuthority(expectedPeer.deviceId)) {
            FormalLanAuthorityLookup.Absent -> Unit
            FormalLanAuthorityLookup.InactiveBlocked ->
                fail(FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED)
            is FormalLanAuthorityLookup.ActiveNeedsExplicitPairing -> {
                if (
                    existing.protocolPublicKeyFingerprint !=
                    expectedPeer.advertisedProtocolFingerprint
                ) {
                    fail(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH)
                }
            }
            is FormalLanAuthorityLookup.ActiveVerified -> {
                if (
                    existing.authority.protocolPublicKeyFingerprint !=
                    expectedPeer.advertisedProtocolFingerprint
                ) {
                    fail(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH)
                }
                fail(FormalLanPeerFailureReason.PAIRING_ALREADY_TRUSTED)
            }
        }
        val result = try {
            pibPort.request(expectedPeer)
        } catch (e: CancellationException) {
            throw e
        } catch (e: PibPairingClient.PairingError) {
            throw FormalLanPeerException(FormalLanPeerFailureReason.PAIRING_FAILED, cause = e)
        }
        val responderIds = (listOf(result.macDeviceId) + result.macAliases)
            .map(::normalizedCanonicalField)
            .filter(String::isNotEmpty)
            .toSet()
        if (
            expectedPeer.deviceId !in responderIds ||
            normalizedFingerprint(result.macFingerprint) !=
            expectedPeer.advertisedProtocolFingerprint
        ) {
            fail(FormalLanPeerFailureReason.PAIRING_BINDING_MISMATCH)
        }
        requireCurrentPeer(expectedPeer, currentPeer)
        FormalLanPairingCandidate(
            macName = result.macDeviceName ?: expectedPeer.displayName,
            macDeviceId = result.macDeviceId,
            discoveryPeerKey = expectedPeer.deviceId,
            sasCode = result.sasCode,
            macFingerprint = result.macFingerprint,
            macSigningAlgorithm = result.macSigningAlgorithm,
            expectedSnapshot = expectedPeer,
            transcript = result
        )
    }

    suspend fun confirmPairingAndRefresh(
        candidate: FormalLanPairingCandidate,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanReadyAuthorization = withContext(Dispatchers.IO) {
        requireCurrentPeer(candidate.expectedSnapshot, currentPeer)
        val confirmedRecord = try {
            pibPort.confirm(candidate.expectedSnapshot, candidate.transcript)
        } catch (e: CancellationException) {
            throw e
        } catch (e: PibPairingClient.PairingError.TrustPersistence) {
            throw FormalLanPeerException(
                reason = FormalLanPeerFailureReason.LOCAL_TRUST_PERSISTENCE_FAILED,
                pibFinalAckVerified = e.finalAckVerified,
                localTrustRollbackConfirmed = e.rollbackConfirmed,
                cause = e
            )
        } catch (e: PibPairingClient.PairingError) {
            throw FormalLanPeerException(FormalLanPeerFailureReason.PAIRING_FAILED, cause = e)
        }
        try {
            val confirmedAuthority = FormalLanAuthoritySnapshot.from(confirmedRecord)
            requireAuthorityMatchesPeer(confirmedAuthority, candidate.expectedSnapshot)
            val durableAuthority = requirePinnedAuthority(candidate.expectedSnapshot)
            if (durableAuthority != confirmedAuthority) {
                fail(FormalLanPeerFailureReason.PAIRING_BINDING_MISMATCH)
            }
            requireCurrentPeer(candidate.expectedSnapshot, currentPeer)
            refresh(candidate.expectedSnapshot, durableAuthority)
            finalizeAuthorization(
                expectedPeer = candidate.expectedSnapshot,
                expectedAuthority = durableAuthority,
                currentPeer = currentPeer
            )
        } catch (e: FormalLanPeerException) {
            throw if (e.durablePibReceiptObtained) {
                e
            } else {
                FormalLanPeerException(
                    reason = e.reason,
                    durablePibReceiptObtained = true,
                    cause = e
                )
            }
        } catch (e: IllegalArgumentException) {
            throw FormalLanPeerException(
                reason = FormalLanPeerFailureReason.PAIRING_BINDING_MISMATCH,
                durablePibReceiptObtained = true,
                cause = e
            )
        }
    }

    /** Existing PIB trust explicitly refreshes SKR before connection. */
    suspend fun refreshAndAuthorize(
        expectedPeer: FormalLanPeerSnapshot,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanReadyAuthorization = withContext(Dispatchers.IO) {
        val authority = requirePinnedAuthority(expectedPeer)
        requireCurrentPeer(expectedPeer, currentPeer)
        refresh(expectedPeer, authority)
        finalizeAuthorization(expectedPeer, authority, currentPeer)
    }

    /** Remote click refreshes only when formal durable X-Wing material is absent. */
    suspend fun authorizeRemoteConnect(
        expectedPeer: FormalLanPeerSnapshot,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanReadyAuthorization = withContext(Dispatchers.IO) {
        val authority = requirePinnedAuthority(expectedPeer)
        if (!hasFormalXWing(expectedPeer.deviceId)) {
            requireCurrentPeer(expectedPeer, currentPeer)
            refresh(expectedPeer, authority)
        }
        finalizeAuthorization(expectedPeer, authority, currentPeer)
    }

    /**
     * Authorizes a remote-only route without attempting PIB or SKR I/O.
     *
     * The existing ProductSession proves the route separately; this method only proves that the
     * peer also has an exact durable product pin and formal X-Wing material. Missing material is a
     * hard failure so an ALLOW_ONCE session can never be promoted into persistent trust here.
     */
    suspend fun authorizeDurableProductSessionRoute(
        deviceId: String,
        advertisedProtocolFingerprint: String
    ): FormalLanDurableRouteAuthorization = withContext(Dispatchers.IO) {
        if (
            !TrustedPeerDeviceIdValidation.isCanonical(deviceId) ||
            normalizedFingerprint(advertisedProtocolFingerprint) !=
            advertisedProtocolFingerprint
        ) {
            fail(FormalLanPeerFailureReason.INVALID_ROUTE_SNAPSHOT)
        }
        val authority = readAuthority(deviceId)
            ?: fail(FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED)
        if (
            deviceId !in authority.allDeviceIds ||
            advertisedProtocolFingerprint != authority.protocolPublicKeyFingerprint
        ) {
            fail(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH)
        }
        if (!hasFormalXWing(deviceId)) {
            fail(FormalLanPeerFailureReason.X_WING_REQUIRED)
        }
        FormalLanDurableRouteAuthorization(
            authorityDeviceIds = authority.allDeviceIds,
            pinnedProtocolFingerprint = authority.protocolPublicKeyFingerprint
        )
    }

    private suspend fun refresh(
        peer: FormalLanPeerSnapshot,
        authority: FormalLanAuthoritySnapshot
    ) {
        try {
            skrPort.refresh(peer, authority.protocolPublicKeyFingerprint)
        } catch (e: CancellationException) {
            throw e
        } catch (e: SignedLanKemRefreshClient.RefreshError.Persistence) {
            throw FormalLanPeerException(
                FormalLanPeerFailureReason.KEM_PERSISTENCE_FAILED,
                cause = e
            )
        } catch (e: SignedLanKemRefreshClient.RefreshError) {
            throw FormalLanPeerException(FormalLanPeerFailureReason.REFRESH_FAILED, cause = e)
        }
    }

    private fun finalizeAuthorization(
        expectedPeer: FormalLanPeerSnapshot,
        expectedAuthority: FormalLanAuthoritySnapshot,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanReadyAuthorization {
        val current = requireCurrentPeer(expectedPeer, currentPeer)
        val currentAuthority = requirePinnedAuthority(current)
        if (currentAuthority != expectedAuthority) {
            fail(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH)
        }
        if (!hasFormalXWing(current.deviceId)) {
            fail(FormalLanPeerFailureReason.X_WING_REQUIRED)
        }
        return FormalLanReadyAuthorization(
            peer = current,
            authorityDeviceIds = currentAuthority.allDeviceIds,
            pinnedProtocolFingerprint = currentAuthority.protocolPublicKeyFingerprint
        )
    }

    private fun requireCurrentPeer(
        expected: FormalLanPeerSnapshot,
        currentPeer: () -> FormalLanPeerSnapshot?
    ): FormalLanPeerSnapshot {
        val current = currentPeer()
            ?: fail(FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED)
        if (!expected.sameSecuritySnapshot(current)) {
            fail(FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED)
        }
        return current
    }

    private fun requirePinnedAuthority(peer: FormalLanPeerSnapshot): FormalLanAuthoritySnapshot {
        val authority = readAuthority(peer.deviceId)
            ?: fail(FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED)
        requireAuthorityMatchesPeer(authority, peer)
        return authority
    }

    private fun requireAuthorityMatchesPeer(
        authority: FormalLanAuthoritySnapshot,
        peer: FormalLanPeerSnapshot
    ) {
        if (
            peer.deviceId !in authority.allDeviceIds ||
            authority.protocolPublicKeyFingerprint != peer.advertisedProtocolFingerprint
        ) {
            fail(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH)
        }
    }

    private fun lookupAuthority(deviceId: String): FormalLanAuthorityLookup = try {
        authorityPort.lookupAuthority(deviceId)
    } catch (e: CancellationException) {
        throw e
    } catch (e: TrustedPeerStoreCorruptionException) {
        throw FormalLanPeerException(
            FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED,
            cause = e
        )
    }

    private fun readAuthority(deviceId: String): FormalLanAuthoritySnapshot? =
        when (val lookup = lookupAuthority(deviceId)) {
            FormalLanAuthorityLookup.Absent,
            is FormalLanAuthorityLookup.ActiveNeedsExplicitPairing -> null
            FormalLanAuthorityLookup.InactiveBlocked ->
                fail(FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED)
            is FormalLanAuthorityLookup.ActiveVerified -> lookup.authority
        }

    private fun hasFormalXWing(deviceId: String): Boolean = try {
        authorityPort.readFormalKem(deviceId).xWingPublicKey?.size ==
            P2PXWingKem.XWING_PUBLIC_KEY_SIZE
    } catch (e: CancellationException) {
        throw e
    } catch (e: RuntimeException) {
        throw FormalLanPeerException(
            FormalLanPeerFailureReason.KEM_PERSISTENCE_FAILED,
            cause = e
        )
    }

    private fun fail(reason: FormalLanPeerFailureReason): Nothing =
        throw FormalLanPeerException(reason)
}

private class PersistentFormalLanAuthorityPort(
    private val identity: LocalP2PIdentity,
    private val peerKemKeyStore: PeerKemKeyStore
) : FormalLanAuthorityPort {
    override fun lookupAuthority(deviceId: String): FormalLanAuthorityLookup {
        val store = identity.trustedPeerStore()
        val canonical = store.findRecordByKnownDeviceIdIncludingInactiveReadOnly(deviceId)
            ?: return FormalLanAuthorityLookup.Absent
        if (canonical.lifecycleState != TrustedPeerLifecycleState.ACTIVE) {
            return FormalLanAuthorityLookup.InactiveBlocked
        }
        val canonicalFingerprint = normalizedFingerprint(canonical.protocolPublicKeyFingerprint)
            ?: throw TrustedPeerStoreCorruptionException(
                "active canonical authority has an invalid protocol fingerprint"
            )
        if (canonical.verificationOrigin != TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1) {
            return FormalLanAuthorityLookup.ActiveNeedsExplicitPairing(canonicalFingerprint)
        }
        return try {
            FormalLanAuthorityLookup.ActiveVerified(FormalLanAuthoritySnapshot.from(canonical))
        } catch (e: IllegalArgumentException) {
            throw TrustedPeerStoreCorruptionException(
                "active authenticated authority metadata is invalid",
                e
            )
        }
    }

    override fun readFormalKem(deviceId: String): PeerKemKeyStore.PeerKemPublicKeys =
        peerKemKeyStore.loadVerifiedReadOnly(deviceId)
}

private class ProductFormalLanPibPort(
    private val client: PibPairingClient
) : FormalLanPibPort {
    override suspend fun request(snapshot: FormalLanPeerSnapshot): PibPairingClient.PairingResult =
        client.requestPairing(
            host = snapshot.handshake.hostAddress,
            port = snapshot.handshake.port,
            targetDeviceId = snapshot.deviceId
        )

    override suspend fun confirm(
        snapshot: FormalLanPeerSnapshot,
        result: PibPairingClient.PairingResult
    ): TrustedPeerRecord = client.confirmPairing(
        host = snapshot.handshake.hostAddress,
        port = snapshot.handshake.port,
        result = result
    )
}

private class ProductFormalLanSkrPort(
    private val client: SignedLanKemRefreshClient
) : FormalLanSkrPort {
    override suspend fun refresh(
        snapshot: FormalLanPeerSnapshot,
        pinnedProtocolFingerprint: String
    ): SignedLanKemRefreshClient.RefreshResult = client.refresh(
        SignedLanKemRefreshClient.Target(
            endpoint = snapshot.handshake.resolvedEndpoint(),
            deviceId = snapshot.deviceId,
            pinnedProtocolFingerprint = pinnedProtocolFingerprint,
            bonjourEndpointDigest = snapshot.endpointDigest
        )
    )
}

private fun normalizedServiceType(raw: String): String =
    raw.trim().lowercase(Locale.ROOT).removePrefix(".").removeSuffix(".")

private fun normalizedCanonicalField(raw: String): String {
    val value = raw.trim()
    return value.takeIf {
        it.isNotEmpty() && it.none { char ->
            char == '\n' || char == '\r' || char == '=' || char.code < 0x20 || char.code == 0x7f
        }
    }.orEmpty()
}

private fun normalizedFingerprint(raw: String?): String? =
    raw?.trim()?.lowercase(Locale.ROOT)?.takeIf { value ->
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
    }

private fun sha256Hex(value: ByteArray): String = MessageDigest.getInstance("SHA-256")
    .digest(value)
    .joinToString(separator = "") { byte ->
        "%02x".format(Locale.ROOT, byte.toInt() and 0xff)
    }
