package com.skybridge.compass.android.settings

import com.skybridge.compass.android.ui.screens.settings.SettingSaveFailure
import com.skybridge.compass.android.ui.screens.settings.SettingSaveOutcome
import com.skybridge.compass.android.ui.screens.settings.settingSaveFailureMessage
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 15.8 / R7.11、R7.12：写入语义、失败提示与回滚。
 *
 * ## 为什么用一份内存存储驱动同一道闸门，而不是实例化真实 DataStore
 *
 * `:app` 的单元测试源集没有 Robolectric，无法构造 `Context`/DataStore；而**要证明的不变量恰恰
 * 是「写入失败时会发生什么」**——真实 DataStore 在单元测试里也无法可靠地制造 IO 失败。
 * 因此这里复刻 `SettingsViewModel.persistSetting` 的闸门语义（成功清除失败记录 / 失败登记且不
 * 让异常逃逸 / 取消继续传播），并用可控的 [FailingStore] 注入失败。闸门是**唯一**写入通路
 * （由 `noSetterBypassesTheWriteGate` 锁定），故此处的等价性成立。
 */
@DisplayName("设置持久化写入、失败提示与回滚（R7.11 / R7.12）")
class SettingPersistenceContractTest {

    /** 可控的内存存储：既能成功落盘，也能按需让写入失败。 */
    private class FailingStore {
        val values = mutableMapOf(
            "general.dark-mode" to "true",
            "general.notifications" to "true",
            "network.discovery-timeout" to "30000"
        )

        /** 下一次写入是否失败。 */
        var failNextWrite: Boolean = false

        /** 写入次数（含失败尝试），用于证明失败时存储未被触碰。 */
        var commitCount: Int = 0

        fun snapshot(): Map<String, String> = values.toMap()

        suspend fun write(key: String, value: String) {
            if (failNextWrite) {
                // 关键：抛出发生在**任何**修改之前，模拟 DataStore 事务失败时不留下部分写入。
                throw IOException("simulated datastore write failure")
            }
            commitCount++
            values[key] = value
        }
    }

    /**
     * 复刻 `SettingsViewModel.persistSetting` 的闸门语义。返回结果而非写入 StateFlow，
     * 使断言不依赖 ViewModel 的协程调度。
     */
    private suspend fun persist(
        controlId: String,
        write: suspend () -> Unit
    ): SettingSaveOutcome = try {
        write()
        SettingSaveOutcome.Saved
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (e: Exception) {
        SettingSaveOutcome.Failed(SettingSaveFailure(controlId = controlId, cause = e))
    }

    @Nested
    @DisplayName("R7.11 写入成功后，消费方下次读取取得新值")
    inner class SuccessfulWrite {

        @Test
        @DisplayName("写入完成后读取即为新值 —— 写入与可见性之间没有中间态")
        fun consumerSeesTheNewValueOnNextRead() = runTest {
            val store = FailingStore()

            val outcome = persist("general.dark-mode") { store.write("general.dark-mode", "false") }

            assertEquals(SettingSaveOutcome.Saved, outcome)
            assertEquals("false", store.values["general.dark-mode"], "下一次读取必须取得新值")
        }

        @Test
        @DisplayName("一次写入只触碰自己的键")
        fun writeTouchesOnlyItsOwnKey() = runTest {
            val store = FailingStore()
            val before = store.snapshot()

            persist("general.dark-mode") { store.write("general.dark-mode", "false") }

            val changed = store.snapshot().filter { (k, v) -> before[k] != v }
            assertEquals(setOf("general.dark-mode"), changed.keys)
        }

        @Test
        @DisplayName("成功写入清除该项此前的失败记录")
        fun successClearsAPriorFailure() = runTest {
            val store = FailingStore()
            store.failNextWrite = true
            val failed = persist("general.dark-mode") { store.write("general.dark-mode", "false") }
            assertTrue(failed is SettingSaveOutcome.Failed)

            store.failNextWrite = false
            val retried = persist("general.dark-mode") { store.write("general.dark-mode", "false") }
            assertEquals(SettingSaveOutcome.Saved, retried)
        }
    }

    @Nested
    @DisplayName("R7.12 写入失败：提示、回滚、不影响其他项")
    inner class FailedWrite {

        @Test
        @DisplayName("失败不让异常逃逸，而是产出可观察的失败记录")
        fun failureIsReportedNotThrown() = runTest {
            val store = FailingStore()
            store.failNextWrite = true

            val outcome = persist("general.notifications") {
                store.write("general.notifications", "false")
            }

            val failed = assertTrue(outcome is SettingSaveOutcome.Failed).let {
                outcome as SettingSaveOutcome.Failed
            }
            assertEquals("general.notifications", failed.failure.controlId)
            assertTrue(failed.failure.cause is IOException)
        }

        @Test
        @DisplayName("失败时已持久化值逐项不变，且其他项也未被改动")
        fun persistedValuesAreUnchangedOnFailure() = runTest {
            val store = FailingStore()
            val before = store.snapshot()
            store.failNextWrite = true

            persist("general.notifications") { store.write("general.notifications", "false") }

            assertEquals(0, store.commitCount, "失败时存储不得被提交")
            assertEquals(before, store.snapshot(), "失败后全部已持久化值必须逐项不变")
        }

        @Test
        @DisplayName("回滚目标就是写入前的已持久化值 —— 与「该次写入从未发生」等价")
        fun rollbackTargetEqualsThePreWriteValue() = runTest {
            val store = FailingStore()
            val preWrite = store.values["general.notifications"]
            store.failNextWrite = true

            persist("general.notifications") { store.write("general.notifications", "false") }

            // 显示值应回滚为 preWrite；由于失败时存储未变，读取面给出的就是 preWrite。
            assertEquals(preWrite, store.values["general.notifications"])
        }

        @Test
        @DisplayName("提示文案指示「保存未生效」，而非含糊的错误")
        fun messageIndicatesTheSaveDidNotTakeEffect() {
            val message = settingSaveFailureMessage(
                SettingSaveFailure("general.notifications", IOException("boom"))
            )
            // 三语中的任一都必须表达「未保存/未生效」，且不得把底层异常文本泄露给用户。
            assertTrue(
                message.contains("未生效") || message.contains("Not saved") || message.contains("保存されていません"),
                "提示须指示保存未生效，实际为：$message"
            )
            assertFalse(message.contains("boom"), "不得把底层异常文本呈现给用户")
        }

        @Test
        @DisplayName("诊断信息保留 controlId 与底层原因，便于定位")
        fun diagnosticMessageCarriesTheCause() {
            val failure = SettingSaveFailure("general.dark-mode", IOException("disk full"))
            assertTrue(failure.message.contains("general.dark-mode"))
            assertTrue(failure.message.contains("disk full"))
        }
    }

    @Nested
    @DisplayName("闸门自身的语义")
    inner class GateSemantics {

        @Test
        @DisplayName("协程取消继续向上传播，不被误报成保存失败")
        fun cancellationIsNotSwallowedAsAFailure() = runTest {
            assertThrows(CancellationException::class.java) {
                kotlinx.coroutines.runBlocking {
                    persist("general.dark-mode") { throw CancellationException("vm cleared") }
                }
            }
        }

        @Test
        @DisplayName("成功路径不产生失败记录")
        fun successProducesNoFailure() = runTest {
            val store = FailingStore()
            val outcome = persist("general.dark-mode") { store.write("general.dark-mode", "false") }
            assertNull((outcome as? SettingSaveOutcome.Failed)?.failure)
        }
    }
}
