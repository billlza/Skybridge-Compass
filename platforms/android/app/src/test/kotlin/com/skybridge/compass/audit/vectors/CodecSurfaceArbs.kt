package com.skybridge.compass.audit.vectors

import com.skybridge.compass.shared.p2p.P2PCryptoCapabilities
import com.skybridge.compass.shared.p2p.P2PHPKESealedBox
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import io.kotest.property.Arb
import io.kotest.property.arbitrary.ArbitraryBuilderContext
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.arbitrary.long

/**
 * 四面被测值的共享生成器（Cross-Platform Parity Audit，任务 17.3–17.9 / R9.2、R9.3、R9.4、R9.5）。
 *
 * 该文件位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包。
 *
 * ## 生成范围严格取自需求，且只收窄到 Android 字段类型能表达的部分
 *
 * 每个生成器的定义域都在 KDoc 中写明，并标注与需求给定范围的**任何**差异及其原因
 * （字段类型上界所致，不是为了让属性更容易通过）。发现的差异一律记录，不静默收窄。
 *
 * ## 不参与编码（G4）
 *
 * 生成器只构造**已解析值**，字节一律由 [CodecSurfaceAdapter.encode] 委托的生产入口产出，
 * 本文件不含任何编码逻辑，也不改变任何线格式。
 */

// ---------------------------------------------------------------------------
// 公共素材
// ---------------------------------------------------------------------------

/**
 * UTF-8 往返安全的字符池：ASCII 可见字符 + 少量多字节字符（含 CJK 与 emoji 的完整代理对）。
 *
 * 刻意**不**使用 `Arb.string()` 的默认 codepoint 生成：孤立代理（lone surrogate）经
 * `String.toByteArray(UTF_8)` 会被替换为 U+FFFD，那是 JVM 字符串本身的有损转换，
 * 与被测的线编解码无关，会把与本属性无关的失败混进来。
 */
private val utf8SafeChars: List<String> =
    (0x20..0x7E).map { it.toChar().toString() } +
        listOf("é", "ü", "ñ", "中", "文", "日", "本", "语", "🚀", "🎯", "안", "녕")

/** 生成 UTF-8 字节数落在 [minBytes]..[maxBytes] 的字符串（按实际字节数控制，不按字符数）。 */
private fun utf8StringArb(minBytes: Int, maxBytes: Int): Arb<String> = arbitrary { rs ->
    require(minBytes <= maxBytes)
    val targetBytes = rs.random.nextInt(minBytes, maxBytes + 1)
    val sb = StringBuilder()
    var bytes = 0
    while (true) {
        val piece = utf8SafeChars[rs.random.nextInt(utf8SafeChars.size)]
        val pieceBytes = piece.toByteArray(Charsets.UTF_8).size
        if (bytes + pieceBytes > targetBytes) {
            // 用单字节 ASCII 补齐到下界，避免因多字节字符跨过上界而卡死。
            if (bytes >= minBytes) break
            sb.append('a')
            bytes += 1
            if (bytes >= targetBytes) break
            continue
        }
        sb.append(piece)
        bytes += pieceBytes
        if (bytes >= targetBytes) break
    }
    sb.toString()
}

/** 任意字节数组，长度落在 [minSize]..[maxSize]。 */
internal fun byteArrayArb(minSize: Int, maxSize: Int): Arb<ByteArray> = arbitrary { rs ->
    val size = rs.random.nextInt(minSize, maxSize + 1)
    ByteArray(size).also { rs.random.nextBytes(it) }
}

/**
 * 可选字段生成：约一半概率取 [arb] 的值，否则取 null，使 null 与非 null 两种形态都被覆盖。
 *
 * 写成 [ArbitraryBuilderContext] 的扩展函数而非生成器块内的局部函数：`arbitrary {}` 的块是
 * `@RestrictsSuspension` 作用域，局部 `suspend fun` 无法在其中调用 `bind()`，
 * 而受限接收者上的扩展挂起函数是被允许的。
 */
private suspend fun <T> ArbitraryBuilderContext.optional(arb: Arb<T>): T? =
    if (Arb.boolean().bind()) arb.bind() else null

// ---------------------------------------------------------------------------
// F1 文件传输消息（R9.2）
// ---------------------------------------------------------------------------

