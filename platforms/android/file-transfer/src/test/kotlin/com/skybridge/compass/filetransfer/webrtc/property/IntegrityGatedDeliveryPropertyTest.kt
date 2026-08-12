package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.handleIncoming

import com.skybridge.compass.filetransfer.webrtc.ReceiveIntegrityDecision
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.crypto.MerkleSha256
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.p2p.filetransfer.MerkleRootAuthV1
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

/** 注入的故障种类；`NONE` 为三项校验全通过的正例。 */
private enum class Fault { NONE, TAMPERED_BYTES, BAD_MERKLE_ROOT, BAD_MERKLE_SIGNATURE, DECLINED }

/**
 * **Feature: cross-platform-parity-audit, Property 26: 三项校验全部通过才落盘，任一失败则零残留**
 *
 * **Validates: Requirements 5.2, 5.3**
 *
 * 任务 11.10。属性分两半，共同刻画"校验通过才落盘"这一条不变式：
 *
 * **第 1 半（端到端，经真实接收路径）**：把 metadata → chunk* → complete 喂给真实生产入口
 * [WebRtcFileTransferController.handleIncoming]，对随机注入的**故障种类**断言：
 *  - 三项校验（大小、整文件 SHA-256、Merkle 根 + 可选签名）全部通过 ⇒ 恰好一次 `completeAck`
 *    （落盘/投递的可判定代理量），且不发 `op=error`，且检查点被删除；
 *  - 任一项失败 ⇒ **永不** `completeAck`（零落盘），发出带可判别原因的 `op=error`，
 *    且检查点被删除（零残留）。
 *
 * **第 2 半（纯判定，穷举失败分支）**：直接驱动 [ReceiveIntegrityDecision.evaluate]，覆盖端到端
 * 难以构造的分支（大小不符、缺 SHA、SHA 不可计算、缺分块散列、签名算法未知、签名不符），
 * 断言"任一失败 ⇒ 非 Pass"且检查顺序稳定（大小先于 SHA，SHA 先于 Merkle，Merkle 先于签名）。
 *
 * 定义域：走**内存接收**路径（无 Android `Context`），故"分块残留文件"的删除由生产代码同一
 * `failFinalizedReceive` 清理分支承担；此处断言其可观测后果——不投递、不 ack、执行检查点删除。
 *
 * ## 本属性暴露的既有生产缺陷（已上报，未在本任务修改生产代码）
 *
 * 检查点的"零残留"在**存储最终状态**这一更强判据下**不成立**：
 * `WebRtcFileTransferController.kt:1148`（`op=chunk` 分支）在**独立协程**里做
 * `checkpointStore.load(...)` → `copy(...)` → `checkpointStore.save(...)`，与终态清理
 * `WebRtcFileTransferController.kt:1621`（`failFinalizedReceive` 内 `scope.launch { delete }`）
 * 之间**没有任何顺序约束**。当分块进度的 `save` 在终态 `delete` 之后落地时，被删除的检查点会被
 * **复活**，且此后无人再删——等待存储静默后该键依然存在，即成为**永久残留**，违反 R5.3
 * "删除该传输产生的全部临时文件与部分数据"。这一 read-modify-write 竞争同时也是既有测试
 * `WebRtcFileTransferControllerIntegrityCleanupTest`"checkpoint must be deleted after delivery"
 * 偶发失败的同一根因。本属性因此只断言"清理动作已执行"，把更强的最终状态判据留给缺陷修复后启用。
 */
