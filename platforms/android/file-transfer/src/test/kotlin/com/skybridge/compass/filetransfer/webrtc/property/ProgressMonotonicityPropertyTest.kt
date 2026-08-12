package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

import com.skybridge.compass.filetransfer.webrtc.OrderedChunkDeliveryTracker
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll
import java.util.Random
import java.util.UUID

/**
 * **Feature: cross-platform-parity-audit, Property 30: 进度值依实际已确认字节数且单调不减**
 *
 * **Validates: Requirements 5.9**
 *
 * 任务 11.14。属性分两半：
 *
 * **第 1 半（批次整体进度，经真实入口 [WebRtcFileTransferController.handleIncoming]）**：
 * 对任意确认消息序列——含**乱序**、**重复确认**、以及**陌生 transferId** 的干扰确认——
 * `batchProgress` 满足：
 *  - **依实际已确认字节数**：`confirmedBytes` 恒等于"已确认文件的字节数之和"（独立重算的判据），
 *    `fraction` 恒等于 `confirmedBytes / totalBytes`，绝非与字节数无关的固定占位值；
 *  - **单调不减**：整个消息序列中 `confirmedBytes` 与 `fraction` 从不下降；
 *  - **有界且收敛**：`fraction ∈ [0,1]`，全部确认后恰为 `1.0`（结束时 100%）;
 *  - **重复确认不重复计数**（幂等）。
 *
 * **第 2 半（发送侧已确认分块计数，经真实入口 [OrderedChunkDeliveryTracker]）**：
 * 在"只增不减"的确认域（即仅 `markDelivered`，对应 R5.9 的进度推进语义）内，`deliveredCount()`
 * 单调不减、恒等于已确认下标的基数、且不被越界/重复确认污染。
 *
 * 定义域：R5.9 的单调性针对"已确认字节数"这一量；对端 NACK 触发的
 * `markUndelivered`（分块回退为未确认）**不在**本属性的定义域内——那是重传语义（R5.10），
 * 其下计数本就允许下降，故此处刻意不把它混入单调性判据。
 */
