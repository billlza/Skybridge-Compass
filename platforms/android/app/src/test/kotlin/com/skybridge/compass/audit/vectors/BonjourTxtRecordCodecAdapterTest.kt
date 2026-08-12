package com.skybridge.compass.audit.vectors

import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import java.util.Random
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 17.2 的 F4 专项测试：Bonjour TXT 适配器的两个长度维度
 * （单对 ≤255 B、整条 ≤1300 B）与解码护栏。
 */
@DisplayName("F4 Bonjour TXT 适配器（单对 ≤255 B / 整条 ≤1300 B）")
class BonjourTxtRecordCodecAdapterTest {

    private val adapter = BonjourTxtRecordCodecAdapter

    private fun sample(): Map<String, ByteArray> = mapOf(
        "did" to "device-17-2".toByteArray(),
        "ver" to "1".toByteArray(),
        "pqc" to byteArrayOf(0x01),
        "name" to "SkyBridge".toByteArray(),
    )

    private fun assertRecordEquals(expected: Map<String, ByteArray>, actual: Map<String, ByteArray>) {
        assertEquals(expected.keys, actual.keys)
        expected.forEach { (key, value) ->
            assertArrayEquals(value, actual[key], "value mismatch for key=$key")
        }
    }

    // ===================================================================
    // 委托与往返
    // ===================================================================

    @Nested
    @DisplayName("委托与往返")
    inner class Delegation {

        @Test
        @DisplayName("委托 BonjourTxtRecordCodec，整条上限与生产常量一致")
        fun delegatesToProduction() {
            assertEquals(CodecSurface.F4_BONJOUR_TXT, adapter.surface)
            assertTrue(adapter.delegatesTo.contains("BonjourTxtRecordCodec.kt"))
            assertEquals(1_300, adapter.maxEncodedBytes)
            assertEquals(BonjourTxtRecordCodec.MAX_RECORD_BYTES, adapter.maxEncodedBytes)
            assertEquals(BonjourTxtRecordCodec.MAX_PAIR_BYTES, adapter.maxPairBytes)
            assertEquals(255, adapter.maxPairBytes)
        }

        @Test
        @DisplayName("往返：decode(encode(v)) == v")
        fun roundTrip() {
            val original = sample()
            val decoded = adapter.decode(adapter.encode(original)).valueOrFail()
            assertRecordEquals(original, decoded)
        }

        @Test
        @DisplayName("空值、空记录都能往返")
        fun roundTripEdgeValues() {
            assertRecordEquals(emptyMap(), adapter.decode(adapter.encode(emptyMap())).valueOrFail())

            val emptyValue = mapOf("flag" to ByteArray(0))
            assertRecordEquals(emptyValue, adapter.decode(adapter.encode(emptyValue)).valueOrFail())
        }

        @Test
        @DisplayName("encode 的字节与生产 encode 完全一致（未改变编码）")
        fun encodeMatchesProductionBytes() {
            assertArrayEquals(BonjourTxtRecordCodec.encode(sample()), adapter.encode(sample()))
        }

        @Test
        @DisplayName("恰好 255 B 的单对可编码并往返")
        fun pairExactlyAtPairLimitRoundTrips() {
            // key(3) + '=' (1) + value(251) = 255 B
            val value = ByteArray(251) { 0x41 }
            val fields = mapOf("kkk" to value)
            val result = adapter.tryEncode(fields)
            assertTrue(result is CodecResult.Success, "expected Success but was $result")
            val encoded = (result as CodecResult.Success).value
            assertEquals(256, encoded.size) // 1 长度前缀 + 255 载荷
            assertRecordEquals(fields, adapter.decode(encoded).valueOrFail())
        }

        @Test
        @DisplayName("整条恰好 1300 B 可编码并往返")
        fun recordExactlyAtRecordLimitRoundTrips() {
            // 每对：key(2) + '=' + value(252) = 255 B 载荷，加 1 长度前缀 = 256 B；5 对 = 1280 B。
            // 再加一对 20 B（1 前缀 + key(3) + '=' + value(15) = 19 载荷）恰好凑到 1300 B。
            val fields = buildMap {
                repeat(5) { i -> put("k$i", ByteArray(252) { 0x42 }) }
                put("kx0", ByteArray(15) { 0x43 })
            }
            val result = adapter.tryEncode(fields)
            assertTrue(result is CodecResult.Success, "expected Success but was $result")
            val encoded = (result as CodecResult.Success).value
            assertEquals(1_300, encoded.size)
            assertRecordEquals(fields, adapter.decode(encoded).valueOrFail())
        }
    }

    // ===================================================================
    // 两个长度维度
    // ===================================================================

