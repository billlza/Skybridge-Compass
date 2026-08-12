package com.skybridge.compass.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 端口选择必须落在配置范围内，范围耗尽时明确失败而非静默回落（任务 15.2 / R7.4）。
 */
class ListenPortAllocatorTest {

    @Test
    fun picksTheFirstFreePortInsideTheConfiguredRange() {
        val occupied = setOf(8080, 8081, 8082)
        val attempted = mutableListOf<Int>()

        val bound = ListenPortAllocator.bindWithin(8080..8090) { port ->
            attempted += port
            if (port in occupied) throw IllegalStateException("port $port in use")
            port
        }

        assertEquals(8083, bound)
        // 升序尝试，且从不越出范围。
        assertEquals(listOf(8080, 8081, 8082, 8083), attempted)
        assertTrue(attempted.all { it in 8080..8090 })
    }

    @Test
    fun neverAttemptsAPortOutsideTheConfiguredRange() {
        val attempted = mutableListOf<Int>()

        ListenPortAllocator.bindWithin(9000..9002) { port ->
            attempted += port
            if (port != 9002) throw IllegalStateException("port $port in use")
            port
        }

        assertEquals(listOf(9000, 9001, 9002), attempted)
        assertTrue(attempted.all { it in 9000..9002 })
    }

    @Test
    fun everyPortOccupied_failsExplicitlyWithoutFallingBackToADefaultPort() {
        val attempted = mutableListOf<Int>()

        val failure = assertThrows(ListenPortRangeExhaustedException::class.java) {
            ListenPortAllocator.bindWithin(8080..8083) { port ->
                attempted += port
                throw IllegalStateException("port $port in use")
            }
        }

        // 范围内每个端口都尝试过，然后明确失败——没有任何硬编码默认端口兜底。
        assertEquals(listOf(8080, 8081, 8082, 8083), attempted)
        assertEquals(8080..8083, failure.portRange)
        assertTrue(failure.message!!.contains("8080..8083"))
    }

    @Test
    fun everyPortOccupied_attachesTheLastBindFailureAsCause() {
        val last = IllegalStateException("port 8081 in use")

        val failure = assertThrows(ListenPortRangeExhaustedException::class.java) {
            ListenPortAllocator.bindWithin(8080..8081) { port ->
                if (port == 8081) throw last
                throw IllegalStateException("port $port in use")
            }
        }

        assertSame(last, failure.cause)
    }

    @Test
    fun singlePortRangeBindsThatExactPort() {
        val bound = ListenPortAllocator.bindWithin(8443..8443) { it }
        assertEquals(8443, bound)
    }
}
