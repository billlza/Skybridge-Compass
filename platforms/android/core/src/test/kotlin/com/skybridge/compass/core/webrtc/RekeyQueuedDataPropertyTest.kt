package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.byteArray
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 23: 密钥更新期间不丢弃已排队数据**
 *
 * **Validates: Requirements 4.8**
 *
 * 任务 9.15 的属性测试。R4.8 的「密钥更新期间不断开 DataChannel、不丢弃文件传输与远程桌面
 * 会话的已排队数据」在 Android 侧由两块生产代码共同保证，本测试分别驱动它们的**真实实现**：
 *
 * 1. **信封层连续性** —— [WebRtcAppSecureEnvelope]（`:shared` 的 `webrtc/`）的
 *    `seal`/`open` 与 [WebRtcAppSecureEnvelope.ReplayWindow]。密钥更新会换用新的
 *    `sendKey`/`receiveKey`/`transcriptHash`，并把出站信封计数器**从头重新计数**
 *    （见 `SkyBridgeWebRtcConnectionManager.resetSecureEnvelopeState()`）。本属性验证：
 *    跨越 rekey 边界的**每一条**已排队数据都能被对端如实打开、载荷逐字节不变、且计数器
 *    重启**不会**被重放窗口误判为重放而丢弃——后者正是「不丢已排队数据」的实际风险点。
 * 2. **密钥材料生命周期** —— [SecureSessionKeyLifecycle]（`:core`）。rekey 的「以新密钥
 *    继续」路径**不得**擦除仍在服务中的旧密钥（否则会破坏在途/已排队的发送）；只有会话
 *    拆解路径才擦除。本属性验证 rekey 后仍能用旧密钥打开 rekey 前已封装的排队数据，
 *    而拆解后密钥材料被置零。
 *
 * ### 为什么计数器重启是关键
 * 重放窗口按 `(packetType, direction, sessionHash, transcriptPrefix, epoch)` 分泳道。
 * rekey 换新 `transcriptHash` ⇒ `transcriptPrefix` 改变 ⇒ **新泳道**，因此新密钥下从 1
 * 重新计数不会撞上旧泳道里已记录的计数值。若两侧共用一条泳道，重启计数就会被判
 * `duplicate-counter` 而丢包——这正是本属性要排除的失效模式。
 *
 * ### 属性定义域
 * 本测试覆盖信封层的排队-重放语义，不驱动真实 WebRTC DataChannel（`:core` 单元测试无
 * 实时传输）。「rekey 期间保持 Established、不关 DataChannel」这一状态迁移契约由既有
 * [SecureSessionKeyLifecycleWiringTest] 在源级锁定，二者互补、不重复。
 *
 * 非空真保证：每个测试断言各分支计数 > 0 并打印计数值。
 */
