package com.skybridge.compass.discovery.data.datasources

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class BonjourDeviceServiceIndexTest : FunSpec({

    test("merges Apple main remote and transfer Bonjour services into one peer") {
        val index = BonjourDeviceServiceIndex()

        index.upsert(
            serviceKey = "remote::SkyBridge Pro",
            device = appleDevice(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                port = 5901,
                capabilities = setOf(DeviceCapability.SCREEN_SHARING),
                extra = mapOf(
                    "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                    "remoteVideoFormats" to "jpeg,h264"
                ),
                signalStrength = 80,
                lastSeen = 1_000
            )
        )
        index.upsert(
            serviceKey = "main::SkyBridge Pro",
            device = appleDevice(
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44000,
                capabilities = emptySet(),
                extra = mapOf(
                    "servicePort:${AppleBonjourInterop.MAIN_SERVICE_TYPE}" to "44000",
                    "uniqueId" to "apple-peer"
                ),
                signalStrength = 90,
                lastSeen = 2_000
            )
        )
        index.upsert(
            serviceKey = "transfer::SkyBridge Pro",
            device = appleDevice(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                port = 44010,
                capabilities = setOf(DeviceCapability.FILE_TRANSFER),
                extra = mapOf("servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010"),
                signalStrength = 70,
                lastSeen = 1_500
            )
        )

        val merged = index.devices().single()

        merged.id shouldBe "apple-peer"
        merged.connectionInfo.serviceType shouldBe AppleBonjourInterop.MAIN_SERVICE_TYPE
        merged.connectionInfo.port shouldBe 44000
        merged.capabilities shouldBe setOf(
            DeviceCapability.SCREEN_SHARING,
            DeviceCapability.FILE_TRANSFER
        )
        merged.connectionInfo.extra["servicePort:${AppleBonjourInterop.MAIN_SERVICE_TYPE}"] shouldBe "44000"
        merged.connectionInfo.extra["servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}"] shouldBe "5901"
        merged.connectionInfo.extra["servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}"] shouldBe "44010"
        merged.connectionInfo.extra["remoteVideoFormats"] shouldBe "jpeg,h264"
        merged.signalStrength shouldBe 90
        merged.lastSeen shouldBe 2_000
    }

    test("removing one Bonjour service keeps peer while another service remains") {
        val index = BonjourDeviceServiceIndex()
        index.upsert(
            serviceKey = "main::SkyBridge Pro",
            device = appleDevice(
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44000
            )
        )
        index.upsert(
            serviceKey = "transfer::SkyBridge Pro",
            device = appleDevice(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                port = 44010,
                capabilities = setOf(DeviceCapability.FILE_TRANSFER)
            )
        )

        index.remove(serviceKey = "transfer::SkyBridge Pro", fallbackDeviceId = "SkyBridge Pro")

        val remaining = index.devices().single()
        remaining.id shouldBe "apple-peer"
        remaining.connectionInfo.serviceType shouldBe AppleBonjourInterop.MAIN_SERVICE_TYPE

        index.remove(serviceKey = "main::SkyBridge Pro", fallbackDeviceId = "SkyBridge Pro")

        index.devices() shouldBe emptyList()
    }

    test("moving a service key to a new stable device id removes the stale peer") {
        val index = BonjourDeviceServiceIndex()
        index.upsert(
            serviceKey = "main::SkyBridge Pro",
            device = appleDevice(
                id = "old-peer",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44000
            )
        )

        index.upsert(
            serviceKey = "main::SkyBridge Pro",
            device = appleDevice(
                id = "new-peer",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44001
            )
        )

        val devices = index.devices()
        devices.map { it.id } shouldBe listOf("new-peer")
        devices.single().connectionInfo.port shouldBe 44001
    }

    test("unrelated peer updates do not change the target peer revision") {
        val index = BonjourDeviceServiceIndex()
        index.upsert(
            "main::A",
            appleDevice(id = "peer-a", serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE, port = 44_000)
        )
        val before = index.devices().single().connectionInfo.extra["serviceIndexRevision"]

        index.upsert(
            "main::B",
            appleDevice(id = "peer-b", serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE, port = 44_001)
        )
        val after = index.devices().single { it.id == "peer-a" }
            .connectionInfo.extra["serviceIndexRevision"]

        after shouldBe before
    }

    test("peer disappearance and reappearance receives a new non-ABA revision") {
        val index = BonjourDeviceServiceIndex()
        val device = appleDevice(
            id = "peer-a",
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            port = 44_000
        )
        index.upsert("main::A", device)
        val first = index.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        index.remove("main::A", "peer-a")
        index.upsert("main::A", device)
        val second = index.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        (second > first) shouldBe true
    }

    test("new discovery index receives a process-unique revision") {
        val firstIndex = BonjourDeviceServiceIndex()
        firstIndex.upsert(
            "main::A",
            appleDevice(id = "peer-a", serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE, port = 44_000)
        )
        val first = firstIndex.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        val secondIndex = BonjourDeviceServiceIndex()
        secondIndex.upsert(
            "main::A",
            appleDevice(id = "peer-a", serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE, port = 44_000)
        )
        val second = secondIndex.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        (second > first) shouldBe true
    }

    test("idempotent resolve preserves revision while a route change advances it") {
        val index = BonjourDeviceServiceIndex()
        index.upsert(
            "main::A",
            appleDevice(
                id = "peer-a",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44_000,
                signalStrength = 20,
                lastSeen = 1_000
            )
        )
        val first = index.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        index.upsert(
            "main::A",
            appleDevice(
                id = "peer-a",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44_000,
                signalStrength = 90,
                lastSeen = 2_000
            )
        )
        val idempotent = index.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        index.upsert(
            "main::A",
            appleDevice(
                id = "peer-a",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44_001,
                signalStrength = 90,
                lastSeen = 3_000
            )
        )
        val changed = index.devices().single().connectionInfo.extra
            .getValue("serviceIndexRevision").toLong()

        idempotent shouldBe first
        (changed > idempotent) shouldBe true
    }

    test("lost unique device churn does not retain revision entries") {
        val index = BonjourDeviceServiceIndex()
        repeat(2_000) { value ->
            val id = "peer-$value"
            val key = "main::$value"
            index.upsert(
                key,
                appleDevice(id = id, serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE, port = 44_000)
            )
            index.remove(key, id)
        }

        index.devices() shouldBe emptyList()
        index.retainedRevisionCount() shouldBe 0
        index.indexedServiceCountForTest() shouldBe 0
    }

    test("service index rejects new keys at capacity and releases capacity after loss") {
        val index = BonjourDeviceServiceIndex()
        repeat(256) { value ->
            index.upsert(
                "main::$value",
                appleDevice(
                    id = "peer-$value",
                    serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                    port = 44_000
                )
            )
        }

        var rejected = false
        try {
            index.upsert(
                "main::overflow",
                appleDevice(
                    id = "overflow",
                    serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                    port = 44_000
                )
            )
        } catch (_: BonjourServiceIndexCapacityException) {
            rejected = true
        }
        rejected shouldBe true
        index.indexedServiceCountForTest() shouldBe 256

        index.remove("main::0", "peer-0")
        index.upsert(
            "main::replacement",
            appleDevice(
                id = "replacement",
                serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                port = 44_000
            )
        )
        index.indexedServiceCountForTest() shouldBe 256
    }

    test("duplicate canonical service instances mark the route ambiguous") {
        val index = BonjourDeviceServiceIndex()
        index.upsert(
            "remote::A",
            appleDevice(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                port = 5_901,
                extra = mapOf(
                    "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                    "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.10"
                )
            )
        )
        index.upsert(
            "remote::B",
            appleDevice(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                port = 5_902,
                extra = mapOf(
                    "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5902"
                )
            )
        )

        index.devices().single().connectionInfo.extra[
            "serviceAmbiguous:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}"
        ] shouldBe "true"
    }

    test("third instance of one canonical service type is rejected per device") {
        val index = BonjourDeviceServiceIndex()
        repeat(2) { value ->
            index.upsert(
                "remote::$value",
                appleDevice(
                    serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                    port = 5_901 + value
                )
            )
        }

        var rejected = false
        try {
            index.upsert(
                "remote::overflow",
                appleDevice(
                    serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                    port = 5_903
                )
            )
        } catch (_: BonjourServiceIndexCapacityException) {
            rejected = true
        }

        rejected shouldBe true
        index.indexedServiceCountForTest() shouldBe 2
        index.devices().single().connectionInfo.extra[
            "serviceAmbiguous:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}"
        ] shouldBe "true"
    }

    test("resolve attempt token rejects old completion without deleting newer attempt") {
        val attempts = BonjourResolveAttemptIndex()
        val old = attempts.begin("remote::Mac")
        attempts.completeIfCurrent("remote::Mac", old) shouldBe true
        val current = attempts.begin("remote::Mac")

        attempts.completeIfCurrent("remote::Mac", old) shouldBe false
        attempts.completeIfCurrent("remote::Mac", current) shouldBe true
        attempts.pendingCountForTest() shouldBe 0
    }

    test("lost invalidates pending resolve so late completion cannot revive route") {
        val attempts = BonjourResolveAttemptIndex()
        val token = attempts.begin("remote::Mac")

        attempts.invalidateCurrent("remote::Mac")

        attempts.currentCountForTest() shouldBe 0
        attempts.pendingCountForTest() shouldBe 1
        attempts.completeIfCurrent("remote::Mac", token) shouldBe false
        attempts.pendingCountForTest() shouldBe 0
    }

    test("same service cannot start a second OS resolve while one is outstanding") {
        val attempts = BonjourResolveAttemptIndex()
        val first = attempts.begin("remote::Mac")

        var rejected = false
        try {
            attempts.begin("remote::Mac")
        } catch (_: BonjourResolveAlreadyPendingException) {
            rejected = true
        }

        rejected shouldBe true
        attempts.pendingCountForTest() shouldBe 1
        attempts.completeIfCurrent("remote::Mac", first) shouldBe true
        attempts.pendingCountForTest() shouldBe 0
    }

    test("lost and refound service waits for stale OS callback before resolving again") {
        val attempts = BonjourResolveAttemptIndex()
        val stale = attempts.begin("remote::Mac")
        attempts.invalidateCurrent("remote::Mac")

        var rejected = false
        try {
            attempts.begin("remote::Mac")
        } catch (_: BonjourResolveAlreadyPendingException) {
            rejected = true
        }
        rejected shouldBe true

        attempts.completeIfCurrent("remote::Mac", stale) shouldBe false
        val fresh = attempts.begin("remote::Mac")
        attempts.completeIfCurrent("remote::Mac", fresh) shouldBe true
    }

    test("pending resolve index is explicitly bounded") {
        val attempts = BonjourResolveAttemptIndex()
        repeat(256) { attempts.begin("service::$it") }

        var rejected = false
        try {
            attempts.begin("service::overflow")
        } catch (_: BonjourResolveCapacityException) {
            rejected = true
        }

        rejected shouldBe true
        attempts.pendingCountForTest() shouldBe 256

        attempts.completeIfCurrent("service::0", 1L) shouldBe true
        attempts.begin("service::replacement") shouldBe 257L
        attempts.pendingCountForTest() shouldBe 256
    }

    test("clearing a discovery session releases all tracked resolves") {
        val attempts = BonjourResolveAttemptIndex()
        attempts.begin("main::A")
        attempts.begin("remote::A")

        attempts.clear()

        attempts.pendingCountForTest() shouldBe 0
        attempts.currentCountForTest() shouldBe 0
    }
})

private fun appleDevice(
    id: String = "apple-peer",
    serviceType: String,
    port: Int,
    capabilities: Set<DeviceCapability> = emptySet(),
    extra: Map<String, String> = emptyMap(),
    signalStrength: Int = 100,
    lastSeen: Long = 1_000
) = DiscoveredDevice(
    id = id,
    name = "SkyBridge Pro",
    type = DeviceType.IOS,
    capabilities = capabilities,
    connectionInfo = ConnectionInfo(
        protocol = DiscoveryProtocol.BONJOUR,
        address = "fe80::1",
        port = port,
        serviceType = serviceType,
        txtRecords = mapOf("deviceid" to id),
        extra = extra
    ),
    signalStrength = signalStrength,
    lastSeen = lastSeen
)
