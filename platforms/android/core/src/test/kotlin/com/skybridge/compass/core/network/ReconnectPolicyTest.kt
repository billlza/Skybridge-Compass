package com.skybridge.compass.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

class ReconnectPolicyTest {

    @Test
    fun delayFor_followsExponentialBackoffSequenceWithoutJitter() {
        // 抖动比例注入为 0，退避基准应为 1s/2s/4s/8s/16s。
        val policy = DefaultReconnectPolicy(maxAttempts = 10, jitterFraction = { 0.0 })

        assertEquals(1.seconds, policy.delayFor(1))
        assertEquals(2.seconds, policy.delayFor(2))
        assertEquals(4.seconds, policy.delayFor(3))
        assertEquals(8.seconds, policy.delayFor(4))
        assertEquals(16.seconds, policy.delayFor(5))
    }

    @Test
    fun delayFor_capsBaseDelayAtThirtySeconds() {
        val policy = DefaultReconnectPolicy(maxAttempts = 10, jitterFraction = { 0.0 })

        // 2^5=32s → 封顶 30s；后续更大序号亦封顶 30s。
        assertEquals(30.seconds, policy.delayFor(6))
        assertEquals(30.seconds, policy.delayFor(7))
        assertEquals(30.seconds, policy.delayFor(10))
    }

    @Test
    fun delayFor_appliesJitterWithinTwentyPercentOfBase() {
        // 最大抖动比例：base * (1 + 0.20)。
        val maxJitter = DefaultReconnectPolicy(maxAttempts = 5, jitterFraction = { 1.0 })
        assertEquals((1.0 * 1.20).seconds, maxJitter.delayFor(1))
        assertEquals((4.0 * 1.20).seconds, maxJitter.delayFor(3))

        // 任意抖动都应落在 [base, base*1.2] 区间内。
        val policy = DefaultReconnectPolicy(maxAttempts = 5, jitterFraction = { 0.13 })
        val base = 4.0
        val d = policy.delayFor(3).inWholeMilliseconds
        assertTrue(d >= (base * 1000).toLong())
        assertTrue(d <= (base * 1.20 * 1000).toLong())
    }

    @Test
    fun constructor_rejectsAttemptsOutsideZeroToTen() {
        assertThrows(IllegalArgumentException::class.java) {
            DefaultReconnectPolicy(maxAttempts = -1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            DefaultReconnectPolicy(maxAttempts = 11)
        }
    }

    @Test
    fun fromMaxReconnectAttempts_clampsToValidRangeAsStorageFallback() {
        assertEquals(0, DefaultReconnectPolicy.fromMaxReconnectAttempts(-5).maxAttempts)
        assertEquals(10, DefaultReconnectPolicy.fromMaxReconnectAttempts(99).maxAttempts)
        // 默认持久化值 3 应原样接线。
        assertEquals(3, DefaultReconnectPolicy.fromMaxReconnectAttempts(3).maxAttempts)
    }
}
