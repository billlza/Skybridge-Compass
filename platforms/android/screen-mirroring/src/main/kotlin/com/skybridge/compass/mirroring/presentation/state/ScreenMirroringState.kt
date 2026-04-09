package com.skybridge.compass.mirroring.presentation.state

import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringStatus
import com.skybridge.compass.mirroring.domain.entities.VideoQuality

/**
 * 屏幕镜像UI状态
 */
data class ScreenMirroringState(
    // 加载状态
    val isLoading: Boolean = false,
    
    // 活跃会话列表
    val activeSessions: List<MirroringSession> = emptyList(),
    
    // 会话历史
    val sessionHistory: List<MirroringSession> = emptyList(),
    
    // 选中的会话ID
    val selectedSessionId: String? = null,
    
    // 错误信息
    val error: String? = null,
    
    // 会话统计信息
    val sessionStats: Map<String, Map<String, Any>> = emptyMap(),
    
    // 连接测试结果
    val connectionTestResult: Map<String, Any>? = null,
    
    // 会话过滤器
    val sessionFilter: SessionFilter = SessionFilter.ALL,
    
    // 排序顺序
    val sortOrder: SortOrder = SortOrder.START_TIME_DESC,
    
    // 是否显示会话详情
    val showSessionDetails: Boolean = false,
    
    // 最后刷新时间
    val lastRefreshTime: Long = 0L,
    
    // 支持的分辨率列表
    val supportedResolutions: List<Pair<Int, Int>> = listOf(
        1920 to 1080, // Full HD
        1280 to 720,  // HD
        854 to 480,   // SD
        640 to 360,   // Low
        426 to 240    // Very Low
    ),
    
    // 支持的帧率列表
    val supportedFrameRates: List<Int> = listOf(60, 30, 24, 15),
    
    // 支持的比特率列表 (bps)
    val supportedBitrates: List<Int> = listOf(
        10_000_000, // 10 Mbps
        5_000_000,  // 5 Mbps
        2_000_000,  // 2 Mbps
        1_000_000,  // 1 Mbps
        500_000     // 500 Kbps
    )
) {
    
    /**
     * 会话过滤器
     */
    enum class SessionFilter {
        ALL,      // 所有会话
        ACTIVE,   // 活跃会话
        PAUSED,   // 暂停会话
        ERROR     // 错误会话
    }
    
    /**
     * 排序顺序
     */
    enum class SortOrder {
        START_TIME_DESC,  // 开始时间降序
        START_TIME_ASC,   // 开始时间升序
        DEVICE_NAME,      // 设备名称
        STATUS            // 状态
    }
    
    /**
     * 获取选中的会话
     */
    val selectedSession: MirroringSession?
        get() = selectedSessionId?.let { id ->
            activeSessions.find { it.id == id }
        }
    
    /**
     * 获取活跃会话数量
     */
    val activeSessionCount: Int
        get() = activeSessions.count { it.status == MirroringStatus.STREAMING }
    
    /**
     * 获取暂停会话数量
     */
    val pausedSessionCount: Int
        get() = activeSessions.count { it.status == MirroringStatus.PAUSED }
    
    /**
     * 获取错误会话数量
     */
    val errorSessionCount: Int
        get() = activeSessions.count { it.status == MirroringStatus.ERROR }
    
    /**
     * 是否有活跃会话
     */
    val hasActiveSessions: Boolean
        get() = activeSessions.isNotEmpty()
    
    /**
     * 是否有错误
     */
    val hasError: Boolean
        get() = error != null
    
    /**
     * 获取会话统计摘要
     */
    val sessionStatsSummary: Map<String, Any>
        get() = mapOf(
            "totalSessions" to activeSessions.size,
            "activeSessions" to activeSessionCount,
            "pausedSessions" to pausedSessionCount,
            "errorSessions" to errorSessionCount,
            "totalHistorySessions" to sessionHistory.size,
            "averageSessionDuration" to calculateAverageSessionDuration(),
            "totalDataTransferred" to calculateTotalDataTransferred()
        )
    
    /**
     * 计算平均会话持续时间
     */
    private fun calculateAverageSessionDuration(): Long {
        if (sessionHistory.isEmpty()) return 0L
        
        val totalDuration = sessionHistory.sumOf { session ->
            val endTime = session.endTime ?: System.currentTimeMillis()
            endTime - session.startTime
        }
        
        return totalDuration / sessionHistory.size
    }
    
    /**
     * 计算总数据传输量
     */
    private fun calculateTotalDataTransferred(): Long {
        return sessionStats.values.sumOf { stats ->
            (stats["bytesTransferred"] as? Long) ?: 0L
        }
    }
    
    /**
     * 获取推荐的质量设置
     */
    fun getRecommendedQuality(deviceId: String): VideoQuality {
        val testResult = connectionTestResult
        if (testResult?.get("deviceId") == deviceId) {
            val bandwidth = testResult["bandwidth"] as? String
            val latency = testResult["latency"] as? String
            
            return when {
                bandwidth?.contains("10") == true -> VideoQuality.ULTRA
            bandwidth?.contains("5") == true -> VideoQuality.HIGH
            bandwidth?.contains("2") == true -> VideoQuality.MEDIUM
            latency?.contains("100") == true -> VideoQuality.LOW
            else -> VideoQuality.LOW
        }
        
        }
        return VideoQuality.MEDIUM // 默认中等质量
    }
    
    /**
     * 获取推荐的分辨率
     */
    fun getRecommendedResolution(quality: VideoQuality): Pair<Int, Int> {
        return when (quality) {
            VideoQuality.ULTRA -> 1920 to 1080
            VideoQuality.HIGH -> 1280 to 720
            VideoQuality.MEDIUM -> 854 to 480
            VideoQuality.LOW -> 640 to 360
            VideoQuality.AUTO -> 854 to 480 // 默认中等分辨率
        }
    }
    
    /**
     * 获取推荐的帧率
     */
    fun getRecommendedFrameRate(quality: VideoQuality): Int {
        return when (quality) {
            VideoQuality.ULTRA -> 60
            VideoQuality.HIGH -> 30
            VideoQuality.MEDIUM -> 24
            VideoQuality.LOW -> 15
            VideoQuality.AUTO -> 24 // 默认中等帧率
        }
    }
    
    /**
     * 获取推荐的比特率
     */
    fun getRecommendedBitrate(quality: VideoQuality): Int {
        return when (quality) {
            VideoQuality.ULTRA -> 10_000_000
            VideoQuality.HIGH -> 5_000_000
            VideoQuality.MEDIUM -> 2_000_000
            VideoQuality.LOW -> 1_000_000
            VideoQuality.AUTO -> 2_000_000 // 默认中等比特率
        }
    }
    
    /**
     * 检查是否可以开始新的镜像会话
     */
    fun canStartNewSession(): Boolean {
        return !isLoading && activeSessionCount < MAX_CONCURRENT_SESSIONS
    }
    
    /**
     * 检查设备是否已有活跃会话
     */
    fun hasActiveSessionForDevice(deviceId: String): Boolean {
        return activeSessions.any { 
            it.deviceId == deviceId && it.status == MirroringStatus.STREAMING 
        }
    }
    
    /**
     * 获取设备的活跃会话
     */
    fun getActiveSessionForDevice(deviceId: String): MirroringSession? {
        return activeSessions.find { 
            it.deviceId == deviceId && it.status == MirroringStatus.STREAMING 
        }
    }
    
    /**
     * 获取会话的实时统计信息
     */
    fun getSessionStats(sessionId: String): Map<String, Any>? {
        return sessionStats[sessionId]
    }
    
    /**
     * 检查会话是否可以暂停
     */
    fun canPauseSession(sessionId: String): Boolean {
        val session = activeSessions.find { it.id == sessionId }
        return session?.status == MirroringStatus.STREAMING
    }
    
    /**
     * 检查会话是否可以恢复
     */
    fun canResumeSession(sessionId: String): Boolean {
        val session = activeSessions.find { it.id == sessionId }
        return session?.status == MirroringStatus.PAUSED
    }
    
    /**
     * 检查会话是否可以重连
     */
    fun canReconnectSession(sessionId: String): Boolean {
        val session = activeSessions.find { it.id == sessionId }
        return session?.status == MirroringStatus.ERROR
    }
    
    companion object {
        const val MAX_CONCURRENT_SESSIONS = 3 // 最大并发会话数
    }
}