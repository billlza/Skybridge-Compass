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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yunqiao.sinan.manager.RemoteDesktopManager
import com.yunqiao.sinan.ui.theme.GlassColors

@Composable
fun RemoteDesktopScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val remoteDesktopManager = remember { RemoteDesktopManager(context) }
    val connectionStatus by remoteDesktopManager.connectionStatus.collectAsStateWithLifecycle()
    val availableDevices by remoteDesktopManager.availableDevices.collectAsStateWithLifecycle()
    
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(
                color = Color.Transparent,
                shape = RoundedCornerShape(16.dp)
            )
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            // 远程桌面标题和状态
            RemoteDesktopHeader(connectionStatus)
        }
        
        item {
            // 连接控制面板
            ConnectionControlPanel(
                connectionStatus = connectionStatus,
                onConnect = { deviceId -> 
                    // remoteDesktopManager.connectToDevice(deviceId)
                },
                onDisconnect = {
                    // remoteDesktopManager.disconnect()
                }
            )
        }
        
        item {
            // 性能和质量设置
            QualitySettingsPanel()
        }
        
        if (availableDevices.isNotEmpty()) {
            item {
                Text(
                    text = "可用设备",
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
            }
            
            items(availableDevices) { device ->
                AvailableDeviceCard(
                    device = device,
                    onConnect = { /* remoteDesktopManager.connectToDevice(device.deviceId) */ }
                )
            }
        } else {
            item {
                // 空状态
                EmptyDevicesState()
            }
        }
    }
}

@Composable
private fun RemoteDesktopHeader(connectionStatus: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "远程桌面",
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    text = "基于WebRTC + QUIC协议",
                    fontSize = 14.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            
            Column(
                horizontalAlignment = Alignment.End
            ) {
                Icon(
                    imageVector = when (connectionStatus) {
                        "connected" -> Icons.Default.CheckCircle
                        "connecting" -> Icons.Default.Sync
                        else -> Icons.Default.RadioButtonUnchecked
                    },
                    contentDescription = null,
                    tint = when (connectionStatus) {
                        "connected" -> Color(0xFF4CAF50)
                        "connecting" -> Color(0xFFFFC107)
                        else -> Color.White.copy(alpha = 0.5f)
                    },
                    modifier = Modifier.size(32.dp)
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = when (connectionStatus) {
                        "connected" -> "已连接"
                        "connecting" -> "连接中"
                        "disconnected" -> "未连接"
                        else -> "准备就绪"
                    },
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
        }
    }
}

@Composable
private fun ConnectionControlPanel(
    connectionStatus: String,
    onConnect: (String) -> Unit,
    onDisconnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "连接控制",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                // 连接状态指示器
                ConnectionStatusItem("延迟", "15ms", Icons.Default.Timer, true)
                ConnectionStatusItem("帧率", "60fps", Icons.Default.Videocam, connectionStatus == "connected")
                ConnectionStatusItem("质量", "高清", Icons.Default.HighQuality, connectionStatus == "connected")
                ConnectionStatusItem("音频", "立体声", Icons.Default.VolumeUp, connectionStatus == "connected")
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 控制按钮
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                if (connectionStatus == "connected") {
                    Button(
                        onClick = onDisconnect,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color.Red
                        ),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("断开连接")
                    }
                } else {
                    Button(
                        onClick = { onConnect("default") },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF00E5FF)
                        ),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.PlayArrow, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("快速连接", color = Color.Black)
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionStatusItem(
    label: String,
    value: String,
    icon: ImageVector,
    isActive: Boolean
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (isActive) Color(0xFF4CAF50) else Color.White.copy(alpha = 0.3f),
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = value,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = if (isActive) Color.White else Color.White.copy(alpha = 0.5f)
        )
        Text(
            text = label,
            fontSize = 10.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
    }
}

@Composable
private fun QualitySettingsPanel() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "画质设置",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 画质选项
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                QualityOption("流畅", "720p", true)
                QualityOption("标清", "1080p", false)
                QualityOption("高清", "1440p", false)
                QualityOption("超清", "4K", false)
            }
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 编码设置
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "编码器: H.265",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
                Text(
                    text = "比特率: 自适应",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
        }
    }
}

@Composable
private fun QualityOption(
    label: String,
    resolution: String,
    isSelected: Boolean
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .background(
                    color = if (isSelected) Color(0xFF00E5FF) else Color.White.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp)
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = label,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = if (isSelected) Color.Black else Color.White
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = resolution,
            fontSize = 10.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
    }
}

@Composable
private fun AvailableDeviceCard(
    device: com.yunqiao.sinan.manager.RemoteDevice,
    onConnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(12.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = device.deviceName,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                
                Text(
                    text = if (device.isOnline) "在线" else "离线",
                    fontSize = 14.sp,
                    color = if (device.isOnline) Color(0xFF4CAF50) else Color.Red
                )
                
                Text(
                    text = "IP: ${device.ipAddress}",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            
            Button(
                onClick = onConnect,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF4CAF50)
                )
            ) {
                Text("连接", color = Color.White)
            }
        }
    }
}

@Composable
private fun EmptyDevicesState() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.Computer,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.size(64.dp)
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Text(
                text = "未发现可连接设备",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(8.dp))
            
            Text(
                text = "请确保目标设备已启动远程桌面服务",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}