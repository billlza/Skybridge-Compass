package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

import com.skybridge.compass.filetransfer.webrtc.OrderedChunkDeliveryTracker
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.crypto.MerkleSha256
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import java.util.Random
import java.util.UUID

/**
 * **Feature: cross-platform-parity-audit, Property 31: 已送达状态的前置事件必含完成确认**
 *
 * **Validates: Requirements 5.10**
 *
 * 任务 11.15。属性：发送端把一次传输判定为"已送达"的**前置事件序列中必然包含对端的完成确认
 * 消息**（`op=completeAck`）；仅"本端队列已全部写出"绝不足以判定送达。
 *
 * 判据（不依赖私有状态，全部经真实生产入口观测）：
 *  - "已送达"的可观测代理量是**该传输的检查点被删除**——生产代码只在收到 `completeAck` 时对一个
 *    正常进行中的发送传输执行"停止跟踪 + 删除检查点"（见 `handleIncoming` 的 `completeAck` 分支）。
 *  - **必要性**：把 metadata → 全部 chunk → complete 全部写出、并让对端把**每一个分块**都
 *    `chunkAck` 确认（即"发送队列已全部写出且全部分块已确认"），但**不发** `completeAck`：
 *    此时检查点**必须仍然存在**（仍呈现为进行中），且批内状态不得为 COMPLETED。
 *  - **充分性（对照组）**：其后补上 `completeAck`，检查点必须被删除、批内状态转为 COMPLETED。
 *  - **交叉核对**：[OrderedChunkDeliveryTracker.isAllDelivered] 为真（全部分块已确认）**仍不**
 *    等价于送达——它只是必要条件，充分性由接收端完整性校验后发出的 `completeAck` 提供。
 *  - **反例分支**：以 `op=error` 结束的传输永不被判为送达（批内状态为 FAILED）。
 *
 * 定义域：发送侧内存传输；批次包裹（单文件批次）用于让"是否 COMPLETED"成为可观测的叶子值。
 */
