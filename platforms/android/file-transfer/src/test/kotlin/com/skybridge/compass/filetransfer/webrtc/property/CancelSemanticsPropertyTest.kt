package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import java.util.Random
import java.util.UUID

/**
 * **Feature: cross-platform-parity-audit, Property 27: 取消语义**
 *
 * **Validates: Requirements 5.5**
 *
 * 任务 11.11。属性：对任意进行中的传输，取消**恰好**作用于被取消的那一路，且作用完整：
 *
 *  1. **立即停止**：取消后，针对该 transferId 的 NACK（`missingChunks`）不再引发任何补发；
 *  2. **释放资源**：该传输的检查点被删除（不再作为续传候选）；
 *  3. **通知对端**：本地发起的取消恰好发出一条 `op=cancel`（复用既有 wire 枚举，非协议变更）；
 *     对端发来的取消**不回声**（不再发 `op=cancel`）；
 *  4. **状态可见**：`progress.lastStatus` 反映取消来源（本地 `cancelled` / 对端 `cancelled by peer`）；
 *  5. **隔离性**：并发的另一路传输不受影响——其检查点存活，且其 NACK 仍能触发补发。
 *
 * 属性经真实生产入口 [WebRtcFileTransferController.cancel] 与
 * [WebRtcFileTransferController.handleIncoming]（`op=cancel`）驱动。
 *
 * 定义域：两路并发的内存发送传输；取消目标随机取"第一路/第二路"，取消来源随机取"本地/对端"，
 * 另外单独覆盖"取消一个未被跟踪的 transferId"这一退化输入（必须无副作用、不抛异常）。
 */
