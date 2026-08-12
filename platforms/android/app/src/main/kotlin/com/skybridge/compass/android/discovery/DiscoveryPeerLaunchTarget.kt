package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.remote.mac.macRemotePeerIdentityHint
import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Locale

data class DiscoveryPeerLaunchTarget(
    val peerId: String,
    val peerName: String,
    val peerType: DeviceType,
    val serviceType: String,
    val instanceName: String? = null,
    val host: String,
    val port: Int,
    val routeProvenance: AppleBonjourEndpointProvenance,
    val deviceIdHint: String?,
    val advertisedFingerprint: String?,
    val authenticatedProductRoute: Boolean = false
) {
    init {
        require(peerId.isNotBlank()) { "launch peerId is empty" }
        require(peerName.isNotBlank()) { "launch peerName is empty" }
        require(serviceType in ALLOWED_SERVICE_TYPES) { "unsupported launch serviceType" }
        instanceName?.let {
            require(it.isNotBlank()) { "launch instanceName is blank" }
        }
        validateHost(host)
        require(port in 1..65535) { "launch port is out of range" }
        deviceIdHint?.let {
            require(it.isNotBlank()) { "launch deviceIdHint is blank" }
        }
        advertisedFingerprint?.let {
            require(HEX_SHA256.matches(it)) { "launch advertisedFingerprint is invalid" }
        }
        if (authenticatedProductRoute) {
            require(serviceType != AppleBonjourInterop.MAIN_SERVICE_TYPE) {
                "handshake route cannot be an authenticated product route"
            }
        }
    }

    val isFileTransfer: Boolean
        get() = serviceType == AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE

    val requiresAuthenticatedClassicFileTransferSession: Boolean
        get() = isFileTransfer && !authenticatedProductRoute

    val isRemoteDesktop: Boolean
        get() = serviceType == AppleBonjourInterop.REMOTE_SERVICE_TYPE

    companion object {
        private val ALLOWED_SERVICE_TYPES = setOf(
            AppleBonjourInterop.MAIN_SERVICE_TYPE,
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            AppleBonjourInterop.REMOTE_SERVICE_TYPE
        )
        private val HEX_SHA256 = Regex("^[0-9a-f]{64}$")

        fun from(
            device: DiscoveredDevice,
            action: DiscoveryPeerAction
        ): DiscoveryPeerLaunchTarget {
            val endpoint = action.endpoint
            val txt = device.connectionInfo.txtRecords + device.connectionInfo.extra
            val identityHint = macRemotePeerIdentityHint(txt)
            return DiscoveryPeerLaunchTarget(
                peerId = device.id.ifBlank { "${endpoint.host}:${endpoint.port}" },
                peerName = device.name.ifBlank { endpoint.host },
                peerType = device.type,
                serviceType = normalizeServiceType(endpoint.serviceType),
                instanceName = endpoint.instanceName?.trim()?.takeIf { it.isNotEmpty() },
                host = endpoint.host.trim(),
                port = endpoint.port,
                routeProvenance = endpoint.provenance,
                deviceIdHint = identityHint.deviceId,
                advertisedFingerprint = identityHint.advertisedFingerprint,
                authenticatedProductRoute = action.enabled && action.kind != DiscoveryPeerActionKind.Handshake
            )
        }

        fun normalizeServiceType(raw: String): String =
            raw.trim().lowercase(Locale.ROOT).removeSuffix(".")
    }
}

object DiscoveryLaunchTargetRoute {
    const val PEER_ID = "peerId"
    const val PEER_NAME = "peerName"
    const val PEER_TYPE = "peerType"
    const val SERVICE_TYPE = "serviceType"
    const val INSTANCE_NAME = "instanceName"
    const val HOST = "host"
    const val PORT = "port"
    const val ROUTE_PROVENANCE = "routeProvenance"
    const val DEVICE_ID_HINT = "deviceIdHint"
    const val ADVERTISED_FINGERPRINT = "advertisedFingerprint"
    const val AUTHENTICATED_PRODUCT_ROUTE = "authenticatedProductRoute"

    val argumentNames: List<String> = listOf(
        PEER_ID,
        PEER_NAME,
        PEER_TYPE,
        SERVICE_TYPE,
        INSTANCE_NAME,
        HOST,
        PORT,
        ROUTE_PROVENANCE,
        DEVICE_ID_HINT,
        ADVERTISED_FINGERPRINT,
        AUTHENTICATED_PRODUCT_ROUTE
    )

    fun patternFor(baseRoute: String): String =
        "$baseRoute?$PEER_ID={$PEER_ID}&$PEER_NAME={$PEER_NAME}&$PEER_TYPE={$PEER_TYPE}" +
            "&$SERVICE_TYPE={$SERVICE_TYPE}&$INSTANCE_NAME={$INSTANCE_NAME}&$HOST={$HOST}&$PORT={$PORT}" +
            "&$ROUTE_PROVENANCE={$ROUTE_PROVENANCE}" +
            "&$DEVICE_ID_HINT={$DEVICE_ID_HINT}&$ADVERTISED_FINGERPRINT={$ADVERTISED_FINGERPRINT}" +
            "&$AUTHENTICATED_PRODUCT_ROUTE={$AUTHENTICATED_PRODUCT_ROUTE}"

