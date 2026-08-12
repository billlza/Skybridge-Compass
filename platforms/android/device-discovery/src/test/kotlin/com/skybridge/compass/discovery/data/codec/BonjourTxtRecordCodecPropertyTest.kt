package com.skybridge.compass.discovery.data.codec

import io.kotest.assertions.throwables.shouldNotThrowAny
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.byte
import io.kotest.property.arbitrary.choice
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.filter
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.map
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 4: Bonjour TXT 写出后解析往返（顺序无关）**
 *
 * **Validates: Requirements 9.4**
 *
 * 任务 7.11 的属性测试。与 [BonjourTxtRecordCodecTest] 的示例测试**互补**：示例测试固定
 * 若干已知边界（空值、200 字节二进制值、恰好 256 字节的超限对、六条 250 字节对导致整records
 * 超限、无 `=` 的对、截断记录），本文件在 R9.4 规定的生成域上验证往返属性本身。
 *
 * **属性定义域（严格取自 R9.4，不擅自放宽）**：字段数 1..16、单个键 1..9 个 ASCII 字节、
 * 单条键值对编码后不超过 [BonjourTxtRecordCodec.MAX_PAIR_BYTES]（255）、整条 TXT 记录编码后
 * 不超过 [BonjourTxtRecordCodec.MAX_RECORD_BYTES]（1300）。生成器按此域**构造性地**产出用例，
 * 再用生产函数 [BonjourTxtRecordCodec.validate] 交叉核对"生成的确实在域内"——若生产校验器与
 * 该域不一致，测试会直接失败而不是悄悄跳过用例。
 *
 * 键取 RFC 6763 §6.4 允许的可打印 ASCII（0x20..0x7E）并排除 `=`；由于 ISO-8859-1 将
 * 0..255 一对一映射为字节，键的字符数等于其字节数，故"1..9 个 ASCII 字节"可直接用字符数表达。
 * 值为任意字节（含 0x00、0xFF 以及 `=` 0x3D）——值内含 `=` 是关键边界：[BonjourTxtRecordCodec.decode]
 * 必须在**第一个** `=` 处切分，值内后续的 `=` 必须原样保留。
 *
 * 为避免属性以空真（vacuous truth）方式通过，每个测试统计其真正走到的分支，并在 `checkAll`
 * 结束后断言每个计数均大于 0。`pinMaxPair` 维度**强制**约一半用例包含"9 字节键 + 245 字节值
 * = 恰好 255 字节"的临界对，使临界覆盖不依赖随机概率。
 */
