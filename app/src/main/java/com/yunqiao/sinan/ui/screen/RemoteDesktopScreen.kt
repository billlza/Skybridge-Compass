package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yunqiao.sinan.manager.Android16PlatformBoost
import com.yunqiao.sinan.manager.BridgeAccountEndpoint
import com.yunqiao.sinan.manager.BridgeDevice
import com.yunqiao.sinan.manager.BridgeLinkQuality
import com.yunqiao.sinan.manager.BridgeTransport
import com.yunqiao.sinan.manager.BridgeTransportHint
import com.yunqiao.sinan.manager.ConnectionStats
import com.yunqiao.sinan.manager.RemoteDesktopManager
import com.yunqiao.sinan.manager.RemoteDesktopResolutionMode
import com.yunqiao.sinan.manager.RemoteDesktopTierProfile
import com.yunqiao.sinan.ui.component.MetricChip
import com.yunqiao.sinan.ui.component.TransportBadge
import com.yunqiao.sinan.ui.component.description
import com.yunqiao.sinan.ui.component.icon
import com.yunqiao.sinan.ui.component.label
import com.yunqiao.sinan.ui.component.portDisplay
import com.yunqiao.sinan.ui.component.tint
import com.yunqiao.sinan.ui.component.transportTintForCapability
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.launch
import java.util.Locale

@Composable
fun RemoteDesktopScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val remoteDesktopManager = remember { RemoteDesktopManager(context) }
    val connectionStatus by remoteDesktopManager.connectionStatus.collectAsStateWithLifecycle()
    val connectionStats by remoteDesktopManager.connectionStats.collectAsStateWithLifecycle()
    val transport by remoteDesktopManager.activeTransport.collectAsStateWithLifecycle()
    val proximityDevices by remoteDesktopManager.proximityDevices.collectAsStateWithLifecycle()
    val remoteAccounts by remoteDesktopManager.remoteAccountDirectory.collectAsStateWithLifecycle()
    val isProximity by remoteDesktopManager.proximityState.collectAsStateWithLifecycle()
    val linkQuality by remoteDesktopManager.linkQuality.collectAsStateWithLifecycle()
    val tierProfile by remoteDesktopManager.tierProfile.collectAsStateWithLifecycle()
    val availableModes by remoteDesktopManager.availableModes.collectAsStateWithLifecycle()
    val activeMode by remoteDesktopManager.activeMode.collectAsStateWithLifecycle()
    val coroutineScope = rememberCoroutineScope()
    var remoteAccountInput by rememberSaveable { mutableStateOf("") }

    DisposableEffect(remoteDesktopManager) {
        onDispose { remoteDesktopManager.release() }
    }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(color = Color.Transparent, shape = RoundedCornerShape(16.dp))
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            RemoteDesktopHeader(
                connectionStatus = connectionStatus,
                transport = transport,
                isProximity = isProximity,
                tierProfile = tierProfile
            )
        }

        item {
            TransportStatusCard(
                transport = transport,
                stats = connectionStats,
                linkQuality = linkQuality
            )
        }

        item {
            ConnectionControlPanel(
                connectionStatus = connectionStatus,
                stats = connectionStats,
                onDisconnect = { remoteDesktopManager.disconnect() }
            )
        }

        item {
            QualitySettingsPanel(
                profile = tierProfile,
                modes = availableModes,
                activeMode = activeMode,
                onSelectMode = { mode -> remoteDesktopManager.selectMode(mode.id) }
            )
        }

        if (proximityDevices.isNotEmpty()) {
            item {
                SectionTitle(text = "附近可直连")
            }
            items(proximityDevices) { device ->
                ProximityDeviceCard(
                    device = device,
                    onConnect = {
                        coroutineScope.launch {
                            remoteDesktopManager.connectToDevice(device.deviceId)
                        }
                    }
                )
            }
        }

        if (remoteAccounts.isNotEmpty()) {
            item {
                SectionTitle(text = "专属账号互联")
            }
            items(remoteAccounts) { account ->
                RemoteAccountCard(
                    account = account,
                    onConnect = { remoteDesktopManager.connectViaAccount(account.accountId) }
                )
            }
        }

        item {
            ManualAccountConnectBlock(
                account = remoteAccountInput,
                onAccountChange = { remoteAccountInput = it },
                onConnect = {
                    if (remoteAccountInput.isNotBlank()) {
                        remoteDesktopManager.connectViaAccount(remoteAccountInput)
                    }
                }
            )
        }

        if (proximityDevices.isEmpty() && remoteAccounts.isEmpty()) {
            item {
                EmptyDevicesState()
            }
        }
    }
}

