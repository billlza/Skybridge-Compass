package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.filetransfer.webrtc.DownloadsFilenameDeduper
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.set
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 32: 重名文件不被覆盖**
 *
 * **Validates: Requirements 5.11**
 *
 * 任务 11.16。属性：对任意"目标名 + 已存在名字集合"，生产入口
 * [DownloadsFilenameDeduper.deduplicate] 返回的落盘名满足：
 *
 *  1. **不覆盖既存文件**：返回名**从不**属于已存在名字集合（这是"保留已存在文件不被覆盖"的
 *     充分必要判据——落盘用的是一个尚未被占用的名字）；
 *  2. **无冲突时不改名**：目标名未被占用时原样返回（不做无谓改名）；
 *  3. **冲突时附加区分序号**：被占用时返回形如 `base (n).ext` 的新名，且**保留扩展名**、
 *     `base` 前缀不变，序号取第一个可用的最小正整数（确定性、可复现）；
 *  4. **确定性**：同一输入重复调用返回同一结果（供 UI 呈现"实际使用的文件名"）；
 *  5. **无扩展名与多点名**（如 `archive.tar.gz`、`README`、`.gitignore`）也满足上述性质，
 *     即只在**最后一个点**处切分，不破坏名字其余部分。
 *
 * 定义域：`nameExists` 谓词由随机名字集合给出（模拟 MediaStore 查询）；序号上限 999 之后的
 * 时间戳回退分支单独以受控输入覆盖（全量占满 1..999 的集合无法随机命中）。
 */
class DownloadsRenamePropertyTest : FunSpec({

    /** 名字素材：含扩展名、多点扩展名、无扩展名、点开头等真实形态。 */
    val baseNameArb = Arb.element(
        "report.pdf",
        "photo.jpeg",
        "archive.tar.gz",
        "README",
        ".gitignore",
        "notes.txt",
        "video.mp4",
        "data.bin",
    )

    /** 已占用名字集合：目标名本身与其若干序号变体的任意子集。 */
    val occupiedPatternArb = Arb.set(Arb.int(0..6), 0..7)

    fun splitName(name: String): Pair<String, String?> {
        val dot = name.lastIndexOf('.')
        val hasExt = dot > 0 && dot < name.lastIndex
        return if (hasExt) name.substring(0, dot) to name.substring(dot + 1) else name to null
    }

    fun candidate(desired: String, index: Int): String {
        if (index == 0) return desired
        val (base, ext) = splitName(desired)
        return if (ext != null) "$base ($index).$ext" else "$base ($index)"
    }

    test("Property 32: 返回名从不占用既存文件；无冲突不改名，冲突则附加最小可用序号并保留扩展名") {
        var noCollision = 0
        var collisionRenamed = 0
        var extensionPreserved = 0
        var noExtensionCases = 0
        var gapReuse = 0

        checkAll(400, baseNameArb, occupiedPatternArb) { desired, occupiedIndices ->
            // 已存在名字集合：由 desired 的第 i 个候选名构成（i=0 即 desired 本身）。
            val existing = occupiedIndices.map { candidate(desired, it) }.toSet()

            var probeCount = 0
            val result = DownloadsFilenameDeduper.deduplicate(
                desiredName = desired,
                nameExists = { name ->
                    probeCount++
                    name in existing
                },
                timestampProvider = { 1_700_000_000_000L },
            )

            // (1) 核心断言：返回名绝不落在已存在集合中 —— 既存文件不会被覆盖。
            (result in existing) shouldBe false
            result.isNotBlank() shouldBe true

            // (4) 确定性：同一输入再算一次结果相同。
            val again = DownloadsFilenameDeduper.deduplicate(
                desiredName = desired,
                nameExists = { it in existing },
                timestampProvider = { 1_700_000_000_000L },
            )
            again shouldBe result

            val (desiredBase, desiredExt) = splitName(desired)

            if (desired !in existing) {
                // (2) 无冲突：原样返回。
                result shouldBe desired
                noCollision++
            } else {
                // (3) 冲突：返回第一个可用的最小序号候选。
                val expectedIndex = (1..DownloadsFilenameDeduper.MAX_SUFFIX)
                    .first { candidate(desired, it) !in existing }
                result shouldBe candidate(desired, expectedIndex)
                // 若被占用的序号集合中间有空洞，最小可用序号会落在空洞处（而非集合最大值 +1）。
                val highestOccupied = occupiedIndices.filter { it > 0 }.maxOrNull() ?: 0
                if (expectedIndex < highestOccupied) gapReuse++
                collisionRenamed++

                // 保留扩展名，且 base 前缀不变。
                if (desiredExt != null) {
                    result.endsWith(".$desiredExt") shouldBe true
                    result.startsWith("$desiredBase (") shouldBe true
                    // 多点名只在最后一个点处切分：`archive.tar.gz` -> `archive.tar (1).gz`
                    splitName(result).second shouldBe desiredExt
                    extensionPreserved++
                } else {
                    result.startsWith("$desiredBase (") shouldBe true
                    noExtensionCases++
                }
            }

            // 探测次数有界（不会退化为无界搜索）。
            (probeCount <= DownloadsFilenameDeduper.MAX_SUFFIX + 1) shouldBe true
        }

        // 非空真保证：无冲突、冲突改名、保留扩展名、无扩展名、空洞复用五个分支都被走到。
        println(
            "Property 32 branch coverage: noCollision=$noCollision collisionRenamed=$collisionRenamed " +
                "extensionPreserved=$extensionPreserved noExtension=$noExtensionCases gapReuse=$gapReuse"
        )
        (noCollision > 0) shouldBe true
        (collisionRenamed > 0) shouldBe true
        (extensionPreserved > 0) shouldBe true
        (noExtensionCases > 0) shouldBe true
        (gapReuse > 0) shouldBe true
    }

    test("Property 32 (序号耗尽): 1..999 全被占用时回退到时间戳名且仍不覆盖") {
        var fallbackCases = 0

        checkAll(200, baseNameArb, Arb.int(1..1_000_000)) { desired, timestampSeed ->
            // 定义域：受控构造"目标名与 1..999 全部候选名均被占用"，随机命中不可能达到。
            val existing = (0..DownloadsFilenameDeduper.MAX_SUFFIX)
                .map { candidate(desired, it) }
                .toSet()
            val timestamp = timestampSeed.toLong()

            val result = DownloadsFilenameDeduper.deduplicate(
                desiredName = desired,
                nameExists = { it in existing },
                timestampProvider = { timestamp },
            )

            // 仍然不覆盖任何既存文件，且落到可判别的时间戳回退名。
            (result in existing) shouldBe false
            val (base, ext) = splitName(desired)
            result shouldBe if (ext != null) "$base-$timestamp.$ext" else "$base-$timestamp"
            // 扩展名仍被保留。
            if (ext != null) result.endsWith(".$ext") shouldBe true
            fallbackCases++
        }

        println("Property 32 (序号耗尽) branch coverage: timestampFallback=$fallbackCases")
        (fallbackCases > 0) shouldBe true
    }
})
