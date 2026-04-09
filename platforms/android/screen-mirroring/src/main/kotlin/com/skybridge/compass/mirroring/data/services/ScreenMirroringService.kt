package com.skybridge.compass.mirroring.data.services

import android.content.Context
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.util.Log
import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringStatus
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap
import com.skybridge.compass.mirroring.domain.entities.*
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.view.Surface
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * 屏幕镜像服务
 * 负责管理屏幕镜像会话的核心逻辑
 */
class ScreenMirroringService(
    private val context: Context,
    private val mediaProjectionManager: MediaProjectionManager,
    private val videoEncoderService: VideoEncoderService,
    private val audioMirroringService: AudioMirroringService,
    private val mirroringNetworkService: MirroringNetworkService
) {
    
    private val _activeSessions = MutableStateFlow<List<MirroringSession>>(emptyList())
    val activeSessions: StateFlow<List<MirroringSession>> = _activeSessions.asStateFlow()
    
    private val sessions = ConcurrentHashMap<String, MirroringSessionManager>()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private var mediaProjection: MediaProjection? = null
    
    /**
     * 开始屏幕镜像
     */
    suspend fun startMirroring(
        deviceId: String,
        deviceName: String,
        mirroringType: MirroringType,
        quality: VideoQuality,
        audioEnabled: Boolean
    ): Result<MirroringSession> = withContext(Dispatchers.IO) {
        try {
            val session = MirroringSession(
                deviceId = deviceId,
                deviceName = deviceName,
                sessionType = mirroringType,
                quality = quality,
                status = MirroringStatus.INITIALIZING,
                resolution = quality.resolution,
                audioEnabled = audioEnabled
            )
            
            val sessionManager = MirroringSessionManager(
                session = session,
                networkService = mirroringNetworkService,
                encoderService = videoEncoderService,
                audioService = audioMirroringService,
                context = context
            )
            
            sessions[session.id] = sessionManager
            updateSessionsList()
            
            // 启动会话
            sessionManager.start()
            
            Result.success(session)
        } catch (e: Exception) {
            Log.e(TAG, "启动屏幕镜像失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止屏幕镜像
     */
    suspend fun stopMirroring(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sessionManager = sessions[sessionId]
                ?: return@withContext Result.failure(IllegalArgumentException("会话不存在"))
            
            sessionManager.stop()
            sessions.remove(sessionId)
            updateSessionsList()
            
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "停止屏幕镜像失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 暂停屏幕镜像
     */
    suspend fun pauseMirroring(sessionId: String): Result<Unit> {
        return sessions[sessionId]?.pause() ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 恢复屏幕镜像
     */
    suspend fun resumeMirroring(sessionId: String): Result<Unit> {
        return sessions[sessionId]?.resume() ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 获取会话信息
     */
    fun getSession(sessionId: String): MirroringSession? {
        return sessions[sessionId]?.getCurrentSession()
    }
    
    /**
     * 更新会话质量
     */
    suspend fun updateQuality(sessionId: String, quality: VideoQuality): Result<Unit> {
        return sessions[sessionId]?.updateQuality(quality) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 更新分辨率
     */
    suspend fun updateResolution(sessionId: String, resolution: Resolution): Result<Unit> {
        return sessions[sessionId]?.updateResolution(resolution) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 切换音频
     */
    suspend fun toggleAudio(sessionId: String, enabled: Boolean): Result<Unit> {
        return sessions[sessionId]?.toggleAudio(enabled) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 更新帧率
     */
    suspend fun updateFrameRate(sessionId: String, frameRate: Int): Result<Unit> {
        return sessions[sessionId]?.updateFrameRate(frameRate) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 更新比特率
     */
    suspend fun updateBitrate(sessionId: String, bitrate: Int): Result<Unit> {
        return sessions[sessionId]?.updateBitrate(bitrate) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 更新压缩级别
     */
    suspend fun updateCompressionLevel(sessionId: String, compressionLevel: CompressionLevel): Result<Unit> {
        return sessions[sessionId]?.updateCompressionLevel(compressionLevel) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 更新网络协议
     */
    suspend fun updateProtocol(sessionId: String, protocol: NetworkProtocol): Result<Unit> {
        return sessions[sessionId]?.updateProtocol(protocol) ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 获取会话统计信息
     */
    fun getSessionStats(sessionId: String): Map<String, Any>? {
        return sessions[sessionId]?.getStats()
    }
    
    /**
     * 重连会话
     */
    suspend fun reconnectSession(sessionId: String): Result<Unit> {
        return sessions[sessionId]?.reconnect() ?: Result.failure(IllegalArgumentException("会话不存在"))
    }
    
    /**
     * 设置媒体投影
     */
    fun setMediaProjection(mediaProjection: MediaProjection) {
        this.mediaProjection = mediaProjection
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        serviceScope.cancel()
        sessions.values.forEach { manager ->
            try {
                runBlocking { manager.stop() }
            } catch (e: Exception) {
                Log.w(TAG, "停止会话失败", e)
            }
        }
        sessions.clear()
        mediaProjection?.stop()
        mediaProjection = null
    }
    
    private fun updateSessionsList() {
        val currentSessions = sessions.values.map { it.getCurrentSession() }
        _activeSessions.value = currentSessions
    }
    
    companion object {
        private const val TAG = "ScreenMirroringService"
    }
}

/**
 * 镜像会话管理器
 */
private class MirroringSessionManager(
    private var session: MirroringSession,
    private val networkService: MirroringNetworkService,
    private val encoderService: VideoEncoderService,
    private val audioService: AudioMirroringService,
    private val context: Context
) {
    
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var encoderSurface: Surface? = null
    private var isRunning = false
    private var isPaused = false
    
    private val sessionScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val statsCollector = SessionStatsCollector()
    
    /**
     * 启动会话
     */
    suspend fun start() = withContext(Dispatchers.IO) {
        try {
            session = session.copy(status = MirroringStatus.CONNECTING)
            
            // 建立网络连接
            networkService.connect(session.deviceId, session.networkProtocol)
            
            // 初始化编码器
            encoderService.initialize(
                resolution = session.resolution,
                bitrate = session.bitrate,
                frameRate = session.frameRate,
                compressionLevel = session.compressionLevel
            )
            
            // 启动音频（如果需要）
            if (session.audioEnabled) {
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.RECORD_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    audioService.startAudioCapture(session.id)
                } else {
                    Log.w("ScreenMirroringService", "缺少 RECORD_AUDIO 权限，禁用音频捕获")
                    session = session.copy(audioEnabled = false)
                }
            }
            
            // 开始屏幕录制
            startScreenCapture()
            
            session = session.copy(status = MirroringStatus.STREAMING)
            isRunning = true
            
            // 启动统计收集
            startStatsCollection()
            
        } catch (e: Exception) {
            session = session.copy(
                status = MirroringStatus.ERROR,
                errorCount = session.errorCount + 1
            )
            throw e
        }
    }
    
    /**
     * 停止会话
     */
    suspend fun stop() {
        withContext(Dispatchers.IO) {
            isRunning = false
            sessionScope.cancel()
            
            virtualDisplay?.release()
            imageReader?.close()
            encoderSurface?.release()
            
            encoderService.release()
            audioService.stopAudioCapture(session.id)
            networkService.disconnect(session.deviceId)
            
            session = session.copy(
                status = MirroringStatus.DISCONNECTED,
                endTime = System.currentTimeMillis()
            )
        }
    }
    
    /**
     * 暂停会话
     */
    suspend fun pause(): Result<Unit> {
        return try {
            isPaused = true
            session = session.copy(status = MirroringStatus.PAUSED)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 恢复会话
     */
    suspend fun resume(): Result<Unit> {
        return try {
            isPaused = false
            session = session.copy(status = MirroringStatus.STREAMING)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新质量设置
     */
    suspend fun updateQuality(quality: VideoQuality): Result<Unit> {
        return try {
            session = session.copy(
                quality = quality,
                resolution = quality.resolution,
                bitrate = quality.bitrate,
                frameRate = quality.frameRate
            )
            
            // 重新配置编码器
            encoderService.reconfigure(
                resolution = session.resolution,
                bitrate = session.bitrate,
                frameRate = session.frameRate
            )
            
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新分辨率
     */
    suspend fun updateResolution(resolution: Resolution): Result<Unit> {
        return try {
            session = session.copy(resolution = resolution)
            encoderService.updateResolution(resolution)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 切换音频
     */
    suspend fun toggleAudio(enabled: Boolean): Result<Unit> {
        return try {
            session = session.copy(audioEnabled = enabled)
            if (enabled) {
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.RECORD_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    audioService.startAudioCapture(session.id)
                } else {
                    Log.w("ScreenMirroringService", "缺少 RECORD_AUDIO 权限，无法启用音频")
                    session = session.copy(audioEnabled = false)
                }
            } else {
                audioService.stopAudioCapture(session.id)
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新帧率
     */
    suspend fun updateFrameRate(frameRate: Int): Result<Unit> {
        return try {
            session = session.copy(frameRate = frameRate)
            encoderService.updateFrameRate(frameRate)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新比特率
     */
    suspend fun updateBitrate(bitrate: Int): Result<Unit> {
        return try {
            session = session.copy(bitrate = bitrate)
            encoderService.updateBitrate(bitrate)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新压缩级别
     */
    suspend fun updateCompressionLevel(compressionLevel: CompressionLevel): Result<Unit> {
        return try {
            session = session.copy(compressionLevel = compressionLevel)
            encoderService.updateCompressionLevel(compressionLevel)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 更新网络协议
     */
    suspend fun updateProtocol(protocol: NetworkProtocol): Result<Unit> {
        return try {
            session = session.copy(networkProtocol = protocol)
            networkService.updateProtocol(session.deviceId, protocol)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 重连会话
     */
    suspend fun reconnect(): Result<Unit> {
        return try {
            session = session.copy(
                status = MirroringStatus.RECONNECTING,
                reconnectCount = session.reconnectCount + 1
            )
            
            // 重新建立连接
            networkService.reconnect(session.deviceId)
            
            session = session.copy(status = MirroringStatus.STREAMING)
            Result.success(Unit)
        } catch (e: Exception) {
            session = session.copy(
                status = MirroringStatus.ERROR,
                errorCount = session.errorCount + 1
            )
            Result.failure(e)
        }
    }
    
    /**
     * 获取当前会话
     */
    fun getCurrentSession(): MirroringSession = session
    
    /**
     * 获取统计信息
     */
    fun getStats(): Map<String, Any> = statsCollector.getStats()
    
    private fun startScreenCapture() {
        // 屏幕录制实现
        // 这里需要MediaProjection的实际实现
    }
    
    private fun startStatsCollection() {
        sessionScope.launch {
            while (isRunning) {
                delay(1000) // 每秒收集一次统计信息
                
                val networkStats = networkService.getNetworkStats(session.deviceId)
                val encoderStats = encoderService.getEncoderStats()
                
                session = session.copy(
                    latency = networkStats["latency"] as? Long ?: 0,
                    packetLoss = networkStats["packetLoss"] as? Float ?: 0f,
                    bandwidth = networkStats["bandwidth"] as? Long ?: 0
                )
                
                statsCollector.updateStats(session, networkStats, encoderStats)
            }
        }
    }
}

/**
 * 会话统计收集器
 */
private class SessionStatsCollector {
    private val stats = mutableMapOf<String, Any>()
    
    fun updateStats(
        session: MirroringSession,
        networkStats: Map<String, Any>,
        encoderStats: Map<String, Any>
    ) {
        stats.putAll(mapOf(
            "sessionId" to session.id,
            "duration" to session.duration,
            "qualityScore" to session.qualityScore,
            "framesSent" to (encoderStats["framesSent"] ?: 0),
            "framesDropped" to (encoderStats["framesDropped"] ?: 0),
            "averageBitrate" to (encoderStats["averageBitrate"] ?: 0),
            "networkLatency" to session.latency,
            "packetLoss" to session.packetLoss,
            "bandwidth" to session.bandwidth,
            "errorCount" to session.errorCount,
            "reconnectCount" to session.reconnectCount
        ))
    }
    
    fun getStats(): Map<String, Any> = stats.toMap()
}