@Composable
private fun RemoteDesktopHeader(
    connectionStatus: String,
    transport: BridgeTransport,
    isProximity: Boolean,
    tierProfile: RemoteDesktopTierProfile
) {
    val statusText = when (connectionStatus) {
        "connected" -> "已连接"
        "connecting" -> "连接中"
        "disconnected" -> "未连接"
        else -> "准备就绪"
    }
    val statusColor = when (connectionStatus) {
        "connected" -> Color(0xFF4CAF50)
        "connecting" -> Color(0xFFFFC107)
        else -> Color.White.copy(alpha = 0.6f)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "远程桌面",
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = if (isProximity) {
                            "检测到近距设备，可直接建立本地高速链路"
                        } else {
                            "智能调度WebRTC + QUIC混合引擎"
                        },
                        fontSize = 13.sp,
                        color = Color.White.copy(alpha = 0.72f)
                    )
                }

                Column(horizontalAlignment = Alignment.End) {
                    Icon(
                        imageVector = when (connectionStatus) {
                            "connected" -> Icons.Default.CheckCircle
                            "connecting" -> Icons.Default.Sync
                            else -> Icons.Default.RadioButtonUnchecked
                        },
                        contentDescription = null,
                        tint = statusColor,
                        modifier = Modifier.size(32.dp)
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = statusText,
                        fontSize = 12.sp,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                    Text(
                        text = "档位：${tierProfile.displayName}",
                        fontSize = 11.sp,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            if (Android16PlatformBoost.isAndroid16) {
                AssistChip(
                    onClick = {},
                    label = { Text(text = "Android 16 极速调优") },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Default.Speed,
                            contentDescription = null,
                            tint = Color.White
                        )
                    },
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = Color.White.copy(alpha = 0.08f),
                        labelColor = Color.White
                    )
                )
                Spacer(modifier = Modifier.height(12.dp))
            }

            TransportBadge(transport = transport)
        }
    }
}

