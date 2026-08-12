package com.skybridge.compass.discovery.data.datasources

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 9: 广播与浏览服务类型交集非空且浏览不因缺失广播而丢弃对端**
 *
 * **Validates: Requirements 3.1**
 *
 * 任务 7.12 的属性测试。与 [BonjourDeviceServiceIndexTest] 的示例测试**互补**：示例测试固定
 * 若干具体的 upsert/remove/merge 序列，本文件在随机生成的"服务类型 × 对端"空间上验证 R3.1
 * 的两个半部：
 *
 * 1. **交集非空**：Android 广播的服务类型集合（生产常量 [AppleBonjourInterop.MAIN_SERVICE_TYPE]，
 *    见 `P2PLocalNodeService.advertise`）与 Apple_Reference 浏览的三个服务类型集合
 *    （[AppleBonjourInterop.DISCOVERY_SERVICE_TYPES]）的交集元素数量 ≥ 1。
 * 2. **不因缺失广播而丢弃对端**：对任意在**未被 Android 广播**的服务类型（`_skybridge-remote._tcp`、
 *    `_skybridge-transfer._tcp`）上发现的对端，浏览侧索引 [BonjourDeviceServiceIndex] 仍必须保留它。
 *
 * **属性定义域**：浏览侧真正驱动的是 `BonjourDiscoveryDataSource.startDiscovery()`，但它需要真实
 * `NsdManager` 回调，无法在 JVM 单元测试中驱动。因此本测试驱动该数据源实际使用的**同一个**索引
 * 组件（`serviceIndex.upsert(...)` / `.devices()`，见 `BonjourDiscoveryDataSource.startDiscovery`
 * 内的 `BonjourDeviceServiceIndex`）与同一份服务类型常量，即"对端是否被丢弃"这一判定的真实所在。
 * NSD 回调分发本身不在本属性的定义域内。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class BonjourServiceTypeIntersectionPropertyTest : FunSpec({

    // region 生成器素材

    /**
     * Android 侧实际广播的服务类型集合。生产实现只注册 MAIN_SERVICE_TYPE
     * （`P2PLocalNodeService.advertise` 传入 `AppleBonjourInterop.MAIN_SERVICE_TYPE`）；
     * 扩展到 remote/transfer 属 Wire_Protocol 面新增，已按 G5 记入 gaps 待 Apple 侧决策（任务 7.10）。
     */
    val advertisedServiceTypes: Set<String> = setOf(AppleBonjourInterop.MAIN_SERVICE_TYPE)

    /** Apple_Reference 浏览的服务类型集合，取生产常量而非测试内重写。 */
    val browsedServiceTypes: List<String> = AppleBonjourInterop.DISCOVERY_SERVICE_TYPES

    /** 未被 Android 广播、但仍被浏览的服务类型——R3.1 后半句的关键输入。 */
    val notAdvertisedButBrowsed: List<String> =
        browsedServiceTypes.filterNot { it in advertisedServiceTypes }

    val validFingerprint = "a".repeat(64)

    fun peer(
        deviceId: String,
        serviceType: String,
        port: Int,
        address: String = "192.168.1.20"
    ): DiscoveredDevice = DiscoveredDevice(
        id = deviceId,
        name = "Peer-$deviceId",
        type = DeviceType.MACOS,
        capabilities = emptySet(),
        connectionInfo = ConnectionInfo(
            protocol = DiscoveryProtocol.BONJOUR,
            address = address,
            port = port,
            serviceType = serviceType,
            txtRecords = mapOf("pubKeyFP" to validFingerprint, "deviceId" to deviceId),
            extra = mapOf(
                "servicePort:$serviceType" to port.toString(),
                "serviceInstance:$serviceType" to "$deviceId.$serviceType.local"
            )
        ),
        signalStrength = 100,
        lastSeen = 1_000L
    )

    fun serviceKey(serviceType: String, deviceId: String): String = "$serviceType::$deviceId"

    data class Observation(
        val deviceId: String,
        val serviceType: String,
        val port: Int
    )

    val observationArb: Arb<Observation> = Arb.bind(
        Arb.element("dev-a", "dev-b", "dev-c", "dev-d"),
        Arb.element(browsedServiceTypes),
        Arb.int(1..65535)
    ) { deviceId, serviceType, port -> Observation(deviceId, serviceType, port) }

    // endregion

    test("Property 9 (交集非空): 广播集合与 Apple 浏览集合的交集元素数 >= 1，且对任意浏览子集成立") {
        // 集合层面的硬不变量（R3.1 前半句），与随机输入无关，先直接断言。
        val intersection = advertisedServiceTypes.intersect(browsedServiceTypes.toSet())
        (intersection.size >= 1) shouldBe true
        intersection.contains(AppleBonjourInterop.MAIN_SERVICE_TYPE) shouldBe true

        var subsetContainsMain = 0
        var subsetOmitsMain = 0

        // Apple 侧可能只浏览三类中的一个子集；只要该子集包含 _skybridge._tcp，交集就非空。
        checkAll(300, Arb.set(Arb.element(browsedServiceTypes), 1..3)) { browsedSubset ->
            val subsetIntersection = advertisedServiceTypes.intersect(browsedSubset)
            if (AppleBonjourInterop.MAIN_SERVICE_TYPE in browsedSubset) {
                subsetContainsMain++
                // 与 Apple 参考实现的实际浏览集合相交，互发现成立。
                (subsetIntersection.size >= 1) shouldBe true
            } else {
                subsetOmitsMain++
                // 定义域说明：Apple 参考实现浏览的完整集合**包含** _skybridge._tcp，
                // 故此分支不是真实 Apple 行为，仅用于确认交集判定本身无误报。
                subsetIntersection.isEmpty() shouldBe true
            }
            // 完整 Apple 浏览集合下交集恒非空——这是 R3.1 要求的真实条件。
            advertisedServiceTypes.intersect(browsedServiceTypes.toSet()).isNotEmpty() shouldBe true
        }

        println(
            "[Property 9 交集] subsetContainsMain=$subsetContainsMain subsetOmitsMain=$subsetOmitsMain"
        )

        (subsetContainsMain > 0) shouldBe true
        (subsetOmitsMain > 0) shouldBe true
    }

    test("Property 9 (不丢弃): 在未被广播的服务类型上发现的对端仍被浏览索引保留") {
        // 定义域前提：确实存在"被浏览但未被广播"的服务类型，否则本属性无意义。
        notAdvertisedButBrowsed.isNotEmpty() shouldBe true

        var onlyNotAdvertisedTypes = 0
        var mixedTypes = 0
        var onlyAdvertisedType = 0
        var multiServicePerDevice = 0

        checkAll(500, Arb.list(observationArb, 1..8)) { observations ->
            val index = BonjourDeviceServiceIndex()
            observations.forEach { obs ->
                index.upsert(
                    serviceKey = serviceKey(obs.serviceType, obs.deviceId),
                    device = peer(obs.deviceId, obs.serviceType, obs.port)
                )
            }

            val devices = index.devices()
            val expectedDeviceIds = observations.map { it.deviceId }.toSet()

            // 核心属性：每个被观察到的对端都出现在浏览结果中，与其服务类型是否被本机广播无关。
            devices.map { it.id }.toSet() shouldBe expectedDeviceIds

            // 逐个核对：仅在未广播类型上出现的对端，一个都不能少。
            val idsSeenOnlyOnNotAdvertised = observations
                .groupBy { it.deviceId }
                .filterValues { obs -> obs.all { it.serviceType in notAdvertisedButBrowsed } }
                .keys
            idsSeenOnlyOnNotAdvertised.forEach { deviceId ->
                devices.any { it.id == deviceId } shouldBe true
            }

            val usedTypes = observations.map { it.serviceType }.toSet()
            when {
                usedTypes.all { it in notAdvertisedButBrowsed } -> onlyNotAdvertisedTypes++
                usedTypes.all { it in advertisedServiceTypes } -> onlyAdvertisedType++
                else -> mixedTypes++
            }
            if (observations.groupBy { it.deviceId }.any { it.value.map { o -> o.serviceType }.distinct().size > 1 }) {
                multiServicePerDevice++
            }
        }

        println(
            "[Property 9 不丢弃] onlyNotAdvertisedTypes=$onlyNotAdvertisedTypes " +
                "onlyAdvertisedType=$onlyAdvertisedType mixedTypes=$mixedTypes " +
                "multiServicePerDevice=$multiServicePerDevice"
        )

        // 非空真保证：三类服务类型组合与"同设备多服务"合并路径都被真正生成到。
        (onlyNotAdvertisedTypes > 0) shouldBe true
        (onlyAdvertisedType > 0) shouldBe true
        (mixedTypes > 0) shouldBe true
        (multiServicePerDevice > 0) shouldBe true
    }

    test("Property 9 (不丢弃): 移除已广播类型的服务实例不会丢弃仍在未广播类型上可见的对端") {
        var removalLeftOtherService = 0
        var removalDroppedDevice = 0

        checkAll(
            300,
            Arb.element("dev-a", "dev-b"),
            Arb.element(notAdvertisedButBrowsed),
            Arb.int(1..65535),
            Arb.int(1..65535)
        ) { deviceId, otherType, mainPort, otherPort ->
            val index = BonjourDeviceServiceIndex()
            val mainType = AppleBonjourInterop.MAIN_SERVICE_TYPE

            index.upsert(serviceKey(mainType, deviceId), peer(deviceId, mainType, mainPort))
            index.upsert(serviceKey(otherType, deviceId), peer(deviceId, otherType, otherPort))
            index.devices().map { it.id } shouldBe listOf(deviceId)

            // 已广播类型上的实例消失（onServiceLost），但对端在未广播类型上仍可见。
            index.remove(serviceKey(mainType, deviceId), fallbackDeviceId = deviceId)
            val afterMainLost = index.devices()

            // 核心属性：对端不得被丢弃。
            afterMainLost.map { it.id } shouldBe listOf(deviceId)
            afterMainLost.single().connectionInfo.serviceType shouldBe otherType
            removalLeftOtherService++

            // 两个实例都消失后才真正移除该对端（对照分支，确认索引不是恒不删除）。
            index.remove(serviceKey(otherType, deviceId), fallbackDeviceId = deviceId)
            if (index.devices().isEmpty()) removalDroppedDevice++
        }

        println(
            "[Property 9 移除] removalLeftOtherService=$removalLeftOtherService " +
                "removalDroppedDevice=$removalDroppedDevice"
        )

        (removalLeftOtherService > 0) shouldBe true
        (removalDroppedDevice > 0) shouldBe true
    }
})