/**
 * F1 生成范围（R9.2），逐项对照：
 *
 * | R9.2 给定范围 | 本生成器 | 说明 |
 * |---|---|---|
 * | 文件名 1..255 UTF-8 字节 | 1..255 UTF-8 字节 | 一致 |
 * | 文件总长度 0..1_099_511_627_776 | 0..1_099_511_627_776（`Long`） | 一致 |
 * | 分片序号 0..4_294_967_295 | 0..[Int.MAX_VALUE] | **收窄**：`chunkIndex` 的 Android 字段类型是 `Int?`（`CrossNetworkFileTransferWire.kt:41`），无法表达 2^31..2^32−1；该差异已记录，不改字段类型（G4：不改线格式） |
 * | 单次批量条目数 1..1024 | `missingChunks` / `batchTotal` 1..1024 | 一致 |
 * | 编码后单条 ≤1 MiB | 由生成器规模保证，并在属性中断言 | 一致 |
 *
 * `chunkData` 等字节字段刻意保持中等规模（≤4 KiB）：R9.2 的上界约束是**编码后单条 ≤1 MiB**，
 * 而 1000+ 次迭代若逐条生成接近 1 MiB 的 base64 载荷会使单条属性耗时进入分钟级；
 * 接近上限的规模由专门的少量大载荷用例覆盖（见 [fileTransferLargeMessageArb]）。
 */
internal val fileTransferMessageArb: Arb<CrossNetworkFileTransferMessage> = arbitrary { rs ->
    val op = Arb.element(CrossNetworkFileTransferOp.entries).bind()
    fileTransferMessageArbFor(op).bind()
}

/** 指定消息类型的 F1 生成器（R9.2 要求「每种消息类型不少于 1000 个用例」）。 */
internal fun fileTransferMessageArbFor(
    op: CrossNetworkFileTransferOp,
): Arb<CrossNetworkFileTransferMessage> = arbitrary {
    val transferId = utf8StringArb(1, 64).bind()

    val fileNameArb = utf8StringArb(1, 255)
    val fileSizeArb = Arb.long(0L..1_099_511_627_776L)
    val chunkIndexArb = Arb.int(0..Int.MAX_VALUE)
    val digestArb = byteArrayArb(32, 32)

    CrossNetworkFileTransferMessage(
        version = Arb.int(1..3).bind(),
        op = op,
        transferId = transferId,
        senderDeviceId = optional(utf8StringArb(1, 128)),
        senderDeviceName = optional(utf8StringArb(1, 64)),
        fileName = when (op) {
            CrossNetworkFileTransferOp.metadata -> fileNameArb.bind()
            else -> optional(fileNameArb)
        },
        fileSize = when (op) {
            CrossNetworkFileTransferOp.metadata -> fileSizeArb.bind()
            else -> optional(fileSizeArb)
        },
        chunkSize = optional(Arb.int(1..1_048_576)),
        totalChunks = optional(Arb.int(0..Int.MAX_VALUE)),
        mimeType = optional(utf8StringArb(1, 64)),
        encryption = optional(Arb.element("aes-gcm-256-v1", "none", "chacha20-poly1305-v1")),
        chunkIndex = when (op) {
            CrossNetworkFileTransferOp.chunk, CrossNetworkFileTransferOp.chunkAck ->
                chunkIndexArb.bind()
            else -> optional(chunkIndexArb)
        },
        chunkData = when (op) {
            CrossNetworkFileTransferOp.chunk -> byteArrayArb(0, 4096).bind()
            else -> optional(byteArrayArb(0, 256))
        },
        nonce = optional(byteArrayArb(12, 12)),
        chunkSha256 = optional(digestArb),
        rawSize = optional(Arb.int(0..1_048_576)),
        receivedBytes = optional(Arb.long(0L..1_099_511_627_776L)),
        fileSha256 = optional(digestArb),
        merkleRoot = optional(digestArb),
        merkleRootSignature = optional(byteArrayArb(0, 64)),
        merkleRootSignatureAlg = optional(Arb.element("hmac-sha256-session-v1", "ed25519-v1")),
        // R9.2 的「单次批量条目数 1..1024」：missingChunks 是该维度的批量载荷。
        missingChunks = if (Arb.boolean().bind()) {
            Arb.list(Arb.int(0..Int.MAX_VALUE), 1..1024).bind().toIntArray()
        } else {
            null
        },
        batchId = optional(utf8StringArb(1, 64)),
        batchIndex = optional(Arb.int(0..1023)),
        batchTotal = optional(Arb.int(1..1024)),
        relativePath = optional(utf8StringArb(1, 255)),
        message = optional(utf8StringArb(0, 256)),
    )
}

