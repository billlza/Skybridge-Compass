package com.skybridge.compass.shared.productsession

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import java.util.UUID

object ProductRouteBindingProtocol {
    const val ENDPOINT_PROVENANCE_RESOLVED_DNS_SD = "resolved-dns-sd-endpoint"
    const val CONTROL_SERVICE_TYPE = "_skybridge._tcp"
    const val FILE_TRANSFER_SERVICE_TYPE = "_skybridge-xfer._tcp"
    const val REMOTE_DESKTOP_SERVICE_TYPE = "_skybridge-rd._tcp"
    const val LEGACY_FILE_TRANSFER_SERVICE_TYPE = "_skybridge-transfer._tcp"
    const val LEGACY_REMOTE_DESKTOP_SERVICE_TYPE = "_skybridge-remote._tcp"

    fun canonicalServiceType(raw: String?): String? =
        when (raw?.trim()?.lowercase(Locale.ROOT)?.removeSuffix(".")) {
            CONTROL_SERVICE_TYPE -> CONTROL_SERVICE_TYPE
            FILE_TRANSFER_SERVICE_TYPE,
            LEGACY_FILE_TRANSFER_SERVICE_TYPE -> FILE_TRANSFER_SERVICE_TYPE
            REMOTE_DESKTOP_SERVICE_TYPE,
            LEGACY_REMOTE_DESKTOP_SERVICE_TYPE -> REMOTE_DESKTOP_SERVICE_TYPE
            else -> null
        }

    fun acceptedServiceTypes(serviceType: String): List<String> =
        when (canonicalServiceType(serviceType)) {
            CONTROL_SERVICE_TYPE -> listOf(CONTROL_SERVICE_TYPE)
            FILE_TRANSFER_SERVICE_TYPE -> listOf(
                FILE_TRANSFER_SERVICE_TYPE,
                LEGACY_FILE_TRANSFER_SERVICE_TYPE
            )
            REMOTE_DESKTOP_SERVICE_TYPE -> listOf(
                REMOTE_DESKTOP_SERVICE_TYPE,
                LEGACY_REMOTE_DESKTOP_SERVICE_TYPE
            )
            else -> emptyList()
        }

    fun canonicalInstanceName(rawInstanceName: String, rawServiceType: String): String? {
        val canonicalServiceType = canonicalServiceType(rawServiceType) ?: return null
        val instanceName = rawInstanceName.trim().removeSuffix(".")
        val matchingSuffix = acceptedServiceTypes(canonicalServiceType)
            .asSequence()
            .map { ".$it.local" }
            .firstOrNull { suffix -> instanceName.endsWith(suffix, ignoreCase = true) }
            ?: return null
        val serviceName = instanceName.dropLast(matchingSuffix.length).trim()
        return serviceName
            .takeIf { it.isNotEmpty() }
            ?.let { "$it.$canonicalServiceType.local" }
    }
}

enum class ProductRouteKind(val wireName: String, val serviceType: String) {
    FILE_TRANSFER(
        wireName = "fileTransfer",
        serviceType = ProductRouteBindingProtocol.FILE_TRANSFER_SERVICE_TYPE
    ),
    REMOTE_DESKTOP(
        wireName = "remoteDesktop",
        serviceType = ProductRouteBindingProtocol.REMOTE_DESKTOP_SERVICE_TYPE
    );

    companion object {
        fun fromWireName(value: String): ProductRouteKind? =
            entries.firstOrNull { it.wireName == value }
    }
}

enum class ProductSessionState {
    ESTABLISHED,
    FAILED,
    DISCONNECTED
}

/**
 * In-memory capability identifying one exact product-session incarnation.
 *
 * [generation] orders replacements inside one manager. The private random lease keeps owners from
 * different managers distinct even when they use the same session id and generation. Callers must
 * retain this object and present it for every authority mutation; a session id alone is never an
 * ownership proof.
 */
