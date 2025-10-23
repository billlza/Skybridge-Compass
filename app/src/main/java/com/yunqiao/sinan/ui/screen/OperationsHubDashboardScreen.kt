package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.operationshub.manager.*
import com.yunqiao.sinan.operationshub.model.*
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.launch

/**
 * 运营中枢界面
 */
@Composable
fun OperationsHubDashboardScreen(
    modifier: Modifier = Modifier,
    onNavigate: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val operationsHubManager = remember { OperationsHubManager(context) }
    val scope = rememberCoroutineScope()
    
    var isInitialized: Boolean by remember { mutableStateOf(false) }
    val hubStatus: OperationsHubStatus by operationsHubManager.hubStatus.collectAsState()
    val overallStats: OperationsHubOverallStatistics by operationsHubManager.overallStatistics.collectAsState()
    
    // 初始化运营枢纽
    LaunchedEffect(Unit) {
        if (!isInitialized) {
            isInitialized = operationsHubManager.initialize()
        }
    }
    
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp)
    ) {
        // 标题区域
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "运营中枢",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    text = "高级功能管理中心",
                    fontSize = 14.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            
            // 状态指示器
            StatusIndicator(status = hubStatus)
        }
        
        Spacer(modifier = Modifier.height(32.dp))
        
        if (isInitialized) {
            // 功能概览卡片
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // 系统监控卡片
                item {
                    SystemMonitorCard(
                        manager = operationsHubManager.systemMonitorManager,
                        onClick = { onNavigate("system_monitor") }
                    )
                }
                
                // 远程桌面卡片
                item {
                    RemoteDesktopCard(
                        manager = operationsHubManager.remoteDesktopManager,
                        onClick = { onNavigate("remote_desktop") }
                    )
                }
                
                // 文件传输卡片
                item {
                    FileTransferCard(
                        manager = operationsHubManager.fileTransferManager,
                        onClick = { onNavigate("file_transfer") }
                    )
                }
                
                // 设备发现卡片
                item {
                    DeviceDiscoveryCard(
                        service = operationsHubManager.deviceDiscoveryService,
                        onClick = { onNavigate("device_discovery") }
                    )
                }
                
                // 诊断和优化卡片
                item {
                    DiagnosticCard(
                        operationsHubManager = operationsHubManager,
                        onClick = { onNavigate("system_monitor") }
                    )
                }
            }
        } else {
            // 初始化中或失败状态
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                when (hubStatus) {
                    OperationsHubStatus.INITIALIZING -> {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            CircularProgressIndicator(
                                color = Color.Cyan
                            )
                            Spacer(modifier = Modifier.height(16.dp))
                            Text(
                                text = "正在初始化运营枢纽...",
                                color = Color.White
                            )
                        }
                    }
                    OperationsHubStatus.ERROR -> {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(
                                imageVector = Icons.Default.Error,
                                contentDescription = null,
                                tint = Color.Red,
                                modifier = Modifier.size(48.dp)
                            )
                            Spacer(modifier = Modifier.height(16.dp))
                            Text(
                                text = "运营枢纽初始化失败",
                                color = Color.White,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Button(
                                onClick = {
                                    scope.launch {
                                        isInitialized = operationsHubManager.initialize()
                                    }
                                }
                            ) {
                                Text("重试")
                            }
                        }
                    }
                    else -> {
                        Text(
                            text = "运营枢纽未准备就绪",
                            color = Color.White
                        )
                    }
                }
            }
        }
    }
}

/**
 * 状态指示器
 */
@Composable
private fun StatusIndicator(status: OperationsHubStatus) {
    val (color, text) = when (status) {
        OperationsHubStatus.IDLE -> Color.Gray to "空闲"
        OperationsHubStatus.INITIALIZING -> Color.Yellow to "初始化中"
        OperationsHubStatus.READY -> Color.Green to "就绪"
        OperationsHubStatus.BUSY -> Color.Magenta to "忙碌"
        OperationsHubStatus.ERROR -> Color.Red to "错误"
    }
    
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(
            modifier = Modifier
                .size(12.dp)
                .background(color, shape = RoundedCornerShape(6.dp))
        )
        Text(
            text = text,
            color = Color.White,
            fontSize = 14.sp
        )
    }
}

