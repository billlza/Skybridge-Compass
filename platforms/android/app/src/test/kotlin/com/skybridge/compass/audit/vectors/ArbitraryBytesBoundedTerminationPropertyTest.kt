package com.skybridge.compass.audit.vectors

import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 8: 任意字节序列解码有界终止且不崩溃**
 *
 * **Validates: Requirements 9.10**
 *
 * 任务 17.9。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3）。
 * 本测试只观察适配器行为，不修改任何解码器（G4）。
 *
 * ## 属性
 *
 * 对长度介于 0 与「该面上限 + 1024 字节」之间的**任意**字节序列，[CodecSurfaceAdapter.decode]：
 *
 * 1. 在单个用例 **1000 ms** 内返回；
 * 2. 返回「解码成功」或「可判别错误」之一（三态之一），**不抛出未捕获异常**；
 * 3. 不终止进程、不进入不终止的循环（由第 1 项的超时观测覆盖）；
 * 4. **不修改入参数组**（R9.6 的"已接收数据不被修改"，在任意输入下同样成立）。
 *
 * [CodecSurfaceAdapter.decode] 的契约明确禁止对**任何**输入抛出异常
 * （见 [CodecSurfaceAdapter] 的 KDoc）；本属性是该契约在随机输入空间上的验证，
 * 是 [HpkeSealedBoxCodecAdapterTest] 中 F3 专项断言（`arbitraryBytesNeverThrow`）的
 * **四面推广**——那里只覆盖 F3 且长度 <200 B，这里覆盖全部八个适配器直到各面上限 +1024 B。
 *
 * ## 输入生成策略（混合，确保非空真）
 *
 * 纯随机字节几乎永远走不到"解码成功"分支，那样这条属性只能证明"错误分支不崩溃"。
 * 为让**三个**分支都真正可达，输入按以下比例混合生成：
 *
 * - **合法编码**（若该面有生产编码入口）——保证 [CodecResult.Success] 可达；
 * - **突变的合法编码**（位翻转 / 截断 / 尾随字节）——最容易走进解码器深处的校验分支；
 * - **纯随机字节**（小 / 中 / 大三档规模）；
 * - **边界长度**：上限 −1、上限、上限 +1、上限 +1024（R9.10 的观察窗口端点）。
 *
 * `messageA` / `messageB` 的合法基底来自只读 Apple corpus，再由生产 typed encoder
 * 重建；因此所有适配器的 Success 与错误分支均可达。
 *
 * ## 迭代次数
 *
 * R9.10 要求**四个编解码面各不少于 5000 个随机用例**。本测试对**每个适配器**各 5000 次：
 * F1 一个、F2 五个、F3 一个、F4 一个，共 8 × 5000 = 40000 个用例，四面均满足下界。
 *
 * ## 失败输入的回归记录
 *
 * R9.10 要求"任一触发失败的输入字节序列被记录为回归用例"：任何失败都以十六进制打印完整
 * （或截断至前 512 B 并标注总长）输入字节与面标识，可直接粘贴为固定回归用例。
 *
 * ## 随机种子
 *
 * 由 `FUZZ_PBT_SEED` 指定，未指定时随机取值并打印到测试输出（R9.10 要求种子记录在测试输出）。
 */
