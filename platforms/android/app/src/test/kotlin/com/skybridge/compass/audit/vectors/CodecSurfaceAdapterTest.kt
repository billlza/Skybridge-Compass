package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.P2PCryptoCapabilities
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import java.util.Random
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 17.2 单元测试：`CodecSurfaceAdapter` 的三态结果与 R9.6 解码护栏。
 *
 * R9.6 考察的是解码器健壮性，主要用合成/敌意字节覆盖；MessageA/B 的正向入口另使用
 * fresh Apple production-codec corpus。23 条 Apple canonical byte equality 由 Property 5 独立覆盖。
 */
@DisplayName("任务 17.2 四面 CodecSurfaceAdapter 与解码器护栏")
class CodecSurfaceAdapterTest {

    // ===================================================================
    // 通用契约
    // ===================================================================

    @Nested
    @DisplayName("通用契约：上限真源与三态可判别")
    inner class GeneralContract {

        @Test
        @DisplayName("每个适配器的 maxEncodedBytes 来自 CodecSurface，不自行声明上限")
        fun capsComeFromCodecSurface() {
            allCodecSurfaceAdapters.forEach { adapter ->
                assertEquals(
                    adapter.surface.maxEncodedBytes,
                    adapter.maxEncodedBytes,
                    "${adapter.surface.id} cap must be the CodecSurface value",
                )
            }
        }

        @Test
        @DisplayName("四个面全部被适配器覆盖")
        fun everySurfaceIsCovered() {
            val covered = allCodecSurfaceAdapters.map { it.surface }.toSet()
            assertEquals(CodecSurface.entries.toSet(), covered)
        }

        @Test
        @DisplayName("每个适配器都记录其委托的生产入口（文件:行）")
        fun everyAdapterDeclaresDelegationTarget() {
            allCodecSurfaceAdapters.forEach { adapter ->
                assertTrue(
                    adapter.delegatesTo.contains(".kt:"),
                    "${adapter.surface.id} must cite a production entry point as 文件:行",
                )
            }
        }

        @Test
        @DisplayName("格式非法与超出长度上限是两个不同的变体，可判别且不相等")
        fun twoErrorKindsAreDiscriminable() {
            val malformed: CodecResult<Unit> = CodecResult.MalformedFormat("bad")
            val toolong: CodecResult<Unit> = CodecResult.ExceedsLengthCap(10, 5)

            assertInstanceOf(CodecResult.MalformedFormat::class.java, malformed)
            assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, toolong)
            assertTrue(malformed !is CodecResult.ExceedsLengthCap)
            assertTrue(toolong !is CodecResult.MalformedFormat)
            assertNotEquals(malformed as Any, toolong as Any)
            assertTrue(!malformed.isSuccess && !toolong.isSuccess)
        }

        @Test
        @DisplayName("每个可编码面：超出上限 1 字节即报 ExceedsLengthCap，且与格式非法可区分")
        fun overCapInputIsClassifiedAsLengthCapForEverySurface() {
            allCodecSurfaceAdapters.forEach { adapter ->
                val over = ByteArray(adapter.maxEncodedBytes + 1)
                val result = adapter.decode(over)
                val cap = assertInstanceOf(
                    CodecResult.ExceedsLengthCap::class.java,
                    result,
                    "${adapter.surface.id} must report ExceedsLengthCap for over-cap input",
                )
                assertEquals(adapter.maxEncodedBytes + 1, cap.actualBytes)
                assertEquals(adapter.maxEncodedBytes, cap.maxEncodedBytes)
                assertEquals(LengthCapScope.WHOLE_MESSAGE, cap.scope)
            }
        }

        @Test
        @DisplayName("恰好等于上限的输入不按长度拒绝（边界不被上限检查外扩）")
        fun exactlyAtCapIsNotRejectedByLength() {
            allCodecSurfaceAdapters.forEach { adapter ->
                val atCap = ByteArray(adapter.maxEncodedBytes)
                val result = adapter.decode(atCap)
                assertTrue(
                    result !is CodecResult.ExceedsLengthCap,
                    "${adapter.surface.id} must not length-reject input exactly at the cap",
                )
            }
        }

        @Test
        @DisplayName("任意字节序列都不抛未捕获异常，且不修改入参数组")
        fun arbitraryBytesNeverThrowAndNeverMutateInput() {
            val random = Random(0x17_02_5EED)
            allCodecSurfaceAdapters.forEach { adapter ->
                repeat(120) {
                    val size = random.nextInt(80)
                    val bytes = ByteArray(size).also { random.nextBytes(it) }
                    val snapshot = bytes.copyOf()

                    // 不抛异常：任何异常都会让该测试失败。
                    val result = adapter.decode(bytes)

                    assertTrue(
                        result is CodecResult.Success ||
                            result is CodecResult.MalformedFormat ||
                            result is CodecResult.ExceedsLengthCap,
                        "${adapter.surface.id} must return one of the three states",
                    )
                    assertArrayEquals(
                        snapshot,
                        bytes,
                        "${adapter.surface.id} decode must not mutate already-received bytes",
                    )
                }
            }
        }

