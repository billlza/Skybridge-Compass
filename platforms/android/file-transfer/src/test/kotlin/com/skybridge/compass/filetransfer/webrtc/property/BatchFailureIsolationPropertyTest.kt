package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll
import java.util.Random

/**
 * **Feature: cross-platform-parity-audit, Property 33: 批次内单文件失败被隔离**
 *
 * **Validates: Requirements 5.13**
 *
 * 任务 11.17。属性：批次中任意一个（或多个）文件失败，**不影响**其余文件继续传输，且批次结束时
 * 每个文件都有明确的成功/失败结果与正确的失败计数。
 *
 * 判据（全部经真实生产入口 [WebRtcFileTransferController.sendBytesAsFilesBatch] 观测）：
 *  1. **不提前中止**：批内**每个**条目都被跟踪（`batchProgress.files.size == n`），失败条目之后的
 *     条目仍被发送——这正是"继续传输该批次中的其余文件"；
 *  2. **失败被隔离**：传输层失败的条目状态为 FAILED，且**只有**它们为 FAILED；
 *  3. **其余文件完整走完流程**：每个存活条目都产生 metadata → chunk* → complete 的完整报文，
 *     且失败条目**完全不出现**在线上（其首个报文即被拒绝）；
 *  4. **结束时逐文件结果与失败数量**：确认全部存活条目后，`completedCount` 等于存活数、
 *     `failedCount` 等于失败数、二者之和为批次条目数、`isTerminal` 为真；
 *  5. **整体进度只计成功字节**：`confirmedBytes` 等于存活条目字节数之和（失败文件不计入）。
 *
 * 定义域：失败以**传输层 send 失败**注入（`PropertyRecordingTransport` 对指定 transferId 返回
 * false），这与 R5.13"校验失败或被终止"的第二种情形同构；校验失败（对端 `op=error`）导致的
 * 单条目 FAILED 由 Property 31 的反例分支覆盖。批次至少 2 个文件，且至少 1 个成功、至少 1 个失败，
 * 以保证"隔离"这一命题非空（全成功或全失败都无法证伪隔离性）。
 */
class BatchFailureIsolationPropertyTest : FunSpec({

    /** (条目数, 失败条目下标集合) —— 保证至少 1 失败、至少 1 成功。 */
    val planArb: Arb<Pair<Int, Set<Int>>> = Arb.bind(
        Arb.int(2..8),
        Arb.list(Arb.int(0..100), 1..8),
    ) { count, rawPicks ->
        val picks = rawPicks.map { it % count }.toMutableSet()
        // 至少留一个成功条目。
        if (picks.size == count) picks.remove(picks.first())
        count to picks.toSet()
    }

    test("Property 33: 批次内单文件失败被隔离，其余文件继续传输并各自给出结果") {
        var singleFailureCases = 0
        var multiFailureCases = 0
        var firstItemFailed = 0
        var lastItemFailed = 0
        var middleItemFailed = 0

        checkAll(300, planArb, Arb.int()) { (count, failingIndices), seed ->
            val random = Random(seed.toLong())
            val items = (0 until count).map { index ->
                WebRtcFileTransferController.BatchBytesItem(
                    fileName = "item$index.bin",
                    bytes = ByteArray(random.nextInt(48) + 1).also { random.nextBytes(it) },
                    relativePath = "batch/item$index.bin",
                )
            }
            val failingPaths = failingIndices.map { items[it].relativePath }.toSet()

            // 传输层对失败条目的每一次 send 都返回 false（从其 metadata 起即失败）。
            val transport = FailingPathsTransport(failingPaths)
            val controller = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )

            controller.sendBytesAsFilesBatch(items, chunkSize = 16)

            val progress = controller.batchProgress.value

            // (1) 不提前中止：每个条目都被跟踪。
            progress.files.size shouldBe count
            progress.files.map { it.relativePath }.toSet() shouldBe items.map { it.relativePath }.toSet()

            val survivingPaths = items.map { it.relativePath }.filterNot { it in failingPaths }

            // (2) 失败被隔离：FAILED 集合恰为注入的失败集合。
            progress.files.filter { it.status == BatchManifestEntry.Status.FAILED }
                .mapNotNull { it.relativePath }
                .toSet() shouldBe failingPaths
            progress.failedCount shouldBe failingPaths.size

            // 存活条目处于进行中（已发出、等待确认），不受他人失败影响。
            survivingPaths.forEach { path ->
                progress.files.single { it.relativePath == path }.status shouldBe
                    BatchManifestEntry.Status.IN_PROGRESS
            }

            // (3) 存活条目各自走完完整流程；失败条目完全不上线。
            val metadatas = transport.messagesOf(CrossNetworkFileTransferOp.metadata)
            metadatas.size shouldBe survivingPaths.size
            metadatas.mapNotNull { it.relativePath }.toSet() shouldBe survivingPaths.toSet()
            transport.messages.none { it.relativePath in failingPaths } shouldBe true
            metadatas.forEach { meta ->
                transport.messages.any {
                    it.op == CrossNetworkFileTransferOp.complete && it.transferId == meta.transferId
                } shouldBe true
                transport.messages.any {
                    it.op == CrossNetworkFileTransferOp.chunk && it.transferId == meta.transferId
                } shouldBe true
            }

            // (4)(5) 确认全部存活条目后：逐文件结果齐备、失败数量正确、进度只计成功字节。
            metadatas.forEach { meta ->
                val complete = transport.messages.single {
                    it.op == CrossNetworkFileTransferOp.complete && it.transferId == meta.transferId
                }
                controller.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.completeAck,
                            transferId = meta.transferId,
                            receivedBytes = complete.receivedBytes,
                            fileSha256 = complete.fileSha256,
                        )
                    )
                )
            }
            val finalProgress = controller.batchProgress.value
            finalProgress.completedCount shouldBe survivingPaths.size
            finalProgress.failedCount shouldBe failingPaths.size
            (finalProgress.completedCount + finalProgress.failedCount) shouldBe count
            finalProgress.isTerminal shouldBe true

            val survivingBytes = items.filter { it.relativePath !in failingPaths }
                .sumOf { it.bytes.size.toLong() }
            finalProgress.confirmedBytes shouldBe survivingBytes

            if (failingPaths.size == 1) singleFailureCases++ else multiFailureCases++
            if (0 in failingIndices) firstItemFailed++
            if ((count - 1) in failingIndices) lastItemFailed++
            if (failingIndices.any { it in 1 until (count - 1) }) middleItemFailed++
        }

        // 非空真保证：单失败/多失败、首/中/尾位置失败都被真正走到。
        println(
            "Property 33 branch coverage: singleFailure=$singleFailureCases multiFailure=$multiFailureCases " +
                "firstItemFailed=$firstItemFailed lastItemFailed=$lastItemFailed middleItemFailed=$middleItemFailed"
        )
        (singleFailureCases > 0) shouldBe true
        (multiFailureCases > 0) shouldBe true
        (firstItemFailed > 0) shouldBe true
        (lastItemFailed > 0) shouldBe true
        (middleItemFailed > 0) shouldBe true
    }
})

