package com.skybridge.compass.audit

import java.io.File
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * R7.6 回归守卫（任务 15.5）：**禁用空开关数量必须为 0**，且数据加密子屏的固定不可更改项
 * 必须保持只读事实呈现。
 *
 * ## 为何是源码级断言，而不是 Compose UI 测试
 *
 * `:app` 的**单元测试源集没有 Compose UI 测试能力** —— `androidx.compose.ui.test.junit4` 只在
 * `androidTestImplementation` 配置里（`app/build.gradle.kts`），即仅 instrumented 测试可用，
 * 而 G7 的构建门只跑 `:app:testDebugUnitTest`（JVM 单元测试）。若把守卫写成 instrumented 测试，
 * 它就**不在构建门内**，无法阻止回归。
 *
 * 因此这里对生产源码做**结构化解析**断言。R7.6 的验收判据本身就是一个源码级事实
 * （「禁用空开关数量为 0」），源码级断言是它最直接的表达；同时按任务 18.5 的思路补一个
 * **UI 结构快照**（[encryptionScreenStructureIsUnchanged]），把行/容器数量与嵌套顺序逐项锁死，
 * 使 G2 / R11.3 的「叶节点内替换、不改层级」可被机器验证。
 *
 * ## 为何不是同义反复
 *
 * [detectorFlagsASyntheticDisabledSwitch] 把探测器作用在**合成的**禁用空开关文本上并要求命中，
 * 证明探测器确实能识别该形态；随后 [noDisabledEmptySwitchInSettingsScreens] 才对真实源码要求 0 命中。
 * 探测器解析的是**剥离注释与字符串字面量后**的代码结构（[stripCommentsAndStringLiterals]），
 * 不会被注释里的字样误判或掩盖。
 */
class SettingsReadOnlyPresentationGuardTest {

    // region 被守卫的源码面

    private val settingsScreenDir = "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings"

    private val securityScreenPath = "$settingsScreenDir/SecuritySettingsScreen.kt"

    /** 设置界面全部 Kotlin 源文件（含 `sections/` 子目录）。 */
    private fun settingsSources(): List<File> {
        val dir = File(repoRoot(), settingsScreenDir)
        assertTrue(dir.isDirectory, "未找到设置界面源码目录：${dir.absolutePath}")
        return dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.sortedBy { it.path }.toList()
    }

    private fun sourceOf(relativePath: String): String {
        val file = File(repoRoot(), relativePath)
        assertTrue(file.isFile, "未找到源文件：${file.absolutePath}")
        return file.readText()
    }

    // endregion

    // region R7.6：禁用空开关数量为 0

    @Test
    @DisplayName("探测器自检：合成的 `onCheckedChange = null, enabled = false` 必须被判为禁用空开关")
    fun detectorFlagsASyntheticDisabledSwitch() {
        val synthetic = """
            @Composable
            fun Fake() {
                Switch(
                    checked = true,
                    onCheckedChange = null,
                    enabled = false
                )
            }
        """.trimIndent()

        val sites = switchCallSites(synthetic)
        assertEquals(1, sites.size, "应解析出恰好一个 Switch 调用点")
        assertTrue(sites.single().isDisabledEmptySwitch, "合成的禁用空开关未被探测器识别 —— 守卫失效")

        // 反向：正常可交互开关不得被误判。
        val healthy = "Switch(checked = x, onCheckedChange = vm::set)"
        assertEquals(
            emptyList<String>(),
            switchCallSites(healthy).filter { it.isDisabledEmptySwitch }.map { it.arguments },
            "可交互开关被误判为禁用空开关",
        )
    }

