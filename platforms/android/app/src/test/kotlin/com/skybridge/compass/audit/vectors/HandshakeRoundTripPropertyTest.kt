package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.PropTestConfig
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 2: P2P 握手消息编解码往返**
 *
 * **Validates: Requirements 9.3**
 *
 * 任务 17.4。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3）。
 * 被测对象全部委托生产入口，本测试不改变任何编码（G4）：
 *
 * - [HandshakeFinishedCodecAdapter]（`P2PHandshakeWire.kt:1196` / `:1210`）
 * - [P2PCryptoCapabilitiesCodecAdapter]（`P2PHandshakeModels.kt:15` / `:28`）
 * - [P2PHandshakePolicyCodecAdapter]（`P2PHandshakeModels.kt:57` / `:75`）
 *
 * ## 属性
 *
 * 对生成范围内的任意握手值，`decode(encode(v))` 产出与 `v` 所有字段逐一相等的对象，
 * 且编码长度 ≤65535 B（R9.3 的单条上限）。
 *
 * ## 定义域（窄于 R9.3 的部分已逐条记录）
 *
 * - `messageA` / `messageB` 现在由唯一生产 typed encoder 覆盖；固定 Apple vectors 锁定其
 *   raw suite order、transcript-bearing bytes 与逐字节重编码。
 * - **`Finished.version` 恒为 `0x01`**：生产 `encodeFinished` 恒写入 `PROTOCOL_VERSION`
 *   （`P2PHandshakeWire.kt:1204`），不携带该字段的自由取值，故 `version != 1` 的值对象
 *   不可编码，不属于往返定义域。
 * - **`mac` 恒 32 B**：生产 `encodeFinished` 的 `require`（`P2PHandshakeWire.kt:1198`）。
 * - 「公钥与封装字段 0..4096 字节」在 F2 的这三种消息里无对应字段（它们出现在 messageA/messageB，
 *   即上述不可编码的两种）；本属性以 `mac`（32 B）与字符串列表覆盖其可达字段。
 *
 * ## 迭代次数
 *
 * R9.3 要求**每种握手消息类型不少于 1000 个随机用例**：三种可编码类型各 1000 次。
 *
 * ## 随机种子
 *
 * 由 `F2_ROUNDTRIP_PBT_SEED` 指定，未指定时随机取值并打印到测试输出。
 */