class CancelSemanticsPropertyTest : FunSpec({

    val shapeArb: Arb<Pair<Int, Int>> = Arb.bind(
        Arb.element(2, 4, 8, 16),
        Arb.int(2..10),
    ) { chunkSize, chunks -> chunkSize to chunks }

    test("Property 27: 取消只停止目标传输、释放其资源并通知对端；并发传输不受影响") {
        var localCancels = 0
        var peerCancels = 0
        var cancelledFirst = 0
        var cancelledSecond = 0

        checkAll(
            250,
            shapeArb,
            Arb.int(),
            Arb.boolean(),
            Arb.boolean(),
        ) { (chunkSize, chunks), payloadSeed, cancelLocally, cancelFirst ->
            val fileSize = chunkSize * chunks
            val random = Random(payloadSeed.toLong())
            val payloadA = ByteArray(fileSize).also { random.nextBytes(it) }
            val payloadB = ByteArray(fileSize).also { random.nextBytes(it) }

            val transport = PropertyRecordingTransport()
            val checkpointStore = PropertyCheckpointStore()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                checkpointStore = checkpointStore,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )

            val idA = UUID.randomUUID().toString()
            val idB = UUID.randomUUID().toString()
            // 无对端接线：ack 永不到达，两路都停留在"进行中"，故取消是有意义的操作。
            controller.sendBytesAsFile(idA, "a.bin", "application/octet-stream", payloadA, chunkSize = chunkSize)
            controller.sendBytesAsFile(idB, "b.bin", "application/octet-stream", payloadB, chunkSize = chunkSize)

            withTimeout(5_000) {
                while (checkpointStore.peek(idA) == null || checkpointStore.peek(idB) == null) yield()
            }

            val target = if (cancelFirst) idA else idB
            val survivor = if (cancelFirst) idB else idA

            if (cancelLocally) {
                controller.cancel(target)
            } else {
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.cancel,
                            transferId = target,
                        )
                    )
                )
            }

            // (2) 目标传输的检查点被释放。
            withTimeout(5_000) {
                while (checkpointStore.peek(target) != null) yield()
            }
            checkpointStore.peek(target) shouldBe null

            // (3) 通知对端 / 不回声。
            val cancelMessages = transport.messagesOf(CrossNetworkFileTransferOp.cancel)
            if (cancelLocally) {
                cancelMessages.size shouldBe 1
                cancelMessages.single().transferId shouldBe target
            } else {
                cancelMessages.size shouldBe 0
            }

            // (4) 状态可见且区分来源。
            controller.progress.value.lastStatus shouldBe
                if (cancelLocally) "cancelled" else "cancelled by peer"

            // (5) 隔离性：另一路检查点存活。
            (checkpointStore.peek(survivor) != null) shouldBe true

            // (1) 取消后目标不再补发。
            transport.clear()
            controller.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.chunkAck,
                        transferId = target,
                        missingChunks = intArrayOf(0),
                        message = "missingChunks",
                    )
                )
            )
            repeat(5) { yield() }
            transport.messages.none {
                it.transferId == target && it.op == CrossNetworkFileTransferOp.chunk
            } shouldBe true

            // (5 续) 另一路的 NACK 仍能触发补发 —— 证明取消没有连带停掉别人。
            transport.clear()
            controller.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.chunkAck,
                        transferId = survivor,
                        missingChunks = intArrayOf(0),
                        message = "missingChunks",
                    )
                )
            )
            withTimeout(5_000) {
                while (transport.messages.none {
                        it.transferId == survivor && it.op == CrossNetworkFileTransferOp.chunk
                    }
                ) {
                    yield()
                }
            }
            transport.messages.any {
                it.transferId == survivor && it.op == CrossNetworkFileTransferOp.chunk
            } shouldBe true

            if (cancelLocally) localCancels++ else peerCancels++
            if (cancelFirst) cancelledFirst++ else cancelledSecond++

            // 测试卫生（在全部断言之后）：存活的那一路也释放掉，避免补发循环累积。
            controller.cancel(survivor)
        }

        // 非空真保证：本地/对端两种来源、第一路/第二路两个目标都被走到。
        println(
            "Property 27 branch coverage: localCancel=$localCancels peerCancel=$peerCancels " +
                "targetFirst=$cancelledFirst targetSecond=$cancelledSecond"
        )
        (localCancels > 0) shouldBe true
        (peerCancels > 0) shouldBe true
        (cancelledFirst > 0) shouldBe true
        (cancelledSecond > 0) shouldBe true
    }

    test("Property 27 (退化输入): 取消未跟踪或空白 transferId 无副作用") {
        var untrackedCases = 0
        var blankCases = 0

        checkAll(200, Arb.element("", "   ", "unknown"), Arb.int(1..8)) { kind, chunks ->
            val transport = PropertyRecordingTransport()
            val checkpointStore = PropertyCheckpointStore()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                checkpointStore = checkpointStore,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )

            val liveId = UUID.randomUUID().toString()
            controller.sendBytesAsFile(
                liveId,
                "live.bin",
                "application/octet-stream",
                ByteArray(4 * chunks) { it.toByte() },
                chunkSize = 4,
            )
            withTimeout(5_000) {
                while (checkpointStore.peek(liveId) == null) yield()
            }

            val cancelTarget = if (kind == "unknown") UUID.randomUUID().toString() else kind
            transport.clear()
            controller.cancel(cancelTarget)
            repeat(3) { yield() }

            // 进行中的那一路完全不受影响。
            (checkpointStore.peek(liveId) != null) shouldBe true

            if (cancelTarget.isBlank()) {
                // 空白 id 被生产代码直接忽略：不发 cancel、不改状态。
                transport.countOf(CrossNetworkFileTransferOp.cancel) shouldBe 0
                blankCases++
            } else {
                // 未跟踪的合法 id：仍通知对端（幂等、无害），但不影响任何在跟踪的传输。
                transport.messagesOf(CrossNetworkFileTransferOp.cancel)
                    .all { it.transferId == cancelTarget } shouldBe true
                untrackedCases++
            }

            // 测试卫生（必须在上面基于 transport 的断言之后）：释放仍在跟踪的那一路。
            controller.cancel(liveId)
        }

        println("Property 27 (退化输入) branch coverage: untracked=$untrackedCases blank=$blankCases")
        (untrackedCases > 0) shouldBe true
        (blankCases > 0) shouldBe true
    }
})
