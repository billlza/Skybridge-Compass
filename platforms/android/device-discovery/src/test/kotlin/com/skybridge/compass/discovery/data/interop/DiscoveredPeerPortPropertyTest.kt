package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.of
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 12: 端口信息缺失的对端被判定为不可连接**
 *
 * **Validates: Requirements 3.6**
 *
 * 任务 7.15 的属性测试。与 [DiscoveredPeerConnectabilityTest] 的示例测试**互补**：示例测试固定
 * 几个已知用例（SRV 端口 0、仅有 TXT 提示、有 indexed servicePort），本文件在随机生成的
 * "SRV 端口 × TXT 端口提示键/值 × indexed servicePort/serviceAddress"空间上验证 R3.6：
 *
 * 当且仅当**两条已解析路由来源全部不可用**时，对端被判定为不可连接且原因为
 * [PeerNotConnectableReason.PORT_INFORMATION_MISSING]。两条可执行来源为：
 * 1. 当前服务解析出的 SRV 端口在 1..65535，可与当前服务地址配对；
 * 2. `servicePort:<serviceType>` 在 1..65535，且同一 service 同时存在
 *    `serviceAddress:<serviceType>`；
 * indexed 端口不得借用主服务或其他 service 的地址。
 * TXT 端口提示键（`port` / `remotePort` / `transferPort` 等）仅是未认证诊断值，不能创建路由。
 *
 * **属性定义域**：身份指纹在本测试中恒为合法值，以把端口维度与 R3.14 的指纹维度**隔离**——
 * 二者同时不满足时的原因优先级由示例测试与 Property 17 覆盖，不在此重复。端口取值刻意覆盖
 * 0、负数、越界（65536+）、非数字与超大数字字符串，因为这些都是 Apple 侧可能写出的真实形态。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class DiscoveredPeerPortPropertyTest : FunSpec({

    val validFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /** Apple 对端可能声明的诊断性 TXT 端口提示键。 */
    val portHintKeys = listOf(
        "port", "remotePort", "remoteControlPort", "remote_port",
        "transferPort", "fileTransferPort", "file_transfer_port"
    )

    /** 不属于端口提示键的普通 TXT 键，用于确认无关键不会被误当作端口来源。 */
    val nonPortHintKeys = listOf("name", "platform", "version", "capabilities", "portal", "supportPort")

    /**
     * 端口字符串取值域：可拨号值、0、负数、越界值、非数字、空串与超长数字。
     * 后几类是 Apple 侧/异常对端可能写出的真实脏数据，必须被判为不可用。
     */
    val portValueArb: Arb<String> = Arb.of(
        "1", "80", "8080", "55001", "65535",           // 合法
        "0", "-1", "-8080",                            // 非法：非正
        "65536", "70000", "99999999999999999999",      // 非法：越界/溢出
        "", "   ", "abc", "80a", "8.0", "0x50"         // 非法：非数字形态
    )

    data class PeerCase(
        val srvPort: Int,
        val txtHintKey: String,
        val txtHintValue: String,
        val includeTxtHint: Boolean,
        val nonPortKey: String,
        val nonPortValue: String,
        val indexedPortValue: String,
        val includeIndexedPort: Boolean,
        val includeIndexedAddress: Boolean,
        val indexedAddressServiceType: String,
        val serviceType: String
    )

    val peerCaseArb: Arb<PeerCase> = Arb.bind(
        // SRV 端口刻意含 0（不可拨号）与负数/越界，模拟解析异常。
        Arb.of(0, 0, 0, 1, 80, 8080, 55001, 65535, -1, 65536),
        Arb.element(portHintKeys),
        portValueArb,
        Arb.boolean(),
        Arb.element(nonPortHintKeys),
        portValueArb,
        portValueArb,
        Arb.boolean(),
        Arb.boolean(),
        Arb.element(
            AppleBonjourInterop.MAIN_SERVICE_TYPE,
            AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        ),
        Arb.element(
            AppleBonjourInterop.MAIN_SERVICE_TYPE,
            AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        )
    ) { srvPort, hintKey, hintValue, includeHint, nonPortKey, nonPortValue,
        indexedValue, includeIndexed, includeIndexedAddress, indexedAddressServiceType,
        serviceType ->
        PeerCase(
            srvPort = srvPort,
            txtHintKey = hintKey,
            txtHintValue = hintValue,
            includeTxtHint = includeHint,
            nonPortKey = nonPortKey,
            nonPortValue = nonPortValue,
            indexedPortValue = indexedValue,
            includeIndexedPort = includeIndexed,
            includeIndexedAddress = includeIndexedAddress,
            indexedAddressServiceType = indexedAddressServiceType,
            serviceType = serviceType
        )
    }

    fun peerOf(case: PeerCase): DiscoveredDevice {
        val txtRecords = buildMap {
            put("pubKeyFP", validFingerprint)
            put("deviceId", "peer-1")
            // 无关键始终写入：确认它不会被误当作端口来源。
            put(case.nonPortKey, case.nonPortValue)
            if (case.includeTxtHint) put(case.txtHintKey, case.txtHintValue)
        }
        val extra = buildMap {
            if (case.includeIndexedPort) {
                put("servicePort:${case.serviceType}", case.indexedPortValue)
            }
            if (case.includeIndexedAddress) {
                put("serviceAddress:${case.indexedAddressServiceType}", "192.168.1.43")
            }
        }
        return DiscoveredDevice(
            id = "peer-1",
            name = "Apple Peer",
            type = DeviceType.MACOS,
            capabilities = emptySet(),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = "192.168.1.42",
                port = case.srvPort,
                serviceType = case.serviceType,
                txtRecords = txtRecords,
                extra = extra
            ),
            signalStrength = 100,
            lastSeen = 1_000L
        )
    }

    fun dialable(raw: String): Boolean = raw.trim().toIntOrNull()?.let { it in 1..65535 } == true

    test("Property 12: 可连接性与已解析 DNS-SD 路由存在性严格一致") {
        var connectableViaSrv = 0
        var connectableViaIndexed = 0
        var diagnosticTxtHintIgnored = 0
        var notConnectable = 0
        var missingIndexedAddressRejected = 0
        var crossServiceAddressRejected = 0
        var nonNumericHintSeen = 0
        var outOfRangeHintSeen = 0

        checkAll(1_000, peerCaseArb) { case ->
            val device = peerOf(case)
            val result = DiscoveredPeerConnectability.classify(device)

            // 独立判据（不复用被测实现）：只有 DNS-SD 解析来源可提供可拨号端口。
            val srvOk = case.srvPort in 1..65535
            val txtOk = case.includeTxtHint && dialable(case.txtHintValue)
            val indexedAddressMatches = case.includeIndexedAddress &&
                AppleBonjourInterop.canonicalServiceType(case.indexedAddressServiceType) ==
                AppleBonjourInterop.canonicalServiceType(case.serviceType)
            val indexedPortValid = case.includeIndexedPort && dialable(case.indexedPortValue)
            val indexedOk = indexedPortValid && indexedAddressMatches
            val anyActionableRouteAvailable = srvOk || indexedOk
            val hasActionableRoute = AppleBonjourPeerRoutes.from(device).hasAnyRoute

            // 核心属性（双向）：可连接 ⇔ 至少一条已解析路由存在。
            result.isConnectable shouldBe anyActionableRouteAvailable
            result.isConnectable shouldBe hasActionableRoute

            if (anyActionableRouteAvailable) {
                // 端口可用时不得报出端口缺失原因。
                result.reasons.contains(PeerNotConnectableReason.PORT_INFORMATION_MISSING) shouldBe false
                // 指纹合法，故完全没有任何不可连接原因。
                result.reasons shouldBe emptyList()
                result.primaryReason shouldBe null
                when {
                    srvOk -> connectableViaSrv++
                    else -> connectableViaIndexed++
                }
            } else {
                notConnectable++
                // 端口全不可用时必须标记不可连接，并给出指明端口缺失的原因。
                result.reasons shouldBe listOf(PeerNotConnectableReason.PORT_INFORMATION_MISSING)
                result.primaryReason shouldBe PeerNotConnectableReason.PORT_INFORMATION_MISSING
            }

            if (!srvOk && indexedPortValid && !case.includeIndexedAddress) {
                result.isConnectable shouldBe false
                missingIndexedAddressRejected++
            }
            if (!srvOk && indexedPortValid && case.includeIndexedAddress &&
                !indexedAddressMatches
            ) {
                result.isConnectable shouldBe false
                crossServiceAddressRejected++
            }

            // 无关 TXT 键即使取值是合法端口数字，也不得使对端变为可连接。
            if (!srvOk && !indexedOk && dialable(case.nonPortValue)) {
                result.isConnectable shouldBe false
            }
            if (!srvOk && !indexedOk && txtOk) {
                result.isConnectable shouldBe false
                diagnosticTxtHintIgnored++
            }

            if (case.includeTxtHint && case.txtHintValue.trim().toIntOrNull() == null) nonNumericHintSeen++
            if (case.includeTxtHint) {
                val parsed = case.txtHintValue.trim().toIntOrNull()
                if (parsed != null && parsed !in 1..65535) outOfRangeHintSeen++
            }
        }

        println(
                "[Property 12 端口] connectableViaSrv=$connectableViaSrv " +
                "connectableViaIndexed=$connectableViaIndexed notConnectable=$notConnectable " +
                "missingIndexedAddressRejected=$missingIndexedAddressRejected " +
                "crossServiceAddressRejected=$crossServiceAddressRejected " +
                "diagnosticTxtHintIgnored=$diagnosticTxtHintIgnored " +
                "nonNumericHintSeen=$nonNumericHintSeen outOfRangeHintSeen=$outOfRangeHintSeen"
        )

        // 非空真保证：两条可连接路径、TXT 忽略路径、不可连接路径与两类脏端口值都被生成到。
        (connectableViaSrv > 0) shouldBe true
        (connectableViaIndexed > 0) shouldBe true
        (missingIndexedAddressRejected > 0) shouldBe true
        (crossServiceAddressRejected > 0) shouldBe true
        (diagnosticTxtHintIgnored > 0) shouldBe true
        (notConnectable > 0) shouldBe true
        (nonNumericHintSeen > 0) shouldBe true
        (outOfRangeHintSeen > 0) shouldBe true
    }

    test("Property 12: SRV 端口为 0 且无任何端口提示时恒不可连接（R3.6 的正面条件）") {
        var checked = 0

        // 精确锁定 R3.6 的条件："SRV 端口为 0 且 TXT 中不存在 1..65535 的端口提示"。
        checkAll(
            300,
            Arb.element(nonPortHintKeys),
            portValueArb,
            Arb.element(
                AppleBonjourInterop.MAIN_SERVICE_TYPE,
                AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
            )
        ) { nonPortKey, nonPortValue, serviceType ->
            val device = peerOf(
                PeerCase(
                    srvPort = 0,
                    txtHintKey = "port",
                    txtHintValue = "",
                    includeTxtHint = false,
                    nonPortKey = nonPortKey,
                    nonPortValue = nonPortValue,
                    indexedPortValue = "",
                    includeIndexedPort = false,
                    includeIndexedAddress = false,
                    indexedAddressServiceType = serviceType,
                    serviceType = serviceType
                )
            )

            val result = DiscoveredPeerConnectability.classify(device)
            result.isConnectable shouldBe false
            result.primaryReason shouldBe PeerNotConnectableReason.PORT_INFORMATION_MISSING
            AppleBonjourPeerRoutes.from(device).hasAnyRoute shouldBe false
            checked++
        }

        println("[Property 12 SRV=0 无提示] checked=$checked")

        (checked > 0) shouldBe true
    }

    test("Property 12: TXT 端口提示的书写形态不会把诊断值升级为可连接路由") {
        var upperCaseVariants = 0
        var paddedVariants = 0

        checkAll(300, Arb.element(portHintKeys), Arb.int(1..65535), Arb.boolean()) { key, port, padValue ->
            val writtenKey = key.uppercase()
            val writtenValue = if (padValue) "  $port  " else "$port"

            val device = DiscoveredDevice(
                id = "peer-case",
                name = "Apple Peer",
                type = DeviceType.MACOS,
                capabilities = emptySet(),
                connectionInfo = ConnectionInfo(
                    protocol = DiscoveryProtocol.BONJOUR,
                    address = "192.168.1.42",
                    port = 0,
                    serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
                    txtRecords = mapOf(
                        "pubKeyFP" to validFingerprint,
                        writtenKey to writtenValue
                    )
                ),
                signalStrength = 100,
                lastSeen = 1_000L
            )

            DiscoveredPeerConnectability.classify(device).isConnectable shouldBe false
            AppleBonjourPeerRoutes.from(device).hasAnyRoute shouldBe false

            upperCaseVariants++
            if (padValue) paddedVariants++
        }

        println(
            "[Property 12 书写形态] upperCaseVariants=$upperCaseVariants paddedVariants=$paddedVariants"
        )

        (upperCaseVariants > 0) shouldBe true
        (paddedVariants > 0) shouldBe true
    }
})
