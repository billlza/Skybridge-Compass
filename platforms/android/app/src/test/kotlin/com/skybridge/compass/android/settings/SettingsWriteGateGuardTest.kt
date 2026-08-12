package com.skybridge.compass.android.settings

import java.io.File
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * 任务 15.8 / R7.12 的**回归护栏**：`SettingsViewModel` 里不得存在绕过写入闸门的持久化写入。
 *
 * 没有这条护栏，下一个新增的 setter 只要照抄旧的 `viewModelScope.launch { Store.set(...) }`
 * 写法，就会静默地把 R7.12 的缺陷带回来——写入失败既无提示也无回滚，而且不会有任何测试失败。
 *
 * 判据是**源码级**的：`viewModelScope.launch` 只允许出现在 `persistSetting` 自身的实现里；
 * 任何直接在 `launch` 块中调用 `XxxStore.set...` 的写法都会让本测试失败。
 *
 * 采用源码扫描而非反射/字节码，理由与任务 15.5 的
 * `SettingsReadOnlyPresentationGuardTest` 一致：要断言的是**代码形态**（写入是否经过闸门），
 * 运行期无法观察到「作者是否绕过了封装」。
 */
@DisplayName("设置写入闸门护栏（R7.12）")
class SettingsWriteGateGuardTest {

    private val viewModelPath =
        "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsViewModel.kt"

    @Test
    @DisplayName("除 persistSetting 自身外，没有 setter 直接用 viewModelScope.launch 写入存储")
    fun noSetterBypassesTheWriteGate() {
        val source = readSource(viewModelPath)
        val lines = source.lines()

        val offenders = mutableListOf<String>()
        lines.forEachIndexed { index, line ->
            if (!line.contains("viewModelScope.launch")) return@forEachIndexed

            // persistSetting 的实现本身必须使用 launch —— 它就是闸门。
            val insideGate = precedingDeclaration(lines, index)?.contains("persistSetting") == true
            if (insideGate) return@forEachIndexed

            // 允许非持久化用途的 launch（例如 Supabase reset 后回调）；只有当 launch 块内出现
            // 对某个 Store 的 set/写入调用时才算绕过闸门。
            val block = blockAfter(lines, index)
            val writesToAStore = STORE_WRITE.containsMatchIn(block)
            if (writesToAStore) {
                offenders += "${viewModelPath.substringAfterLast('/')}:${index + 1} → ${line.trim()}"
            }
        }

        assertEquals(
            emptyList<String>(),
            offenders,
            "这些写入绕过了 persistSetting 闸门，写入失败时不会呈现「保存未生效」也不会回滚（R7.12）",
        )
    }

    @Test
    @DisplayName("闸门确实捕获异常并登记失败，且让 CancellationException 继续传播")
    fun theGateHandlesFailureAndPreservesCancellation() {
        val source = readSource(viewModelPath)
        val gate = source.substringAfter("private fun persistSetting")

        assertTrue(
            gate.contains("CancellationException"),
            "闸门必须显式重抛 CancellationException，否则 ViewModel 销毁会被误报为保存失败",
        )
        assertTrue(
            gate.contains("SettingSaveFailure"),
            "闸门必须把失败登记为 SettingSaveFailure",
        )
    }

    @Test
    @DisplayName("每个写入都带一个 controlId，且这些 id 都是审计清单里的真实控件")
    fun everyWriteIsAttributedToAnInventoryControl() {
        val source = readSource(viewModelPath)
        val ids = Regex("""persistSetting\("([^"]+)"\)""")
            .findAll(source)
            .map { it.groupValues[1] }
            .toList()

        assertTrue(ids.size >= 26, "写入点数量异常偏少，实际 ${ids.size}：闸门可能被绕过")

        // controlId 必须能在审计清单里找到同名控件，使「界面提示的是哪一项」与审计证据对齐。
        //
        // 唯一例外是**动作写入**：它们确实写存储（因此必须经闸门），但按 15.1 的计数规则不属于
        // 45 条控件（一次性动作按钮被明确排除）。例外必须在此逐条列举并说明，不允许以放宽判据的
        // 方式蒙混过关——新增一个未列举的 id 会让本测试失败。
        val actionWriteIds = setOf(
            // Supabase「清除配置」按钮：动作按钮，无持久化控件对位。
            "cloud.supabase-reset",
        )
        val inventoryIds = com.skybridge.compass.audit.SettingsControlInventory.all.map { it.id }.toSet()
        val unknown = ids.filter { it !in inventoryIds && it !in actionWriteIds }.distinct().sorted()
        assertEquals(
            emptyList<String>(),
            unknown,
            "这些 controlId 既不在 SettingsControlInventory 中、也未登记为动作写入，提示无法与审计证据对齐",
        )
    }

    // region helpers

    private val STORE_WRITE = Regex("""\w+Store\.(set|reset|save|clear|persist)\w*\(""")

    /** 找到 [index] 之前最近的一行函数声明。 */
    private fun precedingDeclaration(lines: List<String>, index: Int): String? {
        for (i in index downTo 0) {
            val line = lines[i]
            if (Regex("""\bfun\s+\w+""").containsMatchIn(line)) return line
        }
        return null
    }

    /** 取自 [index] 起的花括号块文本（简单按缩进/配对截取，足够覆盖本文件的写法）。 */
    private fun blockAfter(lines: List<String>, index: Int): String {
        val sb = StringBuilder()
        var depth = 0
        var started = false
        for (i in index until lines.size) {
            val line = lines[i]
            sb.appendLine(line)
            line.forEach { ch ->
                if (ch == '{') { depth++; started = true }
                if (ch == '}') depth--
            }
            if (started && depth <= 0) break
        }
        return sb.toString()
    }

    private fun readSource(relativePath: String): String {
        val file = File(repoRoot(), relativePath)
        assertTrue(file.isFile, "未找到源文件：$relativePath")
        return file.readText()
    }

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile.normalize()
        while (dir != null) {
            if (File(dir, "settings.gradle.kts").isFile) return dir
            dir = dir.parentFile
        }
        error("未能自 ${System.getProperty("user.dir")} 向上定位仓库根")
    }

    // endregion
}
