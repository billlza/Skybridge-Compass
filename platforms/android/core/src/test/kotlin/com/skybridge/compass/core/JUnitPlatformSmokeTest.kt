package com.skybridge.compass.core

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * JUnit Jupiter 引擎接入验证（任务 2.1 / R1.9）。
 *
 * 使用 `org.junit.jupiter.api.Test` 确认 `:core` 模块的 `testDebugUnitTest`
 * 在 `useJUnitPlatform()` 下由 Jupiter 引擎执行至少一个测试；模块原有的
 * JUnit 4 测试继续由 Vintage 引擎执行。
 */
class JUnitPlatformSmokeTest {

    @Test
    fun jupiterEngineExecutesInCoreModule() {
        assertEquals(6, 2 * 3)
        assertTrue(listOf(1, 2, 3).sum() == 6)
    }
}
