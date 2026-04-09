package com.skybridge.compass.android.ui.screens.devicediscovery

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocolProfiles
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.presentation.events.DeviceDiscoveryEvent
import com.skybridge.compass.discovery.presentation.viewmodels.DeviceDiscoveryViewModel

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun DeviceDiscoveryScreen(
    navController: NavController,
    viewModel: DeviceDiscoveryViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val discoveredDevices = uiState.devices
    val isScanning = uiState.isDiscovering
    val context = androidx.compose.ui.platform.LocalContext.current
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    var searchText by remember { mutableStateOf("") }
    var autoConnectedDeviceId by rememberSaveable { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        viewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery())
    }

    DisposableEffect(Unit) {
        onDispose { viewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery) }
    }

    val filteredDevices = remember(discoveredDevices, searchText) {
        val keyword = searchText.trim()
        if (keyword.isEmpty()) {
            discoveredDevices
        } else {
            discoveredDevices.filter { device ->
                device.name.contains(keyword, ignoreCase = true) ||
                    device.connectionInfo.address.contains(keyword, ignoreCase = true) ||
                    device.type.displayName().contains(keyword, ignoreCase = true)
            }
        }
    }

    LaunchedEffect(filteredDevices, appSettings.autoConnect) {
        if (!appSettings.autoConnect) {
            autoConnectedDeviceId = null
            return@LaunchedEffect
        }

        val candidate = filteredDevices.singleOrNull {
            !it.isConnected && DiscoveryProtocolProfiles.supportsDirectConnect(it.connectionInfo.protocol)
        }
        if (candidate == null) {
            autoConnectedDeviceId = null
            return@LaunchedEffect
        }

        if (autoConnectedDeviceId == candidate.id) return@LaunchedEffect
        autoConnectedDeviceId = candidate.id
        viewModel.onEvent(DeviceDiscoveryEvent.ConnectToDevice(candidate))
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        contentPadding = PaddingValues(top = 8.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = t("设备发现", "Device Discovery", "デバイス検出"),
                    style = MaterialTheme.typography.headlineLarge,
                    color = Color.White,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        item {
            LiquidGlassSurface(
                modifier = Modifier.fillMaxWidth(),
                blurRadius = 0.dp,
                tintColor = Color.White.copy(alpha = 0.06f),
                tintAlpha = 0.06f,
                borderAlpha = 0.12f,
                highlightAlpha = 0.04f,
                edgeGlowAlpha = 0.03f,
                contentPadding = PaddingValues(12.dp)
            ) {
                OutlinedTextField(
                    value = searchText,
                    onValueChange = { searchText = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(t("搜索设备…", "Search devices…", "デバイスを検索…")) },
                    leadingIcon = {
                        Icon(Icons.Filled.Search, contentDescription = null)
                    }
                )
            }
        }

        item {
            DiscoveryStatusCard(
                isScanning = isScanning,
                discoveredCount = discoveredDevices.size,
                filteredCount = filteredDevices.size,
                onToggleScan = {
                    if (isScanning) {
                        viewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery)
                    } else {
                        viewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery())
                    }
                }
            )
        }

        if (filteredDevices.isEmpty()) {
            item {
                EmptyDevicesCard(
                    isScanning = isScanning,
                    onScan = { viewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery()) }
                )
            }
        } else {
            items(filteredDevices, key = { it.id }) { device ->
                IOSDeviceRowCard(
                    device = device,
                    devSettings = devSettings,
                    onConnect = { viewModel.onEvent(DeviceDiscoveryEvent.ConnectToDevice(device)) },
                    onRefresh = { viewModel.onEvent(DeviceDiscoveryEvent.RefreshDevices) }
                )
            }
        }
    }
}

