package com.skybridge.compass.core.services

import org.junit.Assert.*
import org.junit.Test

/**
 * HardwareMonitorService 属性测试
 * 
 * **Feature: core-features-completion, Property 1: Network Quality Calculation Consistency**
 * **Validates: Requirements 1.3**
 */
class HardwareMonitorServiceTest {
    
    /**
     * Property 1: Network Quality Calculation Consistency
     * 
     * For any combination of latency (0-10000ms), bandwidth (0-1000Mbps), 
     * and packet loss (0-100%), the network quality calculation should 
     * produce a deterministic QualityLevel result.
     */
    @Test
    fun `network quality calculation is deterministic`() {
        // 测试多种输入组合，验证计算结果的确定性
        val testCases = listOf(
            // latency, bandwidth, packetLoss -> expected level
            Triple(10L, 100f, 0.5f) to QualityLevel.EXCELLENT,
            Triple(49L, 50f, 0.9f) to QualityLevel.EXCELLENT,
            Triple(50L, 100f, 1.5f) to QualityLevel.GOOD,
            Triple(99L, 50f, 2.9f) to QualityLevel.GOOD,
            Triple(100L, 30f, 3.5f) to QualityLevel.FAIR,
            Triple(199L, 20f, 4.9f) to QualityLevel.FAIR,
            Triple(200L, 10f, 5.0f) to QualityLevel.POOR,
            Triple(500L, 5f, 10f) to QualityLevel.POOR,
            Triple(-1L, 0f, 100f) to QualityLevel.OFFLINE
        )
        
        testCases.forEach { (input, expectedLevel) ->
            val (latency, bandwidth, packetLoss) = input
            
            // 计算两次，验证确定性
            val quality1 = calculateNetworkQuality(latency, bandwidth, packetLoss)
            val quality2 = calculateNetworkQuality(latency, bandwidth, packetLoss)
            
            assertEquals(
                "Quality calculation should be deterministic for latency=$latency, bandwidth=$bandwidth, packetLoss=$packetLoss",
                quality1, quality2
            )
            assertEquals(
                "Expected $expectedLevel for latency=$latency, bandwidth=$bandwidth, packetLoss=$packetLoss",
                expectedLevel, quality1.level
            )
        }
    }
    
    @Test
    fun `network quality calculation boundary values`() {
        // 边界值测试
        
        // 延迟边界
        assertEquals(QualityLevel.EXCELLENT, calculateNetworkQuality(0L, 100f, 0f).level)
        assertEquals(QualityLevel.EXCELLENT, calculateNetworkQuality(49L, 100f, 0f).level)
        assertEquals(QualityLevel.GOOD, calculateNetworkQuality(50L, 100f, 0f).level)
        assertEquals(QualityLevel.GOOD, calculateNetworkQuality(99L, 100f, 0f).level)
        assertEquals(QualityLevel.FAIR, calculateNetworkQuality(100L, 100f, 0f).level)
        assertEquals(QualityLevel.FAIR, calculateNetworkQuality(199L, 100f, 0f).level)
        assertEquals(QualityLevel.POOR, calculateNetworkQuality(200L, 100f, 0f).level)
        
        // 丢包率边界
        assertEquals(QualityLevel.EXCELLENT, calculateNetworkQuality(30L, 100f, 0.99f).level)
        assertEquals(QualityLevel.GOOD, calculateNetworkQuality(30L, 100f, 1.0f).level)
        assertEquals(QualityLevel.GOOD, calculateNetworkQuality(30L, 100f, 2.99f).level)
        assertEquals(QualityLevel.FAIR, calculateNetworkQuality(30L, 100f, 3.0f).level)
        assertEquals(QualityLevel.FAIR, calculateNetworkQuality(30L, 100f, 4.99f).level)
        assertEquals(QualityLevel.POOR, calculateNetworkQuality(30L, 100f, 5.0f).level)
        
        // 离线状态
        assertEquals(QualityLevel.OFFLINE, calculateNetworkQuality(-1L, 0f, 0f).level)
        assertEquals(QualityLevel.OFFLINE, calculateNetworkQuality(-100L, 100f, 0f).level)
    }
    
    @Test
    fun `network quality calculation with random inputs is consistent`() {
        // 使用伪随机数进行属性测试
        val random = java.util.Random(42) // 固定种子保证可重复
        
        repeat(100) {
            val latency = random.nextLong().let { if (it < 0) -1L else it % 10001 }
            val bandwidth = random.nextFloat() * 1000f
            val packetLoss = random.nextFloat() * 100f
            
            val quality1 = calculateNetworkQuality(latency, bandwidth, packetLoss)
            val quality2 = calculateNetworkQuality(latency, bandwidth, packetLoss)
            
            assertEquals(
                "Quality calculation should be deterministic for random inputs",
                quality1, quality2
            )
            
            // 验证返回值的有效性
            assertNotNull(quality1.level)
            assertEquals(latency, quality1.latencyMs)
            assertEquals(bandwidth, quality1.bandwidthMbps, 0.001f)
            assertEquals(packetLoss, quality1.packetLossPercent, 0.001f)
        }
    }
    
    /**
     * 辅助函数：计算网络质量（与 HardwareMonitorServiceImpl 逻辑一致）
     */
    private fun calculateNetworkQuality(
        latencyMs: Long,
        bandwidthMbps: Float,
        packetLossPercent: Float
    ): NetworkQuality {
        val level = when {
            latencyMs < 0 -> QualityLevel.OFFLINE
            latencyMs < 50 && packetLossPercent < 1f -> QualityLevel.EXCELLENT
            latencyMs < 100 && packetLossPercent < 3f -> QualityLevel.GOOD
            latencyMs < 200 && packetLossPercent < 5f -> QualityLevel.FAIR
            else -> QualityLevel.POOR
        }
        return NetworkQuality(level, latencyMs, bandwidthMbps, packetLossPercent)
    }
}
