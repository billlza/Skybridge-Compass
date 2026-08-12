package com.skybridge.compass.audit.vectors

import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import com.skybridge.compass.shared.p2p.P2PHPKESealedBox
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec

/**
 * 四面 [CodecSurfaceAdapter] 实现（任务 17.2 / R9.6）。
 *
 * 每个适配器都**委托生产入口**，不重新实现任何编解码逻辑；见各类的 [CodecSurfaceAdapter.delegatesTo]。
 */

// ---------------------------------------------------------------------------
// F1 文件传输消息
// ---------------------------------------------------------------------------

/**
 * F1 文件传输消息适配器：`CrossNetworkFileTransferMessage` ↔ canonical JSON，单条 ≤1 MiB。
 *
 * 委托生产入口：
 * - 编码/解码 `CrossNetworkFileTransferWireCodec`
 * - shipping controller 的发送与接收同样只委托该 codec
 *
 * ## 边界保持论证
 *
 * shipping controller 在 codec 边界外用 `runCatching` 把任何解码异常统一视为 "invalid payload"
 * 并拒绝；本适配器把同一异常集合归一为 [CodecResult.MalformedFormat]，接受集合完全一致。长度上限预检查只在
 * `bytes.size > 1 MiB` 时拒绝——该情形下生产侧 DataChannel 单条消息上限本就不允许其出现，
 * 且预检查发生在 `decodeToString()` 之前，不会改变 ≤1 MiB 输入的任何判定。
 *
 * ## 护栏
 *
 * 超过 1 MiB 的字节在 `decodeToString()`（会分配一个与输入等长的 `String`）**之前**即被拒绝，
 * 因此单次解析的新增分配上界为「1 MiB 的 UTF-16 展开 + 解析产物」，被拒绝路径为常数级。
 * 适配器无状态，不修改入参数组。
 */
object FileTransferMessageCodecAdapter : CodecSurfaceAdapter<CrossNetworkFileTransferMessage> {

    override val surface: CodecSurface = CodecSurface.F1_FILE_TRANSFER

    override val delegatesTo: String =
        "CrossNetworkFileTransferWireCodec.kt:23 (encode) / :34 (decode)"

    override fun decode(bytes: ByteArray): CodecResult<CrossNetworkFileTransferMessage> {
        // 长度校验先行：在任何 String/JSON 分配之前。
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F1 file-transfer message") {
            CrossNetworkFileTransferWireCodec.decode(bytes)
        }
    }

    override fun encode(value: CrossNetworkFileTransferMessage): ByteArray =
        CrossNetworkFileTransferWireCodec.encode(value)
}

// ---------------------------------------------------------------------------
// F2 P2P 握手消息
// ---------------------------------------------------------------------------

/**
 * F2 P2P 握手消息适配器：`P2PHandshakeWire.encodeFinished` ↔ `decodeFinished`，单条 ≤65535 B。
 *
 * 委托生产入口：
 * - 编码 `P2PHandshakeWire.kt:1196`（`encodeFinished`）
 * - 解码 `P2PHandshakeWire.kt:1210`（`decodeFinished`）
 *
 * F2 面还包含 `decodeMessageA`（`P2PHandshakeWire.kt:206`）/ `decodeMessageB`（`:502`）与
 * `P2PCryptoCapabilities` / `P2PHandshakePolicy` 的 `deterministicEncode/Decode`
 * （`P2PHandshakeModels.kt:15,28,57,75`）；它们由 [P2PCryptoCapabilitiesCodecAdapter]、
 * [P2PHandshakePolicyCodecAdapter] 与 [HandshakeMessageACodecAdapter] /
 * [HandshakeMessageBCodecAdapter]
 * 覆盖，共享同一 [CodecSurface.F2_P2P_HANDSHAKE] 上限。
 *
 * ## 边界保持论证
 *
 * `decodeFinished` 只接受解包后恰好 38 B 的输入，远小于 65535 B 上限，故长度上限预检查
 * 不可能拒绝任何它会接受的输入（>65535 B 的输入它必然以「length mismatch」拒绝）。
 *
 * ## 护栏
 *
 * `decodeFinished` 先 `require(data.size == 38)` 再 `copyOfRange`，本身不按声明长度预分配；
 * 适配器无状态，分配为常数级。
 */