/**
 * 接近 F1 编码上限（1 MiB）的少量大载荷用例：`chunkData` 取 512 KiB..760 KiB，
 * base64 展开后逼近但不越过 1 MiB，用于覆盖"上限附近仍能往返"这一形态。
 */
internal val fileTransferLargeMessageArb: Arb<CrossNetworkFileTransferMessage> = arbitrary {
    CrossNetworkFileTransferMessage(
        op = CrossNetworkFileTransferOp.chunk,
        transferId = "large-transfer",
        chunkIndex = Arb.int(0..Int.MAX_VALUE).bind(),
        chunkData = byteArrayArb(512 * 1024, 760 * 1024).bind(),
    )
}

// ---------------------------------------------------------------------------
// F2 P2P 握手消息（R9.3）
// ---------------------------------------------------------------------------

/**
 * F2 `Finished` 生成器。
 *
 * **定义域**：`mac` 恒为 32 字节（生产 `encodeFinished` 以 `require(mac32.size == 32)` 约束，
 * `P2PHandshakeWire.kt:1198`），`version` 恒为 `0x01`。
 *
 * `version` 不随机的原因是**编码方向不携带该字段的自由取值**：`encodeFinished` 恒写入
 * `PROTOCOL_VERSION`（`P2PHandshakeWire.kt:1204`），故 `version != 0x01` 的值对象无法被编码出来，
 * 不属于「可编码值」的定义域。这一点是生产编码入口的既有行为，本测试不改变它（G4）。
 */
internal val handshakeFinishedArb: Arb<P2PHandshakeWire.Finished> = arbitrary {
    P2PHandshakeWire.Finished(
        version = 0x01,
        direction = Arb.element(P2PHandshakeWire.FinishedDirection.entries).bind(),
        mac = byteArrayArb(32, 32).bind(),
    )
}

/**
 * F2 `P2PCryptoCapabilities` 生成器。
 *
 * **定义域**（对照 R9.3）：
 * - 「声明的密码套件列表 1..64 项」→ 四个列表各 1..64 项（另含少量 0 项形态，
 *   因为生产编码对空列表合法，属于该面真实可达的输入）；
 * - 「设备与会话标识 1..128 字节」→ `platformVersion` / `providerTypeRaw` 取 1..128 UTF-8 字节；
 * - 「编码后单条 ≤65535 字节」→ 由上述规模保证，并在属性中断言。
 *
 * 字符串取自 UTF-8 往返安全池（见文件头说明）。
 */
internal val cryptoCapabilitiesArb: Arb<P2PCryptoCapabilities> = arbitrary {
    // R9.3「密码套件列表 1..64 项」；另含 0 项形态（生产编码对空列表合法，属该面可达输入）。
    val suiteListArb = Arb.list(utf8StringArb(1, 32), 0..64)
    P2PCryptoCapabilities(
        supportedKEM = suiteListArb.bind(),
        supportedSignature = suiteListArb.bind(),
        supportedAuthProfiles = suiteListArb.bind(),
        supportedAEAD = suiteListArb.bind(),
        pqcAvailable = Arb.boolean().bind(),
        platformVersion = utf8StringArb(1, 128).bind(),
        providerTypeRaw = utf8StringArb(1, 128).bind(),
    )
}

/**
 * F2 `P2PHandshakePolicy` 生成器。
 *
 * **定义域**：三个布尔字段全组合 + `minimumTierRaw` 取 1..128 UTF-8 字节。
 *
 * 注意生产 `deterministicDecode` 对**空字节**返回 `DEFAULT`（`P2PHandshakeModels.kt:77`），
 * 那是解码方向的特例，不影响本生成器：`deterministicEncode` 恒写出 4 个字段（非空字节），
 * 故 `encode → decode` 的往返不经过该特例路径。
 */
internal val handshakePolicyArb: Arb<P2PHandshakePolicy> = arbitrary {
    P2PHandshakePolicy(
        requirePqc = Arb.boolean().bind(),
        allowClassicFallback = Arb.boolean().bind(),
        minimumTierRaw = utf8StringArb(1, 128).bind(),
        requireSecureEnclavePoP = Arb.boolean().bind(),
    )
}

