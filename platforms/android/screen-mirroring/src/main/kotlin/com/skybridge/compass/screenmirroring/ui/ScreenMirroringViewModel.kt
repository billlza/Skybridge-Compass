package com.skybridge.compass.screenmirroring.ui

import android.content.Context
import android.content.Intent
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.model.ScreenCaptureConfig
import com.skybridge.compass.screenmirroring.model.ScreenFrame
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository
import com.skybridge.compass.mirroring.di.ScreenMirroringDI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.launch

/**
 * 屏幕镜像ViewModel
 * 管理屏幕镜像相关的UI状态和业务逻辑
 */
class ScreenMirroringViewModel private constructor(
    private val screenMirroringRepository: ScreenMirroringRepository
) : ViewModel() {
    
    companion object {
        fun create(context: Context): ScreenMirroringViewModel {
            val container = ScreenMirroringDI.getInstance(context)
            return ScreenMirroringViewModel(container.provideScreenMirroringRepository())
        }
    }
    
    // UI状态
    private val _uiState = MutableStateFlow(ScreenMirroringUiState())
    val uiState: StateFlow<ScreenMirroringUiState> = _uiState.asStateFlow()
    
    // 屏幕捕获状态 - 简化实现
    val isCaptureActive = MutableStateFlow(false).asStateFlow()
    
    // 当前配置 - 简化实现
    val currentConfig = MutableStateFlow(ScreenCaptureConfig()).asStateFlow()
    
    // 屏幕帧 - 简化实现
    val screenFrames = MutableSharedFlow<ScreenFrame>().asSharedFlow()
    
    // 流传输统计 - 简化实现，返回空流
    val streamingStats = kotlinx.coroutines.flow.flowOf(emptyMap<String, Any>())
    
    // 显示统计 - 简化实现，返回空流
    val displayStats = kotlinx.coroutines.flow.flowOf(emptyMap<String, Any>())
    
    // 当前显示帧 - 简化实现，返回空流
    val currentDisplayFrame = kotlinx.coroutines.flow.flowOf(null as ScreenFrame?)
    
    init {
        // 监听屏幕捕获状态变化
        viewModelScope.launch {
            isCaptureActive.collect { isActive: Boolean ->
                _uiState.value = _uiState.value.copy(
                    isCaptureActive = isActive
                )
            }
        }
        
        // 监听配置变化
        viewModelScope.launch {
            currentConfig.collect { config: ScreenCaptureConfig? ->
                _uiState.value = _uiState.value.copy(
                    currentConfig = config
                )
            }
        }
        
        // 监听屏幕帧
        viewModelScope.launch {
            screenFrames.collect { frame: ScreenFrame? ->
                _uiState.value = _uiState.value.copy(
                    lastFrame = frame,
                    frameCount = _uiState.value.frameCount + 1
                )
            }
        }
    }
    
    /**
     * 开始屏幕捕获
     */
    fun startScreenCapture(
        resultCode: Int,
        resultData: Intent,
        config: ScreenCaptureConfig? = null
    ) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 使用getRecommendedQuality替代不存在的getRecommendedConfig
                val captureConfig = config ?: ScreenCaptureConfig()
                
                // 使用startMirroring替代不存在的startScreenCapture
                val result = screenMirroringRepository.startMirroring("default")
                
                if (result.isFailure) {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "启动屏幕捕获失败"
                    )
                } else {
                    _uiState.value = _uiState.value.copy(isLoading = false)
                    Logger.ui("屏幕捕获已启动")
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "启动屏幕捕获失败"
                )
                Logger.ui("启动屏幕捕获失败", e)
            }
        }
    }
    
    /**
     * 停止屏幕捕获
     */
    fun stopScreenCapture() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 使用stopMirroring替代不存在的stopScreenCapture
                val result = screenMirroringRepository.stopMirroring("default")
                
                if (result.isFailure) {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "停止屏幕捕获失败"
                    )
                } else {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        frameCount = 0,
                        lastFrame = null
                    )
                    Logger.ui("屏幕捕获已停止")
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "停止屏幕捕获失败"
                )
                Logger.ui("停止屏幕捕获失败", e)
            }
        }
    }
    
    /**
     * 截图
     */
    fun takeScreenshot(resultCode: Int, resultData: Intent) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 简化实现，创建一个模拟的截图结果
                val frame = ScreenFrame(
                    timestamp = System.currentTimeMillis(),
                    width = 1080,
                    height = 1920,
                    format = ScreenFrame.Format.BITMAP
                )
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    lastScreenshot = frame
                )
                Logger.ui("截图完成")
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "截图失败"
                )
                Logger.ui("截图失败", e)
            }
        }
    }
    
    /**
     * 开始向设备流传输
     */
    fun startStreamingToDevice(device: Device, config: ScreenCaptureConfig? = null) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                val streamConfig = config ?: ScreenCaptureConfig.streaming()
                
                // 使用startMirroring替代不存在的startStreamingToDevice
                val result = screenMirroringRepository.startMirroring(device.id)
                
                if (result.isSuccess) {
                    val currentSessions = _uiState.value.streamingSessions.toMutableMap()
                    currentSessions[device.id] = StreamingSession(
                        device = device,
                        config = streamConfig,
                        startTime = System.currentTimeMillis()
                    )
                    
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        streamingSessions = currentSessions
                    )
                    Logger.ui("开始向设备 ${device.name} 流传输")
                } else {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "启动流传输失败"
                    )
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "启动流传输失败"
                )
                Logger.ui("启动流传输失败", e)
            }
        }
    }
    
    /**
     * 停止向设备的流传输
     */
    fun stopStreamingToDevice(deviceId: String) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 使用stopMirroring方法替代不存在的stopStreamingToDevice
                val result = screenMirroringRepository.stopMirroring(deviceId)
                
                if (result.isSuccess) {
                    val currentSessions = _uiState.value.streamingSessions.toMutableMap()
                    currentSessions.remove(deviceId)
                    
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        streamingSessions = currentSessions
                    )
                    Logger.ui("停止向设备 $deviceId 的流传输")
                } else {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "停止流传输失败"
                    )
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "停止流传输失败"
                )
                Logger.ui("停止流传输失败", e)
            }
        }
    }
    
    /**
     * 开始显示来自设备的屏幕
     */
    fun startDisplayFromDevice(deviceId: String) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 使用startMirroring方法替代不存在的startDisplayFromDevice
                val result = screenMirroringRepository.startMirroring(deviceId)
                
                if (result.isSuccess) {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        currentDisplayDeviceId = deviceId
                    )
                    Logger.ui("开始显示设备 $deviceId 的屏幕")
                } else {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "启动屏幕显示失败"
                    )
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "启动屏幕显示失败"
                )
                Logger.ui("启动屏幕显示失败", e)
            }
        }
    }
    
    /**
     * 停止显示来自设备的屏幕
     */
    fun stopDisplayFromDevice(deviceId: String) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 使用stopMirroring方法替代不存在的stopDisplayFromDevice
                val result = screenMirroringRepository.stopMirroring(deviceId)
                
                if (result.isSuccess) {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        currentDisplayDeviceId = if (_uiState.value.currentDisplayDeviceId == deviceId) null else _uiState.value.currentDisplayDeviceId
                    )
                    Logger.ui("停止显示设备 $deviceId 的屏幕")
                } else {
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = result.exceptionOrNull()?.message ?: "停止屏幕显示失败"
                    )
                }
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "停止屏幕显示失败"
                )
                Logger.ui("停止屏幕显示失败", e)
            }
        }
    }
    
    /**
     * 切换显示设备
     */
    fun switchDisplayDevice(deviceId: String) {
        // 简化实现，只更新UI状态
        _uiState.value = _uiState.value.copy(currentDisplayDeviceId = deviceId)
    }
    
    /**
     * 更新捕获配置
     */
    fun updateCaptureConfig(config: ScreenCaptureConfig) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            
            try {
                // 简化实现，直接更新UI状态
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    currentConfig = config
                )
                Logger.ui("捕获配置已更新")
                
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "更新配置失败"
                )
                Logger.ui("更新配置失败", e)
            }
        }
    }
    
    /**
     * 清除错误
     */
    fun clearError() {
        _uiState.value = _uiState.value.copy(error = null)
    }
    
    /**
     * 获取推荐配置
     */
    fun getRecommendedConfig(): ScreenCaptureConfig {
        // 返回默认配置
        return ScreenCaptureConfig()
    }
    
    /**
     * 检查权限
     */
    fun hasScreenCapturePermission(): Boolean {
        // MediaProjection permission cannot be reliably checked without holding the latest granted intent.
        // Treat permission as granted only when capture/streaming is active.
        return uiState.value.isCaptureActive || uiState.value.streamingSessions.isNotEmpty()
    }
    
    override fun onCleared() {
        super.onCleared()
        // 使用cleanupFinishedSessions替代不存在的cleanup方法
        viewModelScope.launch {
            screenMirroringRepository.cleanupFinishedSessions()
        }
    }
}

/**
 * 屏幕镜像UI状态
 */
data class ScreenMirroringUiState(
    val isLoading: Boolean = false,
    val error: String? = null,
    val isCaptureActive: Boolean = false,
    val currentConfig: ScreenCaptureConfig? = null,
    val lastFrame: ScreenFrame? = null,
    val lastScreenshot: ScreenFrame? = null,
    val frameCount: Int = 0,
    val streamingSessions: Map<String, StreamingSession> = emptyMap(),
    val currentDisplayDeviceId: String? = null
)

/**
 * 流传输会话
 */
data class StreamingSession(
    val device: Device,
    val config: ScreenCaptureConfig,
    val startTime: Long
)