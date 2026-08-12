package com.skybridge.compass.core.p2p

import java.util.Locale

/** Durable result of accepting KEM material from the currently authenticated product session. */
internal enum class AuthenticatedPairingPersistenceResult {
    TRUST_AND_KEM_DURABLE,
    KEM_DURABLE_UNDER_EXISTING_TRUST,
    SESSION_ONLY
}

internal data class AuthenticatedPairingPersistenceOutcome(
    val disposition: AuthenticatedPairingPersistenceResult,
    val validatedKemPublicKeys: PeerKemKeyStore.PeerKemPublicKeys,
    val normalizedPeerIds: Set<String>,
    val observedProtocolFingerprint: String
)

/** Canonical binding syntax shared by durable pairing and owner-scoped session material. */
internal object AuthenticatedPairingBindingNormalization {
    fun peerId(raw: String): String? = raw.trim().takeIf { value ->
        value.isNotEmpty() &&
            value.length <= MAX_PEER_ID_LENGTH &&
            value.none { it.code < 0x20 || it.code == 0x7f || it == '=' }
    }

    fun protocolFingerprint(raw: String): String? =
        raw.trim().lowercase(Locale.ROOT).takeIf { value ->
            value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        }

    private const val MAX_PEER_ID_LENGTH = 256
}

/**
 * Cross-store failure after an explicit trust decision was already durably recorded.
 *
 * Trusted-peer and KEM preferences are intentionally separate stores, so they cannot form one
 * atomic transaction. Once the user-approved authority is durable it must not be deleted merely
 * because the subsequent KEM write fails. Callers surface this typed partial state and may retry
 * only the KEM refresh under the still-active authority.
 */
internal class AuthenticatedPairingPartialPersistenceException(
    message: String,
    cause: Throwable
) : IllegalStateException(message, cause)

internal data class AuthenticatedPairingAttempt(
    val generation: Long,
    val observedProtocolFingerprint: String
)

/**
 * Linearization gate between authenticated-handshake replacement/close and post-approval writes.
 * The approval wait happens outside this gate; only the exact recheck plus synchronous durable
 * mutation is protected, so either the old attempt commits first or replacement completes first.
 */
internal class AuthenticatedPairingAttemptGate {
    private val lock = Any()
    private var generation = 0L
    private var observedProtocolFingerprint: String? = null

    fun establishIfActive(
        observedProtocolFingerprint: String,
        isActive: () -> Boolean,
        onEstablished: () -> Unit = {}
    ): AuthenticatedPairingAttempt? = synchronized(lock) {
        if (!isActive()) return@synchronized null
        onEstablished()
        generation = Math.addExact(generation, 1L)
        this.observedProtocolFingerprint = observedProtocolFingerprint
        AuthenticatedPairingAttempt(generation, observedProtocolFingerprint)
    }

    fun clear() = synchronized(lock) {
        generation = Math.addExact(generation, 1L)
        observedProtocolFingerprint = null
    }

    fun snapshot(): AuthenticatedPairingAttempt? = synchronized(lock) {
        observedProtocolFingerprint?.let { AuthenticatedPairingAttempt(generation, it) }
    }

    fun <T : Any> runIfCurrent(
        attempt: AuthenticatedPairingAttempt,
        action: () -> T
    ): T? = synchronized(lock) {
        if (generation != attempt.generation ||
            observedProtocolFingerprint != attempt.observedProtocolFingerprint
        ) {
            return@synchronized null
        }
        action()
    }
}

/**
 * Orders product-session persistence around the authority boundary shared by TCP and WebRTC.
 * Network/session ownership must be checked by the caller immediately before invoking this
 * synchronous operation.
 */
