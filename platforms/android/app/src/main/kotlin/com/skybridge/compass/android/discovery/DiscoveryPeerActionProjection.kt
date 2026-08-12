package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.remote.mac.macRemotePeerIdentityHint
import com.skybridge.compass.discovery.data.interop.AppleBonjourPeerEndpoint
import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.discovery.data.interop.AppleBonjourPeerRoutes
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.shared.productsession.AuthenticatedProductRouteBinding
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionAuthority
import com.skybridge.compass.shared.productsession.ProductSessionState
import java.util.Locale

object DiscoveryPeerActionProjection {
    fun actionsFor(
        device: DiscoveredDevice,
        developerSettings: DeveloperSettings,
        productSession: EstablishedDiscoveryProductSession? = null,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): List<DiscoveryPeerAction> {
        val routes = AppleBonjourPeerRoutes.from(device)
        return buildList {
            routes.handshake?.let { endpoint ->
                add(
                    DiscoveryPeerAction(
                        kind = DiscoveryPeerActionKind.Handshake,
                        endpoint = endpoint,
                        enabled = !device.isConnected,
                        disabledReason = if (device.isConnected) {
                            DiscoveryPeerActionDisabledReason.AlreadyConnected
                        } else {
                            null
                        }
                    )
                )
            }
            routes.fileTransfer?.let { endpoint ->
                val disabledReason = productActionDisabledReason(
                    kind = DiscoveryPeerActionKind.FileTransfer,
                    featureEnabled = developerSettings.enableFileTransfer,
                    endpoint = endpoint,
                    device = device,
                    productSession = productSession,
                    nowEpochMillis = nowEpochMillis
                )
                add(
                    DiscoveryPeerAction(
                        kind = DiscoveryPeerActionKind.FileTransfer,
                        endpoint = endpoint,
                        enabled = disabledReason == null,
                        disabledReason = disabledReason
                    )
                )
            }
            routes.remoteDesktop?.let { endpoint ->
                val disabledReason = productActionDisabledReason(
                    kind = DiscoveryPeerActionKind.RemoteDesktop,
                    featureEnabled = developerSettings.enableRemoteControl,
                    endpoint = endpoint,
                    device = device,
                    productSession = productSession,
                    nowEpochMillis = nowEpochMillis
                )
                add(
                    DiscoveryPeerAction(
                        kind = DiscoveryPeerActionKind.RemoteDesktop,
                        endpoint = endpoint,
                        enabled = disabledReason == null,
                        disabledReason = disabledReason
                    )
                )
            }
        }
    }

    fun productSessionFor(
        device: DiscoveredDevice,
        productSessions: List<ProductSessionAuthority>,
        nowEpochMillis: Long = System.currentTimeMillis()
    ): EstablishedDiscoveryProductSession? {
        val identityHint = macRemotePeerIdentityHint(device.connectionInfo.txtRecords + device.connectionInfo.extra)
        val advertisedDeviceId = identityHint.deviceId
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        val advertisedFingerprint = identityHint.advertisedFingerprint
            ?.trim()
            ?.takeIf { it.matches(HEX_SHA256) }
            ?: return null

        val session = productSessions.firstOrNull {
            it.state == ProductSessionState.ESTABLISHED &&
                it.expiresAtEpochMillis > nowEpochMillis &&
                it.remoteDeviceId == advertisedDeviceId &&
                it.remotePublicKeyFingerprint == advertisedFingerprint
        } ?: return null

        return EstablishedDiscoveryProductSession(
            sessionId = session.sessionId,
            remoteDeviceId = session.remoteDeviceId,
            remotePublicKeyFingerprint = session.remotePublicKeyFingerprint,
            state = DiscoveryProductSessionState.Established,
            expiresAtEpochMillis = session.expiresAtEpochMillis,
            authenticatedRouteBindings = session.authenticatedRouteBindings.mapNotNull { it.toDiscoveryRouteBinding() }
        )
    }
}

private fun productActionDisabledReason(
    kind: DiscoveryPeerActionKind,
    featureEnabled: Boolean,
    endpoint: AppleBonjourPeerEndpoint,
    device: DiscoveredDevice,
    productSession: EstablishedDiscoveryProductSession?,
    nowEpochMillis: Long
): DiscoveryPeerActionDisabledReason? {
    if (!featureEnabled) return DiscoveryPeerActionDisabledReason.FeatureDisabled
    if (endpoint.provenance !in RESOLVED_ROUTE_PROVENANCE) {
        return DiscoveryPeerActionDisabledReason.UnsupportedRouteProvenance
    }

    val session = productSession
        ?: return DiscoveryPeerActionDisabledReason.AuthenticatedProductSessionRequired
    if (session.state != DiscoveryProductSessionState.Established || session.sessionId.isBlank()) {
        return DiscoveryPeerActionDisabledReason.ProductSessionNotEstablished
    }
    if (session.expiresAtEpochMillis != null && session.expiresAtEpochMillis <= nowEpochMillis) {
        return DiscoveryPeerActionDisabledReason.ProductSessionExpired
    }

    val identityHint = macRemotePeerIdentityHint(device.connectionInfo.txtRecords + device.connectionInfo.extra)
    val advertisedDeviceId = identityHint.deviceId
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: return DiscoveryPeerActionDisabledReason.MissingPeerIdentity
    val advertisedFingerprint = identityHint.advertisedFingerprint
            ?.trim()
            ?.takeIf { it.matches(HEX_SHA256) }
            ?: return DiscoveryPeerActionDisabledReason.MissingPeerIdentity

    if (session.remoteDeviceId != advertisedDeviceId) {
        return DiscoveryPeerActionDisabledReason.PeerDeviceIdMismatch
    }
    if (session.remotePublicKeyFingerprint.trim() != advertisedFingerprint) {
        return DiscoveryPeerActionDisabledReason.PeerFingerprintMismatch
    }

    val endpointInstanceName = endpoint.instanceName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: return DiscoveryPeerActionDisabledReason.MissingRouteInstanceName

    val binding = session.authenticatedRouteBindings.firstOrNull {
        it.kind == kind &&
            normalizeServiceType(it.serviceType) == normalizeServiceType(endpoint.serviceType) &&
            it.instanceName == endpointInstanceName &&
            it.host == endpoint.host &&
            it.port == endpoint.port &&
            it.endpointProvenance == ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD &&
            (it.provenance == null || it.provenance == endpoint.provenance)
    } ?: return DiscoveryPeerActionDisabledReason.MissingAuthenticatedRouteBinding
    if (binding.expiresAtEpochMillis != null && binding.expiresAtEpochMillis <= nowEpochMillis) {
        return DiscoveryPeerActionDisabledReason.AuthenticatedRouteBindingExpired
    }

    return null
}

