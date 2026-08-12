package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import java.util.Locale

/**
 * Actionable routes derived from a merged Apple/SkyBridge Bonjour peer.
 *
 * The discovery layer may observe canonical or legacy SkyBridge NSD service labels. This projection
 * turns those service facts into canonical explicit endpoints without treating capability strings
 * as proof of a dialable route.
 */
data class AppleBonjourPeerRoutes(
    val handshake: AppleBonjourPeerEndpoint?,
    val fileTransfer: AppleBonjourPeerEndpoint?,
    val remoteDesktop: AppleBonjourPeerEndpoint?
) {
    val hasAnyRoute: Boolean
        get() = handshake != null || fileTransfer != null || remoteDesktop != null

    companion object {
        val Empty = AppleBonjourPeerRoutes(
            handshake = null,
            fileTransfer = null,
            remoteDesktop = null
        )

        fun from(device: DiscoveredDevice): AppleBonjourPeerRoutes {
            if (device.connectionInfo.protocol != DiscoveryProtocol.BONJOUR) return Empty

            val remoteEndpoint = if (device.type == DeviceType.ANDROID) {
                null
            } else {
                endpointFor(device, AppleBonjourInterop.REMOTE_SERVICE_TYPE)
            }

            return AppleBonjourPeerRoutes(
                handshake = endpointFor(device, AppleBonjourInterop.MAIN_SERVICE_TYPE),
                fileTransfer = endpointFor(device, AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE),
                remoteDesktop = remoteEndpoint
            )
        }

        private fun endpointFor(
            device: DiscoveredDevice,
            serviceType: String
        ): AppleBonjourPeerEndpoint? {
            if (device.connectionInfo.extra.serviceValue("serviceAmbiguous", serviceType) == "true") {
                return null
            }
            val directPort = directServicePort(device, serviceType)
            val indexedPort = device.connectionInfo.extra.serviceValue("servicePort", serviceType)
                ?.toIntOrNull()
                ?.takeIf { it in 1..65535 }
            val port = directPort
                ?: indexedPort
                ?: return null

            val indexedHost = device.connectionInfo.extra.serviceValue("serviceAddress", serviceType)
            val host = if (directPort != null) {
                indexedHost ?: device.connectionInfo.address.takeIf { it.isNotBlank() }
            } else {
                indexedHost
            } ?: return null
            val instanceName = device.connectionInfo.extra.serviceValue("serviceInstance", serviceType)
            val advertisedDeviceId = device.connectionInfo.extra
                .serviceValue("serviceDeviceId", serviceType)
            val advertisedFingerprint = device.connectionInfo.extra
                .serviceValue("serviceFingerprint", serviceType)
                ?.lowercase(Locale.ROOT)
                ?.takeIf(HEX_SHA256::matches)
            val discoveryRevision = device.connectionInfo.extra[DISCOVERY_REVISION_KEY]
                ?.toLongOrNull()
                ?.takeIf { it > 0L }

            return AppleBonjourPeerEndpoint(
                serviceType = serviceType,
                instanceName = instanceName,
                host = host,
                port = port,
                provenance = if (directPort != null) {
                    AppleBonjourEndpointProvenance.DIRECT_SERVICE
                } else {
                    AppleBonjourEndpointProvenance.SERVICE_INDEX
                },
                advertisedDeviceId = advertisedDeviceId,
                advertisedFingerprint = advertisedFingerprint,
                discoveryRevision = discoveryRevision
            )
        }

        private fun directServicePort(device: DiscoveredDevice, serviceType: String): Int? =
            device.connectionInfo.port
                .takeIf {
                    AppleBonjourInterop.canonicalServiceType(device.connectionInfo.serviceType) ==
                        AppleBonjourInterop.canonicalServiceType(serviceType) &&
                        it in 1..65535
                }

        private const val DISCOVERY_REVISION_KEY = "serviceIndexRevision"
        private val HEX_SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

data class AppleBonjourPeerEndpoint(
    val serviceType: String,
    val instanceName: String? = null,
    val host: String,
    val port: Int,
    val provenance: AppleBonjourEndpointProvenance,
    val advertisedDeviceId: String? = null,
    val advertisedFingerprint: String? = null,
    val discoveryRevision: Long? = null
)

enum class AppleBonjourEndpointProvenance {
    DIRECT_SERVICE,
    SERVICE_INDEX
}

private fun Map<String, String>.serviceValue(prefix: String, serviceType: String): String? {
    val expectedServiceType = AppleBonjourInterop.canonicalServiceType(serviceType) ?: return null
    val normalizedPrefix = "${prefix.trim().lowercase(Locale.ROOT)}:"
    return entries.firstOrNull { (key, value) ->
        val normalizedKey = key.trim().lowercase(Locale.ROOT).removeSuffix(".")
        value.isNotBlank() &&
            normalizedKey.startsWith(normalizedPrefix) &&
            AppleBonjourInterop.canonicalServiceType(
                normalizedKey.removePrefix(normalizedPrefix)
            ) == expectedServiceType
    }?.value?.trim()
}