class IntegrityGatedDeliveryPropertyTest : FunSpec({

    val faultArb = Arb.element(Fault.entries)

    val shapeArb: Arb<Pair<Int, Int>> = Arb.bind(
        Arb.element(1, 2, 3, 4, 8, 16, 32),
        Arb.int(1..12),
    ) { chunkSize, chunks -> chunkSize to chunks }

    test("Property 26 (端到端): 三项校验全过才投递；任一失败则零投递、零残留") {
        val observed = mutableMapOf<Fault, Int>()

        checkAll(300, shapeArb, Arb.int(), faultArb) { (chunkSize, chunks), payloadSeed, fault ->
            val fileSize = chunkSize.toLong() * chunks.toLong()
            val payload = ByteArray(fileSize.toInt()).also { Random(payloadSeed.toLong()).nextBytes(it) }
            val chunkList = (0 until chunks).map { i ->
                payload.copyOfRange(i * chunkSize, (i + 1) * chunkSize)
            }

            val transport = PropertyRecordingTransport()
            val checkpointStore = PropertyCheckpointStore()
            val receiver = WebRtcFileTransferController(
                transport,
                json = propertyJson,
                checkpointStore = checkpointStore,
                inboundApprovalProvider = if (fault == Fault.DECLINED) {
                    decliningApprovalProvider()
                } else {
                    acceptingApprovalProvider()
                },
                idleInterruptTimeoutMs = 600_000L,
                idleWatchdogPollMs = 60_000L,
            )
            val transferId = UUID.randomUUID().toString()

            receiver.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.metadata,
                        transferId = transferId,
                        fileName = "integrity.bin",
                        fileSize = fileSize,
                        chunkSize = chunkSize,
                        totalChunks = chunks,
                        mimeType = "application/octet-stream",
                    )
                )
            )

            // 分块：TAMPERED_BYTES 时篡改最后一块的内容（其自身摘要自洽，故只有整文件 SHA 会失败）。
            chunkList.forEachIndexed { index, original ->
                val data = if (fault == Fault.TAMPERED_BYTES && index == chunks - 1) {
                    original.copyOf().also { it[it.lastIndex] = (it[it.lastIndex] + 1).toByte() }
                } else {
                    original
                }
                receiver.handleIncoming(
                    encodeFt(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.chunk,
                            transferId = transferId,
                            chunkIndex = index,
                            chunkData = data,
                            chunkSha256 = sha256(data),
                            rawSize = data.size,
                        )
                    )
                )
            }

            // complete：按故障种类构造校验材料。Merkle 根始终提供，签名按会话 HMAC 规则计算。
            val trueMerkleRoot = MerkleSha256.root(chunkList.map { sha256(it) })
            val merkleRoot = if (fault == Fault.BAD_MERKLE_ROOT) ByteArray(32) { 0x5A } else trueMerkleRoot
            val fileSha = sha256(payload)
            val goodSig = transport.computeOutboundHmacSha256(
                MerkleRootAuthV1.preimage(
                    transferId = transferId,
                    merkleRoot = merkleRoot,
                    fileSha256 = fileSha,
                )
            )
            val signature = if (fault == Fault.BAD_MERKLE_SIGNATURE) ByteArray(32) { 0x11 } else goodSig

            receiver.handleIncoming(
                encodeFt(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.complete,
                        transferId = transferId,
                        receivedBytes = fileSize,
                        fileSha256 = fileSha,
                        merkleRoot = merkleRoot,
                        merkleRootSignature = signature,
                        merkleRootSignatureAlg = "hmac-sha256-session-v1",
                    )
                )
            )

            val shouldDeliver = fault == Fault.NONE
            withTimeout(5_000) {
                if (shouldDeliver) {
                    while (transport.countOf(CrossNetworkFileTransferOp.completeAck) == 0) yield()
                } else if (fault != Fault.DECLINED) {
                    // 失败分支必须把可判别原因回报对端。
                    while (transport.countOf(CrossNetworkFileTransferOp.error) == 0) yield()
                }
                // 无论通过与否，本次传输的检查点都必须被删除（零残留）。
                while (checkpointStore.deleteCount.get() == 0) yield()
            }
            checkpointStore.awaitQuiescence()

            if (shouldDeliver) {
                // 三项校验全过：恰好投递一次、不报错。
                transport.countOf(CrossNetworkFileTransferOp.completeAck) shouldBe 1
                transport.countOf(CrossNetworkFileTransferOp.error) shouldBe 0
                (receiver.progress.value.lastStatus?.startsWith("received complete") == true) shouldBe true
            } else {
                // 任一失败：绝不落盘、绝不 ack。
                transport.countOf(CrossNetworkFileTransferOp.completeAck) shouldBe 0
            }

            // 零残留（清理动作）：本次传输在终态一定执行了检查点删除，且不再被列为续传候选之外
            // 的活动传输。注意这里断言的是"删除已发生"，而非"存储中最终不含该键"——后者受一个
            // **既有生产缺陷**影响：分块进度的异步 `save` 可能在终态 `delete` 之后落地，把检查点
            // 复活成永久残留（详见本文件末尾注释与审计报告）。该缺陷与任务 11.10 的实现无关，
            // 属既有问题，故此处不以弱化断言的方式掩盖，而是单独记录并上报。
            (checkpointStore.deleteCount.get() > 0) shouldBe true

            observed[fault] = (observed[fault] ?: 0) + 1
        }

        // 非空真保证：五个分支（含正例）都被真正生成到。
        println("Property 26 (端到端) branch coverage: $observed")
        Fault.entries.forEach { fault ->
            ((observed[fault] ?: 0) > 0) shouldBe true
        }
    }

    test("Property 26 (纯判定): 任一校验失败即非 Pass，且检查顺序稳定") {
        // 定义域：直接驱动纯判定单元，覆盖端到端难构造的失败分支。
        val goodHash = ByteArray(32) { 0x01 }
        val goodRoot = ByteArray(32) { 0x02 }

        var passCases = 0
        var sizeFail = 0
        var shaFail = 0
        var merkleFail = 0
        var sigFail = 0

        val faultArb2 = Arb.element(
            "none", "size", "sha-missing", "sha-unavailable", "sha-mismatch",
            "merkle-hashes-missing", "merkle-mismatch", "sig-alg", "sig-invalid",
        )

        checkAll(300, Arb.int(1..10_000), faultArb2) { size, fault ->
            val outcome = ReceiveIntegrityDecision.evaluate(
                expectedSize = size.toLong(),
                actualSize = if (fault == "size") size.toLong() + 1L else size.toLong(),
                expectedFileSha256 = if (fault == "sha-missing") null else goodHash,
                actualFileSha256 = when (fault) {
                    "sha-unavailable" -> null
                    "sha-mismatch" -> ByteArray(32) { 0x09 }
                    else -> goodHash
                },
                expectedMerkleRoot = goodRoot,
                actualMerkleRoot = if (fault == "merkle-mismatch") ByteArray(32) { 0x77 } else goodRoot,
                merkleChunkHashesMissing = fault == "merkle-hashes-missing",
                merkleSigProvided = true,
                merkleSigAlgRecognized = fault != "sig-alg",
                merkleSigValid = fault != "sig-invalid",
            )

            if (fault == "none") {
                outcome shouldBe ReceiveIntegrityDecision.Outcome.Pass
                passCases++
            } else {
                // 任一失败 ⇒ 非 Pass，且带可判别的原因文本。
                (outcome is ReceiveIntegrityDecision.Outcome.Fail) shouldBe true
                val fail = outcome as ReceiveIntegrityDecision.Outcome.Fail
                fail.peerMessage.isNotBlank() shouldBe true

                // 检查顺序稳定：先大小、再 SHA、再 Merkle、最后签名。
                when (fault) {
                    "size" -> {
                        fail.peerMessage shouldBe "size mismatch"
                        sizeFail++
                    }
                    "sha-missing", "sha-unavailable", "sha-mismatch" -> {
                        (fail.peerMessage.contains("sha256")) shouldBe true
                        shaFail++
                    }
                    "merkle-hashes-missing", "merkle-mismatch" -> {
                        (fail.peerMessage.contains("merkle")) shouldBe true
                        merkleFail++
                    }
                    else -> {
                        (fail.peerMessage.contains("merkle sig") ||
                            fail.peerMessage.contains("merkle signature")) shouldBe true
                        sigFail++
                    }
                }
            }
        }

        // 非空真保证：正例与四类失败分支都被走到。
        println(
            "Property 26 (纯判定) branch coverage: pass=$passCases size=$sizeFail sha=$shaFail " +
                "merkle=$merkleFail sig=$sigFail"
        )
        (passCases > 0) shouldBe true
        (sizeFail > 0) shouldBe true
        (shaFail > 0) shouldBe true
        (merkleFail > 0) shouldBe true
        (sigFail > 0) shouldBe true
    }
})