@OptIn(ExperimentalKotest::class)
class HandshakeRoundTripPropertyTest : FunSpec({

    val seed: Long = System.getenv("F2_ROUNDTRIP_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 2] F2 handshake round-trip PBT effective seed = $seed")
        println(
            "[Property 2] reproduce with: F2_ROUNDTRIP_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*HandshakeRoundTripPropertyTest*'",
        )
    }

    // R9.3：每种握手消息类型不少于 1000 个随机生成用例。
    val config = PropTestConfig(seed = seed, iterations = 1_000)

    test("Property 2 (F2/finished): decode(encode(v)) 逐字段等于 v，且编码 ≤65535 B") {
        val adapter = HandshakeFinishedCodecAdapter

        var responderToInitiator = 0
        var initiatorToResponder = 0
        var distinctMacs = HashSet<String>()

        checkAll(config, handshakeFinishedArb) { finished ->
            val encoded = adapter.encode(finished)
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true
            // Finished 是定长 38 B 线格式，顺带固定该事实（生产 encodeFinished 的输出长度）。
            encoded.size shouldBe 38

            val decoded = adapter.decode(encoded).valueOrFail()
            val mismatch = finishedFieldMismatch(finished, decoded)
            if (mismatch != null) {
                throw AssertionError("F2 finished 往返不保真：$mismatch")
            }

            when (finished.direction) {
                P2PHandshakeWire.FinishedDirection.RESPONDER_TO_INITIATOR -> responderToInitiator++
                P2PHandshakeWire.FinishedDirection.INITIATOR_TO_RESPONDER -> initiatorToResponder++
            }
            distinctMacs.add(finished.mac.toHexLower())
        }

        println(
            "[Property 2/finished] 方向 R→I=$responderToInitiator I→R=$initiatorToResponder " +
                "不同 mac 数=${distinctMacs.size}",
        )

        // 反空真：两个方向都必须被生成到，且 mac 确实随机（不是同一个值重复 1000 次）。
        (responderToInitiator > 0) shouldBe true
        (initiatorToResponder > 0) shouldBe true
        (distinctMacs.size > 900) shouldBe true
    }

    test("Property 2 (F2/cryptoCapabilities): decode(encode(v)) 逐字段等于 v，且编码 ≤65535 B") {
        val adapter = P2PCryptoCapabilitiesCodecAdapter

        var withEmptyList = 0
        var withLargeList = 0
        var pqcAvailable = 0
        var pqcUnavailable = 0
        var withNonAscii = 0
        var maxEncoded = 0

        checkAll(config, cryptoCapabilitiesArb) { caps ->
            val encoded = adapter.encode(caps)
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true

            val decoded = adapter.decode(encoded).valueOrFail()

            // R9.3：所有字段逐一相等。四个列表为 List<String>，可安全用 ==（无数组字段）。
            decoded.supportedKEM shouldBe caps.supportedKEM
            decoded.supportedSignature shouldBe caps.supportedSignature
            decoded.supportedAuthProfiles shouldBe caps.supportedAuthProfiles
            decoded.supportedAEAD shouldBe caps.supportedAEAD
            decoded.pqcAvailable shouldBe caps.pqcAvailable
            decoded.platformVersion shouldBe caps.platformVersion
            decoded.providerTypeRaw shouldBe caps.providerTypeRaw
            // 列表顺序必须保持（deterministicEncode 是有序编码）。
            decoded shouldBe caps

            val lists = listOf(
                caps.supportedKEM, caps.supportedSignature,
                caps.supportedAuthProfiles, caps.supportedAEAD,
            )
            if (lists.any { it.isEmpty() }) withEmptyList++
            if (lists.any { it.size > 32 }) withLargeList++
            if (caps.pqcAvailable) pqcAvailable++ else pqcUnavailable++
            if ((caps.platformVersion + caps.providerTypeRaw + lists.flatten().joinToString(""))
                    .any { it.code > 127 }
            ) {
                withNonAscii++
            }
            if (encoded.size > maxEncoded) maxEncoded = encoded.size
        }

        println(
            "[Property 2/cryptoCapabilities] 含空列表=$withEmptyList 含>32项列表=$withLargeList " +
                "pqc真=$pqcAvailable 假=$pqcUnavailable 含非ASCII=$withNonAscii 最大编码=$maxEncoded B",
        )

        (withEmptyList > 0) shouldBe true
        (withLargeList > 0) shouldBe true
        (pqcAvailable > 0) shouldBe true
        (pqcUnavailable > 0) shouldBe true
        (withNonAscii > 0) shouldBe true
    }

    test("Property 2 (F2/handshakePolicy): decode(encode(v)) 逐字段等于 v，且编码 ≤65535 B") {
        val adapter = P2PHandshakePolicyCodecAdapter

        // 三个布尔字段的 8 种组合都应被覆盖。
        val boolCombos = HashSet<String>()
        var withNonAscii = 0
        var maxEncoded = 0

        checkAll(config, handshakePolicyArb) { policy ->
            val encoded = adapter.encode(policy)
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true
            // 非空编码：这保证往返不经过 deterministicDecode 的"空字节 → DEFAULT"特例。
            (encoded.isNotEmpty()) shouldBe true

            val decoded = adapter.decode(encoded).valueOrFail()

            decoded.requirePqc shouldBe policy.requirePqc
            decoded.allowClassicFallback shouldBe policy.allowClassicFallback
            decoded.minimumTierRaw shouldBe policy.minimumTierRaw
            decoded.requireSecureEnclavePoP shouldBe policy.requireSecureEnclavePoP
            decoded shouldBe policy

            boolCombos.add(
                "${policy.requirePqc}/${policy.allowClassicFallback}/${policy.requireSecureEnclavePoP}",
            )
            if (policy.minimumTierRaw.any { it.code > 127 }) withNonAscii++
            if (encoded.size > maxEncoded) maxEncoded = encoded.size
        }

        println(
            "[Property 2/handshakePolicy] 布尔组合覆盖=${boolCombos.size}/8 " +
                "含非ASCII=$withNonAscii 最大编码=$maxEncoded B",
        )

        // 反空真：三个布尔字段的全部 8 种组合都必须被生成到。
        boolCombos.size shouldBe 8
        (withNonAscii > 0) shouldBe true
    }

    test("Property 2 (F2/messageA+messageB): Apple wire decodes and typed production encode is exact") {
        val loader = CompatibilityVectorLoader.fromWorkspace()
        val messageA = loader.loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageA").single().rawBytes
        val messageB = loader.loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageB").single().rawBytes

        HandshakeMessageACodecAdapter.encode(
            HandshakeMessageACodecAdapter.decode(messageA).valueOrFail(),
        ).contentEquals(messageA) shouldBe true
        HandshakeMessageBCodecAdapter.encode(
            HandshakeMessageBCodecAdapter.decode(messageB).valueOrFail(),
        ).contentEquals(messageB) shouldBe true
    }
})