internal class AuthenticatedPairingPersistence(
    private val trustedPeerStore: TrustedPeerStore,
    private val peerKemStore: PeerKemKeyStore
) {
    fun persistApprovedAttempt(
        decision: PairingTrustDecision,
        declaredDeviceId: String,
        aliasIds: Collection<String>,
        observedProtocolFingerprint: String,
        deviceName: String?,
        protocolSigningAlgorithm: String?,
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?
    ): AuthenticatedPairingPersistenceResult = persistApprovedAttemptWithOutcome(
        decision = decision,
        declaredDeviceId = declaredDeviceId,
        aliasIds = aliasIds,
        observedProtocolFingerprint = observedProtocolFingerprint,
        deviceName = deviceName,
        protocolSigningAlgorithm = protocolSigningAlgorithm,
        kemPublicKeys = kemPublicKeys,
        platform = platform,
        osVersion = osVersion
    ).disposition

    fun persistApprovedAttemptWithOutcome(
        decision: PairingTrustDecision,
        declaredDeviceId: String,
        aliasIds: Collection<String>,
        observedProtocolFingerprint: String,
        deviceName: String?,
        protocolSigningAlgorithm: String?,
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?
    ): AuthenticatedPairingPersistenceOutcome {
        require(decision != PairingTrustDecision.DECLINE) {
            "declined pairing attempts cannot mutate persistent state"
        }
        val normalizedDeclaredDeviceId = normalizePeerId(declaredDeviceId)
        val persistenceIds = normalizePeerIds(aliasIds + normalizedDeclaredDeviceId)
        val normalizedObservedFingerprint =
            AuthenticatedPairingBindingNormalization.protocolFingerprint(
                observedProtocolFingerprint
            )
            ?: throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session protocol fingerprint is invalid",
                rollbackConfirmed = true
            )
        val validatedKeys = try {
            PeerKemKeyStoreRecords.materialize(
                kemPublicKeys = kemPublicKeys,
                platform = platform,
                osVersion = osVersion
            )
        } catch (error: IllegalArgumentException) {
            throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session KEM key material is invalid",
                rollbackConfirmed = true,
                cause = error
            )
        }
        if (validatedKeys.qPeriaptPublicKey == null &&
            validatedKeys.xWingPublicKey == null &&
            validatedKeys.mlKem768PublicKey == null
        ) {
            throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session exchange contains no eligible KEM key",
                rollbackConfirmed = true
            )
        }
        var approvedTrustCommitted = false

        if (decision == PairingTrustDecision.TRUST_ALWAYS) {
            trustedPeerStore.upsertExplicitlyApprovedCurrentPathAuthority(
                deviceId = normalizedDeclaredDeviceId,
                name = deviceName,
                protocolSigningAlgorithm = protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = normalizedObservedFingerprint,
                aliasIds = persistenceIds
            )
            approvedTrustCommitted = true
            val exactAuthorityRetained = try {
                trustedPeerStore.findExactVerifiedAuthorityReadOnly(
                    deviceIds = persistenceIds,
                    protocolPublicKeyFingerprint = normalizedObservedFingerprint
                ) != null
            } catch (error: RuntimeException) {
                throw AuthenticatedPairingPartialPersistenceException(
                    message = "approved trust commit completed but its exact durable postcondition could not be read",
                    cause = error
                )
            }
            if (!exactAuthorityRetained) {
                throw AuthenticatedPairingPartialPersistenceException(
                    message = "approved trust commit completed but its exact durable postcondition was not retained",
                    cause = TrustedPeerStorePersistenceException(
                        "approved authority failed exact durable reread"
                    )
                )
            }
        } else if (trustedPeerStore.findExactVerifiedAuthorityReadOnly(
                deviceIds = persistenceIds,
                protocolPublicKeyFingerprint = normalizedObservedFingerprint
            ) == null
        ) {
            // ALLOW_ONCE authorizes only this already-authenticated session. It must not create a
            // durable trust or KEM origin when no exact active product authority predates it.
            return outcome(
                disposition = AuthenticatedPairingPersistenceResult.SESSION_ONLY,
                validatedKeys = validatedKeys,
                persistenceIds = persistenceIds,
                normalizedObservedFingerprint = normalizedObservedFingerprint
            )
        }

        try {
            peerKemStore.saveForAliases(
                peerIds = persistenceIds,
                kemPublicKeys = kemPublicKeys,
                platform = platform,
                osVersion = osVersion,
                verifiedProtocolFingerprint = normalizedObservedFingerprint
            )
        } catch (error: RuntimeException) {
            if (approvedTrustCommitted) {
                throw AuthenticatedPairingPartialPersistenceException(
                    message = "approved trust is durable but authenticated KEM persistence failed",
                    cause = error
                )
            }
            throw error
        }

        val disposition = if (approvedTrustCommitted) {
            AuthenticatedPairingPersistenceResult.TRUST_AND_KEM_DURABLE
        } else {
            AuthenticatedPairingPersistenceResult.KEM_DURABLE_UNDER_EXISTING_TRUST
        }
        return outcome(
            disposition = disposition,
            validatedKeys = validatedKeys,
            persistenceIds = persistenceIds,
            normalizedObservedFingerprint = normalizedObservedFingerprint
        )
    }

    private fun outcome(
        disposition: AuthenticatedPairingPersistenceResult,
        validatedKeys: PeerKemKeyStore.PeerKemPublicKeys,
        persistenceIds: Set<String>,
        normalizedObservedFingerprint: String
    ): AuthenticatedPairingPersistenceOutcome = AuthenticatedPairingPersistenceOutcome(
        disposition = disposition,
        validatedKemPublicKeys = validatedKeys.deepCopy(),
        normalizedPeerIds = persistenceIds.toSet(),
        observedProtocolFingerprint = normalizedObservedFingerprint
    )

    private fun normalizePeerIds(rawPeerIds: Collection<String>): Set<String> {
        val normalized = rawPeerIds.map(::normalizePeerId).toSet()
        if (normalized.isEmpty()) {
            throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session has no peer identifier",
                rollbackConfirmed = true
            )
        }
        return normalized
    }

    private fun normalizePeerId(raw: String): String =
        AuthenticatedPairingBindingNormalization.peerId(raw)
            ?: throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session peer identifier is invalid",
                rollbackConfirmed = true
            )

    private fun PeerKemKeyStore.PeerKemPublicKeys.deepCopy() =
        PeerKemKeyStore.PeerKemPublicKeys(
            qPeriaptPublicKey = qPeriaptPublicKey?.copyOf(),
            xWingPublicKey = xWingPublicKey?.copyOf(),
            mlKem768PublicKey = mlKem768PublicKey?.copyOf()
        )
}
