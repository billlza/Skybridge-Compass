package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.P2PHPKESealedBox
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 17.2 的 F3 专项测试：`P2PHPKESealedBox.parse` 的 `require` 归一化，
 * 且**接受/拒绝边界不被改变**（R9.6 的硬约束，改变边界即改变线协议 G4/G5）。
 *
 * 核心手段是**对照测试**：对同一批输入分别调用
 * - 生产入口 `P2PHPKESealedBox.parse`（经 [HpkeSealedBoxCodecAdapter.parseDirectly] 包一层 `runCatching`），
 * - 适配层 [HpkeSealedBoxCodecAdapter.decode]，
 *
 * 断言二者判定**逐输入一致**：`parse` 成功 ⇔ 适配器 Success 且值相等；`parse` 抛异常 ⇔ 适配器返回错误。
 */
@DisplayName("F3 HPKE 密封盒适配器与接受/拒绝边界保持")
class HpkeSealedBoxCodecAdapterTest {

    private val adapter = HpkeSealedBoxCodecAdapter

    private fun box(
        version: Int = 1,
        suiteWireId: UShort = 0x0101u,
        encLen: Int = 32,
        nonceLen: Int = 12,
        ctLen: Int = 64,
        tagLen: Int = 16,
    ) = P2PHPKESealedBox(
        version = version,
        suiteWireId = suiteWireId,
        encapsulatedKey = ByteArray(encLen) { (it and 0xFF).toByte() },
        nonce = ByteArray(nonceLen) { (it + 1 and 0xFF).toByte() },
        ciphertext = ByteArray(ctLen) { (it * 3 and 0xFF).toByte() },
        tag = ByteArray(tagLen) { (it * 5 and 0xFF).toByte() },
    )