@Composable
private fun DiscoveryStatusCard(
    isScanning: Boolean,
    discoveredCount: Int,
    filteredCount: Int,
    onToggleScan: () -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f,
        contentPadding = PaddingValues(14.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .background(
                        Brush.linearGradient(
                            colors = listOf(Color(0xFF0A84FF).copy(alpha = 0.35f), Color(0xFF7CC0FF).copy(alpha = 0.20f))
                        ),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (isScanning) Icons.Filled.Wifi else Icons.Filled.WifiOff,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(20.dp)
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (isScanning) {
                        t("正在扫描局域网设备…", "Scanning local network devices…", "ローカルネットワークのデバイスをスキャン中…")
                    } else {
                        t("扫描已暂停", "Scanning paused", "スキャンは一時停止中です")
                    },
                    style = MaterialTheme.typography.titleSmall,
                    color = Color.White
                )
                Text(
                    text = t(
                        "发现 $discoveredCount 台 · 当前显示 $filteredCount 台",
                        "Found $discoveredCount devices · Showing $filteredCount",
                        "$discoveredCount 台を検出 · $filteredCount 台を表示中"
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.70f)
                )
            }
            AssistChip(
                onClick = onToggleScan,
                label = {
                    Text(if (isScanning) t("停止扫描", "Stop Scan", "スキャン停止") else t("开始扫描", "Start Scan", "スキャン開始"))
                },
                leadingIcon = {
                    Icon(
                        imageVector = if (isScanning) Icons.Filled.Wifi else Icons.Filled.Search,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp)
                    )
                },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = if (isScanning) Color(0xFFFF453A).copy(alpha = 0.16f) else Color(0xFF0A84FF).copy(alpha = 0.16f),
                    labelColor = if (isScanning) Color(0xFFFF7B72) else Color(0xFF7CC0FF),
                    leadingIconContentColor = if (isScanning) Color(0xFFFF7B72) else Color(0xFF7CC0FF)
                )
            )
        }
    }
}

@Composable
private fun EmptyDevicesCard(
    isScanning: Boolean,
    onScan: () -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f,
        contentPadding = PaddingValues(vertical = 26.dp, horizontal = 20.dp)
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = Icons.Filled.Devices,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.52f),
                modifier = Modifier.size(46.dp)
            )
            Spacer(modifier = Modifier.height(10.dp))
            Text(
                text = if (isScanning) t("正在扫描设备…", "Scanning devices…", "デバイスをスキャン中…") else t("未发现设备", "No devices found", "デバイスが見つかりません"),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = if (isScanning) {
                    t("请稍候，新的设备会自动出现", "Please wait, new devices will appear automatically", "しばらくお待ちください。新しいデバイスは自動で表示されます")
                } else {
                    t("点击“开始扫描”搜索同网段设备", "Tap “Start Scan” to find devices on the same network", "「スキャン開始」を押して同一ネットワーク上のデバイスを検索")
                },
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.66f)
            )
            if (!isScanning) {
                Spacer(modifier = Modifier.height(14.dp))
                OutlinedButton(onClick = onScan) {
                    Icon(Icons.Filled.Search, contentDescription = null)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(t("开始扫描", "Start Scan", "スキャン開始"))
                }
            }
        }
    }
}

@Composable
private fun IOSDeviceRowCard(
    device: DiscoveredDevice,
    devSettings: DeveloperSettings,
    onConnect: () -> Unit,
    onRefresh: () -> Unit
) {
    val accent = device.type.iconTint()
    val directConnectSupported = DiscoveryProtocolProfiles.supportsDirectConnect(device.connectionInfo.protocol)
    val statusLabel = when {
        device.isConnected -> t("已连接", "Connected", "接続済み")
        directConnectSupported -> t("可连接", "Ready to Connect", "接続可能")
        else -> t("仅发现", "Discovery Only", "検出のみ")
    }
    val statusColor = when {
        device.isConnected -> Color(0xFF34C759)
        directConnectSupported -> Color.White.copy(alpha = 0.72f)
        else -> Color(0xFFFF9F0A)
    }

    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f,
        contentPadding = PaddingValues(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(
                        Brush.linearGradient(
                            colors = listOf(accent.copy(alpha = 0.30f), accent.copy(alpha = 0.12f))
                        ),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = device.type.icon(),
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(20.dp)
                )
            }
            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = device.name,
                        style = MaterialTheme.typography.titleSmall,
                        color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = statusLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = statusColor,
                        modifier = Modifier
                            .background(
                                color = if (device.isConnected) Color(0xFF34C759).copy(alpha = 0.16f) else Color.White.copy(alpha = 0.08f),
                                shape = RoundedCornerShape(999.dp)
                            )
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
                Text(
                    text = "${device.type.displayName()} • ${device.connectionInfo.address}",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.66f),
                    maxLines = 1
                )
                if (!directConnectSupported) {
                    Text(
                        text = t(
                            "该发现协议当前不提供直接互通入口",
                            "This discovery protocol does not currently expose a direct interop connect path",
                            "この検出プロトコルでは現在、直接の相互接続を提供していません"
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.58f),
                        maxLines = 2
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    device.capabilities
                        .filter { it.isEnabledBy(devSettings) }
                        .take(2)
                        .forEach { capability ->
                            AssistChip(
                                onClick = {},
                                label = { Text(capability.displayName()) },
                                colors = AssistChipDefaults.assistChipColors(
                                    containerColor = accent.copy(alpha = 0.15f),
                                    labelColor = accent
                                )
                            )
                        }
                }
            }

            Spacer(modifier = Modifier.width(6.dp))
            Column(horizontalAlignment = Alignment.End) {
                Icon(
                    imageVector = Icons.Filled.Wifi,
                    contentDescription = null,
                    tint = signalTint(device.signalStrength),
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    text = "${device.signalStrength}dBm",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White.copy(alpha = 0.62f)
                )
            }
        }

        Spacer(modifier = Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = onRefresh,
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Filled.Refresh, contentDescription = null)
                Spacer(modifier = Modifier.width(6.dp))
                Text(t("刷新", "Refresh", "更新"))
            }
            OutlinedButton(
                onClick = onConnect,
                modifier = Modifier.weight(1f),
                enabled = !device.isConnected && directConnectSupported
            ) {
                Icon(Icons.Filled.Bolt, contentDescription = null)
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    when {
                        device.isConnected -> t("已连接", "Connected", "接続済み")
                        directConnectSupported -> t("连接", "Connect", "接続")
                        else -> t("不支持", "Unsupported", "未対応")
                    }
                )
            }
        }
    }
}

