package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.CrossNetworkFileTransferValidator
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll
import java.util.Random
import java.util.UUID

/**
 * **Feature: cross-platform-parity-audit, Property 25: 分块序列恰好覆盖文件全部字节**
 *
 * **Validates: Requirements 5.1**
 *
 * 任务 11.9。属性：对任意（文件大小, 分块大小）组合，发送端产生的 `op=chunk` 序列**恰好**覆盖
 * 文件的全部字节——既无空洞、也无重叠、也无重复、也无越界：
 *
 *  1. 分块条数等于生产端 [CrossNetworkFileTransferValidator.validatedExpectedChunkCount] 的期望值；
 *  2. `chunkIndex` 按发送顺序严格递增且恰为 `0..n-1`（无缺号、无重号）；
 *  3. 按下标拼接各分块字节 **逐字节等于**原文件（覆盖的充分必要判据）；
 *  4. 各分块的字节区间 `[i*chunkSize, i*chunkSize + size)` 首尾相接、长度之和等于文件大小，
 *     末块为余数块、其余为满块；
 *  5. 每个分块自带的 `chunkSha256` 与其数据一致（分块边界未被错位切分）。
 *
 * 属性经**真实生产入口** [WebRtcFileTransferController.sendBytesAsFile] 驱动：断言对象是控制器
 * 实际写到传输层的报文，测试不重新实现任何切分逻辑。
 *
 * 定义域：文件大小为正（生产校验器拒绝 0 字节）、分块大小 ≥ 1，且分块条数控制在 40 以内以保证
 * 单次迭代的运行时间有界；这一定义域覆盖了整除/非整除与单块/多块的全部四个组合分支。
 * 快照在 `sendBytesAsFile` 返回后立即读取——后台补发循环首次触发需 1200ms，故初始发送流是干净的。
 */
class ChunkCoveragePropertyTest : FunSpec({

    /** 分块大小素材：含 1、素数、以及典型 2 的幂，用于制造各种余数形态。 */
    val chunkSizeArb = Arb.element(1, 2, 3, 4, 5, 7, 8, 13, 16, 32, 64, 100, 128, 256)

    /**
     * 生成 (分块大小, 分块条数, 末块字节数)。文件大小由三者决定：
     * `fileSize = chunkSize * (chunks - 1) + lastSize`，`lastSize ∈ 1..chunkSize`。
     * 这样即可**受控地**同时命中"整除"（lastSize == chunkSize）与"有余数"两个分支。
     */
    val shapeArb: Arb<Triple<Int, Int, Int>> = Arb.bind(
        chunkSizeArb,
        Arb.int(1..40),
        Arb.int(0..1_000_000),
    ) { chunkSize, chunks, lastRaw ->
        val lastSize = (lastRaw % chunkSize) + 1
        Triple(chunkSize, chunks, lastSize)
    }

    test("Property 25: 分块序列恰好覆盖文件全部字节（无空洞、无重叠、无重复）") {
        var exactDivision = 0
        var withRemainder = 0
        var singleChunk = 0
        var multiChunk = 0

        checkAll(400, shapeArb, Arb.int()) { (chunkSize, chunks, lastSize), payloadSeed ->
            val fileSize = chunkSize.toLong() * (chunks - 1).toLong() + lastSize.toLong()
            val payload = ByteArray(fileSize.toInt()).also { Random(payloadSeed.toLong()).nextBytes(it) }

            val transport = PropertyRecordingTransport()
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                // 本属性与空闲/中断看门狗无关：拉长轮询与阈值，避免大量后台协程干扰运行时间。
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )
            val transferId = UUID.randomUUID().toString()

            controller.sendBytesAsFile(
                transferId = transferId,
                fileName = "coverage.bin",
                mimeType = "application/octet-stream",
                bytes = payload,
                chunkSize = chunkSize,
            )

            // 与生产校验器的期望条数一致（同一判据同时被 validateMetadata 强制）。
            val expectedChunks = CrossNetworkFileTransferValidator
                .validatedExpectedChunkCount(fileSize, chunkSize)
            expectedChunks shouldBe chunks

            val chunkMessages = transport.messagesOf(CrossNetworkFileTransferOp.chunk)
            chunkMessages.size shouldBe expectedChunks

            // (2) 下标按发送顺序严格递增且恰为 0..n-1。
            chunkMessages.map { it.chunkIndex } shouldBe List(expectedChunks) { it }

            // (3) 拼接后逐字节等于原文件：覆盖"恰好"的充分必要条件。
            val reassembled = ByteArray(fileSize.toInt())
            var cursor = 0
            chunkMessages.forEach { message ->
                val data = requireNotNull(message.chunkData) { "chunk must carry data" }
                data.copyInto(reassembled, cursor)
                cursor += data.size
            }
            cursor.toLong() shouldBe fileSize
            reassembled.contentEquals(payload) shouldBe true

            // (4) 区间首尾相接：满块 + 末块余数，长度之和等于文件大小。
            chunkMessages.forEachIndexed { index, message ->
                val data = requireNotNull(message.chunkData)
                val expectedSize = if (index == expectedChunks - 1) lastSize else chunkSize
                data.size shouldBe expectedSize
                // rawSize（若在线）必须与实际字节数一致。
                message.rawSize?.let { it shouldBe data.size }
            }
            chunkMessages.sumOf { it.chunkData!!.size.toLong() } shouldBe fileSize

            // (5) 每块自带摘要与其数据一致 —— 分块未被错位切分。
            chunkMessages.forEach { message ->
                val data = requireNotNull(message.chunkData)
                val declared = requireNotNull(message.chunkSha256) { "chunk must carry chunkSha256" }
                declared.contentEquals(sha256(data)) shouldBe true
            }

            // 元数据声明的总量与实际分块序列自洽。
            val metadata = transport.messagesOf(CrossNetworkFileTransferOp.metadata).single()
            metadata.fileSize shouldBe fileSize
            metadata.chunkSize shouldBe chunkSize
            metadata.totalChunks shouldBe expectedChunks

            if (lastSize == chunkSize) exactDivision++ else withRemainder++
            if (expectedChunks == 1) singleChunk++ else multiChunk++

            // 测试卫生（在全部断言之后）：释放本次迭代的补发循环，避免数百次迭代把被放弃的协程
            // 累积到共享 IO 线程池上，干扰同一模块其他测试的时序。
            controller.cancel(transferId)
        }

        // 非空真保证：四个分支都被真正走到（计数写入测试输出，便于核查非空真）。
        println(
            "Property 25 branch coverage: exactDivision=$exactDivision withRemainder=$withRemainder " +
                "singleChunk=$singleChunk multiChunk=$multiChunk"
        )
        (exactDivision > 0) shouldBe true
        (withRemainder > 0) shouldBe true
        (singleChunk > 0) shouldBe true
        (multiChunk > 0) shouldBe true
    }
})
