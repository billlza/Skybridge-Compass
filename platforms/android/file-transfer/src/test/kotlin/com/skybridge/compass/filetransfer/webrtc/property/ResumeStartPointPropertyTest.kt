package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming
import com.skybridge.compass.filetransfer.webrtc.TestWebRtcSecureOperationOwner

import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.filetransfer.webrtc.resume.ResumeReceivePlanner
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.assertions.throwables.shouldThrowAny
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll
import kotlinx.coroutines.yield
import java.io.ByteArrayInputStream
import java.util.Random
import java.util.UUID

/**
 * **Feature: cross-platform-parity-audit, Property 28: 续传起点为最后一个校验通过的分块边界**
 *
 * **Validates: Requirements 5.6, 5.7**
 *
 * 任务 11.12。属性分两半，分别覆盖发送侧与接收侧的续传起点：
 *
 * **发送侧（经真实入口 [WebRtcFileTransferController.resumeSendFromCheckpoint]）**：
 * 对任意"已确认分块集合"，续传首轮重发的分块集合**恰好**是其补集——已确认的分块一个都不重传
 * （R5.6"不重传已确认的分块"），未确认的一个都不漏；且续传仍会重发 metadata 与 complete 以推动
 * 对端定案，并注册发送上下文使定向 NACK 仍只补发被点名的那一块。
 *
 * **接收侧（经真实入口 [ResumeReceivePlanner.restoreContiguousPrefix]）**：
 * 恢复出的前缀长度**恰好**是分块对齐的部分文件长度所代表的连续块数，起点即"最后一个校验通过的
 * 分块边界"；而与部分文件不一致的检查点（缺连续块、缺/坏散列、长度未对齐）一律被**拒绝**，
 * 绝不用于续传——这正是"起点必须是校验通过的边界"的反面保证。
 *
 * 定义域：分块条数 1..24（保证单次迭代有界）；发送侧走内存流（`openStream` 提供全量字节），
 * 与文件大小是否超过重发缓存上限无关的那一半 R5.7 由 `resumeSendFromCheckpoint` 的检查点驱动语义
 * 覆盖——起点始终取自检查点而非缓存。
 */