/**
 * Transport that fails every send belonging to a batch item whose `relativePath` is in
 * [failingPaths] (identified at its metadata message and remembered by transferId thereafter).
 */
private class FailingPathsTransport(
    private val failingPaths: Set<String>
) : com.skybridge.compass.filetransfer.webrtc.TestCrossNetworkWebRtcTransportAdapter() {

    private val delegate = PropertyRecordingTransport()
    private val failingTransferIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    val messages get() = delegate.messages

    fun messagesOf(op: CrossNetworkFileTransferOp) = delegate.messagesOf(op)

    override val state get() = delegate.state
    override val signalingStatus get() = delegate.signalingStatus
    override val dataChannelConfigStatus get() = delegate.dataChannelConfigStatus
    override val authenticatedPeerMetadata get() = delegate.authenticatedPeerMetadata

    override var onData: ((ByteArray) -> Unit)?
        get() = delegate.onData
        set(value) { delegate.onData = value }
    override var onPacketData: ((ByteArray, com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope.PacketType) -> Unit)?
        get() = delegate.onPacketData
        set(value) { delegate.onPacketData = value }

    override fun hasSessionKeys() = delegate.hasSessionKeys()
    override fun authenticatedPeerDeviceId() = delegate.authenticatedPeerDeviceId()
    override fun negotiatedSuiteName() = delegate.negotiatedSuiteName()
    override fun negotiatedSuiteWireId() = delegate.negotiatedSuiteWireId()
    override fun hasPqcSessionKeys() = delegate.hasPqcSessionKeys()
    override fun hasQPeriaptSessionKeys() = delegate.hasQPeriaptSessionKeys()
    override fun computeOutboundHmacSha256(preimage: ByteArray) = delegate.computeOutboundHmacSha256(preimage)
    override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray) =
        delegate.verifyInboundHmacSha256(preimage, mac)
    override fun setLocalDeviceId(id: String) = delegate.setLocalDeviceId(id)
    override fun setPqcEnabled(enabled: Boolean) = delegate.setPqcEnabled(enabled)
    override fun setHandshakePolicyOverride(policy: com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride?) =
        delegate.setHandshakePolicyOverride(policy)
    override suspend fun generateConnectionCode() = delegate.generateConnectionCode()
    override fun startOfferer(code: String) = delegate.startOfferer(code)
    override fun startAnswerer(code: String) = delegate.startAnswerer(code)
    override fun disconnect() = delegate.disconnect()
    override fun release() = delegate.release()

    override fun send(
        bytes: ByteArray,
        packetType: com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope.PacketType
    ): Boolean {
        if (packetType != com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
            return true
        }
        val message = decodeFt(bytes)
        if (message.op == CrossNetworkFileTransferOp.metadata && message.relativePath in failingPaths) {
            failingTransferIds += message.transferId
            return false
        }
        if (message.transferId in failingTransferIds) return false
        return delegate.send(bytes, packetType)
    }
}
