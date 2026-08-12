package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.P2PHPKESealedBox
import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 3: HPKE 密封盒合并编码往返**
 *
 * **Validates: Requirements 9.5**
 *
 * 任务 17.5。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3）。
 * 被测对象是 [HpkeSealedBoxCodecAdapter]，委托生产入口 `P2PHPKESealedBox.kt:29`
 * （`combinedWithHeader`）/ `:52`（`parse`），本测试不改变任何编码（G4）。
 *
 * ## 属性
 *
 * 对生成范围内的任意 [com.skybridge.compass.shared.p2p.P2PHPKESealedBox]，
 * `decode(encode(v))` 产出与 `v` 所有字段逐一相等的对象，且合并编码 ≤131072 B（128 KiB）。
 *
 * 与 [HpkeSealedBoxCodecAdapterTest] 的**示例**测试互补：那里固定了 `require` 各分支与
 * 边界保持的具体用例，这里在随机值域上验证往返保真。
 *
 * ## 定义域（与 R9.5 的差异已逐条记录）
 *
 * 见 [hpkeSealedBoxArb] 的 KDoc 对照表。两点值得点明：
 *
 * - **R9.5 的「附加认证数据 0..1024 字节」在 F3 线格式中无对应字段**：
 *   [com.skybridge.compass.shared.p2p.P2PHPKESealedBox] 的字段为
 *   version / suiteWireId / encapsulatedKey / nonce / ciphertext / tag
 *   （`P2PHPKESealedBox.kt:22-28`），AAD 不进入 `combinedWithHeader()` 的字节。
 *   该项**不是被忽略**，而是该面没有可生成、可往返的 AAD 字段；若 Apple 侧的密封盒携带 AAD，
 *   那是一处线格式差异，须按 G5 记入 `gaps/wire-protocol-pending.md`，不在此处臆造字段。
 * - **`nonceLen` / `tagLen` 只取 production codec 接受的 canonical 组合**：v1 为 12/16，
 *   v2 为 0/0。其他 v2 组合在编码和解码边界均被拒绝，由专项负向测试覆盖。
 *
 * ## 迭代次数
 *
 * R9.5 要求不少于 1000 个随机用例：本属性 1000 次，另加密文上限（65536 B）专项 20 次。
 *
 * ## 随机种子
 *
 * 由 `F3_ROUNDTRIP_PBT_SEED` 指定，未指定时随机取值并打印到测试输出。
 */
