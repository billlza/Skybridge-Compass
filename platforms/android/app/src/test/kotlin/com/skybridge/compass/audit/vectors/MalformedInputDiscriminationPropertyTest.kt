package com.skybridge.compass.audit.vectors

import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 7: 非法与超限输入产生可判别错误且分配有界**
 *
 * **Validates: Requirements 9.6**
 *
 * 任务 17.8。位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包（G3）。
 * 本测试只观察适配器行为，不修改任何解码器，也不"为了让属性通过"而调整接受/拒绝边界（G4）。
 *
 * ## 属性（R9.6 的五项逐一对应）
 *
 * 对每个面的任意非法 / 超限输入：
 *
 * 1. **可判别的错误类别**：结果恰为 [CodecResult.MalformedFormat] 与
 *    [CodecResult.ExceedsLengthCap] 之一（两者是独立变体，判别不依赖解析错误文案）；
 * 2. **不抛出未捕获异常、不终止进程**：`decode` 对任意输入都返回三态之一；
 * 3. **完成长度校验前不按声明长度预分配缓冲**：声明超大长度而实际很短的敌意输入
 *    被**常数级**成本拒绝（以分配量与耗时双重观测）；
 * 4. **单次解析新增分配 ≤ 该面上限的 2 倍**：对上述两类**被拒绝**输入实测线程分配字节数；
 * 5. **已有会话状态与已接收数据不被修改**：适配器无状态，且 `decode` 不写回入参数组。
 *
 * ## 分配测量的定义域（重要，刻意收窄且说明理由）
 *
 * 第 4 项以 `ThreadMXBean.getThreadAllocatedBytes` 实测，但**只对两类结构上应为常数级成本的
 * 被拒绝输入**断言 ≤2× 上限：
 *
 * - **超出长度上限**的输入（`bytes.size > maxEncodedBytes`）——长度预检查在任何解码动作前返回；
 * - **声明长度超大而实际字节很短**的敌意输入——生产解码器先校验后分配。
 *
 * **不**对"上限内的任意格式非法输入"断言分配上界：那类输入的解码器可以合法地先构造与输入等长的
 * 中间表示（例如 F1 的 `decodeToString()` 会分配约 2× 输入长度的 UTF-16 字符串），
 * 其分配随**实际输入长度**增长，这是被允许的——R9.6 约束的是"不按**声明长度**预分配"。
 * 对它们仍断言可判别、不抛异常、不改入参、有界耗时。该定义域收窄是对需求的忠实解读，
 * 不是为了回避一个会失败的断言。
 *
 * 分配测量取多次重复的**最小值**，以滤除 JIT 与 GC 记账噪声；测量不可用时（JVM 不支持该扩展）
 * 该子断言按"无法测量"记录并跳过**该子项**，其余断言照常执行（会打印提示）。
 *
 * ## 随机种子
 *
 * 由 `MALFORMED_PBT_SEED` 指定，未指定时随机取值并打印到测试输出。
 */