class ResumeStartPointPropertyTest : FunSpec({

    val shapeArb: Arb<Pair<Int, Int>> = Arb.bind(
        Arb.element(1, 2, 4, 8, 16, 32),
        Arb.int(1..24),
    ) { chunkSize, chunks -> chunkSize to chunks }

    test("Property 28 (发送侧): 续传只重发未确认分块，起点即最后一个已确认边界") {
        var noneAcked = 0
        var someAcked = 0
        var allAcked = 0

        checkAll(300, shapeArb, Arb.int()) { (chunkSize, chunks), seed ->
            val random = Random(seed.toLong())
            val fileSize = chunkSize.toLong() * chunks.toLong()
            val payload = ByteArray(fileSize.toInt()).also { random.nextBytes(it) }

            // 随机的已确认分块集合（可为空、可为全集、可为任意子集）。
            val acked = (0 until chunks).filter { random.nextBoolean() }.toSortedSet()

            val transport = PropertyRecordingTransport()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )
            val transferId = UUID.randomUUID().toString()

            val checkpoint = TransferCheckpoint.newSend(
                transferId = transferId,
                sourceUri = null,
                fileName = "resume.bin",
                mimeType = "application/octet-stream",
                fileSize = fileSize,
                chunkSize = chunkSize,
                totalChunks = chunks,
            ).copy(ackedChunks = acked.toIntArray())

            controller.resumeSendFromCheckpoint(
                checkpoint = checkpoint,
                owner = TestWebRtcSecureOperationOwner,
                mimeType = "application/octet-stream",
                openStream = { ByteArrayInputStream(payload) },
            )

            // 核心断言：首轮重发的分块集合 == 未确认分块集合（补集），逐元素相等。
            val resentIndices = transport.messagesOf(CrossNetworkFileTransferOp.chunk)
                .mapNotNull { it.chunkIndex }
            val expectedResend = (0 until chunks).filterNot { it in acked }
            resentIndices shouldBe expectedResend

            // 已确认的分块一个都没被重传。
            resentIndices.none { it in acked } shouldBe true

            // 续传仍重发 metadata 与 complete（推动对端定案），且分块字节与原文一致。
            transport.messagesOf(CrossNetworkFileTransferOp.metadata)
                .any { it.transferId == transferId } shouldBe true
            transport.messagesOf(CrossNetworkFileTransferOp.complete)
                .any { it.transferId == transferId } shouldBe true
            transport.messagesOf(CrossNetworkFileTransferOp.chunk).forEach { message ->
                val index = requireNotNull(message.chunkIndex)
                val data = requireNotNull(message.chunkData)
                val expectedBytes = payload.copyOfRange(
                    index * chunkSize,
                    minOf((index + 1) * chunkSize, payload.size),
                )
                data.contentEquals(expectedBytes) shouldBe true
            }

            // 续传注册了发送上下文：定向 NACK 只补发被点名的那一块（起点不回退到 0）。
            val nackTarget = random.nextInt(chunks)
            transport.clear()
            controller.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.chunkAck,
                        transferId = transferId,
                        missingChunks = intArrayOf(nackTarget),
                        message = "missingChunks",
                    )
                )
            )
            repeat(5) { yield() }
            transport.messagesOf(CrossNetworkFileTransferOp.chunk)
                .mapNotNull { it.chunkIndex } shouldBe listOf(nackTarget)

            when (acked.size) {
                0 -> noneAcked++
                chunks -> allAcked++
                else -> someAcked++
            }

            // 测试卫生（在全部断言之后）：释放本次迭代的补发循环。
            controller.cancel(transferId)
        }

        // 非空真保证：未确认/部分确认/全确认三个分支都被走到。
        println(
            "Property 28 (发送侧) branch coverage: noneAcked=$noneAcked someAcked=$someAcked allAcked=$allAcked"
        )
        (noneAcked > 0) shouldBe true
        (someAcked > 0) shouldBe true
        (allAcked > 0) shouldBe true
    }

    test("Property 28 (接收侧): 对齐前缀被接受为续传起点，不一致检查点被拒绝") {
        var zeroPrefix = 0
        var partialPrefix = 0
        var fullPrefix = 0
        var rejectedUnaligned = 0
        var rejectedMissingChunk = 0
        var rejectedBadHash = 0

        val recvShapeArb: Arb<Triple<Int, Int, Int>> = Arb.bind(
            Arb.element(2, 4, 8, 16, 32),
            Arb.int(1..24),
            Arb.int(0..1_000_000),
        ) { chunkSize, chunks, prefixRaw -> Triple(chunkSize, chunks, prefixRaw) }

        checkAll(
            300,
            recvShapeArb,
            Arb.element("ok", "unaligned", "missing-chunk", "bad-hash"),
        ) { (chunkSize, chunks, prefixRaw), variant ->
            val fileSize = chunkSize.toLong() * chunks.toLong()
            val prefixChunks = prefixRaw % (chunks + 1)
            val partialLength = chunkSize.toLong() * prefixChunks.toLong()

            val received = (0 until prefixChunks).toMutableSet()
            val hashes = received.associateWith { index ->
                sha256(byteArrayOf(index.toByte())).joinToString("") { "%02x".format(it) }
            }.toMutableMap()

            when (variant) {
                "ok" -> {
                    val restored = ResumeReceivePlanner.restoreContiguousPrefix(
                        fileSize = fileSize,
                        chunkSize = chunkSize,
                        totalChunks = chunks,
                        partialLength = partialLength,
                        receivedChunks = received,
                        receivedChunkSha256HexByIndex = hashes,
                    )
                    // 起点恰为分块对齐的边界：块数与字节数自洽。
                    restored.prefixChunks shouldBe prefixChunks
                    restored.restoredBytes shouldBe partialLength
                    restored.chunkHashesByIndex.keys shouldBe (0 until prefixChunks).toSet()
                    restored.chunkHashesByIndex.values.all { it.size == ResumeReceivePlanner.SHA256_BYTES } shouldBe true
                    // 与独立判据交叉核对。
                    ResumeReceivePlanner.prefixChunksForPartialLength(
                        fileSize, chunkSize, chunks, partialLength,
                    ) shouldBe prefixChunks

                    when (prefixChunks) {
                        0 -> zeroPrefix++
                        chunks -> fullPrefix++
                        else -> partialPrefix++
                    }
                }
                "unaligned" -> {
                    // 未对齐长度（非 0、非满、非分块整数倍）必须被拒绝，不得用于续传。
                    val unaligned = partialLength + 1L
                    if (unaligned < fileSize && unaligned % chunkSize.toLong() != 0L) {
                        shouldThrowAny {
                            ResumeReceivePlanner.restoreContiguousPrefix(
                                fileSize = fileSize,
                                chunkSize = chunkSize,
                                totalChunks = chunks,
                                partialLength = unaligned,
                                receivedChunks = received,
                                receivedChunkSha256HexByIndex = hashes,
                            )
                        }
                        rejectedUnaligned++
                    }
                }
                "missing-chunk" -> {
                    // 缺少连续块中的一块 ⇒ 检查点与部分文件不一致 ⇒ 拒绝。
                    if (prefixChunks > 0) {
                        received.remove(prefixChunks - 1)
                        shouldThrowAny {
                            ResumeReceivePlanner.restoreContiguousPrefix(
                                fileSize = fileSize,
                                chunkSize = chunkSize,
                                totalChunks = chunks,
                                partialLength = partialLength,
                                receivedChunks = received,
                                receivedChunkSha256HexByIndex = hashes,
                            )
                        }
                        rejectedMissingChunk++
                    }
                }
                else -> {
                    // 散列长度非法 ⇒ 该边界未被校验通过 ⇒ 拒绝。
                    if (prefixChunks > 0) {
                        hashes[prefixChunks - 1] = "abcd"
                        shouldThrowAny {
                            ResumeReceivePlanner.restoreContiguousPrefix(
                                fileSize = fileSize,
                                chunkSize = chunkSize,
                                totalChunks = chunks,
                                partialLength = partialLength,
                                receivedChunks = received,
                                receivedChunkSha256HexByIndex = hashes,
                            )
                        }
                        rejectedBadHash++
                    }
                }
            }
        }

        // 非空真保证：三种接受形态与三种拒绝形态都被真正走到。
        println(
            "Property 28 (接收侧) branch coverage: zeroPrefix=$zeroPrefix partialPrefix=$partialPrefix " +
                "fullPrefix=$fullPrefix rejectUnaligned=$rejectedUnaligned " +
                "rejectMissingChunk=$rejectedMissingChunk rejectBadHash=$rejectedBadHash"
        )
        (zeroPrefix > 0) shouldBe true
        (partialPrefix > 0) shouldBe true
        (fullPrefix > 0) shouldBe true
        (rejectedUnaligned > 0) shouldBe true
        (rejectedMissingChunk > 0) shouldBe true
        (rejectedBadHash > 0) shouldBe true
    }
})
