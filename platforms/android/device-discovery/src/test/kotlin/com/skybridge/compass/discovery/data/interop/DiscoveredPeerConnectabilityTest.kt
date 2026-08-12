package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeFalse
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.collections.shouldContainExactly
import io.kotest.matchers.shouldBe

class DiscoveredPeerConnectabilityTest : FunSpec({

    val validFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    fun peer(
        id: String = "peer",
        name: String = "SkyBridge Peer",
        type: DeviceType = DeviceType.MACOS,
        port: Int = 44000,
        serviceType: String? = AppleBonjourInterop.MAIN_SERVICE_TYPE,
        txtRecords: Map<String, String> = mapOf("pubKeyFP" to validFingerprint),
        extra: Map<String, String> = emptyMap(),
        osVersion: String? = "26.0"
    ) = DiscoveredDevice(
        id = id,
        name = name,
        type = type,
        capabilities = emptySet(),
        connectionInfo = ConnectionInfo(
            protocol = DiscoveryProtocol.BONJOUR,
            address = "192.168.1.10",
            port = port,
            serviceType = serviceType,
            txtRecords = txtRecords,
            extra = extra
        ),
        signalStrength = 100,
        lastSeen = 1_000,
        osVersion = osVersion
    )

    test("valid Apple peer with resolved SRV port and valid fingerprint is connectable") {
        val result = DiscoveredPeerConnectability.classify(peer())

        result.isConnectable.shouldBeTrue()
        result.reasons.shouldBe(emptyList())
        result.primaryReason.shouldBe(null)
    }

    test("SRV port 0 with no TXT port hint is not connectable with port reason") {
        val result = DiscoveredPeerConnectability.classify(
            peer(
                port = 0,
                extra = mapOf("servicePort:${AppleBonjourInterop.MAIN_SERVICE_TYPE}" to "0")
            )
        )

        result.isConnectable.shouldBeFalse()
        result.reasons.shouldContainExactly(PeerNotConnectableReason.PORT_INFORMATION_MISSING)
    }

    test("SRV port 0 with only a TXT port hint remains non-connectable") {
        val result = DiscoveredPeerConnectability.classify(
            peer(
                port = 0,
                txtRecords = mapOf("pubKeyFP" to validFingerprint, "port" to "5901")
            )
        )

        result.isConnectable.shouldBeFalse()
        result.reasons.shouldContainExactly(PeerNotConnectableReason.PORT_INFORMATION_MISSING)
        AppleBonjourPeerRoutes.from(
            peer(
                port = 0,
                txtRecords = mapOf("pubKeyFP" to validFingerprint, "port" to "5901")
            )
        ).hasAnyRoute.shouldBeFalse()
    }

    test("SRV port 0 with a fully resolved indexed service endpoint keeps the peer connectable") {
        val result = DiscoveredPeerConnectability.classify(
            peer(
                port = 0,
                extra = mapOf(
                    "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                    "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to
                        "192.168.1.11"
                )
            )
        )

        result.isConnectable.shouldBeTrue()
    }

    test("indexed servicePort cannot borrow the primary or another service address") {
        listOf(
            mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010"
            ),
            mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.12"
            )
        ).forEach { extra ->
            val device = peer(port = 0, extra = extra)
            val result = DiscoveredPeerConnectability.classify(device)

            result.isConnectable.shouldBeFalse()
            result.reasons.shouldContainExactly(PeerNotConnectableReason.PORT_INFORMATION_MISSING)
            AppleBonjourPeerRoutes.from(device).hasAnyRoute.shouldBeFalse()
        }
    }

    test("missing fingerprint is not connectable with missing reason") {
        val result = DiscoveredPeerConnectability.classify(
            peer(txtRecords = emptyMap())
        )

        result.isConnectable.shouldBeFalse()
        result.primaryReason.shouldBe(PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING)
    }

    test("oversized fingerprint (>255 bytes) is not connectable with too-long reason") {
        val oversized = "a".repeat(AppleBonjourInterop.MAX_PUB_KEY_FINGERPRINT_BYTES + 1)
        val result = DiscoveredPeerConnectability.classify(
            peer(txtRecords = mapOf("pubKeyFP" to oversized))
        )

        result.isConnectable.shouldBeFalse()
        result.primaryReason.shouldBe(PeerNotConnectableReason.IDENTITY_FINGERPRINT_TOO_LONG)
    }

    test("malformed fingerprint is not connectable with malformed reason") {
        val result = DiscoveredPeerConnectability.classify(
            peer(txtRecords = mapOf("pubKeyFP" to "not-a-valid-fingerprint"))
        )

        result.isConnectable.shouldBeFalse()
        result.primaryReason.shouldBe(PeerNotConnectableReason.IDENTITY_FINGERPRINT_MALFORMED)
    }

    test("fingerprint problem is surfaced ahead of port problem when both apply") {
        val result = DiscoveredPeerConnectability.classify(
            peer(port = 0, txtRecords = emptyMap())
        )

        result.isConnectable.shouldBeFalse()
        result.primaryReason.shouldBe(PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING)
        result.reasons.shouldContainExactly(
            PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING,
            PeerNotConnectableReason.PORT_INFORMATION_MISSING
        )
    }

    test("classifying one illegal peer does not affect a valid peer classification") {
        val valid = peer(id = "valid")
        val illegal = peer(id = "illegal", port = 0, txtRecords = emptyMap())

        val validResult = DiscoveredPeerConnectability.classify(valid)
        val illegalResult = DiscoveredPeerConnectability.classify(illegal)
        // Re-classify the valid peer after the illegal one to prove per-device independence.
        val validAgain = DiscoveredPeerConnectability.classify(valid)

        validResult.isConnectable.shouldBeTrue()
        illegalResult.isConnectable.shouldBeFalse()
        validAgain.isConnectable.shouldBeTrue()
    }
})