// ---------------------------------------------------------------------------
// F3 HPKE 密封盒（R9.5）
// ---------------------------------------------------------------------------

/**
 * F3 生成器，定义域为**生产 `parse` 在 `isHandshake = true` 下可接受**的值域：
 *
 * | R9.5 给定范围 | 本生成器 | 说明 |
 * |---|---|---|
 * | 封装公钥 0..1216 字节 | 0..1216 | 一致（生产 `parse` 允许到 4096，本生成器按需求取 1216） |
 * | 附加认证数据 0..1024 字节 | 不适用 | **F3 线格式无 AAD 字段**：`P2PHPKESealedBox` 的字段为 version/suiteWireId/encapsulatedKey/nonce/ciphertext/tag（`P2PHPKESealedBox.kt:22-28`），AAD 不进入合并编码，故无可生成的字段 |
 * | 密文 0..65535 字节 | 0..65535（另含 65536 边界） | 一致；65536 是 `parse(isHandshake = true)` 的 `maxCt`（`P2PHPKESealedBox.kt:80`） |
 * | 合并编码 ≤131072 字节 | 由上述规模保证（最大 17+1216+12+65536+16 = 66797） | 一致，并在属性中断言 |
 *
 * `nonceLen` / `tagLen` 只取生产 codec 接受的 canonical 组合：v1 为 12/16，v2 为 0/0。
 * 其他 v2 组合是 Apple production decoder 同样拒绝的 encoding aliases，由负向测试覆盖。
 */
internal val hpkeSealedBoxArb: Arb<P2PHPKESealedBox> = arbitrary {
    val version = Arb.element(1, 2).bind()
    val nonceLen = if (version == 1) 12 else 0
    val tagLen = if (version == 1) 16 else 0
    // 密文规模：绝大多数取小值以控制 1000+ 迭代的耗时，少量取上限附近。
    // 0 与 65536（parse 的 maxCt）是两个**边界**，显式给它们固定概率而非依赖
    // 区间均匀采样恰好命中 —— 后者命中 0 的概率仅 1/4097，会让边界覆盖变成偶然事件。
    val ctLen = when (Arb.int(0..19).bind()) {
        0 -> 65_536 // parse(isHandshake=true) 的 maxCt 边界
        1 -> Arb.int(60_000..65_535).bind()
        2, 3 -> 0 // 空密文边界
        else -> Arb.int(0..4096).bind()
    }
    // encapsulatedKey 同理：0 与 1216（R9.5 上界）是边界，显式覆盖。
    val encLen = when (Arb.int(0..19).bind()) {
        0, 1 -> 0
        2 -> 1216
        else -> Arb.int(0..1216).bind()
    }
    P2PHPKESealedBox(
        version = version,
        suiteWireId = Arb.int(0..0xFFFF).bind().toUShort(),
        encapsulatedKey = byteArrayArb(encLen, encLen).bind(),
        nonce = byteArrayArb(nonceLen, nonceLen).bind(),
        ciphertext = byteArrayArb(ctLen, ctLen).bind(),
        tag = byteArrayArb(tagLen, tagLen).bind(),
    )
}

// ---------------------------------------------------------------------------
// F4 Bonjour TXT（R9.4）
// ---------------------------------------------------------------------------

/**
 * F4 生成器，定义域严格取自 R9.4：
 *
 * - 字段数 1..16；
 * - 单个键 1..9 个 ASCII 字节；
 * - 单条键值对编码后 ≤255 字节；
 * - 整条 TXT 记录编码后 ≤1300 字节。
 *
 * **键的取值收窄及其原因**：键取可见 ASCII（0x21..0x7E）且**排除** `=`。
 * - 排除 `=`：生产 `encode` 以 `require(!key.contains('='))` 拒绝（`BonjourTxtRecordCodec.kt:63`），
 *   含 `=` 的键不可编码，不属于定义域；
 * - 排除空键：生产 `encode` 以 `require(key.isNotEmpty())` 拒绝（`:62`），且 `decode` 会丢弃空键
 *   （`:118`、`:126`），故空键不属于往返定义域；
 * - 排除空白与不可见字符：RFC 6763 §6.4 规定键为可见 ASCII，这是该面的线协议定义域。
 *
 * 值为任意字节（含 `=`、含 0x00）——`decode` 按**首个** `=` 切分（`BonjourTxtRecordCodec.kt:112`），
 * 故值内含 `=` 仍能无损往返，这一形态被刻意覆盖。
 */
