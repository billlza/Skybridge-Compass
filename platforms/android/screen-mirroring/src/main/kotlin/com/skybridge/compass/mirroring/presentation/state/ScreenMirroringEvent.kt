package com.skybridge.compass.mirroring.presentation.state

import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringType
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.entities.CompressionLevel
import com.skybridge.compass.mirroring.domain.entities.NetworkProtocol

/**
 * 屏幕镜像UI事件
 */
sealed class ScreenMirroringEvent {
    
    /**
     * 开始屏幕镜像
     */
    data class StartMirroring(
        val deviceId: String,
        val deviceName: String,
        val sessionType: MirroringType = MirroringType.SCREEN_ONLY,
        val quality: VideoQuality = VideoQuality.MEDIUM,
        val resolution: Pair<Int, Int> = 1280 to 720,
        val frameRate: Int = 30,
        val bitrate: Int = 2_000_000,
        val enableAudio: Boolean = false,
        val compression: CompressionLevel = CompressionLevel.BALANCED,
        val encryption: Boolean = true,
        val networkProtocol: NetworkProtocol = NetworkProtocol.TCP
    ) : ScreenMirroringEvent()
    
    /**
     * 停止屏幕镜像
     */
    data class StopMirroring(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 暂停屏幕镜像
     */
    data class PauseMirroring(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 恢复屏幕镜像
     */
    data class ResumeMirroring(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 更新镜像质量
     */
    data class UpdateQuality(
        val sessionId: String,
        val quality: VideoQuality
    ) : ScreenMirroringEvent()
    
    /**
     * 更新分辨率
     */
    data class UpdateResolution(
        val sessionId: String,
        val resolution: Pair<Int, Int>
    ) : ScreenMirroringEvent()
    
    /**
     * 更新帧率
     */
    data class UpdateFrameRate(
        val sessionId: String,
        val frameRate: Int
    ) : ScreenMirroringEvent()
    
    /**
     * 更新比特率
     */
    data class UpdateBitrate(
        val sessionId: String,
        val bitrate: Int
    ) : ScreenMirroringEvent()
    
    /**
     * 切换音频
     */
    data class ToggleAudio(
        val sessionId: String,
        val enableAudio: Boolean
    ) : ScreenMirroringEvent()
    
    /**
     * 更新压缩方式
     */
    data class UpdateCompression(
        val sessionId: String,
        val compression: CompressionLevel
    ) : ScreenMirroringEvent()
    
    /**
     * 更新网络协议
     */
    data class UpdateNetworkProtocol(
        val sessionId: String,
        val protocol: NetworkProtocol
    ) : ScreenMirroringEvent()
    
    /**
     * 重连会话
     */
    data class ReconnectSession(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 选择会话
     */
    data class SelectSession(
        val sessionId: String?
    ) : ScreenMirroringEvent()
    
    /**
     * 刷新会话列表
     */
    object RefreshSessions : ScreenMirroringEvent()
    
    /**
     * 清除错误
     */
    object ClearError : ScreenMirroringEvent()
    
    /**
     * 优化设置
     */
    data class OptimizeSettings(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 查看会话详情
     */
    data class ViewSessionDetails(
        val sessionId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 导出会话历史
     */
    object ExportSessionHistory : ScreenMirroringEvent()
    
    /**
     * 清除会话历史
     */
    object ClearSessionHistory : ScreenMirroringEvent()
    
    /**
     * 测试连接
     */
    data class TestConnection(
        val deviceId: String
    ) : ScreenMirroringEvent()
    
    /**
     * 更新会话过滤器
     */
    data class UpdateSessionFilter(
        val filter: ScreenMirroringState.SessionFilter
    ) : ScreenMirroringEvent()
    
    /**
     * 更新排序顺序
     */
    data class UpdateSortOrder(
        val sortOrder: ScreenMirroringState.SortOrder
    ) : ScreenMirroringEvent()
    
    /**
     * 批量操作事件
     */
    sealed class BatchOperation : ScreenMirroringEvent() {
        
        /**
         * 停止所有会话
         */
        object StopAllSessions : BatchOperation()
        
        /**
         * 暂停所有会话
         */
        object PauseAllSessions : BatchOperation()
        
        /**
         * 恢复所有会话
         */
        object ResumeAllSessions : BatchOperation()
        
        /**
         * 重连所有错误会话
         */
        object ReconnectAllErrorSessions : BatchOperation()
        
        /**
         * 优化所有会话设置
         */
        object OptimizeAllSessions : BatchOperation()
    }
    
    /**
     * 高级设置事件
     */
    sealed class AdvancedSettings : ScreenMirroringEvent() {
        
        /**
         * 更新加密设置
         */
        data class UpdateEncryption(
            val sessionId: String,
            val encryption: Boolean
        ) : AdvancedSettings()
        
        /**
         * 更新缓冲区大小
         */
        data class UpdateBufferSize(
            val sessionId: String,
            val bufferSize: Int
        ) : AdvancedSettings()
        
        /**
         * 更新网络超时
         */
        data class UpdateNetworkTimeout(
            val sessionId: String,
            val timeout: Int
        ) : AdvancedSettings()
        
        /**
         * 启用/禁用硬件加速
         */
        data class ToggleHardwareAcceleration(
            val sessionId: String,
            val enabled: Boolean
        ) : AdvancedSettings()
        
        /**
         * 更新编码器配置
         */
        data class UpdateEncoderConfig(
            val sessionId: String,
            val config: Map<String, Any>
        ) : AdvancedSettings()
        
        /**
         * 更新网络适配设置
         */
        data class UpdateNetworkAdaptation(
            val sessionId: String,
            val enabled: Boolean,
            val minBitrate: Int,
            val maxBitrate: Int
        ) : AdvancedSettings()
    }
    
    /**
     * 性能监控事件
     */
    sealed class PerformanceMonitoring : ScreenMirroringEvent() {
        
        /**
         * 开始性能监控
         */
        data class StartMonitoring(
            val sessionId: String,
            val interval: Long = 1000L // 监控间隔（毫秒）
        ) : PerformanceMonitoring()
        
        /**
         * 停止性能监控
         */
        data class StopMonitoring(
            val sessionId: String
        ) : PerformanceMonitoring()
        
        /**
         * 导出性能数据
         */
        data class ExportPerformanceData(
            val sessionId: String,
            val format: String = "json" // json, csv, xml
        ) : PerformanceMonitoring()
        
        /**
         * 设置性能警告阈值
         */
        data class SetPerformanceThresholds(
            val sessionId: String,
            val latencyThreshold: Int = 100, // 延迟阈值（毫秒）
            val packetLossThreshold: Float = 5.0f, // 丢包率阈值（百分比）
            val bitrateThreshold: Int = 500_000 // 比特率阈值（bps）
        ) : PerformanceMonitoring()
    }
    
    /**
     * 录制相关事件
     */
    sealed class Recording : ScreenMirroringEvent() {
        
        /**
         * 开始录制
         */
        data class StartRecording(
            val sessionId: String,
            val outputPath: String,
            val format: String = "mp4",
            val quality: VideoQuality = VideoQuality.HIGH
        ) : Recording()
        
        /**
         * 停止录制
         */
        data class StopRecording(
            val sessionId: String
        ) : Recording()
        
        /**
         * 暂停录制
         */
        data class PauseRecording(
            val sessionId: String
        ) : Recording()
        
        /**
         * 恢复录制
         */
        data class ResumeRecording(
            val sessionId: String
        ) : Recording()
        
        /**
         * 截图
         */
        data class TakeScreenshot(
            val sessionId: String,
            val outputPath: String,
            val format: String = "png"
        ) : Recording()
    }
    
    /**
     * 网络诊断事件
     */
    sealed class NetworkDiagnostics : ScreenMirroringEvent() {
        
        /**
         * 运行网络诊断
         */
        data class RunDiagnostics(
            val deviceId: String
        ) : NetworkDiagnostics()
        
        /**
         * 测试带宽
         */
        data class TestBandwidth(
            val deviceId: String,
            val duration: Int = 10 // 测试持续时间（秒）
        ) : NetworkDiagnostics()
        
        /**
         * 测试延迟
         */
        data class TestLatency(
            val deviceId: String,
            val packetCount: Int = 10
        ) : NetworkDiagnostics()
        
        /**
         * 测试丢包率
         */
        data class TestPacketLoss(
            val deviceId: String,
            val packetCount: Int = 100
        ) : NetworkDiagnostics()
        
        /**
         * 网络质量评估
         */
        data class AssessNetworkQuality(
            val deviceId: String
        ) : NetworkDiagnostics()
    }
}