        @Test
        @DisplayName("空输入不抛异常")
        fun emptyInputNeverThrows() {
            allCodecSurfaceAdapters.forEach { adapter ->
                // 空输入不属于「超出长度上限」，只能是成功或格式非法。
                val result = adapter.decode(ByteArray(0))
                assertTrue(
                    result is CodecResult.Success || result is CodecResult.MalformedFormat,
                    "${adapter.surface.id} empty input must be Success or MalformedFormat, was $result",
                )
            }
        }

        @Test
        @DisplayName("声明超大长度但实际字节很短的敌意输入被拒绝而非预分配缓冲")
        fun hostileDeclaredLengthDoesNotPreallocate() {
            // 每个面构造「头部声明一个巨大长度、实际只有十几字节」的输入。
            // 若解码器在校验前按声明长度预分配，这里会 OOM 或耗时暴涨；正常应立即返回错误。
            val hostileInputs = listOf(
                // F3：magic + version=1 + suite + flags + encLen=0xFFFF + nonce=12 + tag=16 + ctLen=0x7FFFFFF0
                byteArrayOf(
                    0x48, 0x50, 0x4B, 0x45, 0x01, 0x00, 0x00, 0x00, 0x00,
                    0xFF.toByte(), 0xFF.toByte(), 0x0C, 0x10,
                    0xF0.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x7F,
                ),
                // F4：长度前缀声明 255 B 但只跟随 3 B
                byteArrayOf(0xFF.toByte(), 0x61, 0x3D, 0x62),
                // F2 deterministic：u32 数组长度 = 0x7FFFFFF0，随后无数据
                byteArrayOf(0xF0.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x7F),
            )

            allCodecSurfaceAdapters.forEach { adapter ->
                hostileInputs.forEach { hostile ->
                    val snapshot = hostile.copyOf()
                    val result = adapter.decode(hostile)
                    assertTrue(
                        result is CodecResult.Success ||
                            result is CodecResult.MalformedFormat ||
                            result is CodecResult.ExceedsLengthCap,
                        "${adapter.surface.id} must handle hostile declared lengths without preallocating",
                    )
                    assertArrayEquals(snapshot, hostile)
                }
            }
        }
    }

    // ===================================================================
    // F1 文件传输消息
    // ===================================================================

    @Nested
    @DisplayName("F1 文件传输消息（≤1 MiB）")
    inner class F1FileTransfer {

        private val adapter = FileTransferMessageCodecAdapter

        private fun sample() = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.metadata,
            transferId = "transfer-17-2",
            fileName = "report.pdf",
            fileSize = 4096L,
            chunkSize = 1024,
            totalChunks = 4,
            mimeType = "application/pdf",
        )

        @Test
        @DisplayName("委托生产入口而非重新实现")
        fun delegatesToProduction() {
            assertEquals(CodecSurface.F1_FILE_TRANSFER, adapter.surface)
            assertTrue(adapter.delegatesTo.contains("CrossNetworkFileTransferWireCodec.kt:"))
            assertTrue(adapter.delegatesTo.contains("encode"))
            assertTrue(adapter.delegatesTo.contains("decode"))
            assertEquals(1 * 1024 * 1024, adapter.maxEncodedBytes)
        }

        @Test
        @DisplayName("有效值往返：decode(encode(v)) == v")
        fun roundTrip() {
            val original = sample()
            val bytes = adapter.encode(original)
            val decoded = adapter.decode(bytes).valueOrFail()
            assertEquals(original, decoded)
        }

        @Test
        @DisplayName("往返对每个 op 都成立")
        fun roundTripForEveryOp() {
            CrossNetworkFileTransferOp.entries.forEach { op ->
                val msg = CrossNetworkFileTransferMessage(op = op, transferId = "t-${op.name}")
                val decoded = adapter.decode(adapter.encode(msg)).valueOrFail()
                assertEquals(msg, decoded)
            }
        }

        @Test
        @DisplayName("带二进制字段（base64）的消息往返保持字节相等")
        fun roundTripWithBinaryFields() {
            val chunk = ByteArray(256) { (it and 0xFF).toByte() }
            val msg = CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.chunk,
                transferId = "t-bin",
                chunkIndex = 3,
                chunkData = chunk,
            )
            val decoded = adapter.decode(adapter.encode(msg)).valueOrFail()
            assertArrayEquals(chunk, decoded.chunkData)
        }

        @Test
        @DisplayName("非 JSON 字节 → 格式非法")
        fun malformedJsonIsMalformedFormat() {
            val result = adapter.decode("{not json at all".encodeToByteArray())
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
        }

        @Test
        @DisplayName("缺少必填字段的 JSON → 格式非法")
        fun missingRequiredFieldIsMalformedFormat() {
            val result = adapter.decode("""{"version":1}""".encodeToByteArray())
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
        }

        @Test
        @DisplayName("超过 1 MiB → 超出长度上限，且与格式非法可判别")
        fun overCapIsExceedsLengthCap() {
            val over = ByteArray(1 * 1024 * 1024 + 1) { '{'.code.toByte() }
            val result = adapter.decode(over)
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(1 * 1024 * 1024 + 1, cap.actualBytes)
            assertTrue(result !is CodecResult.MalformedFormat)
        }

        @Test
        @DisplayName("上限内但内容非法 → 格式非法（两类错误互斥）")
        fun withinCapMalformedStaysMalformed() {
            val within = ByteArray(4096) { 'x'.code.toByte() }
            val result = adapter.decode(within)
            assertInstanceOf(CodecResult.MalformedFormat::class.java, result)
            assertTrue(result !is CodecResult.ExceedsLengthCap)
        }
    }

    // ===================================================================
    // F2 P2P 握手消息
    // ===================================================================

    @Nested
    @DisplayName("F2 P2P 握手消息（≤65535 B）")
    inner class F2Handshake {

        @Test
        @DisplayName("Finished 往返：decode(encode(v)) == v")
        fun finishedRoundTrip() {
            P2PHandshakeWire.FinishedDirection.entries.forEach { direction ->
                val mac = ByteArray(32) { (it * 7 and 0xFF).toByte() }
                val encoded = P2PHandshakeWire.encodeFinished(direction, mac)
                val decoded = HandshakeFinishedCodecAdapter.decode(encoded).valueOrFail()
                assertEquals(direction, decoded.direction)
                assertArrayEquals(mac, decoded.mac)
                assertArrayEquals(encoded, HandshakeFinishedCodecAdapter.encode(decoded))
            }
        }

        @Test
        @DisplayName("Finished 魔数错误 → 格式非法")
        fun finishedBadMagicIsMalformed() {
            val bytes = P2PHandshakeWire.encodeFinished(
                P2PHandshakeWire.FinishedDirection.INITIATOR_TO_RESPONDER,
                ByteArray(32),
            )
            bytes[0] = 0x00
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                HandshakeFinishedCodecAdapter.decode(bytes),
            )
        }

        @Test
        @DisplayName("Finished 截断 → 格式非法")
        fun finishedTruncatedIsMalformed() {
            val bytes = P2PHandshakeWire.encodeFinished(
                P2PHandshakeWire.FinishedDirection.RESPONDER_TO_INITIATOR,
                ByteArray(32),
            )
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                HandshakeFinishedCodecAdapter.decode(bytes.copyOf(20)),
            )
        }

        @Test
        @DisplayName("Finished 方向字节非法 → 格式非法")
        fun finishedBadDirectionIsMalformed() {
            val bytes = P2PHandshakeWire.encodeFinished(
                P2PHandshakeWire.FinishedDirection.INITIATOR_TO_RESPONDER,
                ByteArray(32),
            )
            bytes[5] = 0x7F
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                HandshakeFinishedCodecAdapter.decode(bytes),
            )
        }

        @Test
        @DisplayName("Finished 超过 65535 B → 超出长度上限")
        fun finishedOverCapIsLengthCap() {
            val result = HandshakeFinishedCodecAdapter.decode(ByteArray(65_536))
            val cap = assertInstanceOf(CodecResult.ExceedsLengthCap::class.java, result)
            assertEquals(65_535, cap.maxEncodedBytes)
        }

        @Test
        @DisplayName("CryptoCapabilities 往返：decode(encode(v)) == v")
        fun capabilitiesRoundTrip() {
            val value = P2PCryptoCapabilities(
                supportedKEM = listOf("x-wing", "mlkem-768"),
                supportedSignature = listOf("ed25519", "mldsa-65"),
                supportedAuthProfiles = listOf("context-bound"),
                supportedAEAD = listOf("chachapoly", "aesgcm"),
                pqcAvailable = true,
                platformVersion = "android-37",
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT,
            )
            val decoded = P2PCryptoCapabilitiesCodecAdapter
                .decode(P2PCryptoCapabilitiesCodecAdapter.encode(value))
                .valueOrFail()
            assertEquals(value, decoded)
        }

        @Test
        @DisplayName("CryptoCapabilities 尾随字节 → 格式非法（保持生产 require 边界）")
        fun capabilitiesTrailingBytesIsMalformed() {
            val value = P2PCryptoCapabilities(
                supportedKEM = listOf("mlkem-768"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = emptyList(),
                supportedAEAD = listOf("aesgcm"),
                pqcAvailable = false,
                platformVersion = "android-37",
                providerTypeRaw = "libaoqs",
            )
            val withTrailer = P2PCryptoCapabilitiesCodecAdapter.encode(value) + byteArrayOf(0x00)
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                P2PCryptoCapabilitiesCodecAdapter.decode(withTrailer),
            )
        }

        @Test
        @DisplayName("CryptoCapabilities 截断 → 格式非法")
        fun capabilitiesTruncatedIsMalformed() {
            val value = P2PCryptoCapabilities(
                supportedKEM = listOf("mlkem-768"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = emptyList(),
                supportedAEAD = listOf("aesgcm"),
                pqcAvailable = false,
                platformVersion = "android-37",
                providerTypeRaw = "liboqs",
            )
            val encoded = P2PCryptoCapabilitiesCodecAdapter.encode(value)
            assertInstanceOf(
                CodecResult.MalformedFormat::class.java,
                P2PCryptoCapabilitiesCodecAdapter.decode(encoded.copyOf(encoded.size / 2)),
            )
        }

        @Test
        @DisplayName("HandshakePolicy 往返：decode(encode(v)) == v")
        fun policyRoundTrip() {
            listOf(
                P2PHandshakePolicy.DEFAULT,
                P2PHandshakePolicy(
                    requirePqc = false,
                    allowClassicFallback = true,
                    minimumTierRaw = "classic",
                    requireSecureEnclavePoP = true,
                ),
            ).forEach { value ->
                val decoded = P2PHandshakePolicyCodecAdapter
                    .decode(P2PHandshakePolicyCodecAdapter.encode(value))
                    .valueOrFail()
                assertEquals(value, decoded)
            }
        }

        @Test
        @DisplayName("HandshakePolicy 空字节仍返回 DEFAULT（不改变生产接受边界）")
        fun policyEmptyInputKeepsProductionAcceptBoundary() {
            // 生产 deterministicDecode 对空输入返回 DEFAULT 而非拒绝；适配层必须保留。
            val decoded = P2PHandshakePolicyCodecAdapter.decode(ByteArray(0)).valueOrFail()
            assertEquals(P2PHandshakePolicy.DEFAULT, decoded)
        }

        @Test
        @DisplayName("MessageA/MessageB 任意字节被归一为两类错误，不抛异常")
        fun messageDecodersNormalizeArbitraryBytes() {
            val random = Random(0x17_02_A_B)
            listOf(HandshakeMessageACodecAdapter, HandshakeMessageBCodecAdapter).forEach { decoder ->
                repeat(100) {
                    val bytes = ByteArray(random.nextInt(64)).also { random.nextBytes(it) }
                    val snapshot = bytes.copyOf()
                    val result = decoder.decode(bytes)
                    assertTrue(
                        result is CodecResult.Success ||
                            result is CodecResult.MalformedFormat ||
                            result is CodecResult.ExceedsLengthCap,
                        "${decoder.surface.id} must normalize arbitrary bytes, was $result",
                    )
                    assertArrayEquals(snapshot, bytes)
                }
            }
        }

        @Test
        @DisplayName("MessageA 声明长度超过剩余字节 → 格式非法（不预分配）")
        fun messageATruncatedFieldIsMalformed() {
            // version + suitesCount=1 + suite + ksCount=1 + suiteId + shareLen=0xFFFF，随后无数据。
            val hostile = byteArrayOf(
                0x01,
                0x01, 0x00,
                0x01, 0x01,
                0x01, 0x00,
                0x01, 0x01,
                0xFF.toByte(), 0xFF.toByte(),
            )
            val result = HandshakeMessageACodecAdapter.decode(hostile)
            assertTrue(result !is CodecResult.Success)
        }

        @Test
        @DisplayName("MessageA/MessageB 编解码均委托唯一生产入口")
        fun messageSurfacesUseShippingEncoders() {
            assertSame(CodecSurface.F2_P2P_HANDSHAKE, HandshakeMessageACodecAdapter.surface)
            assertSame(CodecSurface.F2_P2P_HANDSHAKE, HandshakeMessageBCodecAdapter.surface)

            val loader = CompatibilityVectorLoader.fromWorkspace()
            val messageABytes = loader
                .loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageA")
                .single()
                .rawBytes
            val messageBBytes = loader
                .loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageB")
                .single()
                .rawBytes
            assertArrayEquals(
                messageABytes,
                HandshakeMessageACodecAdapter.encode(
                    HandshakeMessageACodecAdapter.decode(messageABytes).valueOrFail(),
                ),
            )
            assertArrayEquals(
                messageBBytes,
                HandshakeMessageBCodecAdapter.encode(
                    HandshakeMessageBCodecAdapter.decode(messageBBytes).valueOrFail(),
                ),
            )
        }
    }
}