@Composable
private fun TransportStatusCard(
    transport: BridgeTransport,
    stats: ConnectionStats,
    linkQuality: BridgeLinkQuality
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface.copy(alpha = 0.92f)),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = "链路概览",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            Spacer(modifier = Modifier.height(12.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    modifier = Modifier.size(44.dp),
                    shape = CircleShape,
                    color = transport.tint().copy(alpha = 0.2f)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = transport.icon(),
                            contentDescription = null,
                            tint = transport.tint(),
                            modifier = Modifier.size(26.dp)
                        )
                    }
                }
                Spacer(modifier = Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = transport.label(),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White
                    )
                    Text(
                        text = transport.description(),
                        fontSize = 12.sp,
                        color = Color.White.copy(alpha = 0.7f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(
                    text = "端口 ${transport.portDisplay()}",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.6f)
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                MetricChip("比特率", "${stats.bitrateKbps.toInt()} kbps", Icons.Default.Bolt)
                MetricChip("帧率", "${stats.frameRate.toInt()} fps", Icons.Default.Videocam)
                MetricChip("往返", "${stats.rttMs.toInt()} ms", Icons.Default.Timer)
            }

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                MetricChip(
                    label = "吞吐",
                    value = String.format(Locale.getDefault(), "%.0f Mbps", linkQuality.throughputMbps),
                    icon = Icons.Default.Speed
                )
                val linkLabel = when (linkQuality.hint) {
                    BridgeTransportHint.WifiDirect -> if (linkQuality.isDirect) "热点直连" else "Wi-Fi"
                    BridgeTransportHint.UltraWideband -> "液态直连"
                    BridgeTransportHint.Bluetooth -> "蓝牙链路"
                    BridgeTransportHint.Nfc -> "NFC"
                    BridgeTransportHint.AirPlay -> "AirPlay"
                    BridgeTransportHint.Lan -> "局域网"
                    BridgeTransportHint.Cloud -> "云桥中继"
                }
                val linkIcon = when (linkQuality.hint) {
                    BridgeTransportHint.WifiDirect -> Icons.Default.WifiTethering
                    BridgeTransportHint.UltraWideband -> Icons.Default.WifiTethering
                    BridgeTransportHint.Bluetooth -> Icons.Default.Bluetooth
                    BridgeTransportHint.Nfc -> Icons.Default.Nfc
                    BridgeTransportHint.AirPlay -> Icons.Default.Cast
                    BridgeTransportHint.Lan -> Icons.Default.Cable
                    BridgeTransportHint.Cloud -> Icons.Default.Cloud
                }
                MetricChip(
                    label = "链路",
                    value = linkLabel,
                    icon = linkIcon
                )
                if (linkQuality.supportsLossless) {
                    MetricChip(
                        label = "画质",
                        value = "近无损",
                        icon = Icons.Default.HighQuality
                    )
                } else if (linkQuality.isDirect) {
                    MetricChip(
                        label = "直连",
                        value = if (linkQuality.throughputMbps > 180f) "高码率" else "稳定",
                        icon = Icons.Default.Bolt
                    )
                }
            }
        }
    }
}

@Composable
private fun ConnectionControlPanel(
    connectionStatus: String,
    stats: ConnectionStats,
    onDisconnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = "实时表现",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                ConnectionStatusItem("抖动", "${stats.jitterMs.toInt()} ms", Icons.Default.ShowChart)
                ConnectionStatusItem("分辨率", "${stats.frameWidth}x${stats.frameHeight}", Icons.Default.HighQuality)
                ConnectionStatusItem("发送", "${stats.bytesSent / 1024} KB", Icons.Default.CloudUpload)
                ConnectionStatusItem("接收", "${stats.bytesReceived / 1024} KB", Icons.Default.CloudDownload)
            }

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End
            ) {
                if (connectionStatus == "connected") {
                    Button(
                        onClick = onDisconnect,
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF5350))
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("断开连接")
                    }
                } else {
                    Text(
                        text = "选择附近设备或输入账号即可发起连接",
                        fontSize = 12.sp,
                        color = Color.White.copy(alpha = 0.65f)
                    )
                }
            }
        }
    }
}

@Composable
private fun ConnectionStatusItem(
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
            tint = Color.White,
            modifier = Modifier.size(22.dp)
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = value,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
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
private fun SectionTitle(text: String) {
    Text(
        text = text,
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
        color = Color.White
    )
}

@Composable
private fun ProximityDeviceCard(
    device: BridgeDevice,
    onConnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = device.displayName,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.weight(1f)
                )
                AssistChip(
                    onClick = {},
                    leadingIcon = {
                        Icon(Icons.Default.SignalWifi4Bar, contentDescription = null, tint = Color.White)
                    },
                    label = {
                        Text("信号 ${device.signalLevel}", color = Color.White)
                    },
                    colors = AssistChipDefaults.assistChipColors(containerColor = Color.White.copy(alpha = 0.08f))
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "地址 ${device.deviceAddress}",
                fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.7f)
            )

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    device.capabilities.forEach { capability ->
                        AssistChip(
                            onClick = {},
                            label = {
                                Text(
                                    text = when (capability) {
                                        BridgeTransportHint.WifiDirect -> "Wi-Fi Direct"
                                        BridgeTransportHint.UltraWideband -> "Ultra"
                                        BridgeTransportHint.Bluetooth -> "Bluetooth"
                                        BridgeTransportHint.Nfc -> "NFC"
                                        BridgeTransportHint.AirPlay -> "AirPlay"
                                        BridgeTransportHint.Lan -> "LAN"
                                        BridgeTransportHint.Cloud -> "Relay"
                                    },
                                    color = Color.White
                                )
                            },
                            colors = AssistChipDefaults.assistChipColors(containerColor = Color.White.copy(alpha = 0.06f))
                        )
                    }
                }

                Button(
                    onClick = onConnect,
                    colors = ButtonDefaults.buttonColors(containerColor = transportTintForCapability(device))
                ) {
                    Icon(Icons.Default.FlashOn, contentDescription = null)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("极速直连")
                }
            }
        }
    }
}