private fun signalTint(signal: Int): Color = when {
    signal >= -60 -> Color(0xFF34C759)
    signal >= -75 -> Color(0xFFFF9F0A)
    else -> Color(0xFFFF453A)
}

private fun DeviceCapability.isEnabledBy(devSettings: DeveloperSettings): Boolean = when (this) {
    DeviceCapability.SCREEN_SHARING -> devSettings.enableScreenMirroring
    DeviceCapability.REMOTE_CONTROL -> devSettings.enableRemoteControl
    DeviceCapability.FILE_TRANSFER -> devSettings.enableFileTransfer
    else -> true
}

private fun DeviceCapability.displayName(): String = when (this) {
    DeviceCapability.SCREEN_SHARING -> resolveLocalizedText("屏幕", "Screen", "画面")
    DeviceCapability.REMOTE_CONTROL -> resolveLocalizedText("远控", "Remote", "遠隔操作")
    DeviceCapability.FILE_TRANSFER -> resolveLocalizedText("文件", "Files", "ファイル")
    DeviceCapability.AUDIO_STREAMING -> resolveLocalizedText("音频", "Audio", "音声")
    DeviceCapability.VIDEO_STREAMING -> resolveLocalizedText("视频", "Video", "映像")
    DeviceCapability.CLIPBOARD_SYNC -> resolveLocalizedText("剪贴板", "Clipboard", "クリップボード")
    DeviceCapability.NOTIFICATION_SYNC -> resolveLocalizedText("通知", "Notifications", "通知")
    DeviceCapability.CAMERA_ACCESS -> resolveLocalizedText("相机", "Camera", "カメラ")
    DeviceCapability.MICROPHONE_ACCESS -> resolveLocalizedText("麦克风", "Microphone", "マイク")
}

private fun DeviceType.icon(): ImageVector = when (this) {
    DeviceType.IOS -> Icons.Filled.PhoneIphone
    DeviceType.MACOS -> Icons.Filled.LaptopMac
    DeviceType.ANDROID -> Icons.Filled.Android
    DeviceType.WINDOWS, DeviceType.LINUX -> Icons.Filled.Computer
    DeviceType.UNKNOWN -> Icons.Filled.Devices
}

private fun DeviceType.iconTint(): Color = when (this) {
    DeviceType.IOS -> Color(0xFF7CC0FF)
    DeviceType.MACOS -> Color(0xFF5E9DFF)
    DeviceType.ANDROID -> Color(0xFF80E27E)
    DeviceType.WINDOWS -> Color(0xFF84B9FF)
    DeviceType.LINUX -> Color(0xFFFFB46A)
    DeviceType.UNKNOWN -> Color.White.copy(alpha = 0.82f)
}

private fun DeviceType.displayName(): String = when (this) {
    DeviceType.IOS -> "iOS"
    DeviceType.MACOS -> "macOS"
    DeviceType.ANDROID -> "Android"
    DeviceType.WINDOWS -> "Windows"
    DeviceType.LINUX -> "Linux"
    DeviceType.UNKNOWN -> resolveLocalizedText("未知", "Unknown", "不明")
}

@Preview(showBackground = true)
@Composable
private fun DeviceDiscoveryScreenPreview() {
    SkyBridgeCompassTheme {
        DeviceDiscoveryScreen(navController = rememberNavController())
    }
}
