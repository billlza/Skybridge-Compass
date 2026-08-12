package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class AppleBonjourPeerRoutesTest : FunSpec({

    test("merged Apple Bonjour peer exposes handshake file-transfer and remote-desktop endpoints") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.MAIN_SERVICE_TYPE}" to "44000",
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "192.168.1.30",
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.31"
            )
        )

        val routes = AppleBonjourPeerRoutes.from(device)

        routes.handshake shouldBe AppleBonjourPeerEndpoint(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            host = "fe80::1",
            port = 44000,
            provenance = AppleBonjourEndpointProvenance.DIRECT_SERVICE
        )
        routes.fileTransfer shouldBe AppleBonjourPeerEndpoint(
            serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            host = "192.168.1.30",
            port = 44010,
            provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
        )
        routes.remoteDesktop shouldBe AppleBonjourPeerEndpoint(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            host = "192.168.1.31",
            port = 5901,
            provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
        )
        routes.hasAnyRoute shouldBe true
    }

    test("capability tokens alone do not create actionable file or remote routes") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::2",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING)
        )

        val routes = AppleBonjourPeerRoutes.from(device)

        routes.handshake shouldBe AppleBonjourPeerEndpoint(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            host = "fe80::2",
            port = 44000,
            provenance = AppleBonjourEndpointProvenance.DIRECT_SERVICE
        )
        routes.fileTransfer shouldBe null
        routes.remoteDesktop shouldBe null
    }

    test("direct remote Bonjour service is an actionable remote desktop route") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            address = "192.168.1.50",
            port = 5902,
            capabilities = emptySet()
        )

        AppleBonjourPeerRoutes.from(device).remoteDesktop shouldBe AppleBonjourPeerEndpoint(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            host = "192.168.1.50",
            port = 5902,
            provenance = AppleBonjourEndpointProvenance.DIRECT_SERVICE
        )
    }

    test("legacy dedicated labels are accepted only as canonical projected routes") {
        val directLegacyRemote = appleDevice(
            serviceType = AppleBonjourInterop.LEGACY_REMOTE_SERVICE_TYPE,
            address = "192.168.1.51",
            port = 5901
        )
        AppleBonjourPeerRoutes.from(directLegacyRemote).remoteDesktop shouldBe
            AppleBonjourPeerEndpoint(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                host = "192.168.1.51",
                port = 5901,
                provenance = AppleBonjourEndpointProvenance.DIRECT_SERVICE
            )

        val legacyIndexedTransfer = appleDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "192.168.1.52",
            port = 44000,
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.LEGACY_FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.LEGACY_FILE_TRANSFER_SERVICE_TYPE}" to
                    "192.168.1.53"
            )
        )
        AppleBonjourPeerRoutes.from(legacyIndexedTransfer).fileTransfer shouldBe
            AppleBonjourPeerEndpoint(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                host = "192.168.1.53",
                port = 44010,
                provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
            )
    }

    test("TXT port hints do not create actionable remote desktop routes") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            address = "192.168.1.55",
            port = 0,
            txtRecords = mapOf(
                "remotePort" to "5901",
                "remoteControlPort" to "5902",
                "port" to "5903"
            )
        )

        AppleBonjourPeerRoutes.from(device).remoteDesktop shouldBe null
    }

    test("indexed route never combines a service port with the primary service address") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "192.168.1.55",
            port = 44_000,
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901"
            )
        )

        AppleBonjourPeerRoutes.from(device).remoteDesktop shouldBe null
    }

    test("ambiguous duplicate service type is not projected as an actionable route") {
        val device = appleDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "192.168.1.56",
            port = 44_000,
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.57",
                "serviceAmbiguous:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "true"
            )
        )

        AppleBonjourPeerRoutes.from(device).remoteDesktop shouldBe null
    }

    test("Android peers never expose a remote desktop route in the public Android app projection") {
        val device = appleDevice(
            type = DeviceType.ANDROID,
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            address = "192.168.1.60",
            port = 5901,
            capabilities = setOf(DeviceCapability.SCREEN_SHARING)
        )

        val routes = AppleBonjourPeerRoutes.from(device)

        routes.remoteDesktop shouldBe null
        routes.handshake shouldBe null
    }

    test("non-Bonjour peers are not projected into Apple interop routes") {
        val device = appleDevice(
            protocol = DiscoveryProtocol.UDP_BROADCAST,
            serviceType = null,
            address = "192.168.1.70",
            port = 8080
        )

        AppleBonjourPeerRoutes.from(device) shouldBe AppleBonjourPeerRoutes.Empty
    }
})

private fun appleDevice(
    protocol: DiscoveryProtocol = DiscoveryProtocol.BONJOUR,
    type: DeviceType = DeviceType.IOS,
    serviceType: String?,
    address: String,
    port: Int,
    capabilities: Set<DeviceCapability> = emptySet(),
    txtRecords: Map<String, String> = mapOf("deviceid" to "apple-peer"),
    extra: Map<String, String> = emptyMap()
) = DiscoveredDevice(
    id = "apple-peer",
    name = "SkyBridge Pro",
    type = type,
    capabilities = capabilities,
    connectionInfo = ConnectionInfo(
        protocol = protocol,
        address = address,
        port = port,
        serviceType = serviceType,
        txtRecords = txtRecords,
        extra = extra
    ),
    signalStrength = 100,
    lastSeen = 1_000
)