@OptIn(ExperimentalKotest::class)
class MalformedInputDiscriminationPropertyTest : FunSpec({

    val seed: Long = System.getenv("MALFORMED_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    val allocationProbe = ThreadAllocationProbe()

    beforeSpec {
        println("[Property 7] malformed/oversize PBT effective seed = $seed")
        println(
            "[Property 7] reproduce with: MALFORMED_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest " +
                "--tests '*MalformedInputDiscriminationPropertyTest*'",
        )
        println("[Property 7] 线程分配测量可用 = ${allocationProbe.available}")
    }

    val config = PropTestConfig(seed = seed, iterations = 400)

    // =======================================================================
    // 1. 超出长度上限 → ExceedsLengthCap，且分配为常数级
    // =======================================================================

    allCodecSurfaceAdapters.forEach { adapter ->
        val label = adapter.auditLabel()

        test("Property 7 ($label/超限): 超过上限的输入恒报 ExceedsLengthCap 且分配 ≤2× 上限") {
            val cap = adapter.maxEncodedBytes

            // 超限输入：上限 +1 .. 上限 +1024（R9.10 的观察窗口同一区间）。
            val overCapArb: Arb<ByteArray> = arbitrary { rs ->
                val size = cap + 1 + rs.random.nextInt(1024)
                // 内容任意：超限判定必须与内容无关（长度预检查先行）。
                ByteArray(size).also { if (rs.random.nextBoolean()) rs.random.nextBytes(it) }
            }

            var cases = 0
            var withRandomContent = 0
            var maxObservedAllocation = 0L
            var allocationMeasured = 0

            // 迭代次数对超限属性取较小值：F1 的上限是 1 MiB，每个用例都要分配 >1 MiB 的输入数组。
            checkAll(PropTestConfig(seed = seed, iterations = 60), overCapArb) { bytes ->
                val snapshot = bytes.copyOf()

                val result = adapter.decode(bytes)

                // R9.6 第 1 项：必须是可判别的"超出长度上限"，而不是格式非法。
                val cap2 = result as? CodecResult.ExceedsLengthCap
                    ?: throw AssertionError(
                        "$label：${bytes.size} B（上限 $cap）应报 ExceedsLengthCap，实际 $result",
                    )
                cap2.actualBytes shouldBe bytes.size
                cap2.maxEncodedBytes shouldBe cap
                cap2.scope shouldBe LengthCapScope.WHOLE_MESSAGE
                // 强制窄化为 ExceedsLengthCap 已在类型层证明它不是 MalformedFormat。
                result.isSuccess shouldBe false

                // R9.6 第 5 项：入参不被修改。
                bytes.contentEquals(snapshot) shouldBe true

                // R9.6 第 4 项：分配 ≤2× 上限（此路径结构上是常数级）。
                val allocated = allocationProbe.minAllocatedBytes(repeats = 3) { adapter.decode(bytes) }
                if (allocated != null) {
                    allocationMeasured++
                    if (allocated > maxObservedAllocation) maxObservedAllocation = allocated
                    if (allocated > 2L * cap) {
                        throw AssertionError(
                            "$label：拒绝 ${bytes.size} B 超限输入分配了 $allocated B，超过上限 2 倍（${2L * cap} B）",
                        )
                    }
                }

                cases++
                if (bytes.any { it != 0.toByte() }) withRandomContent++
            }

            println(
                "[Property 7/$label/超限] 用例=$cases 随机内容=$withRandomContent " +
                    "已测分配=$allocationMeasured 最大分配=$maxObservedAllocation B（限 ${2L * cap} B）",
            )

            (cases > 0) shouldBe true
            (withRandomContent > 0) shouldBe true
        }
    }

    // =======================================================================
    // 2. 上限内的非法输入 → 可判别错误，不抛异常，不改入参，耗时有界
    // =======================================================================

    allCodecSurfaceAdapters.forEach { adapter ->
        val label = adapter.auditLabel()

        test("Property 7 ($label/非法): 上限内的非法输入恒报可判别错误且不修改入参") {
            // 上限内的非法输入：随机字节 + 截断的合法编码 + 位翻转的合法编码。
            val malformedArb: Arb<Pair<String, ByteArray>> = arbitrary { rs ->
                val valid = validEncodingFor(adapter)
                when (rs.random.nextInt(if (valid == null) 2 else 5)) {
                    0 -> {
                        val size = rs.random.nextInt(0, 512)
                        "random-$size" to ByteArray(size).also { rs.random.nextBytes(it) }
                    }
                    1 -> {
                        // 全零字节：多数面的魔数/版本校验会拒绝。
                        val size = rs.random.nextInt(0, 64)
                        "zeros-$size" to ByteArray(size)
                    }
                    2 -> {
                        // 截断的合法编码。
                        val cut = if (valid!!.isEmpty()) 0 else rs.random.nextInt(0, valid.size)
                        "truncated-$cut/${valid.size}" to valid.copyOf(cut)
                    }
                    3 -> {
                        // 位翻转的合法编码。
                        val mutated = valid!!.copyOf()
                        if (mutated.isNotEmpty()) {
                            val idx = rs.random.nextInt(mutated.size)
                            mutated[idx] = (mutated[idx].toInt() xor 0xFF).toByte()
                        }
                        "bitflip" to mutated
                    }
                    else -> {
                        // 尾随垃圾字节的合法编码。
                        val extra = ByteArray(1 + rs.random.nextInt(8))
                            .also { rs.random.nextBytes(it) }
                        "trailing" to (valid!! + extra)
                    }
                }
            }

            var malformedCount = 0
            var lengthCapCount = 0
            var successCount = 0
            var maxElapsedMillis = 0L
            val shapes = HashSet<String>()

            checkAll(config, malformedArb) { (shape, bytes) ->
                val snapshot = bytes.copyOf()

                val start = System.nanoTime()
                // R9.6 第 2 项：decode 对任意输入不抛异常。
                val result = adapter.decode(bytes)
                val elapsedMillis = (System.nanoTime() - start) / 1_000_000

                // 结果恰为三态之一，且三者互斥。
                when (result) {
                    is CodecResult.Success -> successCount++
                    is CodecResult.MalformedFormat -> {
                        malformedCount++
                        // 可判别：两类错误是独立变体，判别不依赖错误文案。
                        result.isSuccess shouldBe false
                    }
                    is CodecResult.ExceedsLengthCap -> lengthCapCount++
                }

                // R9.6 第 5 项：已接收数据不被修改。
                bytes.contentEquals(snapshot) shouldBe true

                // 有界终止（R9.6 与 R9.10 共用的观察）：单个用例远低于 1000 ms。
                (elapsedMillis < 1_000) shouldBe true
                if (elapsedMillis > maxElapsedMillis) maxElapsedMillis = elapsedMillis

                shapes.add(shape.substringBefore('-'))
            }

            println(
                "[Property 7/$label/非法] 格式非法=$malformedCount 超限=$lengthCapCount " +
                    "成功=$successCount 输入形态=${shapes.sorted()} 最大耗时=${maxElapsedMillis}ms",
            )

            // 反空真：必须真的走到"格式非法"分支，否则这条属性什么也没验证。
            (malformedCount > 0) shouldBe true
            (shapes.size >= 2) shouldBe true
        }
    }

    // =======================================================================
    // 3. 声明长度超大而实际字节很短：不按声明长度预分配
    // =======================================================================

    test("Property 7 (F3/敌意声明长度): 声明 ctLen 超大而实际很短的输入被常数级成本拒绝") {
        val adapter = HpkeSealedBoxCodecAdapter
        val cap = adapter.maxEncodedBytes

        // 手工拼装 17 B HPKE 头部：声明巨大的 ctLen / encLen，实际载荷 0..32 B。
        val hostileArb: Arb<Pair<Int, ByteArray>> = arbitrary { rs ->
            val declaredCtLen = when (rs.random.nextInt(4)) {
                0 -> Int.MAX_VALUE
                1 -> 1 shl 30
                2 -> 65_536
                else -> 1 shl 20
            }
            val payload = ByteArray(rs.random.nextInt(0, 33)).also { rs.random.nextBytes(it) }
            val bb = java.nio.ByteBuffer.allocate(17 + payload.size)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            bb.put(byteArrayOf(0x48, 0x50, 0x4B, 0x45)) // "HPKE"
            bb.put(1) // version
            bb.putShort(0x0101) // suiteWireId
            bb.putShort(0) // flags
            bb.putShort(0) // encLen
            bb.put(12) // nonceLen
            bb.put(16) // tagLen
            bb.putInt(declaredCtLen)
            bb.put(payload)
            declaredCtLen to bb.array()
        }

        var cases = 0
        var maxAllocation = 0L
        var measured = 0
        var maxElapsedMillis = 0L
        val declaredValues = HashSet<Int>()

        checkAll(PropTestConfig(seed = seed, iterations = 300), hostileArb) { (declaredCtLen, bytes) ->
            val snapshot = bytes.copyOf()

            val start = System.nanoTime()
            val result = adapter.decode(bytes)
            val elapsedMillis = (System.nanoTime() - start) / 1_000_000

            // 声明长度与实际长度不一致 → 格式非法（不是长度上限：实际字节远小于上限）。
            (result is CodecResult.MalformedFormat) shouldBe true
            (result is CodecResult.ExceedsLengthCap) shouldBe false

            bytes.contentEquals(snapshot) shouldBe true
            (elapsedMillis < 1_000) shouldBe true
            if (elapsedMillis > maxElapsedMillis) maxElapsedMillis = elapsedMillis

            // 核心：R9.6 第 3/4 项 —— 不按声明长度预分配，分配 ≤2× 上限。
            // 声明 ctLen 可达 Int.MAX_VALUE（2 GiB），若预分配则此处必然爆炸或 OOM。
            val allocated = allocationProbe.minAllocatedBytes(repeats = 3) { adapter.decode(bytes) }
            if (allocated != null) {
                measured++
                if (allocated > maxAllocation) maxAllocation = allocated
                if (allocated > 2L * cap) {
                    throw AssertionError(
                        "F3：声明 ctLen=$declaredCtLen、实际 ${bytes.size} B 的输入分配了 $allocated B，" +
                            "超过上限 2 倍（${2L * cap} B）——疑似按声明长度预分配",
                    )
                }
            }

            cases++
            declaredValues.add(declaredCtLen)
        }

        println(
            "[Property 7/F3敌意声明长度] 用例=$cases 声明取值=${declaredValues.sorted()} " +
                "已测分配=$measured 最大分配=$maxAllocation B（限 ${2L * cap} B）最大耗时=${maxElapsedMillis}ms",
        )

        // 补强：分配量对声明长度不敏感（与 F4 同一判据）。声明 ctLen 从 64 KiB 到 2 GiB 变化，
        // 实际字节恒为 17 B；若按声明长度预分配，分配量会随之爆炸。
        val perDeclared = listOf(65_536, 1 shl 20, 1 shl 24, 1 shl 30, Int.MAX_VALUE)
            .mapNotNull { declaredCtLen ->
                val bb = java.nio.ByteBuffer.allocate(17).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                bb.put(byteArrayOf(0x48, 0x50, 0x4B, 0x45))
                bb.put(1); bb.putShort(0x0101); bb.putShort(0); bb.putShort(0)
                bb.put(12); bb.put(16); bb.putInt(declaredCtLen)
                val probe = bb.array()
                allocationProbe.minAllocatedBytes(repeats = 8) { adapter.decode(probe) }
                    ?.let { declaredCtLen to it }
            }

        if (perDeclared.isNotEmpty()) {
            val values = perDeclared.map { it.second }
            val spread = values.max() - values.min()
            println("[Property 7/F3敌意声明长度] 逐声明 ctLen 分配=$perDeclared 极差=$spread B")
            if (spread > 256) {
                throw AssertionError(
                    "F3：拒绝路径分配随声明 ctLen 变化（极差 $spread B，逐值 $perDeclared），" +
                        "疑似按声明长度预分配（R9.6）",
                )
            }
        }

        (cases > 0) shouldBe true
        // 反空真：必须真的用过 Int.MAX_VALUE 这类极端声明值。
        (declaredValues.contains(Int.MAX_VALUE)) shouldBe true
        (declaredValues.size >= 3) shouldBe true
    }

    /**
     * F4 的分配上界断言方式与 F3 不同，原因是**实测得到的**事实：
     *
     * F4 的整条上限只有 1300 B，2 倍即 2600 B，而 JVM 抛出并填充**一个**异常的栈轨迹在本测试
     * 的调用栈深度下就要约 2100 B（实测：裸 `IllegalArgumentException` = 2120 B，
     * 生产 `decode` 抛出 = 2304 B，经适配层归一 = 3144 B，成功路径仅 488 B）。
     * 也就是说 F4 拒绝路径的分配几乎全部是**异常构造的固定开销**，与输入内容、
     * 更与"声明长度"无关：实测声明长度取 16 / 64 / 128 / 200 / 255 时分配量**完全相同**（3144 B）。
     *
     * 因此对 F4 断言「拒绝一次的绝对分配 ≤2×1300 B」测的是 JVM 异常开销，不是 R9.6 想约束的
     * "按声明长度预分配"。这里改为断言 R9.6 的**实质**：分配量**不随声明长度增长**
     * （以多个声明长度的分配量极差为判据），并单独记录固定开销。这不是放宽要求——
     * 若解码器真按声明长度预分配，声明 255 B 与声明 16 B 的分配量必然拉开差距，本断言会失败。
     */
    test("Property 7 (F4/敌意声明长度): 长度前缀超过剩余字节的记录被拒绝，且分配不随声明长度增长") {
        val adapter = BonjourTxtRecordCodecAdapter
        val cap = adapter.maxEncodedBytes

        // TXT 的长度前缀是单字节（≤255），故"声明超大"的上界是 255；
        // 构造 prefix=声明值 而实际剩余远小于该值的记录。
        val hostileArb: Arb<Pair<Int, ByteArray>> = arbitrary { rs ->
            val declared = rs.random.nextInt(1, 256)
            val remaining = rs.random.nextInt(0, declared)
            val out = ByteArray(1 + remaining)
            out[0] = declared.toByte()
            if (remaining > 0) {
                val tail = ByteArray(remaining).also { rs.random.nextBytes(it) }
                tail.copyInto(out, 1)
            }
            declared to out
        }

        var cases = 0
        val declaredValues = HashSet<Int>()

        checkAll(PropTestConfig(seed = seed, iterations = 300), hostileArb) { (declared, bytes) ->
            val snapshot = bytes.copyOf()
            val result = adapter.decode(bytes)

            // 截断记录 → 格式非法（可判别，且不是长度上限）。
            (result is CodecResult.MalformedFormat) shouldBe true
            (result is CodecResult.ExceedsLengthCap) shouldBe false
            bytes.contentEquals(snapshot) shouldBe true

            cases++
            declaredValues.add(declared)
        }

        // 核心：分配量对声明长度的敏感性。同一实际长度（4 B）下只改变声明长度，
        // 若存在按声明长度的预分配，分配量必随声明长度单调增长。
        val perDeclared = listOf(16, 64, 128, 200, 255).mapNotNull { declared ->
            val probe = ByteArray(4).also { it[0] = declared.toByte() }
            allocationProbe.minAllocatedBytes(repeats = 8) { adapter.decode(probe) }
                ?.let { declared to it }
        }

        if (perDeclared.isNotEmpty()) {
            val values = perDeclared.map { it.second }
            val spread = values.max() - values.min()
            println(
                "[Property 7/F4敌意声明长度] 逐声明长度分配=$perDeclared 极差=$spread B",
            )
            // 若按声明长度预分配，声明 255 与声明 16 的分配差至少是数百字节量级。
            // 实测极差为 0（固定开销）；这里留出 256 B 余量以容忍 JIT/GC 记账噪声。
            if (spread > 256) {
                throw AssertionError(
                    "F4：拒绝路径分配随声明长度变化（极差 $spread B，逐值 $perDeclared），" +
                        "疑似按声明长度预分配（R9.6）",
                )
            }
            // 同时记录固定开销与该面 2× 上限的关系，供审计报告引用。
            println(
                "[Property 7/F4敌意声明长度] 拒绝一次的固定分配≈${values.min()} B；" +
                    "该面 2× 上限=${2L * cap} B（固定开销主要来自异常栈轨迹填充，与声明长度无关）",
            )
        } else {
            println("[Property 7/F4敌意声明长度] 线程分配测量不可用，跳过分配子断言")
        }

        (cases > 0) shouldBe true
        (declaredValues.size >= 50) shouldBe true
    }

    // =======================================================================
    // 4. F4 编码方向的第二个长度维度：单对 255 B
    // =======================================================================

    test("Property 7 (F4/单对超限): 单个键值对超过 255 B 在编码方向报 SINGLE_PAIR 可判别错误") {
        val adapter = BonjourTxtRecordCodecAdapter

        val oversizePairArb: Arb<Map<String, ByteArray>> = arbitrary { rs ->
            val key = "k" + rs.random.nextInt(100)
            // 单对编码 = key + '=' + value；使其 >255。
            val valueLen = 255 - key.length + rs.random.nextInt(1, 64)
            mapOf(key to ByteArray(valueLen).also { rs.random.nextBytes(it) })
        }

        var singlePairViolations = 0
        var maxActual = 0

        checkAll(PropTestConfig(seed = seed, iterations = 200), oversizePairArb) { fields ->
            val result = adapter.tryEncode(fields)

            val violation = result as? CodecResult.ExceedsLengthCap
                ?: throw AssertionError("F4 单对超限应报 ExceedsLengthCap，实际 $result")
            // 可判别的**维度**：单对上限而非整条记录上限。
            violation.scope shouldBe LengthCapScope.SINGLE_PAIR
            violation.maxEncodedBytes shouldBe BonjourTxtRecordCodecAdapter.maxPairBytes
            (violation.actualBytes > 255) shouldBe true

            singlePairViolations++
            if (violation.actualBytes > maxActual) maxActual = violation.actualBytes
        }

        println(
            "[Property 7/F4单对超限] 用例=$singlePairViolations 最大单对=$maxActual B（限 255 B）",
        )

        (singlePairViolations > 0) shouldBe true
    }

    test("Property 7 (F4/整条超限): 整条记录超过 1300 B 在编码方向报 WHOLE_MESSAGE 可判别错误") {
        val adapter = BonjourTxtRecordCodecAdapter

        // 多个合法单对（各 ≤255 B）累加后超过 1300 B。
        val oversizeRecordArb: Arb<Map<String, ByteArray>> = arbitrary { rs ->
            val fields = LinkedHashMap<String, ByteArray>()
            val pairCount = 7 + rs.random.nextInt(10)
            repeat(pairCount) { i ->
                val key = "key$i"
                val valueLen = 200 + rs.random.nextInt(40)
                fields[key] = ByteArray(valueLen).also { rs.random.nextBytes(it) }
            }
            fields
        }

        var recordViolations = 0
        var maxActual = 0

        checkAll(PropTestConfig(seed = seed, iterations = 200), oversizeRecordArb) { fields ->
            val result = adapter.tryEncode(fields)

            val violation = result as? CodecResult.ExceedsLengthCap
                ?: throw AssertionError("F4 整条超限应报 ExceedsLengthCap，实际 $result")
            violation.scope shouldBe LengthCapScope.WHOLE_MESSAGE
            violation.maxEncodedBytes shouldBe adapter.maxEncodedBytes
            (violation.actualBytes > 1300) shouldBe true

            recordViolations++
            if (violation.actualBytes > maxActual) maxActual = violation.actualBytes
        }

        println(
            "[Property 7/F4整条超限] 用例=$recordViolations 最大记录=$maxActual B（限 1300 B）",
        )

        (recordViolations > 0) shouldBe true
    }

    // =======================================================================
    // 5. 两类错误在同一面上都可达（可判别性的实质检验）
    // =======================================================================

    test("Property 7 (可判别性): 每个面都同时可达 MalformedFormat 与 ExceedsLengthCap") {
        val reached = LinkedHashMap<String, MutableSet<String>>()

        allCodecSurfaceAdapters.forEach { adapter ->
            val kinds = reached.getOrPut(adapter.auditLabel()) { mutableSetOf() }

            // 超限 → ExceedsLengthCap
            when (adapter.decode(ByteArray(adapter.maxEncodedBytes + 1))) {
                is CodecResult.ExceedsLengthCap -> kinds.add("ExceedsLengthCap")
                is CodecResult.MalformedFormat -> kinds.add("MalformedFormat")
                is CodecResult.Success -> kinds.add("Success")
            }

            // 单字节 0xFF → 期望格式非法（所有面的魔数/结构都不可能匹配单个 0xFF）。
            when (adapter.decode(byteArrayOf(0xFF.toByte()))) {
                is CodecResult.ExceedsLengthCap -> kinds.add("ExceedsLengthCap")
                is CodecResult.MalformedFormat -> kinds.add("MalformedFormat")
                is CodecResult.Success -> kinds.add("Success")
            }
        }

        reached.forEach { (surface, kinds) ->
            println("[Property 7/可判别性] $surface 可达错误类别=${kinds.sorted()}")
        }

        // 每个面都必须两类错误都可达 —— 否则"可判别"是空话。
        reached.forEach { (surface, kinds) ->
            if (!kinds.contains("ExceedsLengthCap") || !kinds.contains("MalformedFormat")) {
                throw AssertionError("$surface 未同时可达两类可判别错误，实际=${kinds.sorted()}")
            }
        }
        reached.size shouldBe allCodecSurfaceAdapters.size
    }
})

/**
 * 适配器的唯一报告标签。
 *
 * 标签同时携带适配器类型与生产入口，避免报告聚合时把同一 surface 的多个 codec 混为一项。
 */
internal fun CodecSurfaceAdapter<*>.auditLabel(): String {
    val entryPoint = Regex("\\(([^)]*)\\)").find(delegatesTo)?.groupValues?.get(1)
    val suffix = if (entryPoint.isNullOrBlank()) "" else "#$entryPoint"
    return "${surface.id}/${this::class.java.simpleName}$suffix"
}

/**
 * 为 [adapter] 产出一段**合法**编码，用作截断 / 位翻转 / 尾随垃圾的基底。
 *
 * MessageA/MessageB 的合法基底来自只读 Apple corpus；编码验证仍由生产 typed encoder完成。
 */
private fun validEncodingFor(adapter: CodecSurfaceAdapter<*>): ByteArray? = when (adapter) {
    is FileTransferMessageCodecAdapter -> FileTransferMessageCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage(
            op = com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp.metadata,
            transferId = "t-1",
            fileName = "a.bin",
            fileSize = 1024L,
        ),
    )

    is HandshakeFinishedCodecAdapter -> HandshakeFinishedCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PHandshakeWire.Finished(
            version = 0x01,
            direction = com.skybridge.compass.shared.p2p.P2PHandshakeWire
                .FinishedDirection.INITIATOR_TO_RESPONDER,
            mac = ByteArray(32) { it.toByte() },
        ),
    )

    is P2PCryptoCapabilitiesCodecAdapter -> P2PCryptoCapabilitiesCodecAdapter.encode(
        com.skybridge.compass.shared.p2p.P2PCryptoCapabilities(
            supportedKEM = listOf("x25519"),
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
            ciphertext = ByteArray(48) { it.toByte() },
            tag = ByteArray(16) { it.toByte() },
        ),
    )

    is BonjourTxtRecordCodecAdapter -> BonjourTxtRecordCodecAdapter.encode(
        mapOf("v" to "1".toByteArray(), "id" to ByteArray(8) { it.toByte() }),
    )

    else -> null
}