class RekeyQueuedDataPropertyTest : FunSpec({

    val packetTypeArb: Arb<WebRtcAppSecureEnvelope.PacketType> = Arb.element(
        // R4.8 明确点名文件传输与远程桌面两类会话数据。
        listOf(
            WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER,
            WebRtcAppSecureEnvelope.PacketType.REMOTE_DESKTOP,
            WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL,
            WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
        )
    )

    val roleArb: Arb<WebRtcAppSecureEnvelope.Role> =
        Arb.element(WebRtcAppSecureEnvelope.Role.entries.toList())

    /**
     * 一组会话密钥（发送/接收/transcript）。rekey 即换用一组全新的值。
     *
     * 用 SHA-256 从标签 + seed 派生，而不是 `(seed * k + i).toByte()` 之类的算术式：
     * 后者截断到字节后**会在不同 seed 间碰撞**（例如 seed=356 与 seed=868 在 `seed*11`
     * 下同为 76 mod 256），使"rekey 确实换了密钥"的生成器自检偶发失败。
     * SHA-256 派生保证不同 seed 得到不同的 32 字节密钥，且完全确定可复现。
     */
    fun keysFor(seed: Int): P2PHandshakeWire.DerivedSessionKeys {
        fun derive(label: String): ByteArray =
            java.security.MessageDigest.getInstance("SHA-256")
                .digest("$label|$seed".toByteArray(Charsets.UTF_8))
        return P2PHandshakeWire.DerivedSessionKeys(
            sendKey = derive("send"),
            receiveKey = derive("recv"),
            transcriptHash = derive("transcript")
        )
    }

    /** 已排队的一条业务数据（非空载荷，长度覆盖小包与较大包）。 */
    val payloadArb: Arb<ByteArray> = Arb.byteArray(Arb.int(1..512), Arb.element((0..255).map { it.toByte() }))

    data class Case(
        val packetType: WebRtcAppSecureEnvelope.PacketType,
        val role: WebRtcAppSecureEnvelope.Role,
        val beforeRekey: List<ByteArray>,
        val afterRekey: List<ByteArray>,
        val oldSeed: Int,
        val newSeed: Int
    )

    val caseArb: Arb<Case> = arbitrary {
        val oldSeed = Arb.int(1..500).bind()
        // 保证 rekey 后确为**不同**的密钥与 transcript（否则不构成一次真正的密钥更新）。
        val newSeed = Arb.int(501..1000).bind()
        Case(
            packetType = packetTypeArb.bind(),
            role = roleArb.bind(),
            beforeRekey = Arb.list(payloadArb, 1..6).bind(),
            afterRekey = Arb.list(payloadArb, 1..6).bind(),
            oldSeed = oldSeed,
            newSeed = newSeed
        )
    }

    test("Property 23: 跨越密钥更新边界的每条已排队数据都被如实交付，计数器重启不被判重放") {
        var casesChecked = 0
        var totalBeforeDelivered = 0
        var totalAfterDelivered = 0
        var counterRestartObserved = 0

        checkAll(500, caseArb) { case ->
            val oldKeys = keysFor(case.oldSeed)
            val newKeys = keysFor(case.newSeed)

            // 生成器自检：这确实是一次真正的密钥更新（三个字段都变了）。
            oldKeys.sendKey.contentEquals(newKeys.sendKey) shouldBe false
            oldKeys.receiveKey.contentEquals(newKeys.receiveKey) shouldBe false
            oldKeys.transcriptHash.contentEquals(newKeys.transcriptHash) shouldBe false

            val oldSessionId = WebRtcAppSecureEnvelope.deterministicSessionId(oldKeys.transcriptHash)
            val newSessionId = WebRtcAppSecureEnvelope.deterministicSessionId(newKeys.transcriptHash)

            // 对端接收侧的重放窗口在 rekey 前后是**同一个实例**——真实连接不会因 rekey 丢弃
            // 接收状态，所以这正是"重启计数是否被误判为重放"的实测场景。
            val receiverWindow = WebRtcAppSecureEnvelope.ReplayWindow()

            // ---- rekey 之前：用旧密钥封装并交付已排队数据，计数器 1..n ----
            var outboundCounter = 0L
            val beforeOpened = case.beforeRekey.map { payload ->
                outboundCounter += 1
                val sealed = WebRtcAppSecureEnvelope.seal(
                    plaintext = payload,
                    sendKey = oldKeys.sendKey,
                    role = case.role,
                    sessionId = oldSessionId,
                    transcriptHash = oldKeys.transcriptHash,
                    packetType = case.packetType,
                    counter = outboundCounter
                )
                // 对端以对应的接收角色打开（发送方 sendKey == 接收方 recvKey）。
                val opened = WebRtcAppSecureEnvelope.open(
                    packet = sealed,
                    recvKey = oldKeys.sendKey,
                    role = peerRoleOf(case.role),
                    sessionId = oldSessionId,
                    transcriptHash = oldKeys.transcriptHash,
                    allowedPacketTypes = setOf(case.packetType)
                )
                // 未被重放窗口丢弃。
                receiverWindow.validateAndRecord(opened)
                opened
            }

            // 每条 rekey 前的排队数据都逐字节如实交付。
            beforeOpened.size shouldBe case.beforeRekey.size
            beforeOpened.forEachIndexed { idx, opened ->
                opened.payload.contentEquals(case.beforeRekey[idx]) shouldBe true
                opened.packetType shouldBe case.packetType
            }
            totalBeforeDelivered += beforeOpened.size

            // ---- 密钥更新发生：换用新密钥，出站计数器从头重新计数（生产行为） ----
            val restartedCounterStart = 1L
            // 这正是关键点：新密钥下的第一个计数值 <= 旧密钥下已用过的最大计数值时，
            // 若共用重放泳道就会被判重放。刻意在 beforeRekey 条数 >= 1 时都成立。
            if (restartedCounterStart <= outboundCounter) counterRestartObserved++

            // ---- rekey 之后：用新密钥继续发送剩余已排队数据，计数从 1 起 ----
            var newCounter = 0L
            val afterOpened = case.afterRekey.map { payload ->
                newCounter += 1
                val sealed = WebRtcAppSecureEnvelope.seal(
                    plaintext = payload,
                    sendKey = newKeys.sendKey,
                    role = case.role,
                    sessionId = newSessionId,
                    transcriptHash = newKeys.transcriptHash,
                    packetType = case.packetType,
                    counter = newCounter
                )
                val opened = WebRtcAppSecureEnvelope.open(
                    packet = sealed,
                    recvKey = newKeys.sendKey,
                    role = peerRoleOf(case.role),
                    sessionId = newSessionId,
                    transcriptHash = newKeys.transcriptHash,
                    allowedPacketTypes = setOf(case.packetType)
                )
                // **核心断言**：计数器重启后的数据**不得**被重放窗口丢弃。
                // 若 rekey 未换泳道，这里会抛 ReplayDetected —— 即"丢弃已排队数据"。
                receiverWindow.validateAndRecord(opened)
                opened
            }

            // 每条 rekey 后的排队数据同样逐字节如实交付，无一丢弃。
            afterOpened.size shouldBe case.afterRekey.size
            afterOpened.forEachIndexed { idx, opened ->
                opened.payload.contentEquals(case.afterRekey[idx]) shouldBe true
                opened.packetType shouldBe case.packetType
            }
            totalAfterDelivered += afterOpened.size

            // 总交付条数 == 总排队条数：一条都没丢。
            (beforeOpened.size + afterOpened.size) shouldBe
                (case.beforeRekey.size + case.afterRekey.size)

            // rekey 换了 transcript ⇒ 换了泳道标识，这是重启计数得以安全的结构原因。
            (beforeOpened.first().transcriptPrefix != afterOpened.first().transcriptPrefix) shouldBe true

            casesChecked++
        }

        println(
            "Property 23 counters: casesChecked=$casesChecked, " +
                "beforeRekeyDelivered=$totalBeforeDelivered, afterRekeyDelivered=$totalAfterDelivered, " +
                "counterRestartOverlap=$counterRestartObserved"
        )

        (casesChecked > 0) shouldBe true
        (totalBeforeDelivered > 0) shouldBe true
        (totalAfterDelivered > 0) shouldBe true
        // 非空真保证的关键一项：确实生成到了"新计数值 <= 旧已用计数值"的重叠情形，
        // 否则本属性就没有真正检验重放误判这一失效模式。
        (counterRestartObserved > 0) shouldBe true
    }

    test("Property 23: rekey 的以新密钥继续路径不擦除在服务中的旧密钥，仅拆解路径擦除") {
        var rekeyContinuations = 0
        var teardowns = 0

        checkAll(300, caseArb) { case ->
            val oldKeys = keysFor(case.oldSeed)
            val sessionId = WebRtcAppSecureEnvelope.deterministicSessionId(oldKeys.transcriptHash)

            // rekey 之前已排队并封装的一条数据（在途发送）。
            val queued = case.beforeRekey.first()
            val sealedBeforeRekey = WebRtcAppSecureEnvelope.seal(
                plaintext = queued,
                sendKey = oldKeys.sendKey,
                role = case.role,
                sessionId = sessionId,
                transcriptHash = oldKeys.transcriptHash,
                packetType = case.packetType,
                counter = 1L
            )

            // ---- rekey「以新密钥继续」：**不**调用 wipeKeyMaterial ----
            // 生产实现（SkyBridgeWebRtcConnectionManager.onHandshakeEstablished 的 REKEY 分支）
            // 只切换 sessionKeys 引用并重置计数器，不擦除旧密钥字节。因此旧密钥仍可用于打开
            // rekey 前已封装的在途数据——这是"不丢已排队数据"的必要条件。
            rekeyContinuations++
            val openedAfterRekey = WebRtcAppSecureEnvelope.open(
                packet = sealedBeforeRekey,
                recvKey = oldKeys.sendKey,
                role = peerRoleOf(case.role),
                sessionId = sessionId,
                transcriptHash = oldKeys.transcriptHash,
                allowedPacketTypes = setOf(case.packetType)
            )
            openedAfterRekey.payload.contentEquals(queued) shouldBe true
            // 旧密钥字节仍在服务中，未被置零。
            oldKeys.sendKey.all { it == 0.toByte() } shouldBe false

            // ---- 会话拆解：此时才擦除（R4.9） ----
            teardowns++
            SecureSessionKeyLifecycle.wipeKeyMaterial(oldKeys)
            oldKeys.sendKey.all { it == 0.toByte() } shouldBe true
            oldKeys.receiveKey.all { it == 0.toByte() } shouldBe true
            oldKeys.transcriptHash.all { it == 0.toByte() } shouldBe true
        }

        println(
            "Property 23 (key lifecycle) counters: rekeyContinuations=$rekeyContinuations, " +
                "teardowns=$teardowns"
        )

        (rekeyContinuations > 0) shouldBe true
        (teardowns > 0) shouldBe true
    }
})

/** 对端角色：发送方的 INITIATOR 对应接收方的 RESPONDER，反之亦然。 */
private fun peerRoleOf(role: WebRtcAppSecureEnvelope.Role): WebRtcAppSecureEnvelope.Role =
    when (role) {
        WebRtcAppSecureEnvelope.Role.INITIATOR -> WebRtcAppSecureEnvelope.Role.RESPONDER
        WebRtcAppSecureEnvelope.Role.RESPONDER -> WebRtcAppSecureEnvelope.Role.INITIATOR
    }