@OptIn(ExperimentalKotest::class)
class HpkeSealedBoxRoundTripPropertyTest : FunSpec({

    val adapter = HpkeSealedBoxCodecAdapter

    val seed: Long = System.getenv("F3_ROUNDTRIP_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 3] F3 HPKE sealed box round-trip PBT effective seed = $seed")
        println(
            "[Property 3] reproduce with: F3_ROUNDTRIP_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*HpkeSealedBoxRoundTripPropertyTest*'",
        )
    }

    // R9.5：不少于 1000 个随机生成用例。
    val config = PropTestConfig(seed = seed, iterations = 1_000)

    test("Property 3 (F3): decode(encode(v)) 逐字段等于 v，且合并编码 ≤128 KiB") {
        var v1 = 0
        var v2 = 0
        var zeroNonce = 0
        var zeroTag = 0
        var emptyEnc = 0
        var emptyCiphertext = 0
        var largeCiphertext = 0
        var maxEncoded = 0

        checkAll(config, hpkeSealedBoxArb) { box ->
            val encoded = adapter.encode(box)

            // R9.5 的上界：合并编码 ≤131072 B。
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true
            // 合并编码长度的结构等式（17 B 头部 + 四段载荷），顺带固定线格式布局。
            encoded.size shouldBe
                17 + box.encapsulatedKey.size + box.nonce.size + box.ciphertext.size + box.tag.size

            val decoded = adapter.decode(encoded).valueOrFail()

            val mismatch = hpkeFieldMismatch(box, decoded)
            if (mismatch != null) {
                throw AssertionError("F3 往返不保真：$mismatch；编码 ${encoded.size} B")
            }

            // 解码结果不得与输入字节共享存储（改动解码值不应影响已接收数据，R9.6）。
            val snapshot = encoded.copyOf()
            decoded.ciphertext.fill(0x5A)
            encoded.contentEquals(snapshot) shouldBe true

            if (box.version == 1) v1++ else v2++
            if (box.nonce.isEmpty()) zeroNonce++
            if (box.tag.isEmpty()) zeroTag++
            if (box.encapsulatedKey.isEmpty()) emptyEnc++
            if (box.ciphertext.isEmpty()) emptyCiphertext++
            if (box.ciphertext.size > 32_768) largeCiphertext++
            if (encoded.size > maxEncoded) maxEncoded = encoded.size
        }

        println(
            "[Property 3] v1=$v1 v2=$v2 零nonce=$zeroNonce 零tag=$zeroTag 空enc=$emptyEnc " +
                "空密文=$emptyCiphertext 大密文(>32KiB)=$largeCiphertext 最大编码=$maxEncoded B",
        )

        // 反空真：两个版本、v2 的零长 nonce/tag、空/大密文都必须被真正生成到。
        (v1 > 0) shouldBe true
        (v2 > 0) shouldBe true
        (zeroNonce > 0) shouldBe true
        (zeroTag > 0) shouldBe true
        (emptyEnc > 0) shouldBe true
        (emptyCiphertext > 0) shouldBe true
        (largeCiphertext > 0) shouldBe true
    }

    test("Property 3 (F3/密文上限): ctLen = 65536（parse 的 maxCt）仍往返且远低于 128 KiB") {
        var checked = 0
        var maxEncoded = 0

        val atCapArb = arbitrary {
            val version = Arb.element(1, 2).bind()
            val nonceLength = if (version == 1) 12 else 0
            val tagLength = if (version == 1) 16 else 0
            P2PHPKESealedBox(
                version = version,
                suiteWireId = Arb.int(0..0xFFFF).bind().toUShort(),
                encapsulatedKey = byteArrayArb(1216, 1216).bind(),
                nonce = byteArrayArb(nonceLength, nonceLength).bind(),
                ciphertext = byteArrayArb(65_536, 65_536).bind(),
                tag = byteArrayArb(tagLength, tagLength).bind(),
            )
        }

        checkAll(PropTestConfig(seed = seed, iterations = 20), atCapArb) { box ->
            val encoded = adapter.encode(box)
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true

            val decoded = adapter.decode(encoded).valueOrFail()
            val mismatch = hpkeFieldMismatch(box, decoded)
            if (mismatch != null) {
                throw AssertionError("F3 上限附近往返不保真：$mismatch；编码 ${encoded.size} B")
            }

            checked++
            if (encoded.size > maxEncoded) maxEncoded = encoded.size
        }

        println(
            "[Property 3/密文上限] 用例=$checked 编码=$maxEncoded B（R9.5 上限 ${adapter.maxEncodedBytes} B）",
        )

        (checked > 0) shouldBe true

        val fixedV1 = P2PHPKESealedBox(
            version = 1,
            suiteWireId = 0x0101u,
            encapsulatedKey = ByteArray(1_216),
            nonce = ByteArray(12),
            ciphertext = ByteArray(65_536),
            tag = ByteArray(16),
        )
        val fixedV2 = P2PHPKESealedBox(
            version = 2,
            suiteWireId = 0x0101u,
            encapsulatedKey = ByteArray(1_216),
            nonce = ByteArray(0),
            ciphertext = ByteArray(65_536),
            tag = ByteArray(0),
        )
        adapter.encode(fixedV1).size shouldBe 66_797
        adapter.encode(fixedV2).size shouldBe 66_769
    }
})