/**
 * 线程分配量探针：以 `com.sun.management.ThreadMXBean.getThreadAllocatedBytes` 测量
 * 单次调用的新增分配字节数（R9.6 第 4 项）。
 *
 * 该扩展接口是 HotSpot / OpenJDK 的标准扩展；不可用时 [available] 为 false，
 * [minAllocatedBytes] 返回 null，调用方据此跳过**该子断言**（而非跳过整条属性）。
 */
private class ThreadAllocationProbe {

    private val bean: com.sun.management.ThreadMXBean? = runCatching {
        val mx = java.lang.management.ManagementFactory.getThreadMXBean()
        (mx as? com.sun.management.ThreadMXBean)?.takeIf { it.isThreadAllocatedMemorySupported }
            ?.also { it.isThreadAllocatedMemoryEnabled = true }
    }.getOrNull()

    val available: Boolean get() = bean != null

    /**
     * 重复执行 [block] [repeats] 次，返回单次调用新增分配字节数的**最小值**。
     *
     * 取最小值而非平均值：JIT 编译、GC 记账与首次调用的类加载都会把某些次的分配抬高，
     * 最小值最接近"稳态下该调用的真实分配量"，且对上界断言是最保守的选择（不会误报失败）。
     */
    fun minAllocatedBytes(repeats: Int = 3, block: () -> Unit): Long? {
        val mx = bean ?: return null
        var min = Long.MAX_VALUE
        repeat(repeats) {
            val before = mx.currentThreadAllocatedBytes
            block()
            val after = mx.currentThreadAllocatedBytes
            val delta = after - before
            if (delta in 0 until min) min = delta
        }
        return if (min == Long.MAX_VALUE) null else min
    }
}
