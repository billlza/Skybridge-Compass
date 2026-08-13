package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk

/**
 * **Feature: cross-platform-parity-audit, Property 16: TXT 热更新保持服务实例名与身份指纹不变**
 *
 * **Validates: Requirements 3.12**
 *
 * 任务 7.19 的属性测试。与 [P2PLocalNodeServiceTest] 的示例测试**互补**：示例测试覆盖固定生命周期，
 * 本文件在随机生成的"配置序列"（能力集合 × 套件 CSV ×
 * showDeviceName 的任意长度变化序列）上验证 R3.12 的两个半部：
 *
 * 1. **变化即重写**：广播活跃期间，当已验证能力集合或密码套件集合发生变化时，
 *    [P2PLocalNodeService.start] 以变化后的集合重新注册广播（TXT 重写）；配置未变化时**不**重复注册
 *    （避免无谓的注销/注册抖动，这是"2 秒内完成重写"在单测中可判定的等价形式）。
 * 2. **身份不变量**：跨任意次热更新，服务实例名来源（`uniqueId` / `deviceId`，
 *    见 `BonjourAdvertiserDataSource.buildServiceInfo` 的 `sanitizeInstanceName(uniqueId ?: deviceId)`）
 *    与身份指纹（`pubKeyFP`）**逐次相同**，且登记的服务类型恒为
 *    [AppleBonjourInterop.MAIN_SERVICE_TYPE]。
 *
 * **属性定义域**：R3.12 的"2 秒内"是时限要求，需真实 NSD 注册回调才能计时，不在单元测试定义域内；
 * 本属性覆盖的是可判定的部分——重写**是否发生**、重写**携带的集合是否为新值**，以及身份字段的不变性。
 * `BonjourAdvertiserDataSource` / `TcpControlServer` / `LocalP2PIdentity` 用 mockk 替身注入，
 * 被测的是 [P2PLocalNodeService] 的真实配置比较与重新广播逻辑。
 *
 * 随机序列只断言对每个输入都成立的不变量；单维度分支覆盖由下方确定性见证提供，避免把随机样本
 * 是否恰好命中稀有相邻组合错误地用作 release gate。
 */
/**
 * 被测服务 + 捕获槽。身份稳定（deviceId / pubKeyFP 恒定），套件 CSV 按 [suitesSequence] 依次返回，
 * 以模拟"可协商套件集合发生变化"这一 R3.12 触发条件。
 */
private class Harness(
    suitesSequence: List<String>,
    deviceId: String,
    fingerprint: String
) {
    val capturedAds = mutableListOf<BonjourAdvertiserDataSource.Advertisement>()
    val capturedServiceTypes = mutableListOf<String>()

    private val advertiser = mockk<BonjourAdvertiserDataSource>(relaxed = true)
    private val identity = mockk<LocalP2PIdentity>()
    private val tcpServer = mockk<TcpControlServer>(relaxed = true)

    val service: P2PLocalNodeService

    init {
        coEvery {
            advertiser.startAdvertising(any(), capture(capturedAds), capture(capturedServiceTypes))
        } returns deviceId

        every { identity.deviceId() } returns deviceId
        every { identity.pubKeyFingerprint() } returns fingerprint
        every { identity.publishedDeviceName(any()) } answers {
            if (firstArg<Boolean>()) "Pixel 9 Pro" else "Android Device"
        }
        every { identity.discoveryCryptoSuitesCsv(any(), any()) } returnsMany suitesSequence

        every { tcpServer.start(any<IntRange>()) } returns 55_001

        service = P2PLocalNodeService(
            advertiser,
            identity,
            tcpServer,
            FakeRuntimeNetworkParametersSource()
        )
    }
}

