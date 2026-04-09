package com.skybridge.compass.mirroring.presentation.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.mirroring.domain.entities.MirroringSession
import com.skybridge.compass.mirroring.domain.entities.MirroringType
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.entities.CompressionLevel
import com.skybridge.compass.mirroring.domain.entities.NetworkProtocol
import com.skybridge.compass.mirroring.domain.entities.MirroringStatus
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository
import com.skybridge.compass.mirroring.domain.usecases.*
import com.skybridge.compass.mirroring.presentation.state.ScreenMirroringEvent
import com.skybridge.compass.mirroring.presentation.state.ScreenMirroringState
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

/**
 * 屏幕镜像ViewModel
 */
class ScreenMirroringViewModel(
    private val screenMirroringRepository: ScreenMirroringRepository,
    private val startMirroringUseCase: StartMirroringUseCase,
    private val stopMirroringUseCase: StopMirroringUseCase,
    private val pauseMirroringUseCase: PauseMirroringUseCase,
    private val resumeMirroringUseCase: ResumeMirroringUseCase,
    private val updateMirroringQualityUseCase: UpdateMirroringQualityUseCase,
    private val toggleAudioUseCase: ToggleAudioUseCase,
    private val reconnectSessionUseCase: ReconnectSessionUseCase,
    private val getSessionStatsUseCase: GetSessionStatsUseCase,
    private val optimizeNetworkSettingsUseCase: OptimizeNetworkSettingsUseCase
) : ViewModel() {
    
    private val _state = MutableStateFlow(ScreenMirroringState())
    val state: StateFlow<ScreenMirroringState> = _state.asStateFlow()
    
    init {
        // 监听活跃会话变化
        observeActiveSessions()
    }
    
    /**
     * 处理UI事件
     */
    fun onEvent(event: ScreenMirroringEvent) {
        when (event) {
            is ScreenMirroringEvent.StartMirroring -> startMirroring(event)
            is ScreenMirroringEvent.StopMirroring -> stopMirroring(event.sessionId)
            is ScreenMirroringEvent.PauseMirroring -> pauseMirroring(event.sessionId)
            is ScreenMirroringEvent.ResumeMirroring -> resumeMirroring(event.sessionId)
            is ScreenMirroringEvent.UpdateQuality -> updateQuality(event.sessionId, event.quality)
            is ScreenMirroringEvent.UpdateResolution -> updateResolution(event.sessionId, event.resolution)
            is ScreenMirroringEvent.UpdateFrameRate -> updateFrameRate(event.sessionId, event.frameRate)
            is ScreenMirroringEvent.UpdateBitrate -> updateBitrate(event.sessionId, event.bitrate)
            is ScreenMirroringEvent.ToggleAudio -> toggleAudio(event.sessionId, event.enableAudio)
            is ScreenMirroringEvent.UpdateCompression -> updateCompression(event.sessionId, event.compression)
            is ScreenMirroringEvent.UpdateNetworkProtocol -> updateNetworkProtocol(event.sessionId, event.protocol)
            is ScreenMirroringEvent.ReconnectSession -> reconnectSession(event.sessionId)
            is ScreenMirroringEvent.SelectSession -> selectSession(event.sessionId)
            is ScreenMirroringEvent.RefreshSessions -> refreshSessions()
            is ScreenMirroringEvent.ClearError -> clearError()
            is ScreenMirroringEvent.OptimizeSettings -> optimizeSettings(event.sessionId)
            is ScreenMirroringEvent.ViewSessionDetails -> viewSessionDetails(event.sessionId)
            is ScreenMirroringEvent.ExportSessionHistory -> exportSessionHistory()
            is ScreenMirroringEvent.ClearSessionHistory -> clearSessionHistory()
            is ScreenMirroringEvent.TestConnection -> testConnection(event.deviceId)
            is ScreenMirroringEvent.UpdateSessionFilter -> updateSessionFilter(event.filter)
            is ScreenMirroringEvent.UpdateSortOrder -> updateSortOrder(event.sortOrder)
            else -> {
                _state.value = _state.value.copy(
                    error = "未处理的事件: ${event::class.simpleName}"
                )
            }
        }
    }
    
    /**
     * 开始屏幕镜像
     */
    private fun startMirroring(event: ScreenMirroringEvent.StartMirroring) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            
            try {
                val result = startMirroringUseCase(
                    deviceId = event.deviceId,
                    mirroringType = event.sessionType,
                    quality = event.quality,
                    audioEnabled = event.enableAudio
                )
                
                result.fold(
                    onSuccess = { session ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            selectedSessionId = session.id
                        )
                    },
                    onFailure = { error ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            error = "启动镜像失败: ${error.message}"
                        )
                    }
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = "启动镜像时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 停止屏幕镜像
     */
    private fun stopMirroring(sessionId: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            
            try {
                val result = stopMirroringUseCase(sessionId)
                
                result.fold(
                    onSuccess = {
                        _state.value = _state.value.copy(
                            isLoading = false,
                            selectedSessionId = if (_state.value.selectedSessionId == sessionId) null else _state.value.selectedSessionId
                        )
                    },
                    onFailure = { error ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            error = "停止镜像失败: ${error.message}"
                        )
                    }
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = "停止镜像时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 暂停屏幕镜像
     */
    private fun pauseMirroring(sessionId: String) {
        viewModelScope.launch {
            try {
                val result = pauseMirroringUseCase(sessionId)
                
                result.onFailure { error ->
                    _state.value = _state.value.copy(
                        error = "暂停镜像失败: ${error.message}"
                    )
                }
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "暂停镜像时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 恢复屏幕镜像
     */
    private fun resumeMirroring(sessionId: String) {
        viewModelScope.launch {
            try {
                val result = resumeMirroringUseCase(sessionId)
                
                result.onFailure { error ->
                    _state.value = _state.value.copy(
                        error = "恢复镜像失败: ${error.message}"
                    )
                }
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "恢复镜像时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新镜像质量
     */
    private fun updateQuality(sessionId: String, quality: VideoQuality) {
        viewModelScope.launch {
            try {
                val result = updateMirroringQualityUseCase(sessionId, quality)
                
                result.onFailure { error ->
                    _state.value = _state.value.copy(
                        error = "更新质量失败: ${error.message}"
                    )
                }
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新质量时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新分辨率
     */
    private fun updateResolution(sessionId: String, resolution: Pair<Int, Int>) {
        viewModelScope.launch {
            try {
                // 这里应该调用相应的用例，暂时直接更新状态
                _state.value = _state.value.copy(
                    sessionStats = _state.value.sessionStats + (sessionId to mapOf(
                        "resolution" to "${resolution.first}x${resolution.second}"
                    ))
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新分辨率时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新帧率
     */
    private fun updateFrameRate(sessionId: String, frameRate: Int) {
        viewModelScope.launch {
            try {
                // 这里应该调用相应的用例，暂时直接更新状态
                _state.value = _state.value.copy(
                    sessionStats = _state.value.sessionStats + (sessionId to mapOf(
                        "frameRate" to "${frameRate}fps"
                    ))
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新帧率时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新比特率
     */
    private fun updateBitrate(sessionId: String, bitrate: Int) {
        viewModelScope.launch {
            try {
                // 这里应该调用相应的用例，暂时直接更新状态
                _state.value = _state.value.copy(
                    sessionStats = _state.value.sessionStats + (sessionId to mapOf(
                        "bitrate" to "${bitrate}bps"
                    ))
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新比特率时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 切换音频
     */
    private fun toggleAudio(sessionId: String, enableAudio: Boolean) {
        viewModelScope.launch {
            try {
                val result = toggleAudioUseCase(sessionId, enableAudio)
                
                result.onFailure { error ->
                    _state.value = _state.value.copy(
                        error = "切换音频失败: ${error.message}"
                    )
                }
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "切换音频时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新压缩方式
     */
    private fun updateCompression(sessionId: String, compression: CompressionLevel) {
        viewModelScope.launch {
            try {
                // 这里应该调用相应的用例，暂时直接更新状态
                _state.value = _state.value.copy(
                    sessionStats = _state.value.sessionStats + (sessionId to mapOf(
                        "compression" to compression.name
                    ))
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新压缩方式时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新网络协议
     */
    private fun updateNetworkProtocol(sessionId: String, protocol: NetworkProtocol) {
        viewModelScope.launch {
            try {
                // 这里应该调用相应的用例，暂时直接更新状态
                _state.value = _state.value.copy(
                    sessionStats = _state.value.sessionStats + (sessionId to mapOf(
                        "networkProtocol" to protocol.name
                    ))
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "更新网络协议时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 重连会话
     */
    private fun reconnectSession(sessionId: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            
            try {
                val result = reconnectSessionUseCase(sessionId)
                
                result.fold(
                    onSuccess = {
                        _state.value = _state.value.copy(isLoading = false)
                    },
                    onFailure = { error ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            error = "重连失败: ${error.message}"
                        )
                    }
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = "重连时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 选择会话
     */
    private fun selectSession(sessionId: String?) {
        _state.value = _state.value.copy(selectedSessionId = sessionId)
        
        // 如果选择了会话，获取其统计信息
        sessionId?.let { id ->
            viewModelScope.launch {
                try {
                    val stats = getSessionStatsUseCase(id)
                    _state.value = _state.value.copy(
                        sessionStats = _state.value.sessionStats + (id to (stats ?: emptyMap()))
                    )
                } catch (e: Exception) {
                    // 忽略统计信息获取错误
                }
            }
        }
    }
    
    /**
     * 刷新会话列表
     */
    private fun refreshSessions() {
        viewModelScope.launch {
            _state.value = _state.value.copy(
                lastRefreshTime = System.currentTimeMillis()
            )
        }
    }
    
    /**
     * 清除错误
     */
    private fun clearError() {
        _state.value = _state.value.copy(error = null)
    }
    
    /**
     * 优化设置
     */
    private fun optimizeSettings(sessionId: String) {
        viewModelScope.launch {
            try {
                val result = optimizeNetworkSettingsUseCase(sessionId)
                
                result.onFailure { error ->
                    _state.value = _state.value.copy(
                        error = "优化设置失败: ${error.message}"
                    )
                }
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "优化设置时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 查看会话详情
     */
    private fun viewSessionDetails(sessionId: String) {
        _state.value = _state.value.copy(
            selectedSessionId = sessionId,
            showSessionDetails = true
        )
    }
    
    /**
     * 导出会话历史
     */
    private fun exportSessionHistory() {
        viewModelScope.launch {
            try {
                // 这里应该实现导出逻辑
                _state.value = _state.value.copy(
                    error = "导出功能暂未实现"
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "导出时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 清除会话历史
     */
    private fun clearSessionHistory() {
        viewModelScope.launch {
            try {
                // 这里应该实现清除历史逻辑
                _state.value = _state.value.copy(
                    sessionHistory = emptyList()
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "清除历史时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 测试连接
     */
    private fun testConnection(deviceId: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            
            try {
                // 这里应该实现连接测试逻辑
                kotlinx.coroutines.delay(2000) // 模拟测试过程
                
                _state.value = _state.value.copy(
                    isLoading = false,
                    connectionTestResult = mapOf(
                        "deviceId" to deviceId,
                        "latency" to "${(10..100).random()}ms",
                        "bandwidth" to "${(1..10).random()}Mbps",
                        "packetLoss" to "${(0..5).random()}%",
                        "quality" to "良好"
                    )
                )
                
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = "连接测试时发生错误: ${e.message}"
                )
            }
        }
    }
    
    /**
     * 更新会话过滤器
     */
    private fun updateSessionFilter(filter: ScreenMirroringState.SessionFilter) {
        _state.value = _state.value.copy(sessionFilter = filter)
    }
    
    /**
     * 更新排序顺序
     */
    private fun updateSortOrder(sortOrder: ScreenMirroringState.SortOrder) {
        _state.value = _state.value.copy(sortOrder = sortOrder)
    }
    
    /**
     * 监听活跃会话变化
     */
    private fun observeActiveSessions() {
        viewModelScope.launch {
            // 这里应该监听仓库中的活跃会话流
            // 暂时使用模拟数据
            kotlinx.coroutines.delay(1000)
            
            _state.value = _state.value.copy(
                activeSessions = emptyList(), // 从仓库获取
                sessionHistory = emptyList()  // 从仓库获取
            )
        }
    }
    
    /**
     * 获取过滤后的会话列表
     */
    fun getFilteredSessions(): List<MirroringSession> {
        val sessions = _state.value.activeSessions
        val filter = _state.value.sessionFilter
        
        val filtered = when (filter) {
            ScreenMirroringState.SessionFilter.ALL -> sessions
            ScreenMirroringState.SessionFilter.ACTIVE -> sessions.filter { 
                it.status == MirroringStatus.STREAMING 
            }
            ScreenMirroringState.SessionFilter.PAUSED -> sessions.filter { 
                it.status == MirroringStatus.PAUSED 
            }
            ScreenMirroringState.SessionFilter.ERROR -> sessions.filter { 
                it.status == MirroringStatus.ERROR 
            }
        }
        
        return when (_state.value.sortOrder) {
            ScreenMirroringState.SortOrder.START_TIME_DESC -> filtered.sortedByDescending { it.startTime }
            ScreenMirroringState.SortOrder.START_TIME_ASC -> filtered.sortedBy { it.startTime }
            ScreenMirroringState.SortOrder.DEVICE_NAME -> filtered.sortedBy { it.deviceName }
            ScreenMirroringState.SortOrder.STATUS -> filtered.sortedBy { it.status.name }
        }
    }
}