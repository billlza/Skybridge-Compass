package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.SwiftDateSeconds
import com.skybridge.compass.shared.productsession.AuthenticatedProductRouteBinding
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionAuthorityStore
import com.skybridge.compass.shared.productsession.ProductSessionMutationResult
import com.skybridge.compass.shared.productsession.ProductSessionOwner

data class AuthenticatedRouteBindingValidationContext(
    val sessionOwner: ProductSessionOwner,
    val localDeviceId: String,
    val localProtocolPublicKeyFingerprint: String,
    val expectedRemoteDeviceId: String,
    val expectedRemotePublicKeyFingerprint: String,
    val sessionHashHex: String,
    val transcriptPrefixHex: String,
    val nowEpochMillis: Long,
    val maxTtlMillis: Long = 10 * 60 * 1000,
    val acceptedFutureSkewMillis: Long = 2 * 60 * 1000
) {
    val sessionId: String
        get() = sessionOwner.sessionId

    init {
        require(localDeviceId.isNotBlank()) { "route-binding validation localDeviceId is empty" }
        require(localProtocolPublicKeyFingerprint.isLowerHex(64)) {
            "route-binding validation localProtocolPublicKeyFingerprint is invalid"
        }
        require(expectedRemoteDeviceId.isNotBlank()) { "route-binding validation expectedRemoteDeviceId is empty" }
        require(expectedRemotePublicKeyFingerprint.isLowerHex(64)) {
            "route-binding validation expectedRemotePublicKeyFingerprint is invalid"
        }
        require(sessionHashHex.isLowerHex(16)) { "route-binding validation sessionHashHex is invalid" }
        require(transcriptPrefixHex.isLowerHex(16)) { "route-binding validation transcriptPrefixHex is invalid" }
        require(nowEpochMillis > 0) { "route-binding validation nowEpochMillis must be positive" }
        require(maxTtlMillis in 1..3_600_000) { "route-binding validation maxTtlMillis is out of range" }
        require(acceptedFutureSkewMillis in 0..600_000) {
            "route-binding validation acceptedFutureSkewMillis is out of range"
        }
    }
}

class AuthenticatedRouteBindingValidationException(message: String) : IllegalArgumentException(message)

class AuthenticatedRouteBindingConsumer(
    private val store: ProductSessionAuthorityStore
) {
    fun consume(
        payload: AppMessage.AuthenticatedRouteBindingPayload,
        context: AuthenticatedRouteBindingValidationContext
    ) {
        val binding = validate(payload, context)
        val mutation = store.upsertEstablishedRouteBinding(
            owner = context.sessionOwner,
            remoteDeviceId = payload.localDeviceId,
            remotePublicKeyFingerprint = payload.routeAuthorityProtocolPublicKeyFingerprint,
            binding = binding,
            nowEpochMillis = context.nowEpochMillis
        )
        when (mutation) {
            ProductSessionMutationResult.APPLIED -> Unit
            ProductSessionMutationResult.STALE_OWNER ->
                throw AuthenticatedRouteBindingValidationException("route-binding session owner is stale")
            ProductSessionMutationResult.OWNER_NOT_ACTIVE ->
                throw AuthenticatedRouteBindingValidationException("route-binding session owner is not active")
        }
    }

    fun validate(
        payload: AppMessage.AuthenticatedRouteBindingPayload,
        context: AuthenticatedRouteBindingValidationContext
    ): AuthenticatedProductRouteBinding {
        val kind = ProductRouteKind.fromWireName(payload.kind)
            ?: throw AuthenticatedRouteBindingValidationException("unsupported route-binding kind")
        val canonicalServiceType = ProductRouteBindingProtocol.canonicalServiceType(payload.serviceType)
        if (canonicalServiceType != kind.serviceType) {
            throw AuthenticatedRouteBindingValidationException("route-binding serviceType does not match kind")
        }
        val canonicalInstanceName = ProductRouteBindingProtocol.canonicalInstanceName(
            rawInstanceName = payload.instanceName,
            rawServiceType = payload.serviceType
        ) ?: throw AuthenticatedRouteBindingValidationException(
            "route-binding instanceName does not match serviceType"
        )
        if (payload.endpointProvenance != ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD) {
            throw AuthenticatedRouteBindingValidationException("unsupported route-binding endpoint provenance")
        }

        val localRouteAuthorityDeviceId = payload.localDeviceId.trim()
        val receiverDeviceId = payload.remoteDeviceId.trim()
        if (localRouteAuthorityDeviceId != context.expectedRemoteDeviceId) {
            throw AuthenticatedRouteBindingValidationException("route-binding remote authority device mismatch")
        }
        if (receiverDeviceId != context.localDeviceId) {
            throw AuthenticatedRouteBindingValidationException("route-binding receiver device mismatch")
        }
        if (payload.routeAuthorityProtocolPublicKeyFingerprint != context.expectedRemotePublicKeyFingerprint) {
            throw AuthenticatedRouteBindingValidationException("route-binding authority fingerprint mismatch")
        }
        if (payload.remoteProtocolPublicKeyFingerprint != context.localProtocolPublicKeyFingerprint) {
            throw AuthenticatedRouteBindingValidationException("route-binding receiver fingerprint mismatch")
        }
        if (payload.sessionHashHex != context.sessionHashHex) {
            throw AuthenticatedRouteBindingValidationException("route-binding session hash mismatch")
        }
        if (payload.transcriptPrefixHex != context.transcriptPrefixHex) {
            throw AuthenticatedRouteBindingValidationException("route-binding transcript prefix mismatch")
        }

        val sentAtEpochMillis = SwiftDateSeconds.toUnixEpochMillis(payload.sentAt)
        val expiresAtEpochMillis = SwiftDateSeconds.toUnixEpochMillis(payload.expiresAt)
        if (expiresAtEpochMillis <= sentAtEpochMillis) {
            throw AuthenticatedRouteBindingValidationException("route-binding validity window is invalid")
        }
        if (sentAtEpochMillis > context.nowEpochMillis + context.acceptedFutureSkewMillis) {
            throw AuthenticatedRouteBindingValidationException("route-binding sentAt is too far in the future")
        }
        if (expiresAtEpochMillis <= context.nowEpochMillis) {
            throw AuthenticatedRouteBindingValidationException("route-binding is expired")
        }
        if (expiresAtEpochMillis - sentAtEpochMillis > context.maxTtlMillis) {
            throw AuthenticatedRouteBindingValidationException("route-binding TTL is too long")
        }

        return AuthenticatedProductRouteBinding(
            kind = kind,
            serviceType = canonicalServiceType,
            instanceName = canonicalInstanceName,
            hostName = payload.hostName.trim(),
            port = payload.port,
            endpointProvenance = payload.endpointProvenance,
            sessionHashHex = payload.sessionHashHex,
            transcriptPrefixHex = payload.transcriptPrefixHex,
            expiresAtEpochMillis = expiresAtEpochMillis
        )
    }
}

fun unsignedLongHex16(value: Long): String =
    java.lang.Long.toUnsignedString(value, 16).padStart(16, '0')

private fun String.isLowerHex(expectedLength: Int): Boolean =
    length == expectedLength && all { it in '0'..'9' || it in 'a'..'f' }