class BonjourTxtRecordCodecPropertyTest : FunSpec({

    // region 生成器（严格构造 R9.4 定义域）

    /** RFC 6763 §6.4 允许的键字节：可打印 ASCII 0x20..0x7E，排除分隔符 `=`。 */
    val keyCharArb: Arb<Char> = Arb.int(0x20..0x7E)
        .filter { it != '='.code }
        .map { it.toChar() }

    /** 键长 1..9 个 ASCII 字节（R9.4）。ISO-8859-1 下字符数即字节数。 */
    val keyArb: Arb<String> = Arb.list(keyCharArb, 1..9).map { it.joinToString("") }

    /** 恰好 9 字节的键，配合 245 字节值构成恰好 255 字节的临界对。 */
    val maxLenKeyArb: Arb<String> = Arb.list(keyCharArb, 9..9).map { it.joinToString("") }

    fun valueArb(sizeRange: IntRange): Arb<ByteArray> =
        Arb.list(Arb.byte(), sizeRange).map { it.toByteArray() }

    /**
     * 值长度分档，覆盖空值、短值、接近单对上限的大值，以及恰好使 9 字节键达到 255 字节上限的
     * 245 字节值。分档而非单一均匀分布，是为了让"接近记录上限"与"极小记录"两端都被真正生成到。
     */
    val valueBytesArb: Arb<ByteArray> = Arb.choice(
        valueArb(0..8),      // 含空值
        valueArb(9..64),
        valueArb(200..245),  // 接近单对上限
        valueArb(245..245)   // 与 9 字节键组成恰好 255 字节的对
    )

    val fieldSpecArb: Arb<Pair<String, ByteArray>> =
        Arb.bind(keyArb, valueBytesArb) { key, value -> key to value }

    /** 恰好 255 字节的键值对：9 字节键 + `=` + 245 字节值。 */
    val maxPairSpecArb: Arb<Pair<String, ByteArray>> =
        Arb.bind(maxLenKeyArb, valueArb(245..245)) { key, value -> key to value }

    data class RecordCase(
        val specs: List<Pair<String, ByteArray>>,
        val pinMaxPair: Boolean,
        val maxPairSpec: Pair<String, ByteArray>,
        val permutationSeed: Int
    )

    val recordCaseArb: Arb<RecordCase> = Arb.bind(
        Arb.list(fieldSpecArb, 1..16),
        Arb.boolean(),
        maxPairSpecArb,
        Arb.int(0..Int.MAX_VALUE)
    ) { specs, pinMaxPair, maxPairSpec, seed ->
        RecordCase(specs, pinMaxPair, maxPairSpec, seed)
    }

    fun encodedPairSize(key: String, value: ByteArray): Int = key.length + 1 + value.size

    /**
     * 按 R9.4 的域约束把候选字段收敛成一个合法字段集合：逐个纳入，跳过超过单对上限的对、
     * 重复键，以及会使整条记录超过 1300 字节的对。跳过（而非遇到即停）能让靠后的小字段仍被
     * 纳入，从而把记录长度推得更靠近 1300 上限，提升临界覆盖。首个字段必然被纳入，故结果
     * 至少含 1 个字段，满足"字段数 1..16"的下界。
     */
    fun buildInDomainRecord(case: RecordCase): Map<String, ByteArray> {
        val ordered = if (case.pinMaxPair) listOf(case.maxPairSpec) + case.specs else case.specs
        val fields = LinkedHashMap<String, ByteArray>()
        var recordBytes = 0
        for ((key, value) in ordered) {
            if (fields.size >= 16) break
            if (fields.containsKey(key)) continue
            val pairBytes = encodedPairSize(key, value)
            if (pairBytes > BonjourTxtRecordCodec.MAX_PAIR_BYTES) continue
            if (recordBytes + 1 + pairBytes > BonjourTxtRecordCodec.MAX_RECORD_BYTES) continue
            fields[key] = value
            recordBytes += 1 + pairBytes
        }
        return fields
    }

    fun recordBytesOf(fields: Map<String, ByteArray>): Int =
        fields.entries.sumOf { (k, v) -> 1 + encodedPairSize(k, v) }

    /** 用确定性置换重排字段的迭代顺序，用于验证"顺序无关"。 */
    fun permuted(fields: Map<String, ByteArray>, seed: Int): LinkedHashMap<String, ByteArray> {
        val entries = fields.entries.toMutableList()
        // 确定性 Fisher-Yates：种子来自生成器，失败可复现。
        var state = seed or 1
        for (i in entries.indices.reversed()) {
            state = state * 1_103_515_245 + 12_345
            val j = ((state ushr 1) % (i + 1)).let { if (it < 0) -it else it }
            val tmp = entries[i]
            entries[i] = entries[j]
            entries[j] = tmp
        }
        val out = LinkedHashMap<String, ByteArray>()
        entries.forEach { out[it.key] = it.value }
        return out
    }

    // endregion

    test("Property 4: 域内字段集合 encode 后 decode 往返相等（键集合与每键值字节均相同）") {
        var singleField = 0
        var multiField = 0
        var withEmptyValue = 0
        var withEqualsInValue = 0
        var withZeroByteValue = 0
        var withHighByteValue = 0
        var exactly255Pair = 0
        var nearRecordLimit = 0
        var smallRecord = 0

        // R9.4 明确要求"不少于 1,000 个随机生成用例"。
        checkAll(1_200, recordCaseArb) { case ->
            val fields = buildInDomainRecord(case)

            // 生成器自检 + 生产校验器交叉核对：用例确实落在 R9.4 定义域内。
            fields.isNotEmpty() shouldBe true
            (fields.size <= 16) shouldBe true
            fields.keys.all { it.length in 1..9 } shouldBe true
            BonjourTxtRecordCodec.validate(fields) shouldBe BonjourTxtRecordCodec.TxtValidation.Valid

            // 核心属性：写出后再解析，产出与原字段集合相等的集合。
            val encoded = shouldNotThrowAny { BonjourTxtRecordCodec.encode(fields) }
            val decoded = BonjourTxtRecordCodec.decode(encoded)

            decoded.keys shouldBe fields.keys
            fields.forEach { (key, value) ->
                decoded.getValue(key).toList() shouldBe value.toList()
            }
            // 编码长度与"每对一个长度字节 + 载荷"的结构一致。
            encoded.size shouldBe recordBytesOf(fields)

            // 分支计数（证明非空真）。
            if (fields.size == 1) singleField++ else multiField++
            if (fields.values.any { it.isEmpty() }) withEmptyValue++
            if (fields.values.any { v -> v.any { it == '='.code.toByte() } }) withEqualsInValue++
            if (fields.values.any { v -> v.any { it == 0.toByte() } }) withZeroByteValue++
            if (fields.values.any { v -> v.any { (it.toInt() and 0xFF) >= 0x80 } }) withHighByteValue++
            if (fields.any { (k, v) -> encodedPairSize(k, v) == BonjourTxtRecordCodec.MAX_PAIR_BYTES }) {
                exactly255Pair++
            }
            val recordBytes = recordBytesOf(fields)
            if (recordBytes >= 1_100) nearRecordLimit++
            if (recordBytes <= 64) smallRecord++
        }

        println(
            "[Property 4 往返] singleField=$singleField multiField=$multiField " +
                "emptyValue=$withEmptyValue equalsInValue=$withEqualsInValue " +
                "zeroByte=$withZeroByteValue highByte=$withHighByteValue " +
                "exactly255Pair=$exactly255Pair nearRecordLimit=$nearRecordLimit smallRecord=$smallRecord"
        )

        // 非空真保证：每条分支都被真正生成到。
        (singleField > 0) shouldBe true
        (multiField > 0) shouldBe true
        (withEmptyValue > 0) shouldBe true
        (withEqualsInValue > 0) shouldBe true
        (withZeroByteValue > 0) shouldBe true
        (withHighByteValue > 0) shouldBe true
        (exactly255Pair > 0) shouldBe true
        (nearRecordLimit > 0) shouldBe true
        (smallRecord > 0) shouldBe true
    }

    test("Property 4 (顺序无关): 相同字段集合的不同书写顺序编码为完全相同的字节且往返一致") {
        var orderActuallyChanged = 0
        var orderCoincidentallySame = 0
        var multiFieldPermutations = 0

        checkAll(1_000, recordCaseArb) { case ->
            val fields = buildInDomainRecord(case)
            val shuffled = permuted(fields, case.permutationSeed)

            // 前提：置换只改顺序，不改内容。
            shuffled.keys.toSet() shouldBe fields.keys.toSet()

            val encodedOriginal = BonjourTxtRecordCodec.encode(fields)
            val encodedShuffled = BonjourTxtRecordCodec.encode(shuffled)

            // 核心属性：编码规范化（按键字节无符号序），故与输入迭代顺序无关。
            encodedShuffled.toList() shouldBe encodedOriginal.toList()

            // 往返结果同样与顺序无关。
            val decoded = BonjourTxtRecordCodec.decode(encodedShuffled)
            decoded.keys shouldBe fields.keys
            fields.forEach { (key, value) ->
                decoded.getValue(key).toList() shouldBe value.toList()
            }

            if (fields.size > 1) multiFieldPermutations++
            if (shuffled.keys.toList() != fields.keys.toList()) {
                orderActuallyChanged++
            } else {
                orderCoincidentallySame++
            }
        }

        println(
            "[Property 4 顺序无关] orderActuallyChanged=$orderActuallyChanged " +
                "orderCoincidentallySame=$orderCoincidentallySame " +
                "multiFieldPermutations=$multiFieldPermutations"
        )

        // 非空真保证：确实生成到了"顺序真的变了"的多字段用例，属性不是在单字段上空转。
        (orderActuallyChanged > 0) shouldBe true
        (orderCoincidentallySame > 0) shouldBe true
        (multiFieldPermutations > 0) shouldBe true
    }
})