@OptIn(ExperimentalKotest::class)
class ArbitraryBytesBoundedTerminationPropertyTest : FunSpec({

    val seed: Long = System.getenv("FUZZ_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 8] arbitrary-bytes bounded-termination PBT effective seed = $seed")
        println(
            "[Property 8] reproduce with: FUZZ_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*ArbitraryBytesBoundedTerminationPropertyTest*'",
        )
    }

    /** R9.10：单个用例的时限。 */
    val perCaseTimeoutMillis = 1_000L

    /** R9.10：四面各不少于 5000 个随机生成用例。 */
    val iterations = 5_000

    allCodecSurfaceAdapters.forEach { adapter ->
        val label = adapter.auditLabel()
        val cap = adapter.maxEncodedBytes

        test("Property 8 ($label): 0..上限+1024 B 的任意字节恒在 1000 ms 内以三态之一返回") {
            val validEncoding = fuzzBaseEncodingFor(adapter)

            /**
             * 混合输入生成器。
             *
             * 规模分布刻意偏向小输入：F1 的上限是 1 MiB，若 5000 次迭代都生成 ~1 MiB 数组，
             * 单是生成输入就要分配数 GB。边界长度（上限 ±1、上限 +1024）由专门的低概率分支
             * 保证被覆盖，并在结束时断言其计数 > 0，故偏向小输入不会漏掉窗口端点。
             */
            val fuzzArb: Arb<Pair<String, ByteArray>> = arbitrary { rs ->
                val roll = rs.random.nextInt(100)
                when {
                    // 合法编码（若可得）：保证 Success 分支可达。
                    roll < 8 && validEncoding != null -> "valid" to validEncoding.copyOf()

                    // 突变的合法编码：最容易深入解码器的校验分支。
                    roll < 30 && validEncoding != null -> {
                        val mutated = validEncoding.copyOf()
                        when (rs.random.nextInt(3)) {
                            0 -> {
                                if (mutated.isNotEmpty()) {
                                    val idx = rs.random.nextInt(mutated.size)
                                    mutated[idx] = (mutated[idx].toInt() xor (1 shl rs.random.nextInt(8)))
                                        .toByte()
                                }
                                "bitflip" to mutated
                            }
                            1 -> {
                                val cut = if (mutated.isEmpty()) 0 else rs.random.nextInt(mutated.size + 1)
                                "truncated" to mutated.copyOf(cut)
                            }
                            else -> {
                                val extra = ByteArray(1 + rs.random.nextInt(16))
                                    .also { rs.random.nextBytes(it) }
                                "trailing" to (mutated + extra)
                            }
                        }
                    }

                    // 边界长度：R9.10 观察窗口的端点。
                    roll < 33 -> {
                        val size = when (rs.random.nextInt(4)) {
                            0 -> (cap - 1).coerceAtLeast(0)
                            1 -> cap
                            2 -> cap + 1
                            else -> cap + 1024
                        }
                        val bytes = ByteArray(size)
                        // 大数组只填充少量随机字节，避免为每个用例写满 1 MiB。
                        if (bytes.isNotEmpty()) {
                            repeat(minOf(64, bytes.size)) {
                                bytes[rs.random.nextInt(bytes.size)] = rs.random.nextInt(256).toByte()
                            }
                        }
                        "boundary-$size" to bytes
                    }

                    // 中等规模随机字节。
                    roll < 45 -> {
                        val size = rs.random.nextInt(256, minOf(8192, cap + 1024) + 1)
                        "medium-$size" to ByteArray(size).also { rs.random.nextBytes(it) }
                    }

                    // 带正确魔数前缀的随机字节：绕过第一道校验，深入后续分支。
                    roll < 60 && validEncoding != null && validEncoding.size >= 4 -> {
                        val size = 4 + rs.random.nextInt(0, 128)
                        val bytes = ByteArray(size).also { rs.random.nextBytes(it) }
                        validEncoding.copyOf(minOf(4, size)).copyInto(bytes)
                        "magic-prefixed-$size" to bytes
                    }

                    // 小规模随机字节（主体）。
                    else -> {
                        val size = rs.random.nextInt(0, 256)
                        "small-$size" to ByteArray(size).also { rs.random.nextBytes(it) }
                    }
                }
            }

            var successCount = 0
            var malformedCount = 0
            var lengthCapCount = 0
            var boundaryCases = 0
            var mutatedCases = 0
            var maxElapsedMillis = 0L
            var maxInputSize = 0
            val shapes = HashSet<String>()

            checkAll(PropTestConfig(seed = seed, iterations = iterations), fuzzArb) { (shape, bytes) ->
                // 入参快照：仅对 ≤64 KiB 的输入做（大输入的复制会让本测试自身的内存开销翻倍，
                // 而"不修改入参"在小输入上已被充分覆盖，且适配器是无状态纯函数）。
                val snapshot = if (bytes.size <= 64 * 1024) bytes.copyOf() else null

                val start = System.nanoTime()
                val result = try {
                    // R9.10 第 2 项：decode 对任意输入不得抛出未捕获异常。
                    adapter.decode(bytes)
                } catch (t: Throwable) {
                    throw AssertionError(
                        buildString {
                            append("R9.10 违反：$label 的 decode 对输入抛出了 ${t::class.java.name}。")
                            append("回归用例（形态=$shape，长度=${bytes.size} B）字节=")
                            append(regressionHex(bytes))
                        },
                        t,
                    )
                }
                val elapsedMillis = (System.nanoTime() - start) / 1_000_000

                // R9.10 第 1 项：单个用例 1000 ms 内返回。
                if (elapsedMillis >= perCaseTimeoutMillis) {
                    throw AssertionError(
                        "R9.10 违反：$label 的 decode 耗时 ${elapsedMillis}ms ≥ ${perCaseTimeoutMillis}ms。" +
                            "回归用例（形态=$shape，长度=${bytes.size} B）字节=" + regressionHex(bytes),
                    )
                }
                if (elapsedMillis > maxElapsedMillis) maxElapsedMillis = elapsedMillis

                // 三态之一（sealed interface 保证穷尽），并统计分支。
                when (result) {
                    is CodecResult.Success -> successCount++
                    is CodecResult.MalformedFormat -> malformedCount++
                    is CodecResult.ExceedsLengthCap -> {
                        lengthCapCount++
                        // 超限分类必须与实际长度一致。
                        result.maxEncodedBytes shouldBe cap
                        (result.actualBytes > cap) shouldBe true
                    }
                }

                // R9.6/R9.10 第 4 项：入参不被修改。
                if (snapshot != null && !bytes.contentEquals(snapshot)) {
                    throw AssertionError(
                        "R9.6 违反：$label 的 decode 修改了入参数组。" +
                            "回归用例（形态=$shape）原字节=" + regressionHex(snapshot) +
                            "，调用后=" + regressionHex(bytes),
                    )
                }

                if (shape.startsWith("boundary")) boundaryCases++
                if (shape == "bitflip" || shape == "truncated" || shape == "trailing") mutatedCases++
                if (bytes.size > maxInputSize) maxInputSize = bytes.size
                shapes.add(shape.substringBefore('-'))
            }

            println(
                "[Property 8/$label] 迭代=$iterations 成功=$successCount 格式非法=$malformedCount " +
                    "超限=$lengthCapCount 边界用例=$boundaryCases 突变用例=$mutatedCases " +
                    "形态=${shapes.sorted()} 最大输入=$maxInputSize B 最大耗时=${maxElapsedMillis}ms",
            )

            // ---- 反空真断言 ----

            // 必须真的走到"格式非法"与"超出长度上限"两类可判别错误。
            (malformedCount > 0) shouldBe true
            (lengthCapCount > 0) shouldBe true

            // 观察窗口端点必须被覆盖（上限 −1 / 上限 / 上限 +1 / 上限 +1024）。
            (boundaryCases > 0) shouldBe true
            (maxInputSize > cap) shouldBe true

            // 输入形态必须多样（不是 5000 次同一种输入）。
            (shapes.size >= 3) shouldBe true

            // Success 分支必须真正被走到，否则这条属性只验证了错误路径。
            (successCount > 0) shouldBe true
            (mutatedCases > 0) shouldBe true
        }
    }

    // =======================================================================
    // 长度为 0 与上限 +1024 的确定性端点（固定用例，补随机生成的覆盖）
    // =======================================================================

    test("Property 8 (端点): 每个面对空输入与上限+1024 B 输入均以三态之一返回且不抛异常") {
        val summary = mutableListOf<String>()

        allCodecSurfaceAdapters.forEach { adapter ->
            val label = adapter.auditLabel()
            val cap = adapter.maxEncodedBytes

            // 端点 1：空输入。
            val empty = ByteArray(0)
            val emptyResult = runCatching { adapter.decode(empty) }
            if (emptyResult.isFailure) {
                throw AssertionError(
                    "R9.10 违反：$label 对空输入抛出 ${emptyResult.exceptionOrNull()}",
                    emptyResult.exceptionOrNull(),
                )
            }

            // 端点 2：上限 +1024 B。
            val overCap = ByteArray(cap + 1024)
            val overResult = runCatching { adapter.decode(overCap) }
            if (overResult.isFailure) {
                throw AssertionError(
                    "R9.10 违反：$label 对 ${cap + 1024} B 输入抛出 ${overResult.exceptionOrNull()}",
                    overResult.exceptionOrNull(),
                )
            }
            // 该端点必然超限（可判别）。
            val over = overResult.getOrThrow()
            (over is CodecResult.ExceedsLengthCap) shouldBe true

            summary += "$label: 空→${emptyResult.getOrThrow()::class.java.simpleName} " +
                "上限+1024→ExceedsLengthCap"
        }

        summary.forEach { println("[Property 8/端点] $it") }
        summary.size shouldBe allCodecSurfaceAdapters.size
    }
})