@Composable
private fun RemoteAccountCard(
    account: BridgeAccountEndpoint,
    onConnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Cloud,
                    contentDescription = null,
                    tint = Color(0xFF7E57C2),
                    modifier = Modifier.size(24.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "账号 ${account.accountId}",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "${account.throughputMbps.toInt()} Mbps",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "中继 ${account.relayId}",
                fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.65f)
            )

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "时延 ${account.latencyMs} ms",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
                Button(
                    onClick = onConnect,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7E57C2))
                ) {
                    Icon(Icons.Default.Link, contentDescription = null)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("云桥连接")
                }
            }
        }
    }
}

@Composable
private fun ManualAccountConnectBlock(
    account: String,
    onAccountChange: (String) -> Unit,
    onConnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface.copy(alpha = 0.95f)),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = "输入云桥账号",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = account,
                onValueChange = onAccountChange,
                label = { Text("账号 ID") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.White.copy(alpha = 0.8f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.5f),
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color.White
                ),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onConnect,
                enabled = account.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF00E5FF))
            ) {
                Icon(Icons.Default.Login, contentDescription = null, tint = Color.Black)
                Spacer(modifier = Modifier.width(8.dp))
                Text("连接账号", color = Color.Black)
            }
        }
    }
}

@Composable
private fun TransportBadge(transport: BridgeTransport) {
    AssistChip(
        onClick = {},
        leadingIcon = {
            Icon(
                imageVector = transport.icon(),
                contentDescription = null,
                tint = transport.tint()
            )
        },
        label = {
            Column {
                Text(
                    text = transport.label(),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White
                )
                Text(
                    text = transport.description(),
                    fontSize = 10.sp,
                    color = Color.White.copy(alpha = 0.72f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        },
        colors = AssistChipDefaults.assistChipColors(
            containerColor = transport.tint().copy(alpha = 0.16f)
        )
    )
}


@Composable
private fun QualitySettingsPanel(
    profile: RemoteDesktopTierProfile,
    modes: List<RemoteDesktopResolutionMode>,
    activeMode: RemoteDesktopResolutionMode?,
    onSelectMode: (RemoteDesktopResolutionMode) -> Unit
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
                text = "画质设置",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )

            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = "当前档位：${profile.displayName}",
                fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.7f)
            )

            val activeLabel = activeMode?.let { "${it.label} ${it.width}x${it.height}" } ?: "未选择"
            Text(
                text = "当前分辨率：$activeLabel",
                fontSize = 11.sp,
                color = Color.White.copy(alpha = 0.6f)
            )

            Spacer(modifier = Modifier.height(10.dp))

            if (modes.isEmpty()) {
                Text(
                    text = "暂无可用画质档位",
                    fontSize = 11.sp,
                    color = Color.White.copy(alpha = 0.6f)
                )
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(modes) { mode ->
                        QualityOption(
                            mode = mode,
                            isSelected = activeMode?.id == mode.id,
                            onClick = { onSelectMode(mode) }
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

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
    mode: RemoteDesktopResolutionMode,
    isSelected: Boolean,
    onClick: () -> Unit
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
                )
                .clickable { onClick() },
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = mode.label,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = if (isSelected) Color.Black else Color.White
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "${mode.width}x${mode.height}",
            fontSize = 10.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
        Text(
            text = "帧率 ${mode.frameRates.joinToString("/")}",
            fontSize = 9.sp,
            color = Color.White.copy(alpha = 0.6f)
        )
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