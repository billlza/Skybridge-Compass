package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

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
 * **Feature: cross-platform-parity-audit, Property 29: 批次字段与整体进度**
 *
 * **Validates: Requirements 5.8**
 *
 * 任务 11.13。属性：对任意批次（1..12 个文件，含目录层级相对路径），经真实生产入口
 * [WebRtcFileTransferController.sendBytesAsFilesBatch] 发送后：
 *
 *  1. **同一批次标识**：全部条目的 `batchId` 是同一个规范化 UUID；
 *  2. **批内序号完备**：`batchIndex` 恰好覆盖 `0..n-1`（不重、不漏），`batchTotal` 恒等于文件数；
 *  3. **相对路径层级保留**：每个条目的 `relativePath` 与输入逐一相等（含多级目录）；
 *  4. **metadata 与 complete 携带同一批次字段**（按 transferId 配对）；
 *  5. **整体进度以字节计**：`batchProgress.totalBytes` 等于各文件字节数之和；随着每个文件的
 *     `completeAck` 到达，`confirmedBytes` 单调递增，且 `fraction` 恰为已确认字节/总字节；
 *     全部确认后 `fraction == 1.0`、`completedCount == n`、`isTerminal` 为真。
 *
 * 定义域：文件大小 ≥ 1 字节（生产校验器拒绝 0 字节文件），批次条数 ≤ 12 且分块较大，
 * 以保证单次迭代有界；批次上限 500 由生产 `MAX_BATCH_FILES` 约束，不在本属性的随机范围内。
 */
class BatchFieldsAndOverallProgressPropertyTest : FunSpec({

    /** 相对路径素材：含单级、多级与深层目录，用于验证层级保留。 */
    val relativePathArb = Arb.element(
        "a.bin",
        "docs/b.bin",
        "docs/nested/c.bin",
        "docs/nested/deeper/d.bin",
        "media/e.bin",
    )

    val itemSpecArb: Arb<Pair<String, Int>> = Arb.bind(
        relativePathArb,
        Arb.int(1..96),
    ) { path, size -> path to size }

    test("Property 29: 批次字段一致完备、相对路径层级保留、整体进度以确认字节数计") {
        var singleItemBatches = 0
        var multiItemBatches = 0
        var nestedPathSeen = 0
        var flatPathSeen = 0

        checkAll(250, Arb.list(itemSpecArb, 1..12), Arb.int()) { specs, seed ->
            val random = Random(seed.toLong())
            // relativePath 在批内必须唯一（同名条目无法按路径配对断言），故去重后编号。
            val items = specs.mapIndexed { index, (path, size) ->
                val dot = path.lastIndexOf('.')
                val unique = path.substring(0, dot) + "-$index" + path.substring(dot)
                WebRtcFileTransferController.BatchBytesItem(
                    fileName = unique.substringAfterLast('/'),
                    bytes = ByteArray(size).also { random.nextBytes(it) },
                    relativePath = unique,
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

            val metadatas = transport.messagesOf(CrossNetworkFileTransferOp.metadata)
            val completes = transport.messagesOf(CrossNetworkFileTransferOp.complete)
            metadatas.size shouldBe items.size
            completes.size shouldBe items.size

            // (1) 同一批次标识。
            metadatas.mapNotNull { it.batchId }.toSet().size shouldBe 1

            // (2) 批内序号恰好覆盖 0..n-1，batchTotal 恒为条目数。
            metadatas.mapNotNull { it.batchIndex }.sorted() shouldBe items.indices.toList()
            metadatas.all { it.batchTotal == items.size } shouldBe true
            completes.mapNotNull { it.batchIndex }.sorted() shouldBe items.indices.toList()
            completes.all { it.batchTotal == items.size } shouldBe true

            // (3) 相对路径层级逐一保留。
            metadatas.mapNotNull { it.relativePath }.toSet() shouldBe items.map { it.relativePath }.toSet()

            // (4) metadata 与 complete 的批次字段按 transferId 配对一致。
            metadatas.forEach { meta ->
                val complete = completes.single { it.transferId == meta.transferId }
                complete.batchId shouldBe meta.batchId
                complete.batchIndex shouldBe meta.batchIndex
                complete.batchTotal shouldBe meta.batchTotal
                complete.relativePath shouldBe meta.relativePath
            }

            // (5) 整体进度以字节计，且随确认单调推进。
            val expectedTotal = items.sumOf { it.bytes.size.toLong() }
            controller.batchProgress.value.totalBytes shouldBe expectedTotal
            controller.batchProgress.value.confirmedBytes shouldBe 0L
            controller.batchProgress.value.fraction shouldBe 0.0

            var confirmedBytes = 0L
            var previousFraction = 0.0
            // 以随机顺序确认各文件，验证整体进度与确认顺序无关、只与已确认字节数有关。
            val shuffledMetas = metadatas.shuffled(random)
            shuffledMetas.forEachIndexed { confirmedCount, meta ->
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.completeAck,
                            transferId = meta.transferId,
                        )
                    )
                )
                val item = items.single { it.relativePath == meta.relativePath }
                confirmedBytes += item.bytes.size.toLong()

                val progress = controller.batchProgress.value
                progress.confirmedBytes shouldBe confirmedBytes
                progress.fraction shouldBe (confirmedBytes.toDouble() / expectedTotal.toDouble())
                (progress.fraction >= previousFraction) shouldBe true
                progress.completedCount shouldBe (confirmedCount + 1)
                previousFraction = progress.fraction
            }

            val finalProgress = controller.batchProgress.value
            finalProgress.confirmedBytes shouldBe expectedTotal
            finalProgress.fraction shouldBe 1.0
            finalProgress.completedCount shouldBe items.size
            finalProgress.failedCount shouldBe 0
            finalProgress.isTerminal shouldBe true

            if (items.size == 1) singleItemBatches++ else multiItemBatches++
            if (items.any { it.relativePath.contains('/') }) nestedPathSeen++
            if (items.any { !it.relativePath.contains('/') }) flatPathSeen++
        }

        // 非空真保证：单文件/多文件批次、含目录层级/纯文件名路径都被走到。
        println(
            "Property 29 branch coverage: singleItemBatch=$singleItemBatches multiItemBatch=$multiItemBatches " +
                "nestedPath=$nestedPathSeen flatPath=$flatPathSeen"
        )
        (singleItemBatches > 0) shouldBe true
        (multiItemBatches > 0) shouldBe true
        (nestedPathSeen > 0) shouldBe true
        (flatPathSeen > 0) shouldBe true
    }
})