    @Test
    @DisplayName("R7.6 验收：设置界面禁用空开关数量为 0")
    fun noDisabledEmptySwitchInSettingsScreens() {
        val offenders = settingsSources().flatMap { file ->
            switchCallSites(file.readText())
                .filter { it.isDisabledEmptySwitch }
                .map { "${file.name}:${it.line}" }
        }

        assertEquals(
            emptyList<String>(),
            offenders,
            "禁用空开关数量必须为 0（R7.6）。固定不可更改项应以只读文本呈现固定取值与不可更改说明，" +
                "而不是 onCheckedChange = null / enabled = false 的惰性开关",
        )
    }

    @Test
    @DisplayName("设置界面不存在 `onCheckedChange = null` 的空回调开关")
    fun noSwitchHasANullCallback() {
        val offenders = settingsSources().flatMap { file ->
            switchCallSites(file.readText())
                .filter { it.hasNullCallback }
                .map { "${file.name}:${it.line}" }
        }

        assertEquals(emptyList<String>(), offenders, "开关的 onCheckedChange 不得为 null")
    }

    @Test
    @DisplayName("设置界面不存在字面量 `enabled = false` 的常关控件 —— 条件门控（属任务 15.7）不受影响")
    fun noControlIsHardDisabledByALiteralFalse() {
        // 判据只针对**字面量 false**：`enabled = settings.allowFileTransfer` /
        // `enabled = tierEnabled` / `enabled = timeoutDirty` 这类**由平台前置条件或表单状态门控**的
        // 控件是合法的（其归属为任务 15.7），必须与 R7.6 的「恒为禁用的空开关」区分开，故不在此判据内。
        val offenders = settingsSources().flatMap { file ->
            literalDisabledSites(file.readText()).map { "${file.name}:$it" }
        }

        assertEquals(
            emptyList<String>(),
            offenders,
            "字面量 enabled = false 的控件恒不可操作，应改为只读事实呈现（R7.6）",
        )
    }

    // endregion

    // region 数据加密子屏：只读事实呈现 + 结构不变（G2 / R11.3 / R7.13）

    @Test
    @DisplayName("数据加密子屏零开关，且两个固定项各以只读文本呈现固定取值")
    fun encryptionScreenPresentsFixedValuesAsReadOnlyText() {
        val body = composableBody(sourceOf(securityScreenPath), "EncryptionSettingsScreen")

        assertEquals(
            0,
            switchCallSites(body).size,
            "数据加密子屏三项全部是固定不可更改项，不应出现任何 Switch",
        )

        // 上面的结构类断言必须跑在**已剥离字符串与注释**的 body 上，否则注释或文案里出现
        // "Switch(" 之类的字样会造成误报。但文案存在性断言恰好相反：它要找的就是字符串字面量，
        // 在剥离后的 body 上永远匹配不到（剥离会把字面量整段空白化）。故文案断言改用**原始** body。
        val rawBody = composableBody(
            sourceOf(securityScreenPath),
            "EncryptionSettingsScreen",
            stripLiterals = false,
        )

        // 传输加密与后量子加密的 trailing 只读**取值**文本，各一处。
        // 匹配 `t(zh, en, ja)` 调用形态而非裸子串：两行的副标题里也含「始终启用」这四个字
        // （"…固定为始终启用，不可关闭。"），裸子串会把说明文案一并数进来（共 4 处）。
        // 这里要断言的是 trailing 槽位那一处取值文本，故按三语齐备的调用形态计数。
        val fixedValueCall = Regex("""t\(\s*"始终启用"\s*,\s*"Always On"\s*,\s*"常時有効"\s*\)""")
        assertEquals(
            2,
            fixedValueCall.findAll(rawBody).count(),
            "传输加密与后量子加密应各有一处「始终启用 / Always On / 常時有効」只读取值文本",
        )
        // 三种语言的取值文案各出现两次（每行一次）。中文另需扣除副标题里的说明性重复。
        assertEquals(2, Regex("""\"Always On\"""").findAll(rawBody).count(), "缺少英文取值文案")
        assertEquals(2, Regex("""\"常時有効\"""").findAll(rawBody).count(), "缺少日文取值文案")
        assertEquals(
            2,
            Regex("""\"始终启用\"""").findAll(rawBody).count(),
            "缺少中文取值文案（独立字符串字面量，不含副标题内的说明性提及）",
        )
        // 不可更改说明（副标题承载），两行各一处。
        assertEquals(
            2,
            Regex("""不可关闭""").findAll(rawBody).count(),
            "两个固定项的副标题都应说明不可更改的原因",
        )
    }

