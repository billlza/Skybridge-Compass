package com.skybridge.compass.mirroring.domain.repositories

import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringType
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.entities.Resolution
import com.skybridge.compass.mirroring.domain.entities.CompressionLevel
import com.skybridge.compass.mirroring.domain.entities.NetworkProtocol
import com.skybridge.compass.core.data.model.ConnectionQuality
import kotlinx.coroutines.flow.Flow

/**
 * 屏幕镜像仓库接口
 * 
 * 定义屏幕镜像的核心业务逻辑
 */
interface ScreenMirroringRepository {
    
    /**
     * 开始屏幕镜像会话
     * 
     * @param deviceId 目标设备ID
     * @param mirroringType 镜像类型
     * @param quality 视频质量
     * @param audioEnabled 是否启用音频
     * @return 镜像会话
     */
    suspend fun startMirroring(
        deviceId: String,
        mirroringType: MirroringType = MirroringType.SCREEN_AUDIO,
        quality: VideoQuality = VideoQuality.AUTO,
        audioEnabled: Boolean = true
    ): Result<MirroringSession>
    
    /**
     * 停止屏幕镜像会话
     * 
     * @param sessionId 会话ID
     */
    suspend fun stopMirroring(sessionId: String): Result<Unit>
    
    /**
     * 暂停屏幕镜像
     * 
     * @param sessionId 会话ID
     */
    suspend fun pauseMirroring(sessionId: String): Result<Unit>
    
    /**
     * 恢复屏幕镜像
     * 
     * @param sessionId 会话ID
     */
    suspend fun resumeMirroring(sessionId: String): Result<Unit>
    
    /**
     * 获取活跃的镜像会话
     */
    fun getActiveSessions(): Flow<List<MirroringSession>>
    
    /**
     * 获取特定会话信息
     * 
     * @param sessionId 会话ID
     */
    suspend fun getSession(sessionId: String): MirroringSession?
    
    /**
     * 更新会话质量设置
     * 
     * @param sessionId 会话ID
     * @param quality 新的视频质量
     */
    suspend fun updateQuality(
        sessionId: String,
        quality: VideoQuality
    ): Result<Unit>
    
    /**
     * 更新会话分辨率
     * 
     * @param sessionId 会话ID
     * @param resolution 新的分辨率
     */
    suspend fun updateResolution(
        sessionId: String,
        resolution: Resolution
    ): Result<Unit>
    
    /**
     * 更新帧率
     * 
     * @param sessionId 会话ID
     * @param frameRate 新的帧率
     */
    suspend fun updateFrameRate(
        sessionId: String,
        frameRate: Int
    ): Result<Unit>
    
    /**
     * 更新比特率
     * 
     * @param sessionId 会话ID
     * @param bitrate 新的比特率
     */
    suspend fun updateBitrate(
        sessionId: String,
        bitrate: Int
    ): Result<Unit>
    
    /**
     * 切换音频开关
     * 
     * @param sessionId 会话ID
     * @param enabled 是否启用音频
     */
    suspend fun toggleAudio(
        sessionId: String,
        enabled: Boolean
    ): Result<Unit>
    
    /**
     * 更新压缩级别
     * 
     * @param sessionId 会话ID
     * @param compressionLevel 压缩级别
     */
    suspend fun updateCompressionLevel(
        sessionId: String,
        compressionLevel: CompressionLevel
    ): Result<Unit>
    
    /**
     * 更新网络协议
     * 
     * @param sessionId 会话ID
     * @param protocol 网络协议
     */
    suspend fun updateNetworkProtocol(
        sessionId: String,
        protocol: NetworkProtocol
    ): Result<Unit>
    
    /**
     * 获取会话统计信息
     * 
     * @param sessionId 会话ID
     */
    suspend fun getSessionStats(sessionId: String): Map<String, Any>?
    
    /**
     * 优化网络设置
     * 
     * @param sessionId 会话ID
     */
    suspend fun optimizeNetworkSettings(sessionId: String): Result<Unit>
    
    /**
     * 重连会话
     * 
     * @param sessionId 会话ID
     */
    suspend fun reconnectSession(sessionId: String): Result<Unit>
    
    /**
     * 获取支持的分辨率列表
     * 
     * @param deviceId 设备ID
     */
    suspend fun getSupportedResolutions(deviceId: String): List<Resolution>
    
    /**
     * 获取推荐的质量设置
     * 
     * @param deviceId 设备ID
     * @param networkSpeed 网络速度（字节/秒）
     */
    suspend fun getRecommendedQuality(
        deviceId: String,
        networkSpeed: Long
    ): VideoQuality
    
    /**
     * 测试连接质量
     * 
     * @param deviceId 设备ID
     */
    suspend fun testConnectionQuality(deviceId: String): ConnectionQuality
    
    /**
     * 清理已结束的会话
     */
    suspend fun cleanupFinishedSessions()
    
    /**
     * 获取会话历史记录
     * 
     * @param limit 限制数量
     */
    suspend fun getSessionHistory(limit: Int = 50): List<MirroringSession>
}