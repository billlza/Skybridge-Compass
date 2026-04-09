package com.skybridge.compass.mirroring.data.repository

import com.skybridge.compass.mirroring.data.services.*
import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.*
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.concurrent.ConcurrentHashMap
import com.skybridge.compass.core.data.model.ConnectionQuality
import android.media.MediaCodec

/**
 * 屏幕镜像仓库实现
 */
class ScreenMirroringRepositoryImpl(
    private val screenMirroringService: ScreenMirroringService,
    private val videoEncoderService: VideoEncoderService,
    private val audioMirroringService: AudioMirroringService,
    private val mirroringNetworkService: MirroringNetworkService
) : ScreenMirroringRepository {
    
    private val activeSessionsMap = ConcurrentHashMap<String, MirroringSession>()
    private val sessionHistory = mutableListOf<MirroringSession>()
    private val repositoryScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private val _activeSessionsFlow = MutableStateFlow<List<MirroringSession>>(emptyList())
    override fun getActiveSessions(): Flow<List<MirroringSession>> = _activeSessionsFlow.asStateFlow()
    
    override suspend fun startMirroring(
        deviceId: String,
        mirroringType: MirroringType,
        quality: VideoQuality,
        audioEnabled: Boolean
    ): Result<MirroringSession> = withContext(Dispatchers.IO) {
        try {
            // 检查是否已有活跃会话
            if (activeSessionsMap.containsKey(deviceId)) {
                return@withContext Result.failure(
                    IllegalStateException("设备 $deviceId 已有活跃的镜像会话")
                )
            }
            
            // 创建新的镜像会话
            val session = MirroringSession(
                id = generateSessionId(),
                deviceId = deviceId,
                deviceName = "Device-$deviceId",
                sessionType = mirroringType,
                quality = quality,
                status = MirroringStatus.CONNECTING,
                startTime = System.currentTimeMillis(),
                frameRate = 30,
                bitrate = 2000000,
                resolution = Resolution(1920, 1080),
                audioEnabled = audioEnabled,
                compressionLevel = CompressionLevel.BALANCED,
                encryptionEnabled = true,
                networkProtocol = NetworkProtocol.TCP
            )
            
            // 启动屏幕镜像服务
            screenMirroringService.startMirroring(
                deviceId = deviceId,
                deviceName = "Device-$deviceId",
                mirroringType = mirroringType,
                quality = quality,
                audioEnabled = audioEnabled
            )
            
            // 建立网络连接
            mirroringNetworkService.connect(
                deviceId = deviceId,
                protocol = NetworkProtocol.TCP
            )
            
            // 设置编码数据回调
            videoEncoderService.setEncodedDataCallback { buffer, bufferInfo ->
                repositoryScope.launch {
                    mirroringNetworkService.sendVideoData(
                        deviceId = deviceId,
                        data = buffer,
                        timestamp = bufferInfo.presentationTimeUs / 1000,
                        isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    )
                }
            }
            
            // 如果启用音频，设置音频数据回调
            if (audioEnabled) {
                audioMirroringService.setAudioDataCallback(session.id) { data, timestamp ->
                    repositoryScope.launch {
                        mirroringNetworkService.sendAudioData(deviceId, data, timestamp)
                    }
                }
            }
            
            // 更新会话状态
            val connectedSession = session.copy(status = MirroringStatus.STREAMING)
            activeSessionsMap[deviceId] = connectedSession
            updateActiveSessionsFlow()
            
            Result.success(connectedSession)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun stopMirroring(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            // 停止屏幕镜像服务
            screenMirroringService.stopMirroring(sessionId)
            
            // 断开网络连接
            mirroringNetworkService.disconnect(sessionId)
            
            // 更新会话状态
            val stoppedSession = session.copy(
                status = MirroringStatus.DISCONNECTED,
                endTime = System.currentTimeMillis()
            )
            
            // 移除活跃会话并添加到历史记录
            activeSessionsMap.remove(session.deviceId)
            sessionHistory.add(stoppedSession)
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun pauseMirroring(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.pauseMirroring(sessionId)
            
            val pausedSession = session.copy(status = MirroringStatus.PAUSED)
            activeSessionsMap[session.deviceId] = pausedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun resumeMirroring(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.resumeMirroring(sessionId)
            
            val resumedSession = session.copy(status = MirroringStatus.STREAMING)
            activeSessionsMap[session.deviceId] = resumedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun getSession(sessionId: String): MirroringSession? {
        return findSessionById(sessionId)
    }
    
    override suspend fun updateQuality(
        sessionId: String,
        quality: VideoQuality
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.updateQuality(sessionId, quality)
            
            val updatedSession = session.copy(quality = quality)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun updateResolution(
        sessionId: String,
        resolution: Resolution
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.updateResolution(sessionId, resolution)
            
            val updatedSession = session.copy(resolution = resolution)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun updateFrameRate(
        sessionId: String,
        frameRate: Int
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.updateFrameRate(sessionId, frameRate)
            
            val updatedSession = session.copy(frameRate = frameRate)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun updateBitrate(
        sessionId: String,
        bitrate: Int
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.updateBitrate(sessionId, bitrate)
            
            val updatedSession = session.copy(bitrate = bitrate)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun toggleAudio(
        sessionId: String,
        enabled: Boolean
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.toggleAudio(sessionId, enabled)
            
            val updatedSession = session.copy(audioEnabled = enabled)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun updateCompressionLevel(
        sessionId: String,
        compressionLevel: CompressionLevel
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            screenMirroringService.updateCompressionLevel(sessionId, compressionLevel)
            
            val updatedSession = session.copy(compressionLevel = compressionLevel)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun updateNetworkProtocol(
        sessionId: String,
        protocol: NetworkProtocol
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            mirroringNetworkService.updateProtocol(sessionId, protocol)
            
            val updatedSession = session.copy(networkProtocol = protocol)
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun optimizeNetworkSettings(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            val stats = mirroringNetworkService.getNetworkStats(session.deviceId)
            val bandwidth = (stats["bandwidth"] as? Number)?.toLong() ?: measureBandwidth(session.deviceId)
            val latency = (stats["latency"] as? Number)?.toLong() ?: measureLatency(session.deviceId)
            val packetLoss = (stats["packetLoss"] as? Number)?.toFloat() ?: measurePacketLoss(session.deviceId)
            
            val targetBitrate = when {
                bandwidth < 1_000_000L -> 500_000
                bandwidth < 3_000_000L -> 1_500_000
                bandwidth < 5_000_000L -> 3_000_000
                else -> 6_000_000
            }
            val lossFactor = kotlin.math.min(packetLoss.toDouble(), 0.3)
            val adjustedBitrate = (targetBitrate * (1.0 - lossFactor)).toInt()
            
            val adjustedFrameRate = when {
                latency > 200L || packetLoss > 0.10f -> 24
                latency > 120L || packetLoss > 0.05f -> 30
                else -> 60
            }
            
            val adjustedResolution = when {
                bandwidth < 2_000_000L || latency > 200L -> Resolution(1280, 720)
                else -> Resolution(1920, 1080)
            }
            
            // 应用编码器更新
            screenMirroringService.updateBitrate(sessionId, adjustedBitrate)
            screenMirroringService.updateFrameRate(sessionId, adjustedFrameRate)
            screenMirroringService.updateResolution(sessionId, adjustedResolution)
            
            // 协议选择：高丢包/高延迟使用 UDP
            val newProtocol = if (packetLoss > 0.05f || latency > 150L) NetworkProtocol.UDP else NetworkProtocol.TCP
            mirroringNetworkService.updateProtocol(sessionId, newProtocol)
            
            val updatedSession = session.copy(
                bitrate = adjustedBitrate,
                frameRate = adjustedFrameRate,
                resolution = adjustedResolution,
                networkProtocol = newProtocol
            )
            activeSessionsMap[session.deviceId] = updatedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun getSessionStats(sessionId: String): Map<String, Any>? {
        val session = findSessionById(sessionId) ?: return null
        
        return mapOf(
            "sessionId" to session.id,
            "deviceId" to session.deviceId,
            "status" to session.status.name,
            "quality" to session.quality.name,
            "frameRate" to session.frameRate,
            "bitrate" to session.bitrate,
            "resolution" to "${session.resolution.width}x${session.resolution.height}",
            "audioEnabled" to session.audioEnabled,
            "compressionLevel" to session.compressionLevel.name,
            "networkProtocol" to session.networkProtocol.name,
            "startTime" to session.startTime,
            "endTime" to (session.endTime ?: 0L),
            "duration" to (session.endTime?.let { it - session.startTime } ?: (System.currentTimeMillis() - session.startTime))
        )
    }
    
    override suspend fun reconnectSession(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val session = findSessionById(sessionId)
                ?: return@withContext Result.failure(
                    IllegalArgumentException("会话不存在: $sessionId")
                )
            
            mirroringNetworkService.reconnect(session.deviceId)
            
            val reconnectedSession = session.copy(status = MirroringStatus.RECONNECTING)
            activeSessionsMap[session.deviceId] = reconnectedSession
            updateActiveSessionsFlow()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    override suspend fun getSupportedResolutions(deviceId: String): List<Resolution> {
        return listOf(
            Resolution(640, 480),
            Resolution(1280, 720),
            Resolution(1920, 1080),
            Resolution(2560, 1440),
            Resolution(3840, 2160)
        )
    }
    
    override suspend fun getRecommendedQuality(
        deviceId: String,
        networkSpeed: Long
    ): VideoQuality {
        return when {
            networkSpeed < 1_000_000 -> VideoQuality.LOW
            networkSpeed < 3_000_000 -> VideoQuality.MEDIUM
            networkSpeed > 5_000_000 -> VideoQuality.HIGH
            else -> VideoQuality.AUTO
        }
    }
    
    override suspend fun testConnectionQuality(deviceId: String): ConnectionQuality {
        return try {
            val latency = measureLatency(deviceId)
            val bandwidth = measureBandwidth(deviceId)
            val packetLoss = measurePacketLoss(deviceId)
            val jitter = measureJitter(deviceId)
            val signalStrength = measureSignalStrength(deviceId)
            
            ConnectionQuality(
                quality = when {
                    latency < 50 && packetLoss < 0.01f -> ConnectionQuality.Quality.EXCELLENT
                    latency < 100 && packetLoss < 0.05f -> ConnectionQuality.Quality.GOOD
                    latency < 200 && packetLoss < 0.1f -> ConnectionQuality.Quality.FAIR
                    else -> ConnectionQuality.Quality.POOR
                },
                score = when {
                    latency < 50 && packetLoss < 0.01f -> 0.9f
                    latency < 100 && packetLoss < 0.05f -> 0.7f
                    latency < 200 && packetLoss < 0.1f -> 0.5f
                    else -> 0.3f
                },
                latency = latency,
                bandwidth = bandwidth,
                packetLoss = packetLoss,
                jitter = jitter,
                signalStrength = signalStrength
            )
        } catch (e: Exception) {
            ConnectionQuality(
                quality = ConnectionQuality.Quality.POOR,
                score = 0.1f,
                latency = -1,
                bandwidth = -1,
                packetLoss = 100.0f,
                jitter = -1,
                signalStrength = 0.0f
            )
        }
    }
    
    private suspend fun measureLatency(deviceId: String): Long {
        return 50L // 模拟延迟测量
    }
    
    private suspend fun measureBandwidth(deviceId: String): Long {
        return 10_000_000L // 模拟带宽测量
    }
    
    private suspend fun measurePacketLoss(deviceId: String): Float {
        return 0.1f // 模拟丢包率测量
    }
    
    private suspend fun measureJitter(deviceId: String): Long {
        return 5L // 模拟抖动测量
    }
    
    private suspend fun measureSignalStrength(deviceId: String): Float {
        return 0.8f // 模拟信号强度测量
    }
    
    override suspend fun cleanupFinishedSessions() {
        val finishedSessions = activeSessionsMap.values.filter { session ->
            session.status == MirroringStatus.DISCONNECTED ||
            session.status == MirroringStatus.ERROR ||
            session.status == MirroringStatus.TIMEOUT
        }
        
        finishedSessions.forEach { session ->
            activeSessionsMap.remove(session.deviceId)
            if (!sessionHistory.contains(session)) {
                sessionHistory.add(session)
            }
        }
        
        updateActiveSessionsFlow()
    }
    
    override suspend fun getSessionHistory(limit: Int): List<MirroringSession> {
        return sessionHistory.takeLast(limit)
    }
    
    private fun findSessionById(sessionId: String): MirroringSession? {
        return activeSessionsMap.values.find { it.id == sessionId }
            ?: sessionHistory.find { it.id == sessionId }
    }
    
    private fun updateActiveSessionsFlow() {
        _activeSessionsFlow.value = activeSessionsMap.values.toList()
    }
    
    private fun generateSessionId(): String {
        return "session_${System.currentTimeMillis()}_${(1000..9999).random()}"
    }
    
    fun cleanup() {
        repositoryScope.cancel()
        activeSessionsMap.clear()
        sessionHistory.clear()
    }
}