class DeliveryRequiresCompleteAckPropertyTest : FunSpec({

    val shapeArb: Arb<Pair<Int, Int>> = Arb.bind(
        Arb.element(2, 4, 8, 16, 32),
        Arb.int(1..10),
    ) { chunkSize, chunks -> chunkSize to chunks }

    test("Property 31: 全部分块已确认但无 completeAck 时不判送达；补上 completeAck 才判送达") {
        var singleChunkCases = 0
        var multiChunkCases = 0
        var allChunksAckedCases = 0

        checkAll(300, shapeArb, Arb.int()) { (chunkSize, chunks), seed ->
            val payload = ByteArray(chunkSize * chunks).also { Random(seed.toLong()).nextBytes(it) }

            val transport = PropertyRecordingTransport()
            val checkpointStore = PropertyCheckpointStore()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                checkpointStore = checkpointStore,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )

            // 单文件批次：批内条目状态是"是否已送达"的可观测叶子值。
            val item = WebRtcFileTransferController.BatchBytesItem(
                fileName = "delivered.bin",
                bytes = payload,
                relativePath = "delivered.bin",
            )
            controller.sendBytesAsFilesBatch(listOf(item), chunkSize = chunkSize)

            val metadata = transport.messagesOf(CrossNetworkFileTransferOp.metadata).single()
            val transferId = metadata.transferId

            // 本端队列已全部写出：metadata + 全部 chunk + complete 都在线上。
            transport.messagesOf(CrossNetworkFileTransferOp.chunk).size shouldBe chunks
            transport.messagesOf(CrossNetworkFileTransferOp.complete).size shouldBe 1

            withTimeout(5_000) {
                while (checkpointStore.peek(transferId) == null) yield()
            }

            // 对端逐块确认**全部**分块（但不发 completeAck）。
            (0 until chunks).forEach { index ->
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.chunkAck,
                            transferId = transferId,
                            chunkIndex = index,
                        )
                    )
                )
            }
            checkpointStore.awaitQuiescence()
            allChunksAckedCases++

            // **必要性**：全部写出 + 全部分块已确认，但没有完成确认 ⇒ 仍不判送达。
            (checkpointStore.peek(transferId) != null) shouldBe true
            controller.batchProgress.value.completedCount shouldBe 0
            controller.batchProgress.value.files.single().status shouldBe
                com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry.Status.IN_PROGRESS

            // 交叉核对：纯判定单元里"全部已确认"为真，但那只是必要条件。
            val tracker = OrderedChunkDeliveryTracker(chunks)
            (0 until chunks).forEach { tracker.markDelivered(it) }
            tracker.isAllDelivered() shouldBe true

            // **充分性**：补上对端完成确认 ⇒ 判为送达（停止跟踪、删除检查点、批内 COMPLETED）。
            controller.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.completeAck,
                        transferId = transferId,
                    )
                )
            )
            withTimeout(5_000) {
                while (checkpointStore.peek(transferId) != null) yield()
            }
            checkpointStore.peek(transferId) shouldBe null
            controller.batchProgress.value.completedCount shouldBe 1
            controller.batchProgress.value.fraction shouldBe 1.0

            if (chunks == 1) singleChunkCases++ else multiChunkCases++
        }

        println(
            "Property 31 branch coverage: singleChunk=$singleChunkCases multiChunk=$multiChunkCases " +
                "allChunksAckedWithoutCompleteAck=$allChunksAckedCases"
        )
        (singleChunkCases > 0) shouldBe true
        (multiChunkCases > 0) shouldBe true
        (allChunksAckedCases > 0) shouldBe true
    }

    test("Property 31 (反例): 以 error 结束或未确认的传输永不被判为已送达") {
        var errorCases = 0
        var silentCases = 0

        checkAll(250, shapeArb, Arb.int(), Arb.element(true, false)) { (chunkSize, chunks), seed, endWithError ->
            val payload = ByteArray(chunkSize * chunks).also { Random(seed.toLong()).nextBytes(it) }

            val transport = PropertyRecordingTransport()
            val checkpointStore = PropertyCheckpointStore()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                checkpointStore = checkpointStore,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )

            val item = WebRtcFileTransferController.BatchBytesItem(
                fileName = "undelivered.bin",
                bytes = payload,
                relativePath = "undelivered.bin",
            )
            controller.sendBytesAsFilesBatch(listOf(item), chunkSize = chunkSize)
            val transferId = transport.messagesOf(CrossNetworkFileTransferOp.metadata).single().transferId

            withTimeout(5_000) {
                while (checkpointStore.peek(transferId) == null) yield()
            }

            if (endWithError) {
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.error,
                            transferId = transferId,
                            message = "merkle root mismatch",
                        )
                    )
                )
                checkpointStore.awaitQuiescence()
                // 以 error 结束：批内状态为 FAILED，绝不计入已送达。
                controller.batchProgress.value.completedCount shouldBe 0
                controller.batchProgress.value.failedCount shouldBe 1
                (controller.progress.value.lastStatus?.startsWith("peer error") == true) shouldBe true
                errorCases++
            } else {
                // 对端完全沉默：既无 completeAck 也无 error ⇒ 仍呈现为进行中。
                checkpointStore.awaitQuiescence()
                (checkpointStore.peek(transferId) != null) shouldBe true
                controller.batchProgress.value.completedCount shouldBe 0
                controller.batchProgress.value.failedCount shouldBe 0
                silentCases++
            }

            // 两条分支下都从未产生"已送达"的满进度。
            (controller.batchProgress.value.fraction < 1.0) shouldBe true

            // 测试卫生（在全部断言之后）：释放仍在跟踪的传输，避免补发循环累积。
            controller.cancel(transferId)
        }

        println("Property 31 (反例) branch coverage: peerError=$errorCases peerSilent=$silentCases")
        (errorCases > 0) shouldBe true
        (silentCases > 0) shouldBe true
    }
})
