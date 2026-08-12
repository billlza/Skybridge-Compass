package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.PropTestConfig
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 1: 文件传输消息序列化往返**
 *
 * **Validates: Requirements 9.2**
 *
 * 任务 17.3。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3：仅 Kotlin）。
 * 被测对象是 [FileTransferMessageCodecAdapter]，它委托生产入口
 * `CrossNetworkFileTransferWireCodec.kt` 的 canonical 编码/兼容解码，本测试**不改变任何编码**（G4）。
 *
 * ## 属性
 *
 * 对生成范围内的任意 [com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage]，
 * `decode(encode(v))` 产出与 `v` **所有字段逐一相等**的对象，且编码长度 ≤1 MiB。
 *
 * 逐字段比较用 [fileTransferFieldMismatch]，**不用** `==`：该 `data class` 含 `ByteArray` /
 * `IntArray` 字段，自动生成的 `equals` 对它们按引用比较，`==` 会让本属性变成一条几乎不可能
 * 通过、且通过时也不证明字节内容相等的伪断言。
 *
 * ## 定义域（窄于 R9.2 的部分已逐条记录）
 *
 * 见 [fileTransferMessageArbFor] 的 KDoc 对照表。唯一的收窄是 `chunkIndex` 取
 * 0..[Int.MAX_VALUE] 而非 R9.2 的 0..4_294_967_295——Android 侧字段类型为 `Int?`
 * （`CrossNetworkFileTransferWire.kt:41`），无法表达 2^31..2^32−1。该差异是字段类型所致，
 * 已记录，不通过修改字段类型来"满足"需求（G4：不改线格式）。
 *
 * ## 迭代次数
 *
 * R9.2 要求**每种消息类型不少于 1000 个随机用例**：8 种消息类型各 1000 次，另加一条
 * 上限附近（512 KiB..760 KiB `chunkData`）的大载荷属性 30 次。
 *
 * ## 反空真（anti-vacuous-truth）
 *
 * 每条属性统计其真正走到的分支计数并在 `checkAll` 后断言全部 > 0，同时打印计数：
 * 仅生成"字段几乎全为 null 的最小消息"也能让往返通过，但那不证明任何字节字段往返正确。
 *
 * ## 随机种子
 *
 * 由 `F1_ROUNDTRIP_PBT_SEED` 指定，未指定时随机取值并打印到测试输出（R9.2 要求种子可复现）。
 */
@OptIn(ExperimentalKotest::class)
class FileTransferRoundTripPropertyTest : FunSpec({

    val adapter = FileTransferMessageCodecAdapter

    val seed: Long = System.getenv("F1_ROUNDTRIP_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 1] F1 file-transfer round-trip PBT effective seed = $seed")
        println(
            "[Property 1] reproduce with: F1_ROUNDTRIP_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*FileTransferRoundTripPropertyTest*'",
        )
    }

    // R9.2：每种消息类型不少于 1000 个随机生成用例。
    val config = PropTestConfig(seed = seed, iterations = 1_000)

    CrossNetworkFileTransferOp.entries.forEach { op ->
        test("Property 1 (F1/$op): decode(encode(v)) 逐字段等于 v，且编码 ≤1 MiB") {
            // 分支计数器：证明该属性不是在"最小消息"上空转通过。
            var withChunkData = 0
            var withoutChunkData = 0
            var withMissingChunks = 0
            var withNonAsciiText = 0
            var withAllOptionalNull = 0
            var encodedOver4KiB = 0
            var maxEncodedBytes = 0

            checkAll(config, fileTransferMessageArbFor(op)) { message ->
                val encoded = adapter.encode(message)

                // R9.2 的编码长度上界：单条 ≤1 MiB。
                (encoded.size <= adapter.maxEncodedBytes) shouldBe true

                val decoded = adapter.decode(encoded).valueOrFail()

                // 核心断言：所有字段逐一相等。
                val mismatch = fileTransferFieldMismatch(message, decoded)
                if (mismatch != null) {
                    throw AssertionError(
                        "F1 往返不保真（op=$op）：$mismatch；编码 ${encoded.size} B",
                    )
                }

                // 统计
                if (message.chunkData != null) withChunkData++ else withoutChunkData++
                if (message.missingChunks != null) withMissingChunks++
                val text = listOfNotNull(
                    message.fileName, message.senderDeviceName, message.relativePath, message.message,
                ).joinToString("")
                if (text.any { it.code > 127 }) withNonAsciiText++
                val optionalAllNull = message.fileName == null && message.chunkData == null &&
                    message.missingChunks == null && message.merkleRoot == null &&
                    message.senderDeviceId == null
                if (optionalAllNull) withAllOptionalNull++
                if (encoded.size > 4096) encodedOver4KiB++
                if (encoded.size > maxEncodedBytes) maxEncodedBytes = encoded.size
            }

            println(
                "[Property 1/$op] chunkData=$withChunkData/无=$withoutChunkData " +
                    "missingChunks=$withMissingChunks 非ASCII文本=$withNonAsciiText " +
                    "可选全null=$withAllOptionalNull 编码>4KiB=$encodedOver4KiB " +
                    "最大编码=$maxEncodedBytes B",
            )

            // 反空真：每条分支都必须真正被走到。
            (withChunkData > 0) shouldBe true
            if (op == CrossNetworkFileTransferOp.chunk) {
                // chunk 消息恒携带 chunkData（该消息类型的语义要求），故"无 chunkData"分支
                // 对它不可达；此处断言"恒携带"而非"两分支都到"，避免为了凑分支而生成
                // 语义上不存在的 chunk 消息。
                withChunkData shouldBe 1_000
                withoutChunkData shouldBe 0
            } else {
                (withoutChunkData > 0) shouldBe true
            }
            (withMissingChunks > 0) shouldBe true
            (withNonAsciiText > 0) shouldBe true
            (encodedOver4KiB > 0) shouldBe true
            // 上限断言必须真正被检验过（即确实产生过非空编码）。
            (maxEncodedBytes > 0) shouldBe true
        }
    }

    test("Property 1 (F1/上限附近): 512 KiB..760 KiB chunkData 仍逐字段往返且 ≤1 MiB") {
        var checked = 0
        var maxEncoded = 0

        checkAll(
            PropTestConfig(seed = seed, iterations = 30),
            fileTransferLargeMessageArb,
        ) { message ->
            val encoded = adapter.encode(message)
            (encoded.size <= adapter.maxEncodedBytes) shouldBe true

            val decoded = adapter.decode(encoded).valueOrFail()
            val mismatch = fileTransferFieldMismatch(message, decoded)
            if (mismatch != null) {
                throw AssertionError("F1 大载荷往返不保真：$mismatch；编码 ${encoded.size} B")
            }

            checked++
            if (encoded.size > maxEncoded) maxEncoded = encoded.size
        }

        println("[Property 1/大载荷] 用例=$checked 最大编码=$maxEncoded B（上限 ${adapter.maxEncodedBytes} B）")

        (checked > 0) shouldBe true
        // 反空真：大载荷属性必须真的生成了大编码（>512 KiB），否则它与普通属性无区别。
        (maxEncoded > 512 * 1024) shouldBe true
    }
})
