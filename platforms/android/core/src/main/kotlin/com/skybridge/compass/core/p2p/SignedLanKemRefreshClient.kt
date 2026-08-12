package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PXWingKem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.SecureRandom

/** Minimal local identity surface consumed by SKR-1; keeps protocol orchestration testable. */
internal interface SignedLanKemRefreshIdentity {
    fun trustedPeerStore(): TrustedPeerStore
    fun requesterMlDsa65PublicKey(): ByteArray?
    fun deviceId(): String
}

private class ProductSignedLanKemRefreshIdentity(
    private val identity: LocalP2PIdentity
) : SignedLanKemRefreshIdentity {
    override fun trustedPeerStore(): TrustedPeerStore = identity.trustedPeerStore()

    override fun requesterMlDsa65PublicKey(): ByteArray? =
        identity.getOrCreateProtocolSigningKeys().mlDsa65PublicKeyRaw

    override fun deviceId(): String = identity.deviceId()
}

/** Post-PIB SKR-1 client. It never creates trust: an active authenticated PIB pin is mandatory. */
class SignedLanKemRefreshClient internal constructor(
    private val identity: SignedLanKemRefreshIdentity,
    private val peerKemKeyStore: PeerKemKeyStore,
    private val transport: BootstrapControlExchange = BootstrapControlTransport(),
    private val verifier: SignedLanKemRefreshVerifier = SignedLanKemRefreshVerifier(),
    private val secureRandom: SecureRandom = SecureRandom(),
    private val currentTimeMillis: () -> Long = System::currentTimeMillis,
    private val localXWingAvailable: () -> Boolean = P2PXWingKem::isAvailable
) {
    constructor(
        identity: LocalP2PIdentity,
        peerKemKeyStore: PeerKemKeyStore
    ) : this(
        identity = ProductSignedLanKemRefreshIdentity(identity),
        peerKemKeyStore = peerKemKeyStore,
        transport = BootstrapControlTransport(),
        verifier = SignedLanKemRefreshVerifier(),
        secureRandom = SecureRandom(),
        currentTimeMillis = System::currentTimeMillis,
        localXWingAvailable = P2PXWingKem::isAvailable
    )

    data class Target(
        val endpoint: ResolvedBootstrapControlEndpoint,
        val deviceId: String,
        val pinnedProtocolFingerprint: String,
        val bonjourEndpointDigest: String
    )

    data class RefreshResult(
        val deviceId: String,
        val aliases: List<String>,
        val keyId: String,
        val generation: Long,
        val expiresAtMillis: Long,
        val signedSuiteWireIds: List<Int>,
        val payloadHashHex: String
    )

    sealed class RefreshError(message: String, cause: Throwable? = null) : Exception(message, cause) {
        class Trust(message: String, cause: Throwable? = null) : RefreshError(message, cause)
        class Identity(message: String, cause: Throwable? = null) : RefreshError(message, cause)
        class Transport(message: String, cause: Throwable? = null) : RefreshError(message, cause)
        class Protocol(message: String, cause: Throwable? = null) : RefreshError(message, cause)
        class Persistence(message: String, cause: Throwable? = null) : RefreshError(message, cause)
    }

    suspend fun refresh(
        target: Target,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS
    ): RefreshResult = withContext(Dispatchers.IO) {
        val trustedPeer = try {
            identity.trustedPeerStore().findVerifiedRecordByKnownDeviceIdReadOnly(target.deviceId)
        } catch (e: TrustedPeerStoreCorruptionException) {
            throw RefreshError.Trust("trusted peer store is corrupted", e)
        } ?: throw RefreshError.Trust("active authenticated PIB pin is required")
        val targetFingerprint = SkrCanonical.normalizedFingerprint(target.pinnedProtocolFingerprint)
            ?: throw RefreshError.Trust("target protocol fingerprint is invalid")
        if (trustedPeer.protocolPublicKeyFingerprint != targetFingerprint) {
            throw RefreshError.Trust("advertised target fingerprint does not match the active PIB pin")
        }
        val targetDeviceId = SkrCanonical.normalizedToken(target.deviceId)
        val trustedIds = (trustedPeer.knownDeviceIds + trustedPeer.deviceId + trustedPeer.currentDeviceId)
            .distinct()
        if (targetDeviceId.isEmpty() || targetDeviceId !in trustedIds) {
            throw RefreshError.Trust("target device id does not resolve to the active PIB pin")
        }
        if (SkrCanonical.normalizedHex(target.bonjourEndpointDigest, exactLength = 64) == null) {
            throw RefreshError.Protocol("Bonjour endpoint digest is invalid")
        }

        val requesterPublicKey = try {
            identity.requesterMlDsa65PublicKey()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw RefreshError.Identity("local protocol identity is unavailable", e)
        } ?: throw RefreshError.Identity("SKR-1 requires the ML-DSA-65 identity used by PIB-1")
        val requesterFingerprint = try {
            ProtocolIdentityBinding.computeFingerprint(
                ProtocolSigningAlgorithm.ML_DSA_65,
                requesterPublicKey
            )
        } catch (e: IllegalArgumentException) {
            throw RefreshError.Identity("local protocol identity key is invalid", e)
        }
        val nonce = ByteArray(NONCE_BYTES).also(secureRandom::nextBytes)
        val nowMillis = currentTimeMillis()
        if (!localXWingAvailable()) {
            throw RefreshError.Identity("SKR-1 requires local X-Wing capability; hybrid suite is unavailable")
        }
        val request = SkrBootstrapWire.KemRefreshRequestPayload(
            requesterDeviceId = identity.deviceId(),
            targetDeviceId = targetDeviceId,
            requesterProtocolIdentityFingerprint = requesterFingerprint,
            targetProtocolIdentityFingerprint = targetFingerprint,
            requestedSuiteWireIds = listOf(
                P2PCryptoSuite.X_WING.wireId.toInt(),
                P2PCryptoSuite.MLKEM_768.wireId.toInt()
            ),
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            policyHashHex = SkrCanonical.policyHashHex(),
            routeScope = SkrCanonical.ROUTE_SCOPE_LAN,
            bonjourEndpointDigest = target.bonjourEndpointDigest,
            nonce = nonce,
            sentAt = PibBootstrapWire.unixMillisToReferenceSeconds(nowMillis)
        )
        val responseBytes = try {
            transport.exchange(
                host = target.endpoint.hostAddress,
                port = target.endpoint.port,
                body = SkrBootstrapWire.encodeRequest(request),
                timeoutMs = timeoutMs
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: BootstrapControlTransport.TransportException) {
            throw RefreshError.Transport(e.message ?: "SKR-1 transport failed", e)
        }
        val response = try {
            SkrBootstrapWire.decodeResponse(responseBytes)
        } catch (e: IllegalArgumentException) {
            throw RefreshError.Protocol("SKR-1 response is malformed", e)
        } catch (e: Exception) {
            throw RefreshError.Protocol("SKR-1 response decoding failed", e)
        }
        val signedPayload = when (response) {
            is SkrBootstrapWire.Response.Signed -> response.payload
            is SkrBootstrapWire.Response.Failure -> {
                val failure = response.payload
                throw RefreshError.Protocol(
                    "Mac rejected SKR-1 stage=${safeDiagnosticToken(failure.stage)} " +
                        "reasonCode=${safeDiagnosticToken(failure.reasonCode)}"
                )
            }
        }
        val minimumGeneration = try {
            peerKemKeyStore.maximumSignedRefreshGeneration(trustedIds + targetDeviceId)
        } catch (e: PeerKemKeyStoreCorruptionException) {
            throw RefreshError.Persistence("peer KEM provenance is corrupted", e)
        }
        val verified = try {
            verifier.verify(
                request = request,
                response = signedPayload,
                pinnedProtocolFingerprint = targetFingerprint,
                minimumGeneration = minimumGeneration,
                nowMillis = currentTimeMillis()
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: SignedLanKemRefreshVerificationUnavailableException) {
            throw RefreshError.Identity(e.message ?: "SKR-1 signature verifier is unavailable", e)
        } catch (e: SignedLanKemRefreshValidationException) {
            throw RefreshError.Protocol(e.message ?: "SKR-1 validation failed", e)
        }
        if (verified.allDeviceIds.any { it !in trustedIds }) {
            throw RefreshError.Trust("SKR-1 response attempted to expand the active PIB authority aliases")
        }

        try {
            peerKemKeyStore.saveSignedLanRefresh(
                peerIds = trustedIds + targetDeviceId,
                refresh = verified
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: PeerKemKeyStorePersistenceException) {
            throw RefreshError.Persistence(e.message ?: "SKR-1 persistence failed", e)
        }
        val durableKeys = try {
            peerKemKeyStore.loadVerifiedReadOnly(targetDeviceId)
        } catch (e: RuntimeException) {
            throw RefreshError.Persistence("durable SKR-1 re-read failed", e)
        }
        val durableSuiteWireIds = buildList {
            if (durableKeys.xWingPublicKey != null) add(P2PCryptoSuite.X_WING.wireId.toInt())
            if (durableKeys.mlKem768PublicKey != null) add(P2PCryptoSuite.MLKEM_768.wireId.toInt())
        }.sorted()
        if (durableSuiteWireIds != verified.signedSuiteWireIds) {
            throw RefreshError.Persistence("durable SKR-1 re-read does not match every signed suite")
        }
        RefreshResult(
            deviceId = verified.responseDeviceId,
            aliases = verified.aliases,
            keyId = verified.keyId,
            generation = verified.generation,
            expiresAtMillis = verified.expiresAtMillis,
            signedSuiteWireIds = verified.signedSuiteWireIds,
            payloadHashHex = verified.payloadHashHex
        )
    }

    private fun safeDiagnosticToken(raw: String): String =
        SkrCanonical.normalizedToken(raw).take(64).ifEmpty { "invalid" }

    private companion object {
        const val NONCE_BYTES = 24
        const val DEFAULT_TIMEOUT_MS = 30_000
    }
}
