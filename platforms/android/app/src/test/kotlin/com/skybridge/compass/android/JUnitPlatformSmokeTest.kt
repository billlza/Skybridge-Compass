package com.skybridge.compass.android

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * JUnit Jupiter 引擎接入验证（任务 2.1 / R1.9）。
 *
 * 该测试类使用 `org.junit.jupiter.api.Test`，用于确认 `:app` 模块的
 * `testDebugUnitTest` 在 `useJUnitPlatform()` 下由 Jupiter 引擎执行至少一个测试
 * （执行数 ≥ 1、跳过数 0）；模块原有的 JUnit 4 测试继续由 Vintage 引擎执行。
 */
class JUnitPlatformSmokeTest {

    @Test
    fun jupiterEngineExecutesInAppModule() {
        assertEquals(4, 2 + 2)
        assertTrue("com.skybridge.compass".startsWith("com.skybridge"))
    }
}