internal val bonjourTxtFieldsArb: Arb<Map<String, ByteArray>> = arbitrary { rs ->
    val keyChars: List<Char> = (0x21..0x7E).map { it.toChar() }.filter { it != '=' }
    val fieldCount = rs.random.nextInt(1, 17)

    val fields = LinkedHashMap<String, ByteArray>()
    var recordBytes = 0
    repeat(fieldCount) {
        // 键 1..9 个 ASCII 字节，且在本记录内唯一（Map 语义天然去重，这里避免生成即覆盖）。
        var key: String
        var guard = 0
        do {
            val keyLen = rs.random.nextInt(1, 10)
            key = (0 until keyLen).map { keyChars[rs.random.nextInt(keyChars.size)] }
                .joinToString("")
            guard++
        } while (fields.containsKey(key) && guard < 32)
        if (fields.containsKey(key)) return@repeat

        // 单对编码 = key + '=' + value ≤255 → value ≤ 255 − keyLen − 1。
        val maxValueForPair = 255 - key.toByteArray(Charsets.ISO_8859_1).size - 1
        // 整条记录 = Σ(1 + pair) ≤1300 → 本对可用的剩余额度。
        val remainingRecord = 1300 - recordBytes - 1 - key.toByteArray(Charsets.ISO_8859_1).size - 1
        val maxValue = minOf(maxValueForPair, remainingRecord)
        if (maxValue < 0) return@repeat

        val valueLen = rs.random.nextInt(0, maxValue + 1)
        val value = ByteArray(valueLen).also { rs.random.nextBytes(it) }
        fields[key] = value
        recordBytes += 1 + key.toByteArray(Charsets.ISO_8859_1).size + 1 + valueLen
    }

    // 字段数下界 1：极端情况下上面的额度控制可能一条都没放进去，补一条最小字段。
    if (fields.isEmpty()) {
        fields["k"] = ByteArray(0)
    }
    fields
}

// ---------------------------------------------------------------------------
// 值相等判定（data class 含 ByteArray/IntArray，需逐字段内容比较）
// ---------------------------------------------------------------------------

/**
 * F1 消息的逐字段相等判定。
 *
 * [CrossNetworkFileTransferMessage] 是含 `ByteArray` / `IntArray` 字段的 `data class`，
 * 其自动生成的 `equals` 对这些字段按**引用**比较，因此不能用 `==` 判定往返相等
 * （R9.2 要求「所有字段逐一相等」）。
 *
 * @return 不相等时返回首个不相等字段的说明；相等时返回 null。
 */
internal fun fileTransferFieldMismatch(
    expected: CrossNetworkFileTransferMessage,
    actual: CrossNetworkFileTransferMessage,
): String? {
    fun <T> cmp(name: String, a: T, b: T): String? =
        if (a == b) null else "字段 $name 不相等：期望 $a，实际 $b"

    fun bytes(name: String, a: ByteArray?, b: ByteArray?): String? = when {
        a == null && b == null -> null
        a == null || b == null -> "字段 $name 不相等：期望 ${a?.size ?: "null"}，实际 ${b?.size ?: "null"}"
        a.contentEquals(b) -> null
        else -> "字段 $name 字节不相等：期望 ${a.toHexLower()}，实际 ${b.toHexLower()}"
    }

    return cmp("version", expected.version, actual.version)
        ?: cmp("op", expected.op, actual.op)
        ?: cmp("transferId", expected.transferId, actual.transferId)
        ?: cmp("senderDeviceId", expected.senderDeviceId, actual.senderDeviceId)
        ?: cmp("senderDeviceName", expected.senderDeviceName, actual.senderDeviceName)
        ?: cmp("fileName", expected.fileName, actual.fileName)
        ?: cmp("fileSize", expected.fileSize, actual.fileSize)
        ?: cmp("chunkSize", expected.chunkSize, actual.chunkSize)
        ?: cmp("totalChunks", expected.totalChunks, actual.totalChunks)
        ?: cmp("mimeType", expected.mimeType, actual.mimeType)
        ?: cmp("encryption", expected.encryption, actual.encryption)
        ?: cmp("chunkIndex", expected.chunkIndex, actual.chunkIndex)
        ?: bytes("chunkData", expected.chunkData, actual.chunkData)
        ?: bytes("nonce", expected.nonce, actual.nonce)
        ?: bytes("chunkSha256", expected.chunkSha256, actual.chunkSha256)
        ?: cmp("rawSize", expected.rawSize, actual.rawSize)
        ?: cmp("receivedBytes", expected.receivedBytes, actual.receivedBytes)
        ?: bytes("fileSha256", expected.fileSha256, actual.fileSha256)
        ?: bytes("merkleRoot", expected.merkleRoot, actual.merkleRoot)
        ?: bytes("merkleRootSignature", expected.merkleRootSignature, actual.merkleRootSignature)
        ?: cmp("merkleRootSignatureAlg", expected.merkleRootSignatureAlg, actual.merkleRootSignatureAlg)
        ?: run {
            val a = expected.missingChunks
            val b = actual.missingChunks
            when {
                a == null && b == null -> null
                a == null || b == null ->
                    "字段 missingChunks 不相等：期望 ${a?.size ?: "null"}，实际 ${b?.size ?: "null"}"
                a.contentEquals(b) -> null
                else -> "字段 missingChunks 内容不相等：期望 ${a.toList()}，实际 ${b.toList()}"
            }
        }
        ?: cmp("batchId", expected.batchId, actual.batchId)
        ?: cmp("batchIndex", expected.batchIndex, actual.batchIndex)
        ?: cmp("batchTotal", expected.batchTotal, actual.batchTotal)
        ?: cmp("relativePath", expected.relativePath, actual.relativePath)
        ?: cmp("message", expected.message, actual.message)
}