object HandshakeFinishedCodecAdapter : CodecSurfaceAdapter<P2PHandshakeWire.Finished> {

    override val surface: CodecSurface = CodecSurface.F2_P2P_HANDSHAKE

    override val delegatesTo: String =
        "P2PHandshakeWire.kt:1196 (encodeFinished) / P2PHandshakeWire.kt:1210 (decodeFinished)"

    override fun decode(bytes: ByteArray): CodecResult<P2PHandshakeWire.Finished> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F2 handshake Finished") {
            P2PHandshakeWire.decodeFinished(bytes)
        }
    }

    override fun encode(value: P2PHandshakeWire.Finished): ByteArray =
        P2PHandshakeWire.encodeFinished(value.direction, value.mac)
}

/**
 * F2 子面：`P2PCryptoCapabilities.deterministicEncode` ↔ `deterministicDecode`。
 *
 * 委托生产入口 `P2PHandshakeModels.kt:15`（encode）/ `P2PHandshakeModels.kt:28`（decode）。
 *
 * ## 边界保持论证
 *
 * `deterministicDecode` 以 `require(dec.isAtEnd)` 拒绝尾随字节，其接受的编码长度由字段内容决定；
 * 长度上限预检查只拒绝 >65535 B 的输入，而 F2 线协议单条消息本就不允许超过该上限，
 * 故在 ≤65535 B 范围内接受/拒绝完全由生产入口决定。
 *
 * ## 护栏
 *
 * `DeterministicCodec.Decoder.decodeString` 先 `require(offset + len <= data.size)` **再** `copyOfRange`；
 * `decodeStringArray` 以 `min(count, 1024)` 限制 `ArrayList` 初始容量，因此声明超大数组长度
 * 不会造成按声明长度的预分配（`repeat` 会在越界时立即 `require` 失败）。分配上界因此由实际字节数
 * 而非声明长度决定，满足「≤ 上限 2 倍」。
 */
object P2PCryptoCapabilitiesCodecAdapter :
    CodecSurfaceAdapter<com.skybridge.compass.shared.p2p.P2PCryptoCapabilities> {

    override val surface: CodecSurface = CodecSurface.F2_P2P_HANDSHAKE

    override val delegatesTo: String =
        "P2PHandshakeModels.kt:15 (deterministicEncode) / P2PHandshakeModels.kt:28 (deterministicDecode)"

    override fun decode(
        bytes: ByteArray,
    ): CodecResult<com.skybridge.compass.shared.p2p.P2PCryptoCapabilities> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F2 crypto capabilities") {
            com.skybridge.compass.shared.p2p.P2PCryptoCapabilities.deterministicDecode(bytes)
        }
    }

    override fun encode(
        value: com.skybridge.compass.shared.p2p.P2PCryptoCapabilities,
    ): ByteArray = value.deterministicEncode()
}

/**
 * F2 子面：`P2PHandshakePolicy.deterministicEncode` ↔ `deterministicDecode`。
 *
 * 委托生产入口 `P2PHandshakeModels.kt:57`（encode）/ `P2PHandshakeModels.kt:75`（decode）。
 *
 * ## 边界保持论证
 *
 * 生产 `deterministicDecode` 对**空输入**返回 `P2PHandshakePolicy.DEFAULT`（`P2PHandshakeModels.kt:77`）
 * 而不是拒绝。适配层保留这一行为（空字节 → [CodecResult.Success] 且值为 `DEFAULT`），
 * 否则就会把原本接受的输入变成拒绝，即改变线协议边界。
 */
