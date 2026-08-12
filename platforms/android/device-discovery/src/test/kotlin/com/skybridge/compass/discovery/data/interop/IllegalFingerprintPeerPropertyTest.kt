package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.map
import io.kotest.property.arbitrary.of
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 17: 非法身份指纹的对端被排除且其他条目不变**
 *
 * **Validates: Requirements 3.14**
 *
 * 任务 7.20 的属性测试。与 [DiscoveredPeerConnectabilityTest] 的示例测试**互补**：示例测试固定
 * 四个指纹用例（缺失、超 255 字节、格式错误、与端口问题并存的优先级）与一个两设备独立性用例，
 * 本文件在随机生成的**混合对端列表**上验证 R3.14 的两个半部：
 *
 * 1. **非法即排除**：指纹缺失 / 编码长度超过
 *    [AppleBonjourInterop.MAX_PUB_KEY_FINGERPRINT_BYTES]（255 字节）/ 不符合约定格式
 *    （64 位小写十六进制）的对端，一律不得被呈现为可连接，且原因可区分为对应的
 *    [PeerNotConnectableReason]。
 * 2. **其他条目不变**：列表中合法对端的判定结果与"列表里有多少非法对端、非法对端排在哪个位置"
 *    **无关**——把同一个合法对端单独分类、与混在任意非法对端之间分类，结果必须逐字段相同。
 *    这是 R3.14"保留已呈现的其他合法对端条目不变"的可判定形式。
 *
 * **属性定义域**：端口维度在本测试中恒合法（SRV 端口取 1..65535），以把指纹维度与 R3.6 的端口
 * 维度**隔离**；二者并存时的原因优先级由示例测试覆盖，Property 12 覆盖端口维度。
 * 非法指纹的构造覆盖：缺失键、空串/纯空白、长度不足/超长的十六进制、含非十六进制字符、
 * 大写十六进制（约定为小写，故大写属非法）、以及 UTF-8 编码超过 255 字节的多字节字符串。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
/** 非法指纹的分类，用于断言"原因可区分"。 */
private enum class IllegalKind { MISSING, TOO_LONG, MALFORMED }

/** 一条非法指纹用例；[rawValue] 为 null 表示 TXT 中完全不存在指纹键。 */
private data class IllegalSpec(val kind: IllegalKind, val rawValue: String?)

