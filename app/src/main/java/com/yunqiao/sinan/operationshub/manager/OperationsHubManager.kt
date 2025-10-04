package com.yunqiao.sinan.operationshub.manager

import android.content.Context
import com.yunqiao.sinan.manager.BridgeConnectionCoordinator
import com.yunqiao.sinan.operationshub.model.*
import com.yunqiao.sinan.operationshub.service.DeviceDiscoveryService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 运营枢纽主管理器
 * 负责统一管理所有运营枢纽功能模块
 */
class OperationsHubManager(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    // 状态管理
    private val _hubStatus = MutableStateFlow(OperationsHubStatus.IDLE)
    val hubStatus: StateFlow<OperationsHubStatus> = _hubStatus.asStateFlow()
    
    private val _overallStatistics = MutableStateFlow(OperationsHubOverallStatistics())
    val overallStatistics: StateFlow<OperationsHubOverallStatistics> = _overallStatistics.asStateFlow()
    
    // 子管理器和服务
    val systemMonitorManager = SystemMonitorManager(context)
    val remoteDesktopManager = RemoteDesktopManager(context)
    val fileTransferManager = FileTransferManager(context)
    val deviceDiscoveryService = DeviceDiscoveryService(context)
    private val bridgeCoordinator = BridgeConnectionCoordinator(context)
    
    private var isInitialized = false
    private val startTime = System.currentTimeMillis()
    
    /**
     * 初始化运营枢纽系统 - 带依赖检查和错误恢复
     */
    suspend fun initialize(): Boolean {
        if (isInitialized) {
            return true
        }
        
        return try {
            _hubStatus.value = OperationsHubStatus.INITIALIZING
            
            // 依赖检查阶段
            val dependencyCheckResults = performDependencyChecks()
            if (!dependencyCheckResults.all { it.value }) {
                _hubStatus.value = OperationsHubStatus.ERROR
                // 记录失败的依赖
                val failedDeps = dependencyCheckResults.filter { !it.value }.keys
                println("OperationsHubManager: 依赖检查失败: $failedDeps")
                return false
            }
            
            // 分阶段初始化各个子系统
            val initResults = mutableMapOf<String, Boolean>()
            
            // 第一阶段：初始化基础系统
            initResults["SystemMonitor"] = initializeSystemMonitorSafely()
            delay(200) // 给系统监控时间初始化
            
            // 第二阶段：初始化设备发现（不依赖其他系统）
            initResults["DeviceDiscovery"] = initializeDeviceDiscoverySafely()
            delay(200)
            
            // 第三阶段：初始化文件传输（依赖设备发现）
            initResults["FileTransfer"] = initializeFileTransferSafely()
            delay(200)
            
            // 第四阶段：初始化远程桌面（依赖系统监控和文件传输）
            initResults["RemoteDesktop"] = initializeRemoteDesktopSafely()
            delay(200)
            
            // 评估初始化结果
            val successCount = initResults.values.count { it }
            val totalCount = initResults.size
            
            when {
                successCount == totalCount -> {
                    _hubStatus.value = OperationsHubStatus.READY
                    isInitialized = true
                    startStatisticsMonitoring()
                    true
                }
                successCount >= totalCount / 2 -> {
                    // 部分成功，进入降级模式
                    _hubStatus.value = OperationsHubStatus.READY
                    isInitialized = true
                    startStatisticsMonitoring()
                    println("OperationsHubManager: 部分初始化成功，进入降级模式")
                    true
                }
                else -> {
                    _hubStatus.value = OperationsHubStatus.ERROR
                    // 记录失败的组件
                    val failedComponents = initResults.filter { !it.value }.keys
                    println("OperationsHubManager: 初始化失败的组件: $failedComponents")
                    false
                }
            }
        } catch (e: Exception) {
            _hubStatus.value = OperationsHubStatus.ERROR
            e.printStackTrace()
            false
        }
    }
    
    /**
     * 执行依赖检查
     */
    private suspend fun performDependencyChecks(): Map<String, Boolean> {
        val checks = mutableMapOf<String, Boolean>()
        
        try {
            // 检查Context是否可用
            checks["Context"] = context != null
            
            // 检查系统服务可用性
            checks["ActivityManager"] = try {
                context.getSystemService(Context.ACTIVITY_SERVICE) != null
            } catch (e: Exception) {
                false
            }
            
            // 检查网络可用性
            checks["ConnectivityManager"] = try {
                context.getSystemService(Context.CONNECTIVITY_SERVICE) != null
            } catch (e: Exception) {
                false
            }
            
            // 检查存储可用性
            checks["Storage"] = try {
                context.filesDir != null && context.filesDir.exists()
            } catch (e: Exception) {
                false
            }
            
            // 检查权限状态
            checks["BasicPermissions"] = try {
                // 基本的网络权限检查
                context.checkSelfPermission(android.Manifest.permission.INTERNET) == 
                android.content.pm.PackageManager.PERMISSION_GRANTED
            } catch (e: Exception) {
                false
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
        
        return checks
    }
    
    /**
     * 关闭运营枢纽系统
     */
    fun shutdown() {
        try {
            _hubStatus.value = OperationsHubStatus.BUSY
            
            // 关闭所有子系统
            systemMonitorManager.cleanup()
            remoteDesktopManager.cleanup()
            fileTransferManager.cleanup()
            deviceDiscoveryService.cleanup()
            bridgeCoordinator.release()

            _hubStatus.value = OperationsHubStatus.IDLE
            isInitialized = false
        } catch (e: Exception) {
            _hubStatus.value = OperationsHubStatus.ERROR
        }
    }
    
    /**
     * 重新启动运营枢纽系统
     */
    suspend fun restart(): Boolean {
        shutdown()
        delay(1000) // 等待系统完全关闭
        return initialize()
    }
    
    /**
     * 获取系统状态概览
     */
    fun getSystemOverview(): Map<String, Any> {
        val currentStats = _overallStatistics.value
        return mapOf(
            "status" to _hubStatus.value.name,
            "uptime" to (System.currentTimeMillis() - startTime),
            "processedTasks" to currentStats.processedTasks,
            "failedTasks" to currentStats.failedTasks,
            "activeConnections" to currentStats.activeConnections,
            "systemLoad" to currentStats.systemLoad,
            "memoryUsage" to currentStats.memoryUsage,
            "isInitialized" to isInitialized
        )
    }
    
    /**
     * 执行综合诊断
     */
    suspend fun performComprehensiveDiagnostic(): OperationsHubDiagnosticResult {
        _hubStatus.value = OperationsHubStatus.BUSY
        
        return try {
            val diagnosticStartTime = System.currentTimeMillis()
            val components = mutableListOf<ComponentDiagnostic>()
            
            // 诊断系统监控
            components.add(diagnoseSystemMonitor())
            delay(200)
            
            // 诊断远程桌面
            components.add(diagnoseRemoteDesktop())
            delay(200)
            
            // 诊断文件传输
            components.add(diagnoseFileTransfer())
            delay(200)
            
            // 诊断设备发现
            components.add(diagnoseDeviceDiscovery())
            delay(200)
            
            // 诊断网络连接
            components.add(diagnoseNetworkConnectivity())
            delay(200)
            
            // 计算总体分数
            val overallScore = components.map { it.score }.average().toFloat()
            val overallStatus = when {
                overallScore >= 0.8f -> DiagnosticStatus.HEALTHY
                overallScore >= 0.6f -> DiagnosticStatus.WARNING
                else -> DiagnosticStatus.ERROR
            }
            
            val diagnosticDuration = System.currentTimeMillis() - diagnosticStartTime
            
            // 生成建议
            val recommendations = generateRecommendations(components)
            
            val result = OperationsHubDiagnosticResult(
                overallStatus = overallStatus,
                overallScore = overallScore,
                components = components,
                diagnosticDuration = diagnosticDuration,
                recommendations = recommendations
            )
            
            _hubStatus.value = OperationsHubStatus.READY
            result
            
        } catch (e: Exception) {
            _hubStatus.value = OperationsHubStatus.ERROR
            OperationsHubDiagnosticResult(
                overallStatus = DiagnosticStatus.ERROR,
                overallScore = 0f,
                components = listOf(
                    ComponentDiagnostic(
                        componentName = "Diagnostic System",
                        status = DiagnosticStatus.ERROR,
                        score = 0f,
                        errorMessage = e.message
                    )
                )
            )
        }
    }
    
    /**
     * 安全初始化系统监控 - 带错误恢复
     */
    private suspend fun initializeSystemMonitorSafely(): Boolean {
        return try {
            systemMonitorManager.startMonitoring()
            delay(500)
            // 验证是否初始化成功
            systemMonitorManager.systemPerformance.value != null
        } catch (e: SecurityException) {
            println("SystemMonitor: 权限不足 - ${e.message}")
            false
        } catch (e: Exception) {
            println("SystemMonitor: 初始化失败 - ${e.message}")
            false
        }
    }
    
    /**
     * 安全初始化远程桌面
     */
    private suspend fun initializeRemoteDesktopSafely(): Boolean {
        return try {
            // 检查前置条件：系统监控是否可用
            val systemMonitorAvailable = try {
                systemMonitorManager.systemPerformance.value != null
            } catch (e: Exception) {
                false
            }
            
            if (!systemMonitorAvailable) {
                println("RemoteDesktop: 系统监控不可用，跳过初始化")
                return false
            }
            
            remoteDesktopManager.initialize()
        } catch (e: Exception) {
            println("RemoteDesktop: 初始化失败 - ${e.message}")
            false
        }
    }
    
    /**
     * 安全初始化文件传输
     */
    private suspend fun initializeFileTransferSafely(): Boolean {
        return try {
            // 检查前置条件：设备发现是否可用
            val deviceDiscoveryAvailable = try {
                deviceDiscoveryService.discoveredDevices.value != null
            } catch (e: Exception) {
                false
            }
            
            fileTransferManager.initialize()
        } catch (e: Exception) {
            println("FileTransfer: 初始化失败 - ${e.message}")
            false
        }
    }
    
    /**
     * 安全初始化设备发现
     */
    private suspend fun initializeDeviceDiscoverySafely(): Boolean {
        return try {
            deviceDiscoveryService.initialize()
        } catch (e: SecurityException) {
            println("DeviceDiscovery: 权限不足 - ${e.message}")
            // 即使权限不足，也认为初始化成功（降级模式）
            true
        } catch (e: Exception) {
            println("DeviceDiscovery: 初始化失败 - ${e.message}")
            false
        }
    }
    
    /**
     * 错误恢复 - 尝试重新初始化失败的组件
     */
    suspend fun attemptErrorRecovery(): Boolean {
        if (_hubStatus.value != OperationsHubStatus.ERROR) {
            return true
        }
        
        _hubStatus.value = OperationsHubStatus.BUSY
        
        return try {
            // 逐个检查和恢复组件
            var recoverySuccess = true
            
            // 恢复系统监控
            if (!isSystemMonitorHealthy()) {
                recoverySuccess = initializeSystemMonitorSafely() && recoverySuccess
            }
            
            // 恢复设备发现
            if (!isDeviceDiscoveryHealthy()) {
                recoverySuccess = initializeDeviceDiscoverySafely() && recoverySuccess
            }
            
            // 恢复文件传输
            if (!isFileTransferHealthy()) {
                recoverySuccess = initializeFileTransferSafely() && recoverySuccess
            }
            
            // 恢复远程桌面
            if (!isRemoteDesktopHealthy()) {
                recoverySuccess = initializeRemoteDesktopSafely() && recoverySuccess
            }
            
            if (recoverySuccess) {
                _hubStatus.value = OperationsHubStatus.READY
                if (!isInitialized) {
                    isInitialized = true
                    startStatisticsMonitoring()
                }
            } else {
                _hubStatus.value = OperationsHubStatus.ERROR
            }
            
            recoverySuccess
        } catch (e: Exception) {
            _hubStatus.value = OperationsHubStatus.ERROR
            e.printStackTrace()
            false
        }
    }
    
    /**
     * 检查各个组件的健康状态
     */
    private fun isSystemMonitorHealthy(): Boolean {
        return try {
            systemMonitorManager.systemPerformance.value != null
        } catch (e: Exception) {
            false
        }
    }
    
    private fun isDeviceDiscoveryHealthy(): Boolean {
        return try {
            deviceDiscoveryService.discoveredDevices.value != null
        } catch (e: Exception) {
            false
        }
    }
    
    private fun isFileTransferHealthy(): Boolean {
        return try {
            fileTransferManager.transferStatistics.value != null
        } catch (e: Exception) {
            false
        }
    }
    
    private fun isRemoteDesktopHealthy(): Boolean {
        return try {
            val serverStatus = remoteDesktopManager.getServerStatus()
            val isRunning = serverStatus["isRunning"] as? Boolean ?: false
            val connectionStatus = remoteDesktopManager.connectionStatus.value
            isRunning && connectionStatus != RemoteConnectionStatus.ERROR
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 开始统计信息监控
     */
    private fun startStatisticsMonitoring() {
        scope.launch {
            while (isInitialized) {
                try {
                    updateOverallStatistics()
                    delay(5000) // 每5秒更新一次
                } catch (e: Exception) {
                    // 在实际使用中应该记录日志
                    delay(10000)
                }
            }
        }
    }
    
    /**
     * 更新总体统计信息
     */
    private fun updateOverallStatistics() {
        val fileTransferStats = fileTransferManager.transferStatistics.value
        val systemPerf = systemMonitorManager.systemPerformance.value
        val activeSessions = remoteDesktopManager.activeSessions.value
        val serverStatus = remoteDesktopManager.getServerStatus()
        val linkQuality = bridgeCoordinator.linkQuality.value

        val currentTime = System.currentTimeMillis()
        val uptime = currentTime - startTime

        val connectedSessions = activeSessions.count {
            it.status == RemoteConnectionStatus.CONNECTED || it.status == RemoteConnectionStatus.STREAMING
        }
        val remoteDesktopBytes = (serverStatus["totalBytesTransmitted"] as? Number)?.toLong() ?: 0L
        val totalTransferredBytes = fileTransferStats.totalDataTransferred * 1024 * 1024 + remoteDesktopBytes

        _overallStatistics.value = OperationsHubOverallStatistics(
            uptime = uptime,
            processedTasks = fileTransferStats.completedTasks.toLong(),
            failedTasks = fileTransferStats.failedTasks.toLong(),
            activeConnections = connectedSessions,
            totalDataTransferred = totalTransferredBytes,
            systemLoad = systemPerf.cpuUsage,
            memoryUsage = (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()),
            networkLatency = linkQuality.latencyMs.toFloat(),
            networkThroughputMbps = linkQuality.throughputMbps,
            lastUpdateTime = currentTime
        )
    }
    
    /**
     * 诊断系统监控
     */
    private suspend fun diagnoseSystemMonitor(): ComponentDiagnostic {
        return try {
            val performance = systemMonitorManager.getCurrentPerformance()
            val score = when {
                performance.cpuUsage < 0.7f && performance.memoryUsage < 0.8f -> 1.0f
                performance.cpuUsage < 0.85f && performance.memoryUsage < 0.9f -> 0.7f
                else -> 0.4f
            }
            
            ComponentDiagnostic(
                componentName = "System Monitor",
                status = if (score >= 0.7f) DiagnosticStatus.HEALTHY else DiagnosticStatus.WARNING,
                score = score,
                details = "CPU: ${(performance.cpuUsage * 100).toInt()}%, Memory: ${(performance.memoryUsage * 100).toInt()}%"
            )
        } catch (e: Exception) {
            ComponentDiagnostic(
                componentName = "System Monitor",
                status = DiagnosticStatus.ERROR,
                score = 0f,
                errorMessage = e.message
            )
        }
    }
    
    /**
     * 诊断远程桌面
     */
    private suspend fun diagnoseRemoteDesktop(): ComponentDiagnostic {
        return try {
            val sessions = remoteDesktopManager.activeSessions.value
            val serverStatus = remoteDesktopManager.getServerStatus()
            val totalSessions = sessions.size
            val streamingSessions = sessions.count { it.status == RemoteConnectionStatus.STREAMING }
            val connectedSessions = sessions.count {
                it.status == RemoteConnectionStatus.CONNECTED || it.status == RemoteConnectionStatus.STREAMING
            }
            val averageFps = (serverStatus["averageFps"] as? Number)?.toFloat() ?: 0f
            val averageBitrate = (serverStatus["averageBitrate"] as? Number)?.toFloat() ?: 0f
            val streamingRatio = if (totalSessions == 0) 0f else streamingSessions.toFloat() / totalSessions.toFloat()

            val score = when {
                totalSessions == 0 -> 0.6f
                streamingRatio >= 0.75f && averageFps >= 55f -> 0.95f
                streamingRatio >= 0.5f && averageFps >= 45f -> 0.75f
                streamingRatio >= 0.3f -> 0.55f
                else -> 0.3f
            }

            ComponentDiagnostic(
                componentName = "Remote Desktop",
                status = when {
                    score >= 0.85f -> DiagnosticStatus.HEALTHY
                    score >= 0.6f -> DiagnosticStatus.WARNING
                    else -> DiagnosticStatus.ERROR
                },
                score = score,
                details = "Sessions: $connectedSessions/$totalSessions · Streaming: $streamingSessions · FPS: ${averageFps.toInt()} · Bitrate: ${averageBitrate.toInt()} kbps"
            )
        } catch (e: Exception) {
            ComponentDiagnostic(
                componentName = "Remote Desktop",
                status = DiagnosticStatus.ERROR,
                score = 0f,
                errorMessage = e.message
            )
        }
    }
    
    /**
     * 诊断文件传输
     */
    private suspend fun diagnoseFileTransfer(): ComponentDiagnostic {
        return try {
            val stats = fileTransferManager.transferStatistics.value
            val totalTasks = stats.completedTasks + stats.failedTasks
            
            val score = if (totalTasks == 0) {
                0.9f // 没有任务时认为正常
            } else {
                stats.completedTasks.toFloat() / totalTasks.toFloat()
            }
            
            ComponentDiagnostic(
                componentName = "File Transfer",
                status = when {
                    score >= 0.8f -> DiagnosticStatus.HEALTHY
                    score >= 0.6f -> DiagnosticStatus.WARNING
                    else -> DiagnosticStatus.ERROR
                },
                score = score,
                details = "Active: ${stats.activeTasks}, Completed: ${stats.completedTasks}, Failed: ${stats.failedTasks}"
            )
        } catch (e: Exception) {
            ComponentDiagnostic(
                componentName = "File Transfer",
                status = DiagnosticStatus.ERROR,
                score = 0f,
                errorMessage = e.message
            )
        }
    }
    
    /**
     * 诊断设备发现
     */
    private suspend fun diagnoseDeviceDiscovery(): ComponentDiagnostic {
        return try {
            val devices = deviceDiscoveryService.discoveredDevices.value
            val onlineDevices = devices.count { it.isOnline }
            
            val score = when {
                devices.isEmpty() -> 0.5f
                onlineDevices == 0 -> 0.3f
                else -> (onlineDevices.toFloat() / devices.size.toFloat()).coerceAtLeast(0.1f)
            }
            
            ComponentDiagnostic(
                componentName = "Device Discovery",
                status = when {
                    score >= 0.6f -> DiagnosticStatus.HEALTHY
                    score >= 0.3f -> DiagnosticStatus.WARNING
                    else -> DiagnosticStatus.ERROR
                },
                score = score,
                details = "Total devices: ${devices.size}, Online: $onlineDevices"
            )
        } catch (e: Exception) {
            ComponentDiagnostic(
                componentName = "Device Discovery",
                status = DiagnosticStatus.ERROR,
                score = 0f,
                errorMessage = e.message
            )
        }
    }
    
    /**
     * 诊断网络连接
     */
    private suspend fun diagnoseNetworkConnectivity(): ComponentDiagnostic {
        return try {
            val quality = bridgeCoordinator.linkQuality.value
            val latency = quality.latencyMs.toFloat()
            val throughput = quality.throughputMbps
            val score = when {
                quality.supportsLossless && quality.isDirect -> 1.0f
                latency < 50f && throughput > 320f -> 0.85f
                latency < 80f && throughput > 160f -> 0.7f
                latency < 120f && throughput > 80f -> 0.55f
                else -> 0.35f
            }

            ComponentDiagnostic(
                componentName = "Network Connectivity",
                status = when {
                    score >= 0.8f -> DiagnosticStatus.HEALTHY
                    score >= 0.6f -> DiagnosticStatus.WARNING
                    else -> DiagnosticStatus.ERROR
                },
                score = score,
                details = "Latency: ${latency.toInt()}ms · Throughput: ${throughput.toInt()} Mbps · Transport: ${quality.hint}"
            )
        } catch (e: Exception) {
            ComponentDiagnostic(
                componentName = "Network Connectivity",
                status = DiagnosticStatus.ERROR,
                score = 0f,
                errorMessage = e.message
            )
        }
    }
    
    /**
     * 生成建议
     */
    private fun generateRecommendations(components: List<ComponentDiagnostic>): List<String> {
        val recommendations = mutableListOf<String>()
        
        components.forEach { component ->
            when (component.status) {
                DiagnosticStatus.WARNING -> {
                    when (component.componentName) {
                        "System Monitor" -> recommendations.add("建议关闭不必要的应用程序以释放系统资源")
                        "Remote Desktop" -> recommendations.add("检查远程桌面连接设置和网络稳定性")
                        "File Transfer" -> recommendations.add("检查网络连接和目标设备可用性")
                        "Device Discovery" -> recommendations.add("检查网络配置和设备电源状态")
                        "Network Connectivity" -> recommendations.add("检查网络连接质量和路由器设置")
                    }
                }
                DiagnosticStatus.ERROR -> {
                    when (component.componentName) {
                        "System Monitor" -> recommendations.add("系统监控有严重问题，建议重启服务")
                        "Remote Desktop" -> recommendations.add("远程桌面服务异常，建议检查系统日志")
                        "File Transfer" -> recommendations.add("文件传输服务故障，建议检查存储空间和权限设置")
                        "Device Discovery" -> recommendations.add("设备发现服务不可用，建议检查网络权限")
                        "Network Connectivity" -> recommendations.add("网络连接有问题，建议检查网络设备和配置")
                    }
                }
                else -> {}
            }
        }
        
        if (recommendations.isEmpty()) {
            recommendations.add("系统运行状态良好，无需额外操作")
        }
        
        return recommendations
    }
}