object P2PHandshakePolicyCodecAdapter :
    CodecSurfaceAdapter<com.skybridge.compass.shared.p2p.P2PHandshakePolicy> {

    override val surface: CodecSurface = CodecSurface.F2_P2P_HANDSHAKE

    override val delegatesTo: String =
        "P2PHandshakeModels.kt:57 (deterministicEncode) / P2PHandshakeModels.kt:75 (deterministicDecode)"

    override fun decode(
        bytes: ByteArray,
    ): CodecResult<com.skybridge.compass.shared.p2p.P2PHandshakePolicy> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F2 handshake policy") {
            com.skybridge.compass.shared.p2p.P2PHandshakePolicy.deterministicDecode(bytes)
        }
    }

    override fun encode(
        value: com.skybridge.compass.shared.p2p.P2PHandshakePolicy,
    ): ByteArray = value.deterministicEncode()
}

/** F2 MessageA adapter; both directions delegate to the sole shipping wire implementation. */
object HandshakeMessageACodecAdapter : CodecSurfaceAdapter<P2PHandshakeWire.MessageA> {
    override val surface: CodecSurface = CodecSurface.F2_P2P_HANDSHAKE
    override val delegatesTo: String =
        "P2PHandshakeWire.kt:348 (encodeMessageA) / P2PHandshakeWire.kt:209 (decodeMessageA)"

    override fun decode(bytes: ByteArray): CodecResult<P2PHandshakeWire.MessageA> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F2 handshake MessageA") {
            P2PHandshakeWire.decodeMessageA(bytes)
        }
    }

    override fun encode(value: P2PHandshakeWire.MessageA): ByteArray =
        P2PHandshakeWire.encodeMessageA(value)
}

/** F2 MessageB adapter; both directions delegate to the sole shipping wire implementation. */
object HandshakeMessageBCodecAdapter : CodecSurfaceAdapter<P2PHandshakeWire.MessageB> {
    override val surface: CodecSurface = CodecSurface.F2_P2P_HANDSHAKE
    override val delegatesTo: String =
        "P2PHandshakeWire.kt:674 (encodeMessageB) / P2PHandshakeWire.kt:611 (decodeMessageB)"

    override fun decode(bytes: ByteArray): CodecResult<P2PHandshakeWire.MessageB> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F2 handshake MessageB") {
            P2PHandshakeWire.decodeMessageB(bytes)
        }
    }

    override fun encode(value: P2PHandshakeWire.MessageB): ByteArray =
        P2PHandshakeWire.encodeMessageB(value)
}

// ---------------------------------------------------------------------------
// F3 HPKE 密封盒
// ---------------------------------------------------------------------------

/**
 * F3 HPKE 密封盒适配器：`combinedWithHeader()` ↔ `parse()`，合并 ≤128 KiB。
 *
 * 委托生产入口：
 * - 编码 `P2PHPKESealedBox.kt:29`（`combinedWithHeader`）
 * - 解码 `P2PHPKESealedBox.kt:52`（`parse`）
 *
 * ## 归一化：`require` → 可判别错误（R9.6 指名要求）
 *
 * 生产 `parse` 用 `require(...)` 抛 `IllegalArgumentException`（`P2PHPKESealedBox.kt:53-95`）。
 * 本适配器把它们归一为两类：
 *
 * - 「合并字节实际长度 > 128 KiB」→ [CodecResult.ExceedsLengthCap]；
 * - 其余全部 `require` 失败（魔数、版本、`encLen`、`nonceLen`、`tagLen`、`ctLen`、长度不一致）
 *   → [CodecResult.MalformedFormat]。
 *
 * ## 边界保持论证（关键）
 *
 * `parse` 在 `isHandshake = true` 下可接受的**最大**合并长度为
 * `17 + encLen(≤4096) + nonceLen(≤12) + ctLen(≤65536) + tagLen(≤16) = 69677 B`，
 * 在 `isHandshake = false` 下为 `17 + 4096 + 12 + 262144 + 16 = 266285 B`。
 *
 * 前者严格小于 128 KiB（131072 B），所以在默认的 `isHandshake = true` 下，长度上限预检查
 * **不可能**拒绝任何 `parse` 会接受的输入——凡是 >128 KiB 的输入，`parse` 本来也会因
 * `ctLen too large` 或 `length mismatch` 而拒绝。因此适配器的接受集合与 `parse` **逐字节相同**，
 * 只是拒绝理由被分成了两个可判别类别。
 *
 * 反之 `isHandshake = false` 的上界 266285 B 超过了 128 KiB，此时长度预检查会**先于** `parse`
 * 拒绝 128 KiB..266285 B 区间的输入。为避免在该模式下改变接受边界，本适配器固定
 * `isHandshake = true`（与 `parse` 的默认参数一致）；非握手模式不属于本面 128 KiB 的建模范围。
 *
 * ## 护栏
 *
 * `parse` 先完成全部长度一致性校验（`require(combined.size == expectedTotal)`，`:88`）
 * **再** `copyOfRange` 切出各段，因此不存在按声明长度的预分配：声明 `ctLen = 65536` 而实际只有
 * 20 B 的敌意输入在任何分配之前即被拒绝。成功路径的分配约等于输入长度（各段之和 = size − 17），
 * 远低于「上限 2 倍」。适配器无状态，不修改入参。
 */