data class DiscoveryPeerAction(
    val kind: DiscoveryPeerActionKind,
    val endpoint: AppleBonjourPeerEndpoint,
    val enabled: Boolean,
    val disabledReason: DiscoveryPeerActionDisabledReason?
)

enum class DiscoveryPeerActionKind {
    Handshake,
    FileTransfer,
    RemoteDesktop
}

enum class DiscoveryPeerActionDisabledReason {
    AlreadyConnected,
    FeatureDisabled,
    AuthenticatedProductSessionRequired,
    ProductSessionNotEstablished,
    ProductSessionExpired,
    MissingPeerIdentity,
    PeerDeviceIdMismatch,
    PeerFingerprintMismatch,
    UnsupportedRouteProvenance,
    MissingRouteInstanceName,
    MissingAuthenticatedRouteBinding,
    AuthenticatedRouteBindingExpired
}

data class EstablishedDiscoveryProductSession(
    val sessionId: String,
    val remoteDeviceId: String,
    val remotePublicKeyFingerprint: String,
    val state: DiscoveryProductSessionState = DiscoveryProductSessionState.Established,
    val expiresAtEpochMillis: Long? = null,
    val authenticatedRouteBindings: List<AuthenticatedDiscoveryProductRouteBinding> = emptyList()
) {
    init {
        require(sessionId.isNotBlank()) { "product sessionId is empty" }
        require(remoteDeviceId.isNotBlank()) { "product session remoteDeviceId is empty" }
        require(remotePublicKeyFingerprint.trim().lowercase(Locale.ROOT).matches(HEX_SHA256)) {
            "product session remotePublicKeyFingerprint is invalid"
        }
        expiresAtEpochMillis?.let {
            require(it > 0) { "product session expiresAtEpochMillis must be positive" }
        }
    }
}

data class AuthenticatedDiscoveryProductRouteBinding(
    val kind: DiscoveryPeerActionKind,
    val serviceType: String,
    val instanceName: String,
    val host: String,
    val port: Int,
    val provenance: AppleBonjourEndpointProvenance? = null,
    val endpointProvenance: String = ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD,
    val expiresAtEpochMillis: Long? = null
) {
    init {
        require(kind != DiscoveryPeerActionKind.Handshake) { "handshake route is not a product action binding" }
        require(serviceType.isNotBlank()) { "route binding serviceType is empty" }
        require(instanceName.isNotBlank()) { "route binding instanceName is empty" }
        require(host.isNotBlank()) { "route binding host is empty" }
        require(port in 1..65535) { "route binding port is out of range" }
        require(endpointProvenance == ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD) {
            "route binding endpointProvenance is unsupported"
        }
        expiresAtEpochMillis?.let {
            require(it > 0) { "route binding expiresAtEpochMillis must be positive" }
        }
    }
}

enum class DiscoveryProductSessionState {
    Established,
    Negotiating,
    Failed,
    Disconnected
}

private val RESOLVED_ROUTE_PROVENANCE = setOf(
    AppleBonjourEndpointProvenance.DIRECT_SERVICE,
    AppleBonjourEndpointProvenance.SERVICE_INDEX
)

private val HEX_SHA256 = Regex("^[0-9a-f]{64}$")

private fun AuthenticatedProductRouteBinding.toDiscoveryRouteBinding(): AuthenticatedDiscoveryProductRouteBinding? {
    val actionKind = when (kind) {
        ProductRouteKind.FILE_TRANSFER -> DiscoveryPeerActionKind.FileTransfer
        ProductRouteKind.REMOTE_DESKTOP -> DiscoveryPeerActionKind.RemoteDesktop
    }
    return AuthenticatedDiscoveryProductRouteBinding(
        kind = actionKind,
        serviceType = serviceType,
        instanceName = instanceName,
        host = hostName,
        port = port,
        endpointProvenance = endpointProvenance,
        expiresAtEpochMillis = expiresAtEpochMillis
    )
}

private fun normalizeServiceType(raw: String): String =
    raw.trim().lowercase(Locale.ROOT).removeSuffix(".")