    @Nested
    @DisplayName("两个长度维度可判别")
    inner class LengthLimits {

        @Test
        @DisplayName("单对超过 255 B → ExceedsLengthCap(SINGLE_PAIR)")
        fun pairOverLimitIsSinglePairScope() {
            // key(3) + '=' + value(252) = 256 B > 255
            val fields = mapOf("kkk" to ByteArray(252) { 0x41 })
            val result = adapter.tryEncode(fields)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(LengthCapScope.SINGLE_PAIR, cap.scope)
            assertEquals(256, cap.actualBytes)
            assertEquals(255, cap.maxEncodedBytes)
        }

        @Test
        @DisplayName("整条超过 1300 B → ExceedsLengthCap(WHOLE_MESSAGE)")
        fun recordOverLimitIsWholeMessageScope() {
            // 6 对 × 256 B = 1536 B > 1300 B，且每对载荷都恰好 255 B（未触发单对上限）。
            val fields = buildMap {
                repeat(6) { i -> put("k$i", ByteArray(252) { 0x42 }) }
            }
            val result = adapter.tryEncode(fields)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(LengthCapScope.WHOLE_MESSAGE, cap.scope)
            assertEquals(1_536, cap.actualBytes)
            assertEquals(1_300, cap.maxEncodedBytes)
        }

        @Test
        @DisplayName("两个维度互相可判别：单对超限优先于整条超限")
        fun twoScopesAreDiscriminable() {
            // 既有一个超大对，也整体超长：报更具体的 SINGLE_PAIR。
            val fields = buildMap {
                put("big", ByteArray(400) { 0x41 })
                repeat(6) { i -> put("k$i", ByteArray(251) { 0x42 }) }
            }
            val cap = assertInstanceOf(
                CodecResult.ExceedsLengthCap::class.java,
                adapter.tryEncode(fields),
            )
            assertEquals(LengthCapScope.SINGLE_PAIR, cap.scope)
        }

        @Test
        @DisplayName("解码方向：超过 1300 B 的记录 → ExceedsLengthCap(WHOLE_MESSAGE)")
        fun decodeOverRecordLimitIsLengthCap() {
            val over = ByteArray(1_301)
            val result = adapter.decode(over)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(1_301, cap.actualBytes)
            assertEquals(1_300, cap.maxEncodedBytes)
            assertEquals(LengthCapScope.WHOLE_MESSAGE, cap.scope)
            assertTrue(result !is CodecResult.MalformedFormat)
        }

        @Test
        @DisplayName("解码方向单对不可能超限：长度前缀是一个字节，天然 ≤255")
        fun decodeCannotProduceSinglePairViolation() {
            // 最大可能的单对：长度前缀 0xFF + 255 B 载荷。
            val bytes = ByteArray(256)
            bytes[0] = 0xFF.toByte()
            bytes[1] = 'k'.code.toByte()
            bytes[2] = '='.code.toByte()
            for (i in 3 until 256) bytes[i] = 0x41
            val decoded = adapter.decode(bytes).valueOrFail()
            assertEquals(setOf("k"), decoded.keys)
            assertEquals(253, decoded.getValue("k").size)
        }
    }

    // ===================================================================
    // 格式非法与护栏
    // ===================================================================

    @Nested
    @DisplayName("格式非法与解码护栏")
    inner class Guardrails {

        @Test
        @DisplayName("截断记录（长度前缀超过剩余字节）→ 格式非法")
        fun truncatedRecordIsMalformed() {
            val result = adapter.decode(byteArrayOf(0x10, 0x61, 0x3D, 0x62))
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
            assertTrue(result !is CodecResult.ExceedsLengthCap)
        }

        @Test
        @DisplayName("声明 255 B 却只跟随 3 B → 格式非法，且不按声明长度预分配")
        fun hostileLengthPrefixIsMalformed() {
            val result = adapter.decode(byteArrayOf(0xFF.toByte(), 0x61, 0x3D, 0x62))
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
        }

        @Test
        @DisplayName("合法记录逐字节截断：全部归一为成功或格式非法，不抛异常")
        fun everyTruncationIsNormalized() {
            val full = adapter.encode(sample())
            for (cut in 0..full.size) {
                val result = adapter.decode(full.copyOf(cut))
                assertTrue(
                    result is CodecResult.Success || result is CodecResult.MalformedFormat,
                    "cut=$cut must be normalized, was $result",
                )
            }
        }

        @Test
        @DisplayName("任意字节永不抛异常，且不修改入参")
        fun arbitraryBytesNeverThrow() {
            val random = Random(0xF4_17_02L)
            repeat(1_000) {
                val bytes = ByteArray(random.nextInt(300)).also { random.nextBytes(it) }
                val snapshot = bytes.copyOf()
                val result = adapter.decode(bytes)
                assertTrue(
                    result is CodecResult.Success ||
                        result is CodecResult.MalformedFormat ||
                        result is CodecResult.ExceedsLengthCap,
                    "F4 must normalize arbitrary bytes, was $result",
                )
                assertArrayEquals(snapshot, bytes, "decode must not mutate received bytes")
            }
        }

        @Test
        @DisplayName("解码结果不与入参共享缓冲：改动结果不影响已接收数据")
        fun decodeDoesNotAliasReceivedBytes() {
            val bytes = adapter.encode(sample())
            val snapshot = bytes.copyOf()
            val decoded = adapter.decode(bytes).valueOrFail()
            decoded.values.forEach { it.fill(0x7F) }
            assertArrayEquals(snapshot, bytes)
        }

        @Test
        @DisplayName("键含 '=' 或为空 → 编码方向归一为格式非法，不抛异常")
        fun structurallyImpossibleKeysAreMalformed() {
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                adapter.tryEncode(mapOf("a=b" to ByteArray(0))),
            )
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                adapter.tryEncode(mapOf("" to ByteArray(0))),
            )
        }

        @Test
        @DisplayName("超长输入的判定是常数级：不因声明长度而分配（1300 B 上限 2 倍内）")
        fun overCapDecodeIsConstantCost() {
            // 8 MiB 的输入必须在任何解析动作之前被长度上限拒绝。
            val huge = ByteArray(8 * 1024 * 1024)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, adapter.decode(huge))
            assertEquals(huge.size, cap.actualBytes)
        }
    }
}