/**
 * 功能卡片基础组件
 */
@Composable
private fun FeatureCard(
    title: String,
    icon: ImageVector,
    status: String,
    statusColor: Color,
    content: @Composable ColumnScope.() -> Unit,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                color = GlassColors.background,
                shape = RoundedCornerShape(12.dp)
            ),
        onClick = onClick,
        colors = CardDefaults.cardColors(
            containerColor = Color.Transparent
        )
    ) {
        Column(
            modifier = Modifier.padding(20.dp)
        ) {
            // 标题行
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = Color.Cyan,
                        modifier = Modifier.size(24.dp)
                    )
                    Text(
                        text = title,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Medium,
                        color = Color.White
                    )
                }
                
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(statusColor, shape = RoundedCornerShape(4.dp))
                    )
                    Text(
                        text = status,
                        fontSize = 12.sp,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 内容区域
            content()
        }
    }
}

/**
 * 系统监控卡片
 */
@Composable
private fun SystemMonitorCard(
    manager: SystemMonitorManager,
    onClick: () -> Unit
) {
    val systemPerf: SystemPerformance by manager.systemPerformance.collectAsState()
    
    FeatureCard(
        title = "系统监控",
        icon = Icons.Default.Monitor,
        status = if (systemPerf.timestamp > 0) "运行中" else "离线",
        statusColor = if (systemPerf.timestamp > 0) Color.Green else Color.Gray,
        content = {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceAround
            ) {
                MetricItem(
                    label = "CPU",
                    value = "${(systemPerf.cpuUsage * 100).toInt()}%",
                    color = if (systemPerf.cpuUsage > 0.8f) Color.Red else Color.Green
                )
                MetricItem(
                    label = "内存",
                    value = "${(systemPerf.memoryUsage * 100).toInt()}%",
                    color = if (systemPerf.memoryUsage > 0.85f) Color.Red else Color.Green
                )
                MetricItem(
                    label = "存储",
                    value = "${(systemPerf.storageUsage * 100).toInt()}%",
                    color = if (systemPerf.storageUsage > 0.9f) Color.Red else Color.Green
                )
                systemPerf.batteryLevel?.let { battery: Int ->
                    MetricItem(
                        label = "电池",
                        value = "$battery%",
                        color = if (battery < 20) Color.Red else Color.Green
                    )
                }
            }
        },
        onClick = onClick
    )
}

/**
 * 远程桌面卡片
 */
@Composable
private fun RemoteDesktopCard(
    manager: RemoteDesktopManager,
    onClick: () -> Unit
) {
    val activeSessions: List<RemoteSession> by manager.activeSessions.collectAsState()
    val connectionStatus: RemoteConnectionStatus by manager.connectionStatus.collectAsState()
    
    FeatureCard(
        title = "远程桌面",
        icon = Icons.Default.Computer,
        status = connectionStatus.name,
        statusColor = when (connectionStatus) {
            RemoteConnectionStatus.CONNECTED, RemoteConnectionStatus.STREAMING -> Color.Green
            RemoteConnectionStatus.CONNECTING -> Color.Yellow
            RemoteConnectionStatus.ERROR -> Color.Red
            else -> Color.Gray
        },
        content = {
            Column {
                Text(
                    text = "活跃会话: ${activeSessions.size}",
                    color = Color.White,
                    fontSize = 14.sp
                )
                if (activeSessions.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(8.dp))
                    activeSessions.take(3).forEach { session ->
                        Text(
                            text = "• ${session.deviceName}",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 12.sp
                        )
                    }
                }
            }
        },
        onClick = onClick
    )
}

/**
 * 文件传输卡片
 */