    @Test
    @DisplayName("UI 结构快照：数据加密子屏的行 / 容器数量与嵌套顺序逐项不变（G2 / R11.3）")
    fun encryptionScreenStructureIsUnchanged() {
        val body = composableBody(sourceOf(securityScreenPath), "EncryptionSettingsScreen")
        val listBody = lazyColumnBody(body)

        // 期望的结构指纹：3 个 item，顺序为 传输加密 / 加密算法 / 后量子加密。
        // 第 1、3 项保持 item > Card > Column > Row > (Column > Text,Text) + trailing Text；
        // 第 2 项（算法行）本来就没有 Row 与 trailing 槽位，保持原样。
        // 这里逐 token 比对，任何新增 / 删除 / 拆分 / 合并 / 重新归属节点都会使断言失败。
        val expected = listOf(
            // 1. 传输加密（trailing 由禁用开关改为只读 Text —— 叶节点内替换）
            "item", "Card", "Column", "Row", "Column", "Text", "Text", "Text",
            // 2. 加密算法（既有只读事实呈现，未改动）
            "item", "Card", "Column", "Text", "Spacer", "Text", "Text",
            // 3. 后量子加密（同第 1 项）
            "item", "Card", "Column", "Row", "Column", "Text", "Text", "Text",
        )

        assertEquals(expected, structureTokens(listBody), "数据加密子屏的 UI 结构已改变")

        // 冗余但直白的计数锁：容器数量不变。
        assertEquals(3, countCalls(listBody, "item"), "item（行/分组容器）数量必须为 3")
        assertEquals(3, countCalls(listBody, "Card"), "Card 分组容器数量必须为 3")
        assertEquals(2, countCalls(listBody, "Row"), "Row 数量必须为 2（仅第 1、3 项有 trailing 槽位）")
        assertEquals(5, countCalls(listBody, "Column"), "Column 数量必须为 5")
    }

    @Test
    @DisplayName("清单侧呈现形态与源码事实一致：加密三项均为只读事实呈现，且各自 declaredAt 可定位")
    fun ledgerPresentationMatchesTheSource() {
        val encryption = SettingsControlInventory.all
            .filter { it.sectionId == SettingsSections.ENCRYPTION }
            .sortedBy { it.orderInSection }

        assertEquals(
            listOf("encryption.transport-encryption", "encryption.algorithm", "encryption.post-quantum"),
            encryption.map { it.id },
            "分区内控件顺序必须逐项不变（R7.13）",
        )
        encryption.forEach { record ->
            assertEquals(
                Presentation.READ_ONLY_FACT,
                record.presentation,
                "${record.id} 应为只读事实呈现",
            )
            val ref = SourceRef.parse(record.declaredAt)
            assertNotNull(ref, "${record.id} 的 declaredAt 须为可定位的 文件:行 —— ${record.declaredAt}")
            val lines = sourceOf(ref!!.file).lines()
            assertTrue(
                ref.line in 1..lines.size,
                "${record.id} 的 declaredAt 行号越界：${record.declaredAt}（文件共 ${lines.size} 行）",
            )
        }
    }

    // endregion

    // region 解析工具

    /** 一个 `Switch(...)` 调用点。[arguments] 为剥离注释与字符串后的实参文本。 */
    private data class SwitchCallSite(val line: Int, val arguments: String) {
        val hasNullCallback: Boolean
            get() = Regex("""onCheckedChange\s*=\s*null\b""").containsMatchIn(arguments)

