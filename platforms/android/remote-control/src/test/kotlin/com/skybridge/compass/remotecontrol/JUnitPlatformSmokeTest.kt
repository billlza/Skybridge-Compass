package com.skybridge.compass.remotecontrol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * JUnit Jupiter 引擎接入验证（任务 2.1 / R1.9）。
 *
 * 使用 `org.junit.jupiter.api.Test` 确认 `:remote-control` 模块的
 * `testDebugUnitTest` 在 `useJUnitPlatform()` 下由 Jupiter 引擎执行至少一个
 * 测试；模块原有的 JUnit 4 测试继续由 Vintage 引擎执行。
 */
class JUnitPlatformSmokeTest {

    @Test
    fun jupiterEngineExecutesInRemoteControlModule() {
        assertEquals(9, 3 * 3)
        assertTrue("remote-control".contains("control"))
    }
}