class ProductSessionOwner private constructor(
    val sessionId: String,
    val generation: Long,
    private val leaseId: UUID
) {
    init {
        require(sessionId.isNotBlank()) { "product session owner sessionId is empty" }
        require(generation > 0) { "product session owner generation must be positive" }
    }

    override fun equals(other: Any?): Boolean =
        other is ProductSessionOwner &&
            sessionId == other.sessionId &&
            generation == other.generation &&
            leaseId == other.leaseId

    override fun hashCode(): Int {
        var result = sessionId.hashCode()
        result = 31 * result + generation.hashCode()
        result = 31 * result + leaseId.hashCode()
        return result
    }

    override fun toString(): String =
        "ProductSessionOwner(sessionId=<redacted:${sessionId.length}>, generation=$generation)"

    companion object {
        fun create(sessionId: String, generation: Long): ProductSessionOwner =
            ProductSessionOwner(
                sessionId = sessionId,
                generation = generation,
                leaseId = UUID.randomUUID()
            )
    }
}

enum class ProductSessionOwnerClaimResult {
    CLAIMED,
    REPLACED_EXISTING_OWNER,
    ALREADY_CURRENT,
    CAPACITY_REACHED
}

enum class ProductSessionMutationResult {
    APPLIED,
    STALE_OWNER,
    OWNER_NOT_ACTIVE
}

data class AuthenticatedProductRouteBinding(
    val kind: ProductRouteKind,
    val serviceType: String,
    val instanceName: String,
    val hostName: String,
    val port: Int,
    val endpointProvenance: String,
    val sessionHashHex: String,
    val transcriptPrefixHex: String,
    val expiresAtEpochMillis: Long
) {
    init {
        require(serviceType.isNotBlank()) { "route binding serviceType is empty" }
        require(instanceName.isNotBlank()) { "route binding instanceName is empty" }
        require(hostName.isNotBlank()) { "route binding hostName is empty" }
        require(hostName.none { it.isWhitespace() || it.code < 0x20 }) {
            "route binding hostName is invalid"
        }
        require(port in 1..65535) { "route binding port is out of range" }
        require(endpointProvenance == ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD) {
            "route binding endpointProvenance is unsupported"
        }
        require(sessionHashHex.isLowerHex(16)) { "route binding sessionHashHex is invalid" }
        require(transcriptPrefixHex.isLowerHex(16)) { "route binding transcriptPrefixHex is invalid" }
        require(expiresAtEpochMillis > 0) { "route binding expiresAtEpochMillis must be positive" }
    }

    internal fun sameRouteIdentity(other: AuthenticatedProductRouteBinding): Boolean =
        kind == other.kind &&
            normalizeServiceType(serviceType) == normalizeServiceType(other.serviceType) &&
            instanceName == other.instanceName &&
            hostName == other.hostName &&
            port == other.port
}

data class ProductSessionAuthority(
    val owner: ProductSessionOwner,
    val sessionId: String,
    val remoteDeviceId: String,
    val remotePublicKeyFingerprint: String,
    val state: ProductSessionState,
    val expiresAtEpochMillis: Long,
    val authenticatedRouteBindings: List<AuthenticatedProductRouteBinding>
) {
    init {
        require(sessionId.isNotBlank()) { "product sessionId is empty" }
        require(owner.sessionId == sessionId) { "product session owner does not match sessionId" }
        require(remoteDeviceId.isNotBlank()) { "product session remoteDeviceId is empty" }
        require(remotePublicKeyFingerprint.isLowerHex(64)) {
            "product session remotePublicKeyFingerprint is invalid"
        }
        require(expiresAtEpochMillis > 0) { "product session expiresAtEpochMillis must be positive" }
    }
}

interface ProductSessionAuthorityStore {
    val sessions: StateFlow<List<ProductSessionAuthority>>

    fun claimSession(owner: ProductSessionOwner): ProductSessionOwnerClaimResult