        val isExplicitlyDisabledByLiteral: Boolean
            get() = Regex("""enabled\s*=\s*false\b""").containsMatchIn(arguments)

        /**
         * R7.6 所指的「禁用空开关」：既没有生效的回调（`onCheckedChange = null`），
         * 又被字面量常关（`enabled = false`）—— 用户永远无法操作，也无任何行为。
         * 两个特征只要命中其一即视为违反：空回调开关本身就是无行为控件。
         */
        val isDisabledEmptySwitch: Boolean
            get() = hasNullCallback || isExplicitlyDisabledByLiteral
    }

    private fun switchCallSites(source: String): List<SwitchCallSite> {
        val clean = stripCommentsAndStringLiterals(source)
        return Regex("""\bSwitch\s*\(""").findAll(clean).map { match ->
            val open = clean.indexOf('(', startIndex = match.range.first)
            val close = matchingDelimiter(clean, open, '(', ')')
            SwitchCallSite(
                line = clean.take(match.range.first).count { it == '\n' } + 1,
                arguments = clean.substring(open + 1, close),
            )
        }.toList()
    }

    /** 字面量 `enabled = false` 出现的行号（不含由变量 / 表达式门控的情形）。 */
    private fun literalDisabledSites(source: String): List<Int> {
        val clean = stripCommentsAndStringLiterals(source)
        return Regex("""enabled\s*=\s*false\b""").findAll(clean)
            .map { clean.take(it.range.first).count { c -> c == '\n' } + 1 }
            .toList()
    }

    /** 结构上有意义的可组合项；`structureTokens` 只登记这些，避免把样式实参当成节点。 */
    private val structuralComposables = listOf("item", "Card", "Column", "Row", "Text", "Spacer", "Switch")

    private fun structureTokens(source: String): List<String> {
        val pattern = Regex("""\b(${structuralComposables.joinToString("|")})\s*[({]""")
        return pattern.findAll(source).map { it.groupValues[1] }.toList()
    }

    private fun countCalls(source: String, composable: String): Int =
        Regex("""\b${Regex.escape(composable)}\s*[({]""").findAll(source).count()

    /**
     * 取出名为 [name] 的 `@Composable fun` 的函数体（剥离注释与字符串后的文本）。
     */
    /**
     * 取某个可组合函数的函数体。
     *
     * @param stripLiterals true（默认）时先剥离注释与字符串字面量，供**结构类**扫描使用
     *   （避免注释/文案中的 `Switch(` 等字样造成误报）；false 时返回原始文本，供**文案存在性**
     *   断言使用——剥离会把字面量整段空白化，在剥离后的文本里找文案永远匹配不到。
     *   两种模式下函数体的起止定位一致（[blankLike] 保持长度与换行，故偏移量不变）。
     */
    private fun composableBody(source: String, name: String, stripLiterals: Boolean = true): String {
        // 定位**始终**在剥离后的文本上进行：字符串字面量里的 `{`/`}`（如模板表达式）会让
        // 括号配对失效，这正是剥离存在的原因。[blankLike] 逐字符等长替换，故两份文本的偏移量
        // 完全一致——定位到的区间可以安全地用于切原始文本。
        val clean = stripCommentsAndStringLiterals(source)
        val decl = Regex("""\bfun\s+${Regex.escape(name)}\s*\(""").find(clean)
        assertNotNull(decl, "未找到可组合函数 $name")
        val paramsOpen = clean.indexOf('(', startIndex = decl!!.range.first)
        val paramsClose = matchingDelimiter(clean, paramsOpen, '(', ')')
        val bodyOpen = clean.indexOf('{', startIndex = paramsClose)
        assertTrue(bodyOpen > 0, "$name 没有块函数体")
        val bodyClose = matchingDelimiter(clean, bodyOpen, '{', '}')
        check(clean.length == source.length) { "剥离必须等长，否则偏移量不可复用" }
        return (if (stripLiterals) clean else source).substring(bodyOpen + 1, bodyClose)
    }