class IllegalFingerprintPeerPropertyTest : FunSpec({

    val validFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /** 合法指纹生成器：恰好 64 位小写十六进制。 */
    val legalFingerprintArb: Arb<String> = Arb.list(
        Arb.element('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'),
        64..64
    ).map { it.joinToString("") }

    /**
     * 非法指纹生成器。`rawValue == null` 表示 TXT 中完全不存在指纹键。
     * 空串/纯空白同样归入 MISSING —— 生产以 `isNullOrBlank()` 判定"缺失"。
     */
    val illegalSpecArb: Arb<IllegalSpec> = Arb.of(
        // 缺失：无键、空串、纯空白。
        IllegalSpec(IllegalKind.MISSING, null),
        IllegalSpec(IllegalKind.MISSING, ""),
        IllegalSpec(IllegalKind.MISSING, "   "),
        // 超长：UTF-8 编码 > 255 字节。256 个 ASCII 与 86 个三字节汉字均越限。
        IllegalSpec(IllegalKind.TOO_LONG, "a".repeat(256)),
        IllegalSpec(IllegalKind.TOO_LONG, "f".repeat(300)),
        IllegalSpec(IllegalKind.TOO_LONG, "指".repeat(86)),
        // 格式错误（长度 <= 255 字节但不符合 64 位小写十六进制）。
        IllegalSpec(IllegalKind.MALFORMED, "not-a-valid-fingerprint"),
        IllegalSpec(IllegalKind.MALFORMED, "0123456789abcdef"),
        IllegalSpec(IllegalKind.MALFORMED, "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"),
        IllegalSpec(IllegalKind.MALFORMED, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"),
        IllegalSpec(IllegalKind.MALFORMED, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefa"),
        IllegalSpec(IllegalKind.MALFORMED, "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        IllegalSpec(IllegalKind.MALFORMED, "0123456789abcdef 0123456789abcdef0123456789abcdef0123456789abcde")
    )

    /** 指纹 TXT 键的各种真实别名（生产 PUB_KEY_FINGERPRINT_TXT_KEYS）。 */
    val fingerprintKeyArb: Arb<String> = Arb.element(
        "pubKeyFP", "pubKeyFp", "pub_key_fp", "identityFingerprint", "publicKeyFingerprint"
    )

    fun peerWith(
        deviceId: String,
        fingerprintKey: String,
        fingerprintValue: String?,
        port: Int
    ): DiscoveredDevice = DiscoveredDevice(
        id = deviceId,
        name = "Peer-$deviceId",
        type = DeviceType.MACOS,
        capabilities = emptySet(),
        connectionInfo = ConnectionInfo(
            protocol = DiscoveryProtocol.BONJOUR,
            address = "192.168.1.50",
            // 端口恒合法，隔离 R3.6 维度。
            port = port,
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            txtRecords = buildMap {
                put("deviceId", deviceId)
                put("name", "Peer-$deviceId")
                if (fingerprintValue != null) put(fingerprintKey, fingerprintValue)
            }
        ),
        signalStrength = 100,
        lastSeen = 1_000L
    )

    fun expectedReasonFor(kind: IllegalKind): PeerNotConnectableReason = when (kind) {
        IllegalKind.MISSING -> PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING
        IllegalKind.TOO_LONG -> PeerNotConnectableReason.IDENTITY_FINGERPRINT_TOO_LONG
        IllegalKind.MALFORMED -> PeerNotConnectableReason.IDENTITY_FINGERPRINT_MALFORMED
    }

    test("Property 17: 非法指纹对端一律不可连接，且原因可区分为缺失/超长/格式错误") {
        var missingSeen = 0
        var tooLongSeen = 0
        var malformedSeen = 0
        var legalSeen = 0

        checkAll(
            1_000,
            illegalSpecArb,
            fingerprintKeyArb,
            legalFingerprintArb,
            Arb.int(1..65535)
        ) { illegalSpec, key, legalValue, port ->
            val illegalPeer = peerWith("illegal", key, illegalSpec.rawValue, port)
            val legalPeer = peerWith("legal", key, legalValue, port)

            val illegalResult = DiscoveredPeerConnectability.classify(illegalPeer)
            val legalResult = DiscoveredPeerConnectability.classify(legalPeer)

            // 核心属性 1：非法指纹对端不得可连接，且首要原因恰为对应的指纹原因。
            illegalResult.isConnectable shouldBe false
            illegalResult.primaryReason shouldBe expectedReasonFor(illegalSpec.kind)
            // 端口合法，故原因列表只含指纹原因（不得混入端口原因）。
            illegalResult.reasons shouldBe listOf(expectedReasonFor(illegalSpec.kind))

            // 对照：同键写入合法指纹的对端必须可连接（确认判定不是恒假）。
            legalResult.isConnectable shouldBe true
            legalResult.reasons shouldBe emptyList()
            legalSeen++

            when (illegalSpec.kind) {
                IllegalKind.MISSING -> missingSeen++
                IllegalKind.TOO_LONG -> tooLongSeen++
                IllegalKind.MALFORMED -> malformedSeen++
            }
        }

        println(
            "[Property 17 分类] missingSeen=$missingSeen tooLongSeen=$tooLongSeen " +
                "malformedSeen=$malformedSeen legalSeen=$legalSeen"
        )

        // 非空真保证：三类非法形态与合法对照都被真正生成到。
        (missingSeen > 0) shouldBe true
        (tooLongSeen > 0) shouldBe true
        (malformedSeen > 0) shouldBe true
        (legalSeen > 0) shouldBe true
    }

    test("Property 17: 混合列表中合法条目的判定不受非法条目的数量与位置影响") {
        var listsWithIllegal = 0
        var listsAllLegal = 0
        var listsAllIllegal = 0
        var multiIllegalLists = 0

        // 列表条目：true = 合法，false = 非法。
        val entryArb: Arb<Pair<Boolean, IllegalSpec>> = Arb.bind(
            Arb.of(true, true, false, false),
            illegalSpecArb
        ) { isLegal, spec -> isLegal to spec }

        checkAll(
            500,
            Arb.list(entryArb, 1..8),
            fingerprintKeyArb,
            legalFingerprintArb,
            Arb.int(1..65535)
        ) { entries, key, legalValue, port ->
            val peers = entries.mapIndexed { index, (isLegal, spec) ->
                val value = if (isLegal) legalValue else spec.rawValue
                peerWith(if (isLegal) "legal-$index" else "illegal-$index", key, value, port)
            }

            val results = peers.map { DiscoveredPeerConnectability.classify(it) }

            // 核心属性 1：可连接子集恰为合法条目集合。
            val connectableIds = peers.zip(results)
                .filter { (_, result) -> result.isConnectable }
                .map { (peer, _) -> peer.id }
            val expectedLegalIds = entries.mapIndexedNotNull { index, (isLegal, _) ->
                "legal-$index".takeIf { isLegal }
            }
            connectableIds shouldBe expectedLegalIds

            // 核心属性 2（其他条目不变）：把每个合法对端**单独**分类，结果必须与它在混合列表中
            // 的分类逐字段相同——即非法条目的存在与位置不改变合法条目的判定。
            peers.zip(results).forEach { (peer, inListResult) ->
                val isolatedResult = DiscoveredPeerConnectability.classify(peer)
                isolatedResult.isConnectable shouldBe inListResult.isConnectable
                isolatedResult.reasons shouldBe inListResult.reasons
                isolatedResult.primaryReason shouldBe inListResult.primaryReason
            }

            // 逆序重新分类同样不改变任何条目的判定（顺序无关）。
            val reversedResults = peers.reversed().map { DiscoveredPeerConnectability.classify(it) }
            reversedResults.reversed().map { it.isConnectable } shouldBe results.map { it.isConnectable }
            reversedResults.reversed().map { it.reasons } shouldBe results.map { it.reasons }

            // 非法条目全部被排除。
            peers.zip(results)
                .filter { (peer, _) -> peer.id.startsWith("illegal-") }
                .forEach { (_, result) -> result.isConnectable shouldBe false }

            val illegalCount = entries.count { !it.first }
            when {
                illegalCount == 0 -> listsAllLegal++
                illegalCount == entries.size -> listsAllIllegal++
                else -> listsWithIllegal++
            }
            if (illegalCount > 1) multiIllegalLists++
        }

        println(
            "[Property 17 混合列表] listsAllLegal=$listsAllLegal listsAllIllegal=$listsAllIllegal " +
                "listsWithIllegal=$listsWithIllegal multiIllegalLists=$multiIllegalLists"
        )

        // 非空真保证：全合法、全非法、混合与多个非法条目的列表都被真正生成到。
        (listsAllLegal > 0) shouldBe true
        (listsAllIllegal > 0) shouldBe true
        (listsWithIllegal > 0) shouldBe true
        (multiIllegalLists > 0) shouldBe true
    }

    test("Property 17: 指纹归一化只接受 64 位小写十六进制，大小写与空白书写不放宽格式约定") {
        var acceptedLower = 0
        var rejectedUpper = 0
        var acceptedPadded = 0

        checkAll(300, legalFingerprintArb) { lower ->
            // 合法小写十六进制被接受。
            AppleBonjourInterop.normalizedPubKeyFingerprint(lower) shouldBe lower
            acceptedLower++

            // 前后空白被 trim 后仍接受（书写形态宽容）。
            AppleBonjourInterop.normalizedPubKeyFingerprint("  $lower  ") shouldBe lower
            acceptedPadded++

            // 大写形态不被接受（约定为小写十六进制），且据此判定为格式错误而非"缺失"。
            val upper = lower.uppercase()
            if (upper != lower) {
                AppleBonjourInterop.normalizedPubKeyFingerprint(upper) shouldBe null
                val peer = peerWith("upper", "pubKeyFP", upper, 8080)
                DiscoveredPeerConnectability.classify(peer).primaryReason shouldBe
                    PeerNotConnectableReason.IDENTITY_FINGERPRINT_MALFORMED
                rejectedUpper++
            }
        }

        println(
            "[Property 17 归一化] acceptedLower=$acceptedLower acceptedPadded=$acceptedPadded " +
                "rejectedUpper=$rejectedUpper"
        )

        (acceptedLower > 0) shouldBe true
        (acceptedPadded > 0) shouldBe true
        // 非空真保证：确实生成到了含字母（故大写形态不同）的指纹。
        (rejectedUpper > 0) shouldBe true
    }
})
