package com.skybridge.compass.audit.vectors

import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 6: 编码幂等与编码—解码—再编码稳定**
 *
 * **Validates: Requirements 9.9**
 *
 * 任务 17.7。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3）。
 * 全部编解码委托生产入口，本测试不改变任何编码（G4）。
 *
 * ## 属性（两个半部，逐面各验证）
 *
 * 对 R9.2–R9.5 生成范围内的任意值 `v`：
 *
 * 1. **编码幂等**：`encode(v)` 重复执行所得字节序列**逐字节相同**；
 * 2. **编码—解码—再编码稳定**：`encode(decode(encode(v)))` 与首次 `encode(v)` **逐字节相等**。
 *
 * 第 2 项比往返属性（17.3–17.5）更强：往返只要求**值**相等，本属性要求**字节**相等，
 * 因此能捕获"值等价但编码不规范化"的差异（如 Map 迭代序泄漏进字节、可选字段的省略策略不稳定）
 * ——这类差异正是跨端字节级不一致的常见来源。
 *
 * ## 四面覆盖与迭代次数
 *
 * R9.9 要求**四个编解码面各不少于 1000 个随机用例**。本测试对四个面的**每个可编码适配器**
 * 各跑 1000 次：F1 一个、F2 三个（finished / cryptoCapabilities / handshakePolicy）、
 * F3 一个、F4 一个，共 6 条属性 × 1000 次。
 *
 * F2 的 `messageA` / `messageB` 是只解码面（无独立生产编码入口，见
 * MessageA/MessageB 的 canonical idempotence 由 production typed encoder 与 Apple vectors 覆盖；
 * F2 面的随机 1000 次要求由上述
 * 三个可编码子面各自满足。
 *
 * ## 反空真
 *
 * 每条属性统计"两次编码非空""编码长度分布"等计数并断言 > 0：若生成器只产出空编码，
 * "两次编码相同"会平凡成立而不证明任何事。
 *
 * ## 随机种子
 *
 * 由 `IDEMPOTENCE_PBT_SEED` 指定，未指定时随机取值并打印到测试输出。
 */