    fun routeFor(baseRoute: String, target: DiscoveryPeerLaunchTarget): String =
        "$baseRoute?" + listOf(
            PEER_ID to target.peerId,
            PEER_NAME to target.peerName,
            PEER_TYPE to target.peerType.name,
            SERVICE_TYPE to target.serviceType,
            INSTANCE_NAME to target.instanceName.orEmpty(),
            HOST to target.host,
            PORT to target.port.toString(),
            ROUTE_PROVENANCE to target.routeProvenance.name,
            DEVICE_ID_HINT to target.deviceIdHint.orEmpty(),
            ADVERTISED_FINGERPRINT to target.advertisedFingerprint.orEmpty(),
            AUTHENTICATED_PRODUCT_ROUTE to target.authenticatedProductRoute.toString()
        ).joinToString("&") { (name, value) -> "$name=${encode(value)}" }

    fun parse(values: Map<String, String?>): Result<DiscoveryPeerLaunchTarget?> = runCatching {
        val present = argumentNames.any { !values[it].isNullOrBlank() }
        if (!present) return@runCatching null

        val peerId = required(values, PEER_ID)
        val peerName = required(values, PEER_NAME)
        val peerType = DeviceType.valueOf(required(values, PEER_TYPE))
        val serviceType = DiscoveryPeerLaunchTarget.normalizeServiceType(required(values, SERVICE_TYPE))
        val instanceName = values[INSTANCE_NAME]?.trim()?.takeIf { it.isNotEmpty() }
        val host = required(values, HOST)
        val port = required(values, PORT).toIntOrNull()
            ?: throw IllegalArgumentException("launch port is invalid")
        val routeProvenance = AppleBonjourEndpointProvenance.valueOf(required(values, ROUTE_PROVENANCE))
        val deviceIdHint = values[DEVICE_ID_HINT]?.trim()?.takeIf { it.isNotEmpty() }
        val advertisedFingerprint = values[ADVERTISED_FINGERPRINT]
            ?.trim()
            ?.lowercase(Locale.ROOT)
            ?.takeIf { it.isNotEmpty() }
        val authenticatedProductRoute = values[AUTHENTICATED_PRODUCT_ROUTE]
            ?.trim()
            ?.lowercase(Locale.ROOT)
            ?.toBooleanStrictOrNull()
            ?: false

        DiscoveryPeerLaunchTarget(
            peerId = peerId,
            peerName = peerName,
            peerType = peerType,
            serviceType = serviceType,
            instanceName = instanceName,
            host = host,
            port = port,
            routeProvenance = routeProvenance,
            deviceIdHint = deviceIdHint,
            advertisedFingerprint = advertisedFingerprint,
            authenticatedProductRoute = authenticatedProductRoute
        )
    }

    fun parseQuery(route: String): Result<DiscoveryPeerLaunchTarget?> {
        val query = route.substringAfter('?', missingDelimiterValue = "")
        if (query.isBlank()) return Result.success(null)
        val values = query.split('&')
            .filter { it.isNotBlank() }
            .associate { pair ->
                val name = pair.substringBefore('=')
                val value = pair.substringAfter('=', missingDelimiterValue = "")
                name to decode(value)
            }
        return parse(values)
    }

    private fun required(values: Map<String, String?>, name: String): String =
        values[name]?.trim()?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("missing launch $name")

    private fun encode(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name())

    private fun decode(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8.name())
}

private fun validateHost(rawHost: String) {
    val host = rawHost.trim()
    require(host.isNotEmpty()) { "launch host is empty" }
    require(host.none { it.isWhitespace() || it.code < 0x20 }) { "launch host is invalid" }
    val normalized = host.removeSurrounding("[", "]").lowercase(Locale.ROOT)
    require(normalized != "localhost") { "launch host must not be loopback" }
    require(normalized != "::" && normalized != "0:0:0:0:0:0:0:0") {
        "launch host must not be wildcard"
    }
    require(normalized != "::1" && normalized != "0:0:0:0:0:0:0:1") {
        "launch host must not be loopback"
    }
    require(normalized != "0.0.0.0") { "launch host must not be wildcard" }
    val ipv4Octets = normalized.split('.').takeIf { it.size == 4 }?.map { part ->
        if (part.isEmpty() || part.any { !it.isDigit() }) return@map null
        part.toIntOrNull()
    }
    if (ipv4Octets != null && ipv4Octets.all { it != null && it in 0..255 }) {
        require(ipv4Octets.first() != 127) { "launch host must not be loopback" }
    }
}