    fun upsertEstablishedRouteBinding(
        owner: ProductSessionOwner,
        remoteDeviceId: String,
        remotePublicKeyFingerprint: String,
        binding: AuthenticatedProductRouteBinding,
        nowEpochMillis: Long
    ): ProductSessionMutationResult

    fun markFailed(owner: ProductSessionOwner): ProductSessionMutationResult
    fun markDisconnected(owner: ProductSessionOwner): ProductSessionMutationResult

    /** Removes an authority and releases this exact owner. */
    fun clearSession(owner: ProductSessionOwner): ProductSessionMutationResult

    /** Removes established route bindings while retaining this owner for a rekeyed session. */
    fun clearEstablishedAuthority(owner: ProductSessionOwner): ProductSessionMutationResult

    fun clearExpired(nowEpochMillis: Long)
}

class InMemoryProductSessionAuthorityStore(
    private val maxSessions: Int = 8,
    private val maxBindingsPerSession: Int = 8
) : ProductSessionAuthorityStore {
    init {
        require(maxSessions in 1..32) { "maxSessions must be between 1 and 32" }
        require(maxBindingsPerSession in 1..32) { "maxBindingsPerSession must be between 1 and 32" }
    }

    private val lock = Any()
    private val activeOwnersBySessionId = linkedMapOf<String, ProductSessionOwner>()
    private val _sessions = MutableStateFlow<List<ProductSessionAuthority>>(emptyList())
    override val sessions: StateFlow<List<ProductSessionAuthority>> = _sessions.asStateFlow()

    override fun claimSession(owner: ProductSessionOwner): ProductSessionOwnerClaimResult =
        synchronized(lock) {
            val existing = activeOwnersBySessionId[owner.sessionId]
            if (existing == owner) {
                return@synchronized ProductSessionOwnerClaimResult.ALREADY_CURRENT
            }
            if (existing == null && activeOwnersBySessionId.size >= maxSessions) {
                return@synchronized ProductSessionOwnerClaimResult.CAPACITY_REACHED
            }

            activeOwnersBySessionId[owner.sessionId] = owner
            _sessions.value = _sessions.value.filterNot { it.sessionId == owner.sessionId }
            if (existing == null) {
                ProductSessionOwnerClaimResult.CLAIMED
            } else {
                ProductSessionOwnerClaimResult.REPLACED_EXISTING_OWNER
            }
        }

    override fun upsertEstablishedRouteBinding(
        owner: ProductSessionOwner,
        remoteDeviceId: String,
        remotePublicKeyFingerprint: String,
        binding: AuthenticatedProductRouteBinding,
        nowEpochMillis: Long
    ): ProductSessionMutationResult {
        require(remoteDeviceId.isNotBlank()) { "product session remoteDeviceId is empty" }
        require(remotePublicKeyFingerprint.isLowerHex(64)) {
            "product session remotePublicKeyFingerprint is invalid"
        }
        require(nowEpochMillis > 0) { "nowEpochMillis must be positive" }
        require(binding.expiresAtEpochMillis > nowEpochMillis) { "route binding is expired" }

        synchronized(lock) {
            ownerMutationRejection(owner)?.let { return it }
            val sessionId = owner.sessionId
            val retained = _sessions.value
                .filter { it.expiresAtEpochMillis > nowEpochMillis }
                .filterNot { it.sessionId == sessionId }

            val existing = _sessions.value.firstOrNull {
                it.sessionId == sessionId && it.owner == owner
            }
            val mergedBindings = ((existing?.authenticatedRouteBindings ?: emptyList())
                .filter { it.expiresAtEpochMillis > nowEpochMillis }
                .filterNot { it.sameRouteIdentity(binding) } + binding)
                .sortedWith(
                    compareBy<AuthenticatedProductRouteBinding> { it.expiresAtEpochMillis }
                        .thenBy { it.kind.name }
                        .thenBy { it.serviceType }
                        .thenBy { it.instanceName }
                        .thenBy { it.hostName }
                        .thenBy { it.port }
                )
                .takeLast(maxBindingsPerSession)

            val updatedSession = ProductSessionAuthority(
                owner = owner,
                sessionId = sessionId,
                remoteDeviceId = remoteDeviceId,
                remotePublicKeyFingerprint = remotePublicKeyFingerprint,
                state = ProductSessionState.ESTABLISHED,
                expiresAtEpochMillis = mergedBindings.maxOf { it.expiresAtEpochMillis },
                authenticatedRouteBindings = mergedBindings
            )

            _sessions.value = (retained + updatedSession)
                .sortedBy { it.expiresAtEpochMillis }
                .takeLast(maxSessions)
            return ProductSessionMutationResult.APPLIED
        }
    }

    override fun markFailed(owner: ProductSessionOwner): ProductSessionMutationResult =
        mark(owner, ProductSessionState.FAILED)

    override fun markDisconnected(owner: ProductSessionOwner): ProductSessionMutationResult =
        mark(owner, ProductSessionState.DISCONNECTED)

    override fun clearSession(owner: ProductSessionOwner): ProductSessionMutationResult =
        synchronized(lock) {
            ownerMutationRejection(owner)?.let { return@synchronized it }
            activeOwnersBySessionId.remove(owner.sessionId)
            _sessions.value = _sessions.value.filterNot {
                it.sessionId == owner.sessionId && it.owner == owner
            }
            ProductSessionMutationResult.APPLIED
        }

    override fun clearEstablishedAuthority(owner: ProductSessionOwner): ProductSessionMutationResult =
        synchronized(lock) {
            ownerMutationRejection(owner)?.let { return@synchronized it }
            _sessions.value = _sessions.value.filterNot {
                it.sessionId == owner.sessionId && it.owner == owner
            }
            ProductSessionMutationResult.APPLIED
        }

    /**
     * Clears expired published authorities only. Active owner claims intentionally remain: route
     * TTL expiry does not prove that the owning transport/session ended. Claims are released only
     * by an exact terminal mutation or exact clear, and their count is bounded by [maxSessions].
     */
    override fun clearExpired(nowEpochMillis: Long) {
        require(nowEpochMillis > 0) { "nowEpochMillis must be positive" }
        synchronized(lock) {
            _sessions.value = _sessions.value
                .mapNotNull { session ->
                    val bindings = session.authenticatedRouteBindings
                        .filter { it.expiresAtEpochMillis > nowEpochMillis }
                    if (session.expiresAtEpochMillis <= nowEpochMillis || bindings.isEmpty()) {
                        null
                    } else {
                        session.copy(
                            expiresAtEpochMillis = bindings.maxOf { it.expiresAtEpochMillis },
                            authenticatedRouteBindings = bindings
                        )
                    }
                }
        }
    }

    private fun mark(
        owner: ProductSessionOwner,
        state: ProductSessionState
    ): ProductSessionMutationResult = synchronized(lock) {
        ownerMutationRejection(owner)?.let { return@synchronized it }
        _sessions.value = _sessions.value.map { session ->
            if (session.sessionId == owner.sessionId && session.owner == owner) {
                session.copy(state = state, authenticatedRouteBindings = emptyList())
            } else {
                session
            }
        }
        activeOwnersBySessionId.remove(owner.sessionId)
        ProductSessionMutationResult.APPLIED
    }

    private fun ownerMutationRejection(owner: ProductSessionOwner): ProductSessionMutationResult? {
        val current = activeOwnersBySessionId[owner.sessionId]
            ?: return ProductSessionMutationResult.OWNER_NOT_ACTIVE
        return if (current == owner) {
            null
        } else {
            ProductSessionMutationResult.STALE_OWNER
        }
    }
}

internal fun normalizeServiceType(raw: String): String =
    ProductRouteBindingProtocol.canonicalServiceType(raw)
        ?: raw.trim().lowercase(Locale.ROOT).removeSuffix(".")

private fun String.isLowerHex(expectedLength: Int): Boolean =
    length == expectedLength && all { it in '0'..'9' || it in 'a'..'f' }
