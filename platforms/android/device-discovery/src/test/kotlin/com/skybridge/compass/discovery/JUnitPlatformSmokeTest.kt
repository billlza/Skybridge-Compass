package com.skybridge.compass.discovery

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * JUnit Jupiter 引擎接入验证（任务 2.1 / R1.9）。
 *
 * `:device-discovery` 已通过 Kotest 启用 `useJUnitPlatform()`；本测试类以
 * 显式补入的 `junit-jupiter-api/engine` 运行一个 `org.junit.jupiter.api.Test`，
 * 确认该模块 `testDebugUnitTest` 由 Jupiter 引擎执行至少一个测试。
 */
class JUnitPlatformSmokeTest {

    @Test
    fun jupiterEngineExecutesInDeviceDiscoveryModule() {
        assertEquals(8, 2 * 4)
        assertTrue("_skybridge._tcp".startsWith("_skybridge"))
    }
}