@OptIn(ExperimentalKotest::class)
class EncodeIdempotencePropertyTest : FunSpec({

    val seed: Long = System.getenv("IDEMPOTENCE_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 6] encode idempotence PBT effective seed = $seed")
        println(
            "[Property 6] reproduce with: IDEMPOTENCE_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*EncodeIdempotencePropertyTest*'",
        )
    }

    // R9.9：四个编解码面各不少于 1000 个随机生成用例。
    val config = PropTestConfig(seed = seed, iterations = 1_000)

    /**
     * 逐面通用的幂等 + 稳定性检查。
     *
     * @param label 报告标签（面 + 子面）。
     * @param adapter 被测适配器。
     * @param valueArb 该面的值生成器。
     */
    fun <T> idempotenceTest(
        label: String,
        adapter: CodecSurfaceAdapter<T>,
        valueArb: Arb<T>,
        /**
         * 该面若为**定长**线格式则给出其固定长度（如 F2 `Finished` 恒 38 B）。
         *
         * 定长面无法产生"编码长度多样"的分支，对它们断言长度多样性会把一个正确的线格式
         * 判成失败；改为断言"长度恒等于该定长"，这对定长面是更强的约束。
         */
        fixedEncodingSize: Int? = null,
    ) {
        test("Property 6 ($label): encode 幂等，且 encode∘decode∘encode 与 encode 逐字节相等") {
            var nonEmptyEncodings = 0
            val distinctEncodings = HashSet<Int>()
            val distinctSizes = HashSet<Int>()
            var maxEncoded = 0

            checkAll(config, valueArb) { value ->
                val first = adapter.encode(value)
                val second = adapter.encode(value)

                // 半部 1：编码幂等 —— 重复编码逐字节相同。
                val idempotenceMismatch = CompatibilityVectorLoader.describeByteMismatch(
                    expected = first,
                    actual = second,
                    context = "$label 重复编码",
                )
                if (idempotenceMismatch != null) {
                    throw AssertionError("R9.9 编码幂等失败：$idempotenceMismatch")
                }

                // 编码须在该面上限内（否则后续 decode 会被长度预检查拒绝，属于生成器越界）。
                (first.size <= adapter.maxEncodedBytes) shouldBe true

                // 半部 2：编码—解码—再编码稳定。
                val decoded = adapter.decode(first).valueOrFail()
                val reEncoded = adapter.encode(decoded)
                val stabilityMismatch = CompatibilityVectorLoader.describeByteMismatch(
                    expected = first,
                    actual = reEncoded,
                    context = "$label 编码—解码—再编码",
                )
                if (stabilityMismatch != null) {
                    throw AssertionError("R9.9 编码—解码—再编码稳定性失败：$stabilityMismatch")
                }

                // 再来一轮，确认稳定性不是"第二次才收敛"（即不动点在第一次编码即达成）。
                val thirdRound = adapter.encode(adapter.decode(reEncoded).valueOrFail())
                thirdRound.contentEquals(first) shouldBe true

                if (first.isNotEmpty()) nonEmptyEncodings++
                distinctEncodings.add(first.contentHashCode())
                distinctSizes.add(first.size)
                if (first.size > maxEncoded) maxEncoded = first.size
            }

            println(
                "[Property 6/$label] 非空编码=$nonEmptyEncodings 不同编码数=${distinctEncodings.size} " +
                    "不同长度数=${distinctSizes.size} 最大编码=$maxEncoded B",
            )

            // 反空真：编码必须非空、内容真的多样，否则幂等断言平凡成立
            //（对同一个字节序列断言"两次编码相同"什么也不证明）。
            (nonEmptyEncodings > 0) shouldBe true
            (distinctEncodings.size > 500) shouldBe true

            if (fixedEncodingSize != null) {
                // 定长面：长度恒为该值（比"长度多样"更强的约束）。
                distinctSizes shouldBe setOf(fixedEncodingSize)
            } else {
                // 变长面：必须真的生成出多种长度，否则等价于只测了一种规模。
                (distinctSizes.size > 1) shouldBe true
            }
        }
    }

    // F1 文件传输消息
    idempotenceTest("F1/fileTransfer", FileTransferMessageCodecAdapter, fileTransferMessageArb)

    // F2 P2P 握手（三个可编码子面）。Finished 是定长 38 B 线格式（4 B 魔数 + 版本 + 方向 + 32 B mac）。
    idempotenceTest(
        "F2/finished",
        HandshakeFinishedCodecAdapter,
        handshakeFinishedArb,
        fixedEncodingSize = 38,
    )
    idempotenceTest("F2/cryptoCapabilities", P2PCryptoCapabilitiesCodecAdapter, cryptoCapabilitiesArb)
    idempotenceTest("F2/handshakePolicy", P2PHandshakePolicyCodecAdapter, handshakePolicyArb)

    // F3 HPKE 密封盒
    idempotenceTest("F3/hpkeSealedBox", HpkeSealedBoxCodecAdapter, hpkeSealedBoxArb)

    // F4 Bonjour TXT
    idempotenceTest("F4/bonjourTxt", BonjourTxtRecordCodecAdapter, bonjourTxtFieldsArb)

    // =======================================================================
    // F4 专项：编码规范化（书写顺序无关），R9.4 + R9.9 的交叉点
    // =======================================================================

    test("Property 6 (F4/顺序无关): 同一字段集合的任意书写顺序编码出逐字节相同的记录") {
        var permutedCases = 0
        var multiFieldCases = 0

        checkAll(PropTestConfig(seed = seed, iterations = 1_000), bonjourTxtFieldsArb) { fields ->
            val canonical = BonjourTxtRecordCodecAdapter.encode(fields)

            // 以相反插入顺序重建等价的 Map：内容相同、迭代序不同。
            val reversed = LinkedHashMap<String, ByteArray>()
            fields.entries.reversed().forEach { (k, v) -> reversed[k] = v }

            val fromReversed = BonjourTxtRecordCodecAdapter.encode(reversed)
            val mismatch = CompatibilityVectorLoader.describeByteMismatch(
                expected = canonical,
                actual = fromReversed,
                context = "F4 书写顺序无关性",
            )
            if (mismatch != null) {
                throw AssertionError("R9.4/R9.9 编码未规范化（受书写顺序影响）：$mismatch")
            }

            // 解码结果也必须与原字段集合相等（键集合 + 逐键值字节）。
            val decoded = BonjourTxtRecordCodecAdapter.decode(canonical).valueOrFail()
            val fieldMismatch = bonjourFieldMismatch(fields, decoded)
            if (fieldMismatch != null) {
                throw AssertionError("F4 往返不保真：$fieldMismatch")
            }

            permutedCases++
            if (fields.size > 1) multiFieldCases++
        }

        println("[Property 6/F4顺序无关] 用例=$permutedCases 多字段用例=$multiFieldCases")

        (permutedCases > 0) shouldBe true
        // 反空真：单字段 Map 的"逆序"与原序相同，属性会平凡通过；必须有多字段用例。
        (multiFieldCases > 500) shouldBe true
    }
})