object HpkeSealedBoxCodecAdapter : CodecSurfaceAdapter<P2PHPKESealedBox> {

    override val surface: CodecSurface = CodecSurface.F3_HPKE_SEALED_BOX

    override val delegatesTo: String =
        "P2PHPKESealedBox.kt:29 (combinedWithHeader) / P2PHPKESealedBox.kt:52 (parse)"

    /**
     * 与 `P2PHPKESealedBox.parse` 的默认参数一致；见「边界保持论证」为何不暴露非握手模式。
     */
    private const val IS_HANDSHAKE = true

    override fun decode(bytes: ByteArray): CodecResult<P2PHPKESealedBox> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F3 HPKE sealed box") {
            P2PHPKESealedBox.parse(bytes, isHandshake = IS_HANDSHAKE)
        }
    }

    override fun encode(value: P2PHPKESealedBox): ByteArray = value.combinedWithHeader()

    /**
     * 直接调用生产 `parse`，仅供边界保持测试作为**对照组**使用：
     * 测试据此断言「`parse` 抛异常 ⇔ 适配器返回错误」「`parse` 成功 ⇔ 适配器返回相同值」。
     */
    internal fun parseDirectly(bytes: ByteArray): Result<P2PHPKESealedBox> =
        runCatching { P2PHPKESealedBox.parse(bytes, isHandshake = IS_HANDSHAKE) }
}

// ---------------------------------------------------------------------------
// F4 Bonjour TXT
// ---------------------------------------------------------------------------

/**
 * F4 Bonjour TXT 适配器：`BonjourTxtRecordCodec.encode` ↔ `decode`，单对 ≤255 B、整条 ≤1300 B。
 *
 * 委托生产入口（任务 7.1 交付，`:device-discovery`）：
 * - 编码 `BonjourTxtRecordCodec.kt:58`（`encode`）
 * - 解码 `BonjourTxtRecordCodec.kt:96`（`decode`）
 * - 长度分类 `BonjourTxtRecordCodec.kt:133`（`validate`）
 *
 * ## 两个长度维度
 *
 * [CodecSurface.F4_BONJOUR_TXT] 的 `maxEncodedBytes` = 1300 B 是**整条记录**上限，
 * 与生产常量 `BonjourTxtRecordCodec.MAX_RECORD_BYTES` 一致（构造时断言）。
 * 单对 255 B 上限来自 `MAX_PAIR_BYTES`，是本面**额外**的约束，用
 * [LengthCapScope.SINGLE_PAIR] 与整条上限区分，不与枚举的 1300 B 冲突。
 *
 * 解码方向上单对超限**不可能**发生：RFC 6763 的长度前缀是一个字节，天然 ≤255。
 * 因此 255 B 维度只在编码方向可触发，由 [tryEncode] 经生产 `validate` 分类。
 *
 * ## 边界保持论证
 *
 * 生产 `decode` 只在「长度前缀声明的字节数超过剩余缓冲」（截断）时 `require` 失败；
 * 适配器把它归一为 [CodecResult.MalformedFormat]。长度上限预检查只拒绝 >1300 B 的输入，
 * 而这类记录不合法（超出本面线协议上限），因此 ≤1300 B 输入的接受/拒绝完全由生产 `decode` 决定。
 *
 * ## 护栏
 *
 * `decode` 先 `require(offset + length <= record.size)` **再** `copyOfRange`
 * （`BonjourTxtRecordCodec.kt:104-109`），故不按声明长度预分配；总分配上界为输入长度量级。
 */