@Composable
private fun FileTransferCard(
    manager: FileTransferManager,
    onClick: () -> Unit
) {
    val transferStats: FileTransferStatistics by manager.transferStatistics.collectAsState()
    
    FeatureCard(
        title = "文件传输",
        icon = Icons.Default.CloudUpload,
        status = if (transferStats.activeTasks > 0) "传输中" else "空闲",
        statusColor = if (transferStats.activeTasks > 0) Color.Green else Color.Gray,
        content = {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceAround
            ) {
                MetricItem(
                    label = "活跃任务",
                    value = "${transferStats.activeTasks}",
                    color = Color.Cyan
                )
                MetricItem(
                    label = "已完成",
                    value = "${transferStats.completedTasks}",
                    color = Color.Green
                )
                MetricItem(
                    label = "失败",
                    value = "${transferStats.failedTasks}",
                    color = if (transferStats.failedTasks > 0) Color.Red else Color.Gray
                )
            }
        },
        onClick = onClick
    )
}

/**
 * 设备发现卡片
 */
@Composable
private fun DeviceDiscoveryCard(
    service: com.yunqiao.sinan.operationshub.service.DeviceDiscoveryService,
    onClick: () -> Unit
) {
    val discoveredDevices: List<DiscoveredDevice> by service.discoveredDevices.collectAsState()
    val discoveryStatus: DiscoveryStatus by service.discoveryStatus.collectAsState()
    
    FeatureCard(
        title = "设备发现",
        icon = Icons.Default.DeviceHub,
        status = discoveryStatus.name,
        statusColor = when (discoveryStatus) {
            DiscoveryStatus.SCANNING -> Color.Yellow
            DiscoveryStatus.COMPLETED -> Color.Green
            DiscoveryStatus.ERROR -> Color.Red
            else -> Color.Gray
        },
        content = {
            Column {
                Text(
                    text = "发现设备: ${discoveredDevices.size}",
                    color = Color.White,
                    fontSize = 14.sp
                )
                if (discoveredDevices.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(8.dp))
                    val devicesByType = discoveredDevices.groupBy { it.deviceType }
                    devicesByType.forEach { (type, devices) ->
                        Text(
                            text = "• ${type.name}: ${devices.size}",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 12.sp
                        )
                    }
                }
            }
        },
        onClick = onClick
    )
}

/**
 * 诊断卡片
 */
@Composable
private fun DiagnosticCard(
    operationsHubManager: OperationsHubManager,
    onClick: () -> Unit
) {
    var diagnosticResult: OperationsHubDiagnosticResult? by remember { mutableStateOf<OperationsHubDiagnosticResult?>(null) }
    val scope = rememberCoroutineScope()
    
    FeatureCard(
        title = "系统诊断",
        icon = Icons.Default.HealthAndSafety,
        status = diagnosticResult?.overallStatus?.name ?: "未检查",
        statusColor = when (diagnosticResult?.overallStatus) {
            DiagnosticStatus.HEALTHY -> Color.Green
            DiagnosticStatus.WARNING -> Color.Yellow
            DiagnosticStatus.ERROR -> Color.Red
            DiagnosticStatus.UNKNOWN -> Color.Gray
            null -> Color.Gray
        },
        content = {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Button(
                        onClick = {
                            scope.launch {
                                diagnosticResult = operationsHubManager.performComprehensiveDiagnostic()
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color.Cyan.copy(alpha = 0.2f)
                        )
                    ) {
                        Text("运行诊断", color = Color.White)
                    }
                    
                    diagnosticResult?.let { result: OperationsHubDiagnosticResult ->
                        Text(
                            text = "健康分数: ${(result.overallScore * 100).toInt()}%",
                            color = Color.White,
                            fontSize = 14.sp
                        )
                    }
                }
                
                diagnosticResult?.let { result: OperationsHubDiagnosticResult ->
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "检测到 ${result.components.size} 个组件",
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 12.sp
                    )
                }
            }
        },
        onClick = onClick
    )
}

/**
 * 指标项组件
 */
@Composable
private fun MetricItem(
    label: String,
    value: String,
    color: Color
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = value,
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = color
        )
        Text(
            text = label,
            fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
    }
}