/** F3 密封盒的逐字段相等判定（同样因 `ByteArray` 字段不能用 `==`）。 */
internal fun hpkeFieldMismatch(
    expected: P2PHPKESealedBox,
    actual: P2PHPKESealedBox,
): String? = when {
    expected.version != actual.version ->
        "字段 version 不相等：期望 ${expected.version}，实际 ${actual.version}"
    expected.suiteWireId != actual.suiteWireId ->
        "字段 suiteWireId 不相等：期望 ${expected.suiteWireId}，实际 ${actual.suiteWireId}"
    !expected.encapsulatedKey.contentEquals(actual.encapsulatedKey) ->
        "字段 encapsulatedKey 不相等：期望 ${expected.encapsulatedKey.size} B，实际 ${actual.encapsulatedKey.size} B"
    !expected.nonce.contentEquals(actual.nonce) ->
        "字段 nonce 不相等：期望 ${expected.nonce.toHexLower()}，实际 ${actual.nonce.toHexLower()}"
    !expected.ciphertext.contentEquals(actual.ciphertext) ->
        "字段 ciphertext 不相等：期望 ${expected.ciphertext.size} B，实际 ${actual.ciphertext.size} B"
    !expected.tag.contentEquals(actual.tag) ->
        "字段 tag 不相等：期望 ${expected.tag.toHexLower()}，实际 ${actual.tag.toHexLower()}"
    else -> null
}

/** F2 `Finished` 的逐字段相等判定。 */
internal fun finishedFieldMismatch(
    expected: P2PHandshakeWire.Finished,
    actual: P2PHandshakeWire.Finished,
): String? = when {
    expected.version != actual.version ->
        "字段 version 不相等：期望 ${expected.version}，实际 ${actual.version}"
    expected.direction != actual.direction ->
        "字段 direction 不相等：期望 ${expected.direction}，实际 ${actual.direction}"
    !expected.mac.contentEquals(actual.mac) ->
        "字段 mac 不相等：期望 ${expected.mac.toHexLower()}，实际 ${actual.mac.toHexLower()}"
    else -> null
}

/**
 * F4 字段集合的相等判定（R9.4：键集合相同且每键值字节序列相同，**不依赖书写顺序**）。
 */
internal fun bonjourFieldMismatch(
    expected: Map<String, ByteArray>,
    actual: Map<String, ByteArray>,
): String? {
    if (expected.keys != actual.keys) {
        val missing = expected.keys - actual.keys
        val extra = actual.keys - expected.keys
        return "键集合不相等：缺失 $missing，多出 $extra"
    }
    for ((key, value) in expected) {
        val actualValue = actual.getValue(key)
        if (!value.contentEquals(actualValue)) {
            return "键 '$key' 的值字节不相等：期望 ${value.toHexLower()}，实际 ${actualValue.toHexLower()}"
        }
    }
    return null
}