object BonjourTxtRecordCodecAdapter : CodecSurfaceAdapter<Map<String, ByteArray>> {

    override val surface: CodecSurface = CodecSurface.F4_BONJOUR_TXT

    override val delegatesTo: String =
        "BonjourTxtRecordCodec.kt:58 (encode) / BonjourTxtRecordCodec.kt:96 (decode)"

    /** 单个 `key=value` 对的编码上限（B），来自生产常量。 */
    val maxPairBytes: Int = BonjourTxtRecordCodec.MAX_PAIR_BYTES

    init {
        // 上限唯一真源自检：枚举的整条上限必须与生产常量一致。
        require(surface.maxEncodedBytes == BonjourTxtRecordCodec.MAX_RECORD_BYTES) {
            "CodecSurface.F4 record cap ${surface.maxEncodedBytes} != " +
                "BonjourTxtRecordCodec.MAX_RECORD_BYTES ${BonjourTxtRecordCodec.MAX_RECORD_BYTES}"
        }
    }

    override fun decode(bytes: ByteArray): CodecResult<Map<String, ByteArray>> {
        lengthCapViolationOrNull(bytes)?.let { return it }
        return normalizingMalformed("F4 Bonjour TXT record") {
            BonjourTxtRecordCodec.decode(bytes)
        }
    }

    override fun encode(value: Map<String, ByteArray>): ByteArray =
        BonjourTxtRecordCodec.encode(value)

    /**
     * 编码方向的归一化：用生产 `validate` 把两个长度维度分类为可判别结果，
     * 单对超限报 [LengthCapScope.SINGLE_PAIR]，整条超限报 [LengthCapScope.WHOLE_MESSAGE]。
     */
    override fun tryEncode(value: Map<String, ByteArray>): CodecResult<ByteArray> =
        when (val validation = BonjourTxtRecordCodec.validate(value)) {
            is BonjourTxtRecordCodec.TxtValidation.PairTooLarge -> CodecResult.ExceedsLengthCap(
                actualBytes = validation.encodedPairBytes,
                maxEncodedBytes = maxPairBytes,
                scope = LengthCapScope.SINGLE_PAIR,
            )

            is BonjourTxtRecordCodec.TxtValidation.RecordTooLarge -> CodecResult.ExceedsLengthCap(
                actualBytes = validation.encodedRecordBytes,
                maxEncodedBytes = maxEncodedBytes,
                scope = LengthCapScope.WHOLE_MESSAGE,
            )

            is BonjourTxtRecordCodec.TxtValidation.Valid ->
                normalizingMalformed("F4 Bonjour TXT encode") { encode(value) }
        }
}

/** 四面适配器清单，供属性测试 17.3–17.9 逐面驱动。 */
val allCodecSurfaceAdapters: List<CodecSurfaceAdapter<*>> = listOf(
    FileTransferMessageCodecAdapter,
    HandshakeFinishedCodecAdapter,
    P2PCryptoCapabilitiesCodecAdapter,
    P2PHandshakePolicyCodecAdapter,
    HandshakeMessageACodecAdapter,
    HandshakeMessageBCodecAdapter,
    HpkeSealedBoxCodecAdapter,
    BonjourTxtRecordCodecAdapter,
)
