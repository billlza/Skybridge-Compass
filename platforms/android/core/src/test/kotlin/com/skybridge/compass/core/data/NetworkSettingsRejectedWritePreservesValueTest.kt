package com.skybridge.compass.core.data

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * R7.8「保留原持久化值」：被拒绝的保存必须让已存值**逐字节不变**，且不影响任何其他键。
 *
 * `NetworkSettingsStore` 的三项数值写入全部经由 [writeIfAccepted]，写入动作只存在于其 `write`
 * 闭包内。因此在这里用一个内存存储替代 DataStore 驱动同一个闸门，就能证明该不变量：拒绝时闭包
 * 从不执行，存储不被触碰。（`:core` 单元测试无 Robolectric，无法实例化真实 DataStore；闸门是
 * 写入的唯一通路，故等价。）
 */
@DisplayName("Rejected network setting write preserves the persisted value (R7.8)")
class NetworkSettingsRejectedWritePreservesValueTest {

    /** 记录每次写入的内存存储，兼作「是否触碰过存储」的探针。 */
    private class FakeStore {
        val values = mutableMapOf<String, Any>(
            KEY_PORT_START to 8080,
            KEY_PORT_END to 8090,
            KEY_TIMEOUT to 30_000L,
            KEY_ATTEMPTS to 3,
            KEY_UNRELATED to "untouched"
        )
        var editCount = 0

        fun snapshot(): Map<String, Any> = values.toMap()

        fun edit(block: (MutableMap<String, Any>) -> Unit) {
            editCount++
            block(values)
        }

        companion object {
            const val KEY_PORT_START = "port_range_start"
            const val KEY_PORT_END = "port_range_end"
            const val KEY_TIMEOUT = "discovery_timeout_ms"
            const val KEY_ATTEMPTS = "max_reconnect_attempts"
            const val KEY_UNRELATED = "encryption_mode"
        }
    }

    private lateinit var store: FakeStore

    private fun newStore(): FakeStore = FakeStore().also { store = it }

    // 与 NetworkSettingsStore 中三个写入者结构一致：校验 → 闸门 → 钳制兜底 → 写入。
    private suspend fun setPortRange(start: Int, end: Int) =
        writeIfAccepted(NetworkSettingsValidator.validatePortRange(start, end)) { range ->
            val s = NetworkSettingsStorageBackstop.clampPortStart(range.first)
            val e = NetworkSettingsStorageBackstop.clampPortEnd(s, range.last)
            store.edit {
                it[FakeStore.KEY_PORT_START] = s
                it[FakeStore.KEY_PORT_END] = e
            }
        }

    private suspend fun setPortRangeFromInput(rawStart: String, rawEnd: String) =
        writeIfAccepted(
            NetworkSettingsValidator.validatePortRangeInput(rawStart, rawEnd)
        ) { range -> setPortRange(range.first, range.last) }

    private suspend fun setDiscoveryTimeoutFromInput(raw: String) =
        writeIfAccepted(
            NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(raw)
        ) { accepted ->
            store.edit {
                it[FakeStore.KEY_TIMEOUT] =
                    NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(accepted)
            }
        }

    private suspend fun setAttemptsFromInput(raw: String) =
        writeIfAccepted(
            NetworkSettingsValidator.validateMaxReconnectAttemptsInput(raw)
        ) { accepted ->
            store.edit {
                it[FakeStore.KEY_ATTEMPTS] =
                    NetworkSettingsStorageBackstop.clampReconnectAttempts(accepted)
            }
        }

    @Test
    fun `rejected port saves leave the stored range and all other keys unchanged`() = runTest {
        val rejectedInputs = listOf(
            "0" to "9000",       // start 越界
            "65536" to "65535",  // start 越界
            "8080" to "0",       // end 越界
            "8080" to "65536",   // end 越界
            "9000" to "8080",    // end < start
            "" to "9000",        // 空
            "8080" to "",        // 空
            "abc" to "9000"      // 非数值
        )
        rejectedInputs.forEach { (rawStart, rawEnd) ->
            val fake = newStore()
            val before = fake.snapshot()
            val result = setPortRangeFromInput(rawStart, rawEnd)

            assertTrue(
                result is NetworkSettingValidation.Rejected,
                "expected rejection for [$rawStart, $rawEnd]"
            )
            assertEquals(0, fake.editCount, "store must not be touched for [$rawStart, $rawEnd]")
            assertEquals(before, fake.snapshot(), "persisted values changed for [$rawStart, $rawEnd]")
        }
    }

    @Test
    fun `rejected discovery timeout saves leave the stored value unchanged`() = runTest {
        listOf("249", "120001", "0", "-1", "", "  ", "abc", "30s").forEach { raw ->
            val fake = newStore()
            val before = fake.snapshot()
            val result = setDiscoveryTimeoutFromInput(raw)

            assertTrue(result is NetworkSettingValidation.Rejected, "expected rejection for [$raw]")
            assertEquals(0, fake.editCount, "store must not be touched for [$raw]")
            assertEquals(before, fake.snapshot(), "persisted values changed for [$raw]")
            assertEquals(30_000L, fake.values[FakeStore.KEY_TIMEOUT])
        }
    }

    @Test
    fun `rejected reconnect saves leave the stored value unchanged`() = runTest {
        listOf("-1", "11", "100", "", " ", "abc").forEach { raw ->
            val fake = newStore()
            val before = fake.snapshot()
            val result = setAttemptsFromInput(raw)

            assertTrue(result is NetworkSettingValidation.Rejected, "expected rejection for [$raw]")
            assertEquals(0, fake.editCount, "store must not be touched for [$raw]")
            assertEquals(before, fake.snapshot(), "persisted values changed for [$raw]")
            assertEquals(3, fake.values[FakeStore.KEY_ATTEMPTS])
        }
    }

    @Test
    fun `accepted saves do write, without silent rewriting`() = runTest {
        val fake = newStore()

        assertTrue(setPortRangeFromInput("1", "65535") is NetworkSettingValidation.Accepted)
        assertEquals(1, fake.values[FakeStore.KEY_PORT_START])
        assertEquals(65535, fake.values[FakeStore.KEY_PORT_END])

        assertTrue(setDiscoveryTimeoutFromInput("250") is NetworkSettingValidation.Accepted)
        assertEquals(250L, fake.values[FakeStore.KEY_TIMEOUT])

        assertTrue(setDiscoveryTimeoutFromInput("120000") is NetworkSettingValidation.Accepted)
        assertEquals(120_000L, fake.values[FakeStore.KEY_TIMEOUT])

        assertTrue(setAttemptsFromInput("0") is NetworkSettingValidation.Accepted)
        assertEquals(0, fake.values[FakeStore.KEY_ATTEMPTS])

        assertTrue(setAttemptsFromInput("10") is NetworkSettingValidation.Accepted)
        assertEquals(10, fake.values[FakeStore.KEY_ATTEMPTS])

        // 不相关的键从未被这三条写入路径改动。
        assertEquals("untouched", fake.values[FakeStore.KEY_UNRELATED])
    }

    @Test
    fun `write gate never invokes the writer on rejection`() = runTest {
        var invoked = false
        val result = writeIfAccepted(
            NetworkSettingsValidator.validateMaxReconnectAttemptsInput("11")
        ) { invoked = true }

        assertTrue(result is NetworkSettingValidation.Rejected)
        assertFalse(invoked, "writer must not run when validation rejects")
    }
}
