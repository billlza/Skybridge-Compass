package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe

class DeviceDeduplicationPolicyTest : FunSpec({

    test("stable device id is the primary deduplication key across endpoints") {
        val bonjour = discoveredDevice(
            id = "apple-peer",
            address = "fe80::1",
            protocol = DiscoveryProtocol.BONJOUR
        )
        val udp = discoveredDevice(
            id = "apple-peer",
            address = "192.168.1.42",
            protocol = DiscoveryProtocol.UDP_BROADCAST
        )

        DeviceDeduplicationPolicy.keyFor(bonjour) shouldBe DeviceDeduplicationPolicy.keyFor(udp)
    }

    test("endpoint key is used only when stable device id is absent") {
        val first = discoveredDevice(id = "", address = "192.168.1.10")
        val second = discoveredDevice(id = "", address = "192.168.1.11")

        DeviceDeduplicationPolicy.keyFor(first) shouldBe DeviceDeduplicationKey(
            namespace = "endpoint",
            value = "SkyBridge Pro|192.168.1.10|IOS"
        )
        DeviceDeduplicationPolicy.keyFor(first) shouldNotBe DeviceDeduplicationPolicy.keyFor(second)
    }

    test("merge preserves primary route while carrying metadata from duplicate observations") {
        val weakBonjour = discoveredDevice(
            id = "apple-peer",
            address = "fe80::1",
            protocol = DiscoveryProtocol.BONJOUR,
            signalStrength = 50,
            lastSeen = 1_000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER),
            extra = mapOf("servicePort:_skybridge-transfer._tcp." to "44010"),
            txtRecords = mapOf("deviceid" to "apple-peer"),
            osVersion = "27.0"
        )
        val strongUdp = discoveredDevice(
            id = "apple-peer",
            address = "192.168.1.42",
            protocol = DiscoveryProtocol.UDP_BROADCAST,
            signalStrength = 80,
            lastSeen = 2_000,
            capabilities = setOf(DeviceCapability.SCREEN_SHARING),
            extra = mapOf("source" to "udp"),
            isConnected = true
        )

        val merged = DeviceDeduplicationPolicy.merge(weakBonjour, strongUdp)

        merged.connectionInfo.protocol shouldBe DiscoveryProtocol.UDP_BROADCAST
        merged.connectionInfo.address shouldBe "192.168.1.42"
        merged.capabilities shouldBe setOf(
            DeviceCapability.FILE_TRANSFER,
            DeviceCapability.SCREEN_SHARING
        )
        merged.connectionInfo.extra["servicePort:_skybridge-transfer._tcp."] shouldBe "44010"
        merged.connectionInfo.extra["source"] shouldBe "udp"
        merged.connectionInfo.txtRecords["deviceid"] shouldBe "apple-peer"
        merged.lastSeen shouldBe 2_000
        merged.isConnected shouldBe true
        merged.osVersion shouldBe "27.0"
    }
})

private fun discoveredDevice(
    id: String,
    address: String,
    protocol: DiscoveryProtocol = DiscoveryProtocol.BONJOUR,
    signalStrength: Int = 70,
    lastSeen: Long = 1_000,
    capabilities: Set<DeviceCapability> = emptySet(),
    extra: Map<String, String> = emptyMap(),
    txtRecords: Map<String, String> = emptyMap(),
    isConnected: Boolean = false,
    osVersion: String? = null
) = DiscoveredDevice(
    id = id,
    name = "SkyBridge Pro",
    type = DeviceType.IOS,
    capabilities = capabilities,
    connectionInfo = ConnectionInfo(
        protocol = protocol,
        address = address,
        port = 44000,
        txtRecords = txtRecords,
        extra = extra
    ),
    signalStrength = signalStrength,
    lastSeen = lastSeen,
    isConnected = isConnected,
    osVersion = osVersion
)