/**
 * 为 [adapter] 产出一段**合法**编码，作为突变基底与 Success 分支的来源。
 *
 * MessageA/MessageB use their pinned Apple wire as the valid seed and still re-encode through the
 * shipping typed encoder in their dedicated compatibility tests.
 */
private fun fuzzBaseEncodingFor(adapter: CodecSurfaceAdapter<*>): ByteArray? = when (adapter) {
    is FileTransferMessageCodecAdapter -> FileTransferMessageCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage(
            op = com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp.chunk,
            transferId = "fuzz-base",
            chunkIndex = 7,
            chunkData = ByteArray(24) { it.toByte() },
        ),
    )

    is HandshakeFinishedCodecAdapter -> HandshakeFinishedCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PHandshakeWire.Finished(
            version = 0x01,
            direction = com.skybridge.compass.shared.p2p.P2PHandshakeWire
                .FinishedDirection.RESPONDER_TO_INITIATOR,
            mac = ByteArray(32) { (it * 7).toByte() },
        ),
    )

    is P2PCryptoCapabilitiesCodecAdapter -> P2PCryptoCapabilitiesCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PCryptoCapabilities(
            supportedKEM = listOf("x25519", "kyber768"),
            supportedSignature = listOf("ed25519"),
            supportedAuthProfiles = listOf("default"),
            supportedAEAD = listOf("aes-gcm-256"),
            pqcAvailable = true,
            platformVersion = "android-15",
            providerTypeRaw = "BouncyCastle",
        ),
    )

    is P2PHandshakePolicyCodecAdapter -> P2PHandshakePolicyCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PHandshakePolicy.DEFAULT,
    )

    is HandshakeMessageACodecAdapter -> CompatibilityVectorLoader.fromWorkspace()
        .loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageA")
        .single()
        .rawBytes

    is HandshakeMessageBCodecAdapter -> CompatibilityVectorLoader.fromWorkspace()
        .loadRequired(CodecSurface.F2_P2P_HANDSHAKE, "messageB")
        .single()
        .rawBytes

    is HpkeSealedBoxCodecAdapter -> HpkeSealedBoxCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PHPKESealedBox(
            version = 1,
            suiteWireId = 0x0101u,
            encapsulatedKey = ByteArray(32) { it.toByte() },
            nonce = ByteArray(12) { it.toByte() },
            ciphertext = ByteArray(64) { (it * 3).toByte() },
            tag = ByteArray(16) { (it * 5).toByte() },
        ),
    )

    is BonjourTxtRecordCodecAdapter -> BonjourTxtRecordCodecAdapter.encode(
        mapOf(
            "v" to "1".toByteArray(),
            "id" to ByteArray(8) { it.toByte() },
            "name" to "fuzz".toByteArray(),
        ),
    )

    else -> null
}

/**
 * 失败输入的回归记录表示（R9.10：触发失败的输入须被记录为回归用例）。
 *
 * 超过 512 B 的输入截断显示并标注总长——完整的 1 MiB 十六进制串对回归用例没有实际价值，
 * 且失败可用打印出的种子精确复现。
 */
private fun regressionHex(bytes: ByteArray): String =
    if (bytes.size <= 512) {
        bytes.toHexLower()
    } else {
        bytes.copyOf(512).toHexLower() + "…（前 512 B，总长 ${bytes.size} B）"
    }
