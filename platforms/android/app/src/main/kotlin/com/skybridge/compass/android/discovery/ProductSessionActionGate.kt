package com.skybridge.compass.android.discovery

import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionAuthority
import com.skybridge.compass.shared.productsession.ProductSessionAuthorityStore
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.productsession.ProductSessionState
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProductSessionActionGate @Inject constructor(
    private val store: ProductSessionAuthorityStore
) {
    /**
     * Structural pre-dial gate for the direct-LAN PIB/SKR bootstrap lane.
     *
     * This deliberately does not require an already-established ProductSession (doing so would
     * make the bootstrap circular). Active pin and formal KEM authority are checked by the core
     * coordinator immediately before the formal client is created.
     */
    fun checkTrustedLanBootstrap(
        peer: FormalLanPeerSnapshot
    ): TrustedLanBootstrapGateDecision = try {
        peer.handshake.resolvedEndpoint()
        peer.remoteDesktop.resolvedEndpoint()
        if (
            peer.handshake.discoveryRevision != peer.remoteDesktop.discoveryRevision ||
            peer.handshake.advertisedDeviceId != peer.remoteDesktop.advertisedDeviceId ||
            peer.handshake.advertisedProtocolFingerprint !=
            peer.remoteDesktop.advertisedProtocolFingerprint
        ) {
            TrustedLanBootstrapGateDecision.Denied(
                TrustedLanBootstrapGateDenialReason.CrossRouteIdentityMismatch
            )
        } else {
            TrustedLanBootstrapGateDecision.Allowed
        }
    } catch (_: IllegalArgumentException) {
        TrustedLanBootstrapGateDecision.Denied(
            TrustedLanBootstrapGateDenialReason.InvalidResolvedRoute
        )
    }

    fun checkFileTransfer(
        target: DiscoveryPeerLaunchTarget,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): ProductActionGateDecision =
        check(target, ProductRouteKind.FILE_TRANSFER, nowEpochMillis)

    fun checkRemoteDesktop(
        target: DiscoveryPeerLaunchTarget,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): ProductActionGateDecision =
        check(target, ProductRouteKind.REMOTE_DESKTOP, nowEpochMillis)

    fun checkRemoteDesktop(
        target: ProductActionGateTarget,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): ProductActionGateDecision =
        check(target, ProductRouteKind.REMOTE_DESKTOP, nowEpochMillis)

    fun isRemoteDesktopAuthorizationCurrent(
        target: ProductActionGateTarget,
        expected: ProductActionGateDecision.Allowed,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): Boolean = checkRemoteDesktop(target, nowEpochMillis) == expected

    /**
     * Unified remote-control decision: preserve an exact established ProductSession route first;
     * only an exact dual-route snapshot may enter the separate PIB/SKR bootstrap lane.
     */
    fun decideRemoteDesktop(
        target: ProductActionGateTarget,
        formalPeer: FormalLanPeerSnapshot?,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): ProductRemoteDesktopDecision {
        return when (val existing = checkRemoteDesktop(target, nowEpochMillis)) {
            is ProductActionGateDecision.Allowed ->
                ProductRemoteDesktopDecision.ExistingProductSession(existing)
            is ProductActionGateDecision.Denied -> {
                val formal = formalPeer
                    ?: return ProductRemoteDesktopDecision.Denied(existing.reason)
                if (!formal.remoteDesktop.matches(target)) {
                    return ProductRemoteDesktopDecision.Denied(
                        ProductActionGateDenialReason.TrustedLanBootstrapUnavailable
                    )
                }
                when (checkTrustedLanBootstrap(formal)) {
                    TrustedLanBootstrapGateDecision.Allowed ->
                        ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
                    is TrustedLanBootstrapGateDecision.Denied ->
                        ProductRemoteDesktopDecision.Denied(
                            ProductActionGateDenialReason.TrustedLanBootstrapUnavailable
                        )
                }
            }
        }
    }

    private fun check(
        target: DiscoveryPeerLaunchTarget,
        kind: ProductRouteKind,
        nowEpochMillis: Long
    ): ProductActionGateDecision =
        check(
            ProductActionGateTarget(
                serviceType = target.serviceType,
                instanceName = target.instanceName,
                host = target.host,
                port = target.port,
                routeProvenance = target.routeProvenance,
                deviceIdHint = target.deviceIdHint,
                advertisedFingerprint = target.advertisedFingerprint
            ),
            kind,
            nowEpochMillis
        )

    private fun check(
        target: ProductActionGateTarget,
        kind: ProductRouteKind,
        nowEpochMillis: Long
    ): ProductActionGateDecision {
        require(nowEpochMillis > 0) { "nowEpochMillis must be positive" }

        if (target.routeProvenance !in RESOLVED_ROUTE_PROVENANCE) {
            return ProductActionGateDecision.Denied(ProductActionGateDenialReason.UnsupportedRouteProvenance)
        }
        if (normalizeServiceType(target.serviceType) != kind.serviceType) {
            return ProductActionGateDecision.Denied(ProductActionGateDenialReason.ServiceTypeMismatch)
        }

        val deviceId = target.deviceIdHint?.trim()?.takeIf { it.isNotEmpty() }
            ?: return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingPeerIdentity)
        val fingerprint = target.advertisedFingerprint
            ?.trim()
            ?.lowercase(Locale.ROOT)
            ?.takeIf { HEX_SHA256.matches(it) }
            ?: return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingPeerIdentity)
        val instanceName = target.instanceName?.trim()?.takeIf { it.isNotEmpty() }
            ?: return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingRouteInstanceName)
        val host = target.host.trim().takeIf { it.isNotEmpty() }
            ?: return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingAuthenticatedRouteBinding)
        if (target.port !in 1..65535) {
            return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingAuthenticatedRouteBinding)
        }

        val matchingSessions = store.sessions.value.filter {
            it.remoteDeviceId == deviceId &&
                it.remotePublicKeyFingerprint == fingerprint
        }
        val established = matchingSessions.firstOrNull { it.state == ProductSessionState.ESTABLISHED }
            ?: return deniedForMissingSession(matchingSessions)
        if (established.expiresAtEpochMillis <= nowEpochMillis) {
            return ProductActionGateDecision.Denied(ProductActionGateDenialReason.ProductSessionExpired)
        }

        val binding = established.authenticatedRouteBindings.firstOrNull {
            it.kind == kind &&
                normalizeServiceType(it.serviceType) == kind.serviceType &&
                it.instanceName == instanceName &&
                it.hostName == host &&
                it.port == target.port &&
                it.endpointProvenance == ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD
        } ?: return ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingAuthenticatedRouteBinding)

        if (binding.expiresAtEpochMillis <= nowEpochMillis) {
            return ProductActionGateDecision.Denied(ProductActionGateDenialReason.AuthenticatedRouteBindingExpired)
        }
        return ProductActionGateDecision.Allowed(
            owner = established.owner,
            sessionId = established.sessionId,
            remoteDeviceId = established.remoteDeviceId,
            remotePublicKeyFingerprint = established.remotePublicKeyFingerprint
        )
    }

    private fun deniedForMissingSession(
        matchingSessions: List<ProductSessionAuthority>
    ): ProductActionGateDecision.Denied =
        if (matchingSessions.isEmpty()) {
            ProductActionGateDecision.Denied(ProductActionGateDenialReason.AuthenticatedProductSessionRequired)
        } else {
            ProductActionGateDecision.Denied(ProductActionGateDenialReason.ProductSessionNotEstablished)
        }

    private companion object {
        private val RESOLVED_ROUTE_PROVENANCE = setOf(
            AppleBonjourEndpointProvenance.DIRECT_SERVICE,
            AppleBonjourEndpointProvenance.SERVICE_INDEX
        )
        private val HEX_SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

private fun com.skybridge.compass.core.p2p.FormalLanBonjourEndpoint.matches(
    target: ProductActionGateTarget
): Boolean =
    serviceType == normalizeServiceType(target.serviceType) &&
        instanceName == target.instanceName?.trim() &&
        hostAddress == target.host.trim() &&
        port == target.port &&
        routeProvenance == target.routeProvenance.name &&
        advertisedDeviceId == target.deviceIdHint?.trim() &&
        advertisedProtocolFingerprint == target.advertisedFingerprint?.trim()?.lowercase(Locale.ROOT)

sealed interface ProductRemoteDesktopDecision {
    data class ExistingProductSession(
        val authorization: ProductActionGateDecision.Allowed
    ) : ProductRemoteDesktopDecision
    data object RequiresTrustedLanBootstrap : ProductRemoteDesktopDecision
    data class Denied(val reason: ProductActionGateDenialReason) : ProductRemoteDesktopDecision
}

sealed interface TrustedLanBootstrapGateDecision {
    data object Allowed : TrustedLanBootstrapGateDecision
    data class Denied(
        val reason: TrustedLanBootstrapGateDenialReason
    ) : TrustedLanBootstrapGateDecision
}

enum class TrustedLanBootstrapGateDenialReason {
    InvalidResolvedRoute,
    CrossRouteIdentityMismatch
}

data class ProductActionGateTarget(
    val serviceType: String,
    val instanceName: String?,
    val host: String,
    val port: Int,
    val routeProvenance: AppleBonjourEndpointProvenance,
    val deviceIdHint: String?,
    val advertisedFingerprint: String?
)

sealed interface ProductActionGateDecision {
    data class Allowed(
        val owner: ProductSessionOwner,
        val sessionId: String,
        val remoteDeviceId: String,
        val remotePublicKeyFingerprint: String
    ) : ProductActionGateDecision

    data class Denied(val reason: ProductActionGateDenialReason) : ProductActionGateDecision
}

enum class ProductActionGateDenialReason {
    AuthenticatedProductSessionRequired,
    ProductSessionNotEstablished,
    ProductSessionExpired,
    MissingPeerIdentity,
    UnsupportedRouteProvenance,
    ServiceTypeMismatch,
    MissingRouteInstanceName,
    MissingAuthenticatedRouteBinding,
    AuthenticatedRouteBindingExpired,
    TrustedLanBootstrapUnavailable
}

fun ProductActionGateDenialReason.userMessage(): String =
    when (this) {
        ProductActionGateDenialReason.AuthenticatedProductSessionRequired ->
            "authenticated product session required"
        ProductActionGateDenialReason.ProductSessionNotEstablished ->
            "product session is not established"
        ProductActionGateDenialReason.ProductSessionExpired ->
            "product session expired"
        ProductActionGateDenialReason.MissingPeerIdentity ->
            "peer identity is missing or invalid"
        ProductActionGateDenialReason.UnsupportedRouteProvenance ->
            "discovery route was not resolved from DNS-SD"
        ProductActionGateDenialReason.ServiceTypeMismatch ->
            "discovery route service type does not match requested action"
        ProductActionGateDenialReason.MissingRouteInstanceName ->
            "discovery route instance name is missing"
        ProductActionGateDenialReason.MissingAuthenticatedRouteBinding ->
            "matching authenticated route binding is missing"
        ProductActionGateDenialReason.AuthenticatedRouteBindingExpired ->
            "authenticated route binding expired"
        ProductActionGateDenialReason.TrustedLanBootstrapUnavailable ->
            "trusted LAN bootstrap routes are unavailable"
    }

private fun normalizeServiceType(raw: String): String =
    raw.trim().lowercase(Locale.ROOT).removeSuffix(".")