class ProgressMonotonicityPropertyTest : FunSpec({

    val itemSizesArb: Arb<List<Int>> = Arb.list(Arb.int(1..64), 1..8)

    test("Property 30 (批次整体进度): 依已确认字节数、单调不减、乱序与重复确认下仍成立") {
        var duplicateAcks = 0
        var strangerAcks = 0
        var reorderedAcks = 0
        var reachedFull = 0

        checkAll(300, itemSizesArb, Arb.int()) { sizes, seed ->
            val random = Random(seed.toLong())
            val items = sizes.mapIndexed { index, size ->
                WebRtcFileTransferController.BatchBytesItem(
                    fileName = "f$index.bin",
                    bytes = ByteArray(size).also { random.nextBytes(it) },
                    relativePath = "batch/f$index.bin",
                )
            }

            val transport = PropertyRecordingTransport()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )
            controller.sendBytesAsFilesBatch(items, chunkSize = 32)

            val totalBytes = items.sumOf { it.bytes.size.toLong() }
            controller.batchProgress.value.totalBytes shouldBe totalBytes

            val metadatas = transport.messagesOf(CrossNetworkFileTransferOp.metadata)
            val bytesByTransferId = metadatas.associate { meta ->
                meta.transferId to items.single { it.relativePath == meta.relativePath }.bytes.size.toLong()
            }
            val completionEvidence = transport.messagesOf(CrossNetworkFileTransferOp.complete)
                .associateBy { it.transferId }

            // 构造确认序列：全部真实确认（乱序）+ 随机重复 + 随机陌生 id 干扰。
            val realAcks = metadatas.map { it.transferId }.shuffled(random)
            val withDuplicates = realAcks.flatMap { id ->
                if (random.nextBoolean()) listOf(id, id) else listOf(id)
            }
            val strangers = List(random.nextInt(3)) { UUID.randomUUID().toString() }
            val sequence = (withDuplicates + strangers).shuffled(random)

            if (withDuplicates.size > realAcks.size) duplicateAcks++
            if (strangers.isNotEmpty()) strangerAcks++
            if (realAcks.size > 1 && realAcks != metadatas.map { it.transferId }) reorderedAcks++

            val confirmed = mutableSetOf<String>()
            var previousConfirmedBytes = 0L
            var previousFraction = 0.0

            sequence.forEach { transferId ->
                val complete = completionEvidence[transferId]
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.completeAck,
                            transferId = transferId,
                            receivedBytes = complete?.receivedBytes,
                            fileSha256 = complete?.fileSha256,
                        )
                    )
                )
                if (transferId in bytesByTransferId) confirmed += transferId

                val progress = controller.batchProgress.value

                // 依实际已确认字节数：与独立重算的判据逐值相等（重复确认不重复计数）。
                val expectedConfirmed = confirmed.sumOf { bytesByTransferId.getValue(it) }
                progress.confirmedBytes shouldBe expectedConfirmed
                progress.fraction shouldBe (expectedConfirmed.toDouble() / totalBytes.toDouble())

                // 单调不减。
                (progress.confirmedBytes >= previousConfirmedBytes) shouldBe true
                (progress.fraction >= previousFraction) shouldBe true

                // 有界。
                (progress.fraction in 0.0..1.0) shouldBe true
                (progress.confirmedBytes <= progress.totalBytes) shouldBe true

                previousConfirmedBytes = progress.confirmedBytes
                previousFraction = progress.fraction
            }

            // 结束时进度值等于 100%。
            val finalProgress = controller.batchProgress.value
            finalProgress.confirmedBytes shouldBe totalBytes
            finalProgress.fraction shouldBe 1.0
            finalProgress.isTerminal shouldBe true
            reachedFull++
        }

        // 非空真保证：重复确认、陌生确认、乱序确认与满进度都被真正走到。
        println(
            "Property 30 (批次整体进度) branch coverage: duplicateAcks=$duplicateAcks " +
                "strangerAcks=$strangerAcks reorderedAcks=$reorderedAcks reachedFull=$reachedFull"
        )
        (duplicateAcks > 0) shouldBe true
        (strangerAcks > 0) shouldBe true
        (reorderedAcks > 0) shouldBe true
        (reachedFull > 0) shouldBe true
    }

    test("Property 30 (已确认分块计数): 仅确认域内单调不减且恒等于已确认下标基数") {
        var duplicateMarks = 0
        var outOfRangeMarks = 0
        var reachedAllDelivered = 0
        var partialDelivery = 0

        val shapeArb: Arb<Pair<Int, List<Int>>> = Arb.bind(
            Arb.int(1..32),
            Arb.list(Arb.int(-4..40), 0..60),
        ) { totalChunks, marks -> totalChunks to marks }

        checkAll(400, shapeArb) { (totalChunks, marks) ->
            val tracker = OrderedChunkDeliveryTracker(totalChunks)

            // 发送顺序恒为严格递增的 0..n-1（R5.1 的顺序判据，此处作为不变量交叉核对）。
            tracker.sendOrder().toList() shouldBe (0 until totalChunks).toList()

            val deliveredIndices = mutableSetOf<Int>()
            var previousCount = 0

            marks.forEach { index ->
                val seenBefore = index in deliveredIndices
                val inRange = index in 0 until totalChunks
                if (!inRange) outOfRangeMarks++
                if (seenBefore) duplicateMarks++

                tracker.markDelivered(index)
                if (inRange) deliveredIndices += index

                // 恒等于已确认下标的基数（越界确认被忽略、重复确认不重复计数）。
                tracker.deliveredCount() shouldBe deliveredIndices.size
                // 单调不减。
                (tracker.deliveredCount() >= previousCount) shouldBe true
                // 有界。
                (tracker.deliveredCount() <= totalChunks) shouldBe true
                // 与逐块查询自洽。
                tracker.isChunkDelivered(index) shouldBe inRange
                // 未确认集合恰为补集。
                tracker.unackedChunks() shouldBe (0 until totalChunks).filterNot { it in deliveredIndices }

                previousCount = tracker.deliveredCount()
            }

            // "全部已确认"恰在确认集合覆盖全体时为真。
            tracker.isAllDelivered() shouldBe (deliveredIndices.size == totalChunks)
            if (tracker.isAllDelivered()) reachedAllDelivered++ else partialDelivery++
        }

        // 非空真保证：重复确认、越界确认、满确认与部分确认都被走到。
        println(
            "Property 30 (已确认分块计数) branch coverage: duplicateMarks=$duplicateMarks " +
                "outOfRangeMarks=$outOfRangeMarks allDelivered=$reachedAllDelivered partial=$partialDelivery"
        )
        (duplicateMarks > 0) shouldBe true
        (outOfRangeMarks > 0) shouldBe true
        (reachedAllDelivered > 0) shouldBe true
        (partialDelivery > 0) shouldBe true
    }
})
