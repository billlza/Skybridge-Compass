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
import com.yunqiao.sinan.manager.DeviceDiscoveryManager
import com.yunqiao.sinan.manager.DiscoveredDevice
import com.yunqiao.sinan.ui.theme.GlassColors
import java.text.SimpleDateFormat
import java.util.*

@Composable
fun DeviceDiscoveryScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val deviceDiscovery = remember { DeviceDiscoveryManager(context) }
    val discoveredDevices by deviceDiscovery.discoveredDevices.collectAsStateWithLifecycle()
    
    // 启动设备发现
    LaunchedEffect(Unit) {
        deviceDiscovery.startDiscovery()
    }
    
    // 清理资源
    DisposableEffect(Unit) {
        onDispose {
            deviceDiscovery.stopDiscovery()
        }
    }
    
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
            // 标题和统计
            DeviceDiscoveryHeader(discoveredDevices.size)
        }
        
        item {
            // 发现协议状态
            DiscoveryProtocolStatus()
        }
        
        if (discoveredDevices.isNotEmpty()) {
            item {
                Text(
                    text = "发现的设备",
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
            }
            
            items(discoveredDevices) { device ->
                DeviceCard(device = device)
            }
        } else {
            item {
                // 空状态
                EmptyDeviceState()
            }
        }
    }
}

@Composable
private fun DeviceDiscoveryHeader(deviceCount: Int) {
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
                    text = "设备发现",
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    text = "扫描局域网设备",
                    fontSize = 14.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            
            Column(
                horizontalAlignment = Alignment.End
            ) {
                Text(
                    text = "$deviceCount",
                    fontSize = 32.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFF00E5FF)
                )
                Text(
                    text = "设备发现",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
        }
    }
}

@Composable
private fun DiscoveryProtocolStatus() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "发现协议状态",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                ProtocolStatusItem("网络扫描", Icons.Default.Wifi, true)
                ProtocolStatusItem("蓝牙", Icons.Default.Bluetooth, true)
                ProtocolStatusItem("UPnP", Icons.Default.Router, true)
                ProtocolStatusItem("mDNS", Icons.Default.Dns, true)
            }
        }
    }
}

@Composable
private fun ProtocolStatusItem(
    name: String,
    icon: ImageVector,
    isActive: Boolean
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (isActive) Color(0xFF4CAF50) else Color.Red,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = name,
            fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
        Text(
            text = if (isActive) "活跃" else "停用",
            fontSize = 10.sp,
            color = if (isActive) Color(0xFF4CAF50) else Color.Red
        )
    }
}

@Composable
private fun DeviceCard(device: DiscoveredDevice) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = device.deviceName,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                    
                    Text(
                        text = device.deviceType,
                        fontSize = 14.sp,
                        color = Color(0xFF00E5FF)
                    )
                    
                    if (device.ipAddress.isNotEmpty()) {
                        Text(
                            text = "IP: ${device.ipAddress}",
                            fontSize = 12.sp,
                            color = Color.White.copy(alpha = 0.7f)
                        )
                    }
                    
                    if (device.port > 0) {
                        Text(
                            text = "端口: ${device.port}",
                            fontSize = 12.sp,
                            color = Color.White.copy(alpha = 0.7f)
                        )
                    }
                }
                
                Column(
                    horizontalAlignment = Alignment.End
                ) {
                    Icon(
                        imageVector = getDeviceIcon(device.deviceType),
                        contentDescription = null,
                        tint = Color(0xFF00E5FF),
                        modifier = Modifier.size(32.dp)
                    )
                    
                    if (device.rssi != 0) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "${device.rssi} dBm",
                            fontSize = 10.sp,
                            color = getSignalColor(device.rssi)
                        )
                    }
                }
            }
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 设备能力信息
            DeviceCapabilitiesInfo(device)
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 设备操作和状态
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.AccessTime,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.5f),
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = formatTime(device.lastSeen),
                        fontSize = 12.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
                
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = device.discoveryProtocol,
                        fontSize = 10.sp,
                        color = Color.White.copy(alpha = 0.5f)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    
                    Button(
                        onClick = { /* 连接设备 */ },
                        modifier = Modifier.height(32.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF00E5FF)
                        )
                    ) {
                        Text(
                            text = "连接",
                            fontSize = 12.sp,
                            color = Color.Black
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DeviceCapabilitiesInfo(device: DiscoveredDevice) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly
    ) {
        CapabilityItem(
            "算力",
            "${device.capabilities.computePower}",
            Icons.Default.Memory
        )
        CapabilityItem(
            "内存",
            "${device.capabilities.memoryCapacity / 1024}GB",
            Icons.Default.Storage
        )
        CapabilityItem(
            "带宽",
            "${device.capabilities.networkBandwidth}Mbps",
            Icons.Default.Speed
        )
        if (device.capabilities.aiAcceleration) {
            CapabilityItem(
                "AI",
                "支持",
                Icons.Default.Psychology
            )
        }
    }
}

@Composable
private fun CapabilityItem(
    label: String,
    value: String,
    icon: ImageVector
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color(0xFF4CAF50),
            modifier = Modifier.size(16.dp)
        )
        Text(
            text = value,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )
        Text(
            text = label,
            fontSize = 10.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
    }
}

@Composable
private fun EmptyDeviceState() {
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
                imageVector = Icons.Default.Search,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.size(64.dp)
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Text(
                text = "正在搜索设备...",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(8.dp))
            
            Text(
                text = "确保设备在同一网络下并且可被发现",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // 扫描状态指示器
                repeat(3) { index ->
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(
                                color = Color(0xFF00E5FF).copy(
                                    alpha = if ((System.currentTimeMillis() / 500) % 3 == index.toLong()) 1f else 0.3f
                                ),
                                shape = androidx.compose.foundation.shape.CircleShape
                            )
                    )
                }
            }
        }
    }
}

private fun getDeviceIcon(deviceType: String): ImageVector {
    return when (deviceType) {
        "bluetooth" -> Icons.Default.Bluetooth
        "ble" -> Icons.Default.BluetoothSearching
        "network" -> Icons.Default.Computer
        "upnp" -> Icons.Default.Router
        "mobile" -> Icons.Default.Smartphone
        "tablet" -> Icons.Default.Tablet
        "desktop" -> Icons.Default.Computer
        "smart_tv" -> Icons.Default.Tv
        else -> Icons.Default.DeviceHub
    }
}

private fun getSignalColor(rssi: Int): Color {
    return when {
        rssi > -50 -> Color(0xFF4CAF50)  // 强信号
        rssi > -70 -> Color(0xFFFFC107)  // 中等信号
        else -> Color.Red                 // 弱信号
    }
}

private fun formatTime(timestamp: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - timestamp
    
    return when {
        diff < 60000 -> "刚刚"
        diff < 3600000 -> "${diff / 60000}分钟前"
        diff < 86400000 -> "${diff / 3600000}小时前"
        else -> SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(timestamp))
    }
}