    /** 取出函数体内 `LazyColumn(...) { ... }` 的 lambda 体。 */
    private fun lazyColumnBody(functionBody: String): String {
        val marker = Regex("""\bLazyColumn\s*\(""").find(functionBody)
        assertNotNull(marker, "未找到 LazyColumn")
        val argsOpen = functionBody.indexOf('(', startIndex = marker!!.range.first)
        val argsClose = matchingDelimiter(functionBody, argsOpen, '(', ')')
        val lambdaOpen = functionBody.indexOf('{', startIndex = argsClose)
        assertTrue(lambdaOpen > 0, "LazyColumn 没有尾随 lambda")
        val lambdaClose = matchingDelimiter(functionBody, lambdaOpen, '{', '}')
        return functionBody.substring(lambdaOpen + 1, lambdaClose)
    }

    private fun matchingDelimiter(text: String, openIndex: Int, open: Char, close: Char): Int {
        require(text[openIndex] == open) { "index $openIndex is not '$open'" }
        var depth = 0
        var i = openIndex
        while (i < text.length) {
            when (text[i]) {
                open -> depth++
                close -> {
                    depth--
                    if (depth == 0) return i
                }
            }
            i++
        }
        error("unbalanced '$open' starting at $openIndex")
    }

    /**
     * 把注释与字符串字面量的**内容**替换为等长空白，保持所有偏移与行号不变。
     *
     * 这样括号 / 花括号匹配不会被字符串里的符号或字符串模板 `${'$'}{...}` 干扰，
     * 也使断言不会被注释中的字样误导（正反两个方向都不会）。
     */
    private fun stripCommentsAndStringLiterals(source: String): String {
        val out = StringBuilder(source.length)
        var i = 0
        while (i < source.length) {
            val rest = source.length - i
            when {
                rest >= 3 && source.startsWith("\"\"\"", i) -> {
                    val end = source.indexOf("\"\"\"", i + 3).let { if (it < 0) source.length else it + 3 }
                    out.append(blankLike(source, i, end))
                    i = end
                }
                source[i] == '"' -> {
                    var j = i + 1
                    while (j < source.length && source[j] != '"') {
                        if (source[j] == '\\') j++
                        j++
                    }
                    val end = (j + 1).coerceAtMost(source.length)
                    out.append(blankLike(source, i, end))
                    i = end
                }
                source[i] == '\'' -> {
                    var j = i + 1
                    while (j < source.length && source[j] != '\'') {
                        if (source[j] == '\\') j++
                        j++
                    }
                    val end = (j + 1).coerceAtMost(source.length)
                    out.append(blankLike(source, i, end))
                    i = end
                }
                rest >= 2 && source.startsWith("//", i) -> {
                    val end = source.indexOf('\n', i).let { if (it < 0) source.length else it }
                    out.append(blankLike(source, i, end))
                    i = end
                }
                rest >= 2 && source.startsWith("/*", i) -> {
                    val end = source.indexOf("*/", i + 2).let { if (it < 0) source.length else it + 2 }
                    out.append(blankLike(source, i, end))
                    i = end
                }
                else -> {
                    out.append(source[i])
                    i++
                }
            }
        }
        return out.toString()
    }

    /** 用空格替换 [from, to) 区间的非换行字符，换行原样保留（维持行号）。 */
    private fun blankLike(source: String, from: Int, to: Int): String =
        buildString(to - from) {
            for (k in from until to) append(if (source[k] == '\n') '\n' else ' ')
        }

    /** 自 `user.dir` 向上寻找含 `settings.gradle.kts` 的仓库根。 */
    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile.normalize()
        while (dir != null) {
            if (File(dir, "settings.gradle.kts").isFile) return dir
            dir = dir.parentFile
        }
        error("未能自 ${System.getProperty("user.dir")} 向上定位仓库根（settings.gradle.kts）")
    }

    // endregion
}