class P2PLocalNodeTxtHotUpdatePropertyTest : FunSpec({

    val deviceId = "device-abc-123"
    val fingerprint = "a".repeat(64)

    val capabilitySetArb: Arb<Set<DeviceCapability>> = Arb.set(
        Arb.element(*DeviceCapability.entries.toTypedArray()),
        0..4
    )

    val suitesCsvArb: Arb<String> = Arb.element(
        "0101",
        "0001,0101",
        "0011,0001,0101",
        "0101,0201,0301"
    )

    data class Step(
        val capabilities: Set<DeviceCapability>,
        val suitesCsv: String,
        val showDeviceName: Boolean
    )

    val stepArb: Arb<Step> = Arb.bind(
        capabilitySetArb,
        suitesCsvArb,
        Arb.boolean()
    ) { capabilities, suites, showDeviceName -> Step(capabilities, suites, showDeviceName) }

    test("Property 16: 跨任意配置序列，服务实例名来源与身份指纹逐次不变；仅集合变化才触发重写") {
        checkAll(400, Arb.list(stepArb, 1..6)) { steps ->
            val harness = Harness(steps.map { it.suitesCsv }, deviceId, fingerprint)

            // 独立判据：逐步计算"配置是否相对上一步发生变化"，不复用被测的比较逻辑。
            val changedSteps = mutableListOf<Step>()
            var previous: Triple<Set<DeviceCapability>, String, Boolean>? = null
            steps.forEach { step ->
                val current = Triple(step.capabilities, step.suitesCsv, step.showDeviceName)
                if (previous != current) changedSteps += step
                previous = current
                harness.service.start(
                    showDeviceName = step.showDeviceName,
                    verifiedCapabilities = step.capabilities
                )
            }

            // 核心属性 1：注册次数恰为"首次 + 配置变化次数"。
            harness.capturedAds.size shouldBe changedSteps.size

            // 核心属性 2（身份不变量）：所有注册携带相同的实例名来源与身份指纹。
            harness.capturedAds.forEach { advertisement ->
                advertisement.uniqueId shouldBe deviceId
                advertisement.deviceId shouldBe deviceId
                advertisement.pubKeyFP shouldBe fingerprint
            }
            harness.capturedAds.map { it.uniqueId }.distinct().size shouldBe 1
            harness.capturedAds.map { it.pubKeyFP }.distinct().size shouldBe 1

            // 登记的服务类型恒为主服务类型（热更新不改变服务类型）。
            harness.capturedServiceTypes.distinct() shouldBe
                listOf(AppleBonjourInterop.MAIN_SERVICE_TYPE)

            // 每次重写携带的能力/套件必须是当次配置的值（新集合，而非陈旧值）。
            harness.capturedAds.forEachIndexed { index, advertisement ->
                val step = changedSteps[index]
                advertisement.capabilities shouldBe
                    P2PLocalNodeAdvertisementPolicy.capabilityTxt(step.capabilities)
                advertisement.cryptoSuites shouldBe
                    P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt(step.suitesCsv)
            }

        }
    }

    test("Property 16: 单维度配置变化与配置不变均有确定性见证") {
        val fileTransfer = setOf(DeviceCapability.FILE_TRANSFER)
        val scenarios = listOf(
            listOf(
                Step(emptySet(), "0101", true),
                Step(fileTransfer, "0101", true)
            ),
            listOf(
                Step(fileTransfer, "0101", true),
                Step(fileTransfer, "0001,0101", true)
            ),
            listOf(
                Step(fileTransfer, "0101", true),
                Step(fileTransfer, "0101", false)
            ),
            listOf(
                Step(fileTransfer, "0101", false),
                Step(fileTransfer, "0101", true)
            ),
            listOf(
                Step(fileTransfer, "0101", false),
                Step(fileTransfer, "0101", false)
            )
        )

        scenarios.forEach { steps ->
            val harness = Harness(steps.map { it.suitesCsv }, deviceId, fingerprint)
            steps.forEach { step ->
                harness.service.start(
                    showDeviceName = step.showDeviceName,
                    verifiedCapabilities = step.capabilities
                )
            }

            val expectedRegistrations = if (steps[0] == steps[1]) 1 else 2
            harness.capturedAds.size shouldBe expectedRegistrations
            harness.capturedServiceTypes.distinct() shouldBe
                listOf(AppleBonjourInterop.MAIN_SERVICE_TYPE)
            harness.capturedAds.forEach { advertisement ->
                advertisement.uniqueId shouldBe deviceId
                advertisement.deviceId shouldBe deviceId
                advertisement.pubKeyFP shouldBe fingerprint
            }
        }

        scenarios.slice(2..3).forEach { steps ->
            val harness = Harness(steps.map { it.suitesCsv }, deviceId, fingerprint)
            steps.forEach { step ->
                harness.service.start(step.showDeviceName, step.capabilities)
            }
            harness.capturedAds.map { it.name } shouldBe steps.map { step ->
                if (step.showDeviceName) "Pixel 9 Pro" else "Android Device"
            }
            harness.capturedAds.map { it.uniqueId }.distinct() shouldBe listOf(deviceId)
            harness.capturedAds.map { it.pubKeyFP }.distinct() shouldBe listOf(fingerprint)
        }
    }

    test("Property 16: 仅密码套件集合变化也必须触发重写，且身份字段保持不变") {
        checkAll(
            300,
            capabilitySetArb,
            suitesCsvArb,
            suitesCsvArb
        ) { capabilities, firstSuites, secondSuites ->
            val harness = Harness(listOf(firstSuites, secondSuites), deviceId, fingerprint)

            // 能力集合与 showDeviceName 保持不变，只让身份报告的套件集合变化。
            harness.service.start(showDeviceName = true, verifiedCapabilities = capabilities)
            harness.service.start(showDeviceName = true, verifiedCapabilities = capabilities)

            if (firstSuites != secondSuites) {
                // 核心属性：仅套件变化即触发以新套件重写 TXT。
                harness.capturedAds.size shouldBe 2
                harness.capturedAds[0].cryptoSuites shouldBe firstSuites
                harness.capturedAds[1].cryptoSuites shouldBe secondSuites
                // 能力字段未变。
                harness.capturedAds[0].capabilities shouldBe harness.capturedAds[1].capabilities
                // 身份不变量。
                harness.capturedAds[0].pubKeyFP shouldBe harness.capturedAds[1].pubKeyFP
                harness.capturedAds[0].uniqueId shouldBe harness.capturedAds[1].uniqueId
                harness.capturedAds[0].deviceId shouldBe harness.capturedAds[1].deviceId
            } else {
                // 套件相同且其它维度不变：不得重复注册。
                harness.capturedAds.size shouldBe 1
            }
        }
    }

    test("Property 16: stop() 后身份不变量在下一轮 start 中仍然成立（注销不改写身份）") {
        checkAll(200, capabilitySetArb, capabilitySetArb, suitesCsvArb) { first, second, suites ->
            val harness = Harness(listOf(suites, suites), deviceId, fingerprint)

            harness.service.start(showDeviceName = true, verifiedCapabilities = first)
            harness.service.stop()
            // stop() 清空配置缓存，故重启后必然重新注册一次（即便配置与停止前相同）。
            harness.service.start(showDeviceName = true, verifiedCapabilities = second)

            harness.capturedAds.size shouldBe 2
            // 身份不变量跨 stop/start 依然成立。
            harness.capturedAds[0].pubKeyFP shouldBe harness.capturedAds[1].pubKeyFP
            harness.capturedAds[0].uniqueId shouldBe harness.capturedAds[1].uniqueId
            harness.capturedAds[1].capabilities shouldBe
                P2PLocalNodeAdvertisementPolicy.capabilityTxt(second)
        }
    }
})