    /** 手工拼装一个 header，用于构造声明长度与实际长度不一致的输入。 */
    private fun header(
        magic: ByteArray = byteArrayOf(0x48, 0x50, 0x4B, 0x45),
        version: Int = 1,
        suiteWireId: Int = 0x0101,
        encLen: Int,
        nonceLen: Int,
        tagLen: Int,
        ctLen: Int,
        payload: ByteArray = ByteArray(0),
    ): ByteArray {
        val bb = ByteBuffer.allocate(17 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(magic)
        bb.put(version.toByte())
        bb.putShort(suiteWireId.toShort())
        bb.putShort(0)
        bb.putShort(encLen.toShort())
        bb.put(nonceLen.toByte())
        bb.put(tagLen.toByte())
        bb.putInt(ctLen)
        bb.put(payload)
        return bb.array()
    }

    private fun assertBoxEquals(expected: P2PHPKESealedBox, actual: P2PHPKESealedBox) {
        assertEquals(expected.version, actual.version)
        assertEquals(expected.suiteWireId, actual.suiteWireId)
        assertArrayEquals(expected.encapsulatedKey, actual.encapsulatedKey)
        assertArrayEquals(expected.nonce, actual.nonce)
        assertArrayEquals(expected.ciphertext, actual.ciphertext)
        assertArrayEquals(expected.tag, actual.tag)
    }

    // ===================================================================
    // 基本契约与往返
    // ===================================================================

    @Nested
    @DisplayName("委托与往返")
    inner class Delegation {

        @Test
        @DisplayName("委托 combinedWithHeader / parse，上限取自 CodecSurface（128 KiB）")
        fun delegatesToProduction() {
            assertEquals(CodecSurface.F3_HPKE_SEALED_BOX, adapter.surface)
            assertTrue(adapter.delegatesTo.contains("P2PHPKESealedBox.kt:29"))
            assertTrue(adapter.delegatesTo.contains("P2PHPKESealedBox.kt:52"))
            assertEquals(128 * 1024, adapter.maxEncodedBytes)
        }

        @Test
        @DisplayName("往返：decode(encode(v)) 逐字段等于 v")
        fun roundTrip() {
            val original = box()
            val decoded = adapter.decode(adapter.encode(original)).valueOrFail()
            assertBoxEquals(original, decoded)
        }

        @Test
        @DisplayName("version 1 与 version 2 都往返成功（含 v2 的 0 长 nonce/tag）")
        fun roundTripBothVersions() {
            assertBoxEquals(box(version = 1), adapter.decode(adapter.encode(box(version = 1))).valueOrFail())
            val v2 = box(version = 2, nonceLen = 0, tagLen = 0)
            assertBoxEquals(v2, adapter.decode(adapter.encode(v2)).valueOrFail())
        }

        @Test
        @DisplayName("encode 的字节与生产 combinedWithHeader 完全一致（未改变编码）")
        fun encodeMatchesProductionBytes() {
            val value = box()
            assertArrayEquals(value.combinedWithHeader(), adapter.encode(value))
        }
    }

    // ===================================================================
    // require → 两类可判别错误
    // ===================================================================

    @Nested
    @DisplayName("require 归一为两类可判别错误")
    inner class ErrorNormalization {

        @Test
        @DisplayName("过短（不足 17 B 头部）→ 格式非法，而非抛 IllegalArgumentException")
        fun tooShortIsMalformed() {
            for (size in 0 until 17) {
                val result = adapter.decode(ByteArray(size))
                assertInstanceOf(
                    CodecResult.MalformedFormat::class.java,
                    result,
                    "size=$size must be MalformedFormat",
                )
            }
        }

        @Test
        @DisplayName("魔数不符 → 格式非法")
        fun badMagicIsMalformed() {
            val bytes = adapter.encode(box())
            bytes[0] = 0x00
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(bytes))
        }

        @Test
        @DisplayName("不支持的版本 → 格式非法")
        fun unsupportedVersionIsMalformed() {
            listOf(0, 3, 255).forEach { version ->
                val bytes = adapter.encode(box())
                bytes[4] = version.toByte()
                assertInstanceOf(
                    CodecResult.MalformedFormat::class.java,
                    adapter.decode(bytes),
                    "version=$version must be MalformedFormat",
                )
            }
        }

        @Test
        @DisplayName("v1 的 nonceLen/tagLen 非法 → 格式非法")
        fun badV1LengthsAreMalformed() {
            val badNonce = header(encLen = 0, nonceLen = 11, tagLen = 16, ctLen = 0)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(badNonce))

            val badTag = header(encLen = 0, nonceLen = 12, tagLen = 15, ctLen = 0)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(badTag))
        }

        @Test
        @DisplayName("encLen 超过 4096 → 格式非法（生产 require 的语义，非本面 128 KiB 上限）")
        fun encLenTooLargeIsMalformed() {
            val bytes = header(encLen = 4097, nonceLen = 12, tagLen = 16, ctLen = 0)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(bytes))
        }

        @Test
        @DisplayName("声明总长与实际长度不一致 → 格式非法")
        fun lengthMismatchIsMalformed() {
            val bytes = header(encLen = 32, nonceLen = 12, tagLen = 16, ctLen = 64)
            // 头部声明 32+12+64+16 = 124 B 载荷，实际 0 B。
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(bytes))
        }

        @Test
        @DisplayName("实际字节超过 128 KiB → 超出长度上限（与格式非法可判别）")
        fun overCapIsLengthCap() {
            val over = ByteArray(128 * 1024 + 1)
            val result = adapter.decode(over)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(128 * 1024 + 1, cap.actualBytes)
            assertEquals(128 * 1024, cap.maxEncodedBytes)
            assertEquals(LengthCapScope.WHOLE_MESSAGE, cap.scope)
            assertTrue(result !is CodecResult.MalformedFormat)
        }

        @Test
        @DisplayName("上限内的超大 ctLen 声明 → 格式非法（属于格式问题，不是长度上限问题）")
        fun withinCapButHugeCtLenIsMalformed() {
            val bytes = header(encLen = 0, nonceLen = 12, tagLen = 16, ctLen = Int.MAX_VALUE)
            val result = adapter.decode(bytes)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
            assertTrue(result !is CodecResult.ExceedsLengthCap)
        }

        @Test
        @DisplayName("ctLen 为负 → 格式非法（不预分配）")
        fun negativeCtLenIsMalformed() {
            val bytes = header(encLen = 0, nonceLen = 12, tagLen = 16, ctLen = -1)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, adapter.decode(bytes))
        }
    }

    // ===================================================================
    // 边界保持（核心）
    // ===================================================================

    @Nested
    @DisplayName("接受/拒绝边界保持：适配层与生产 parse 判定逐输入一致")
    inner class BoundaryPreservation {

        /**
         * 覆盖生产 `parse` 每一条 `require` 的两侧，外加随机与截断输入。
         */
        private fun boundaryCorpus(): List<Pair<String, ByteArray>> {
            val corpus = mutableListOf<Pair<String, ByteArray>>()

            // 合法样本（各版本 / 各长度组合）
            corpus += "valid-v1" to box(version = 1).combinedWithHeader()
            corpus += "valid-v2-zero-nonce-tag" to
                box(version = 2, nonceLen = 0, tagLen = 0).combinedWithHeader()
            corpus += "valid-empty-ct" to box(ctLen = 0).combinedWithHeader()
            corpus += "valid-empty-enc" to box(encLen = 0).combinedWithHeader()

            // encLen 边界：4096 接受 / 4097 拒绝
            corpus += "encLen-4096" to box(encLen = 4096).combinedWithHeader()
            corpus += "encLen-4097-header" to
                header(encLen = 4097, nonceLen = 12, tagLen = 16, ctLen = 0)

            // ctLen 边界（isHandshake=true 上限 64 KiB）：65536 接受 / 65537 拒绝
            corpus += "ctLen-65536" to box(encLen = 0, ctLen = 65_536).combinedWithHeader()
            corpus += "ctLen-65537" to box(encLen = 0, ctLen = 65_537).combinedWithHeader()

            // 头部长度边界：16 / 17 B
            corpus += "size-16" to ByteArray(16)
            corpus += "size-17-zero" to ByteArray(17)

            // 魔数 / 版本 / nonceLen / tagLen 各非法值
            corpus += "bad-magic" to
                header(magic = byteArrayOf(0x48, 0x50, 0x4B, 0x00), encLen = 0, nonceLen = 12, tagLen = 16, ctLen = 0)
            listOf(0, 3, 255).forEach { v ->
                corpus += "version-$v" to
                    header(version = v, encLen = 0, nonceLen = 12, tagLen = 16, ctLen = 0)
            }
            listOf(0, 11, 13, 255).forEach { n ->
                corpus += "v1-nonceLen-$n" to
                    header(version = 1, encLen = 0, nonceLen = n, tagLen = 16, ctLen = 0)
                corpus += "v2-nonceLen-$n" to
                    header(version = 2, encLen = 0, nonceLen = n, tagLen = 16, ctLen = 0)
            }
            listOf(0, 15, 17, 255).forEach { t ->
                corpus += "v1-tagLen-$t" to
                    header(version = 1, encLen = 0, nonceLen = 12, tagLen = t, ctLen = 0)
                corpus += "v2-tagLen-$t" to
                    header(version = 2, encLen = 0, nonceLen = 12, tagLen = t, ctLen = 0)
            }
            corpus += "v2-v1-nonce-only" to
                header(version = 2, encLen = 0, nonceLen = 12, tagLen = 0, ctLen = 0)
            corpus += "v2-v1-tag-only" to
                header(version = 2, encLen = 0, nonceLen = 0, tagLen = 16, ctLen = 0)
            corpus += "v2-v1-nonce-and-tag" to
                header(version = 2, encLen = 0, nonceLen = 12, tagLen = 16, ctLen = 0)

            // 声明长度与实际长度差 ±1（length mismatch 两侧）
            val base = box(encLen = 8, ctLen = 8).combinedWithHeader()
            corpus += "exact" to base
            corpus += "one-byte-short" to base.copyOf(base.size - 1)
            corpus += "one-byte-long" to (base + byteArrayOf(0x00))

            // 截断的合法样本，逐字节
            val full = box(encLen = 4, ctLen = 4).combinedWithHeader()
            for (cut in 0..full.size) {
                corpus += "truncated-$cut" to full.copyOf(cut)
            }

            // 随机字节
            val random = Random(0xF3_17_02L)
            repeat(400) { i ->
                val bytes = ByteArray(random.nextInt(80)).also { random.nextBytes(it) }
                corpus += "random-$i" to bytes
            }
            // 随机但带正确魔数的字节（更容易走进 header 之后的分支）
            repeat(400) { i ->
                val bytes = ByteArray(17 + random.nextInt(64)).also { random.nextBytes(it) }
                bytes[0] = 0x48; bytes[1] = 0x50; bytes[2] = 0x4B; bytes[3] = 0x45
                bytes[4] = if (i % 2 == 0) 1 else 2
                corpus += "random-magic-$i" to bytes
            }

            return corpus
        }

        @Test
        @DisplayName("凡 parse 接受者适配器必接受且值相同；凡 parse 拒绝者适配器必返回可判别错误")
        fun acceptRejectBoundaryIsUnchanged() {
            var acceptedCount = 0
            var rejectedCount = 0

            boundaryCorpus().forEach { (label, bytes) ->
                val direct = HpkeSealedBoxCodecAdapter.parseDirectly(bytes)
                val adapted = adapter.decode(bytes)

                if (direct.isSuccess) {
                    acceptedCount++
                    val expected = direct.getOrThrow()
                    assertTrue(
                        adapted is CodecResult.Success,
                        "[$label] production parse accepted but adapter rejected: boundary changed",
                    )
                    assertBoxEquals(expected, (adapted as CodecResult.Success).value)
                } else {
                    rejectedCount++
                    assertTrue(
                        adapted is CodecResult.MalformedFormat || adapted is CodecResult.ExceedsLengthCap,
                        "[$label] production parse rejected but adapter accepted: boundary changed",
                    )
                }
            }

            // 语料必须真的覆盖到两侧，否则这条测试可以空转通过。
            assertTrue(acceptedCount >= 8, "corpus must contain accepted inputs, was $acceptedCount")
            assertTrue(rejectedCount >= 50, "corpus must contain rejected inputs, was $rejectedCount")
        }

        @Test
        @DisplayName("适配器接受的最大合并长度（69677 B）严格小于 128 KiB 上限")
        fun maximumParseableSizeIsBelowTheCap() {
            // parse 在 isHandshake=true 下的理论上界：17 + 4096 + 12 + 65536 + 16。
            val theoreticalMax = 17 + 4096 + 12 + 65_536 + 16
            assertEquals(69_677, theoreticalMax)
            assertTrue(
                theoreticalMax < adapter.maxEncodedBytes,
                "cap pre-check must not be able to reject anything parse would accept",
            )

            // 实证：构造该理论最大样本，两条路径都接受。
            val largest = box(encLen = 4096, nonceLen = 12, ctLen = 65_536, tagLen = 16)
            val bytes = largest.combinedWithHeader()
            assertEquals(theoreticalMax, bytes.size)
            assertTrue(HpkeSealedBoxCodecAdapter.parseDirectly(bytes).isSuccess)
            assertBoxEquals(largest, adapter.decode(bytes).valueOrFail())
        }

        @Test
        @DisplayName("任意字节永不抛异常，且不修改入参")
        fun arbitraryBytesNeverThrow() {
            val random = Random(0xBEEF_F3L)
            repeat(1_000) {
                val bytes = ByteArray(random.nextInt(200)).also { random.nextBytes(it) }
                val snapshot = bytes.copyOf()
                adapter.decode(bytes)
                assertArrayEquals(snapshot, bytes)
            }
        }

        @Test
        @DisplayName("成功解析产出的是输入的副本，改动结果不影响已接收数据")
        fun decodeDoesNotAliasReceivedBytes() {
            val bytes = adapter.encode(box(encLen = 4, ctLen = 4))
            val snapshot = bytes.copyOf()
            val decoded = adapter.decode(bytes).valueOrFail()

            decoded.ciphertext.fill(0x7F)
            decoded.nonce.fill(0x7E)
            decoded.tag.fill(0x7D)
            decoded.encapsulatedKey.fill(0x7C)

            assertArrayEquals(snapshot, bytes, "mutating the decoded value must not touch received bytes")
        }
    }
}
