package com.skybridge.compass.android.ui.screens.devicediscovery

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.Folder
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.SkyBridgeApplication
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.discovery.DiscoveryPeerAction
import com.skybridge.compass.android.discovery.DiscoveryPeerActionKind
import com.skybridge.compass.android.discovery.DiscoveryPeerActionProjection
import com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.permissions.PermissionManager
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.theme.IOSParityTokens
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.discovery.data.interop.DiscoveredPeerConnectability
import com.skybridge.compass.discovery.data.interop.PeerNotConnectableReason
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.presentation.events.DeviceDiscoveryEvent
import com.skybridge.compass.discovery.presentation.viewmodels.DeviceDiscoveryViewModel
import com.skybridge.compass.shared.productsession.ProductSessionAuthority
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun DeviceDiscoveryScreen(
    navController: NavController,
    viewModel: DeviceDiscoveryViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val productSessions by viewModel.productSessions.collectAsState()
    val discoveredDevices = uiState.devices
    val isScanning = uiState.isDiscovering
    val context = androidx.compose.ui.platform.LocalContext.current
    val lifecycleScope = rememberCoroutineScope()
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    var searchText by remember { mutableStateOf("") }
    var autoConnectedDeviceId by rememberSaveable { mutableStateOf<String?>(null) }
    var permissionWasDenied by rememberSaveable { mutableStateOf(false) }
    var localNodeStopError by rememberSaveable { mutableStateOf<String?>(null) }
    val localNodeStopFailureMessage = t(
        "停止局域网广播失败",
        "Failed to stop local-network advertising",
        "ローカルネットワーク広告の停止に失敗しました"
    )
    // R3.8: guards the one-shot auto-request so entering the screen initiates the
    // permission prompt exactly once per visit and does not re-loop after a denial
    // (subsequent requests go through the on-screen "Allow Access" re-request entry).
    var permissionAutoRequested by rememberSaveable { mutableStateOf(false) }
    var hasBonjourPermission by remember {
        mutableStateOf(
            PermissionManager.arePermissionsGranted(
                context = context,
                feature = PermissionManager.Feature.BONJOUR_LOCAL_NETWORK
            )
        )
    }
    val bonjourPermissions = remember {
        PermissionManager.permissionsFor(
            feature = PermissionManager.Feature.BONJOUR_LOCAL_NETWORK,
            sdkInt = Build.VERSION.SDK_INT
        )
    }

    fun startAuthorizedDiscovery() {
        localNodeStopError = null
        (context.applicationContext as? SkyBridgeApplication)?.startLocalNodeDiscovery()
        viewModel.onEvent(DeviceDiscoveryEvent.StartDiscovery())
    }

    fun stopUnauthorizedDiscovery() {
        val application = context.applicationContext as? SkyBridgeApplication
        if (application != null) {
            lifecycleScope.launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    application.stopLocalNodeDiscovery()
                    localNodeStopError = null
                } catch (error: Exception) {
                    localNodeStopError = localNodeStopFailureMessage
                }
            }
        }
        viewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery)
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        val granted = bonjourPermissions.all { permission -> result[permission] == true }
        hasBonjourPermission = granted
        permissionWasDenied = !granted
        if (granted) {
            startAuthorizedDiscovery()
        } else {
            stopUnauthorizedDiscovery()
        }
    }

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        val granted = PermissionManager.arePermissionsGranted(
            context = context,
            feature = PermissionManager.Feature.BONJOUR_LOCAL_NETWORK
        )
        hasBonjourPermission = granted
        if (granted) {
            permissionWasDenied = false
            startAuthorizedDiscovery()
        } else {
            stopUnauthorizedDiscovery()
        }
    }

    DisposableEffect(Unit) {
        onDispose { viewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery) }
    }

    // R3.8: within 1s of entering the discovery screen, initiate all required local-network
    // permission requests for the running Android version. LaunchedEffect fires on the first
    // composition (well under the 1s bound). Advertising and browsing are started only from the
    // launcher callback once every required permission result returns granted. When the platform
    // requires no local-network permission, bonjourPermissions is empty and ON_RESUME already
    // starts discovery, so we skip the empty request.
    LaunchedEffect(Unit) {
        if (!permissionAutoRequested &&
            !hasBonjourPermission &&
            !permissionWasDenied &&
            bonjourPermissions.isNotEmpty()
        ) {
            permissionAutoRequested = true
            permissionLauncher.launch(bonjourPermissions.toTypedArray())
        }
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

    LaunchedEffect(filteredDevices, appSettings.autoConnect, devSettings) {
        if (!appSettings.autoConnect) {
            autoConnectedDeviceId = null
            return@LaunchedEffect
        }

        val candidate = filteredDevices.singleOrNull {
            DiscoveryPeerActionProjection.actionsFor(it, devSettings).any { action ->
                action.kind == DiscoveryPeerActionKind.Handshake && action.enabled
            }
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

        if (!hasBonjourPermission) {
            item {
                LocalNetworkPermissionCard(
                    permissionWasDenied = permissionWasDenied,
                    onRequestPermission = {
                        permissionLauncher.launch(bonjourPermissions.toTypedArray())
                    },
                    onOpenSettings = {
                        context.startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                "package:${context.packageName}".toUri()
                            )
                        )
                    }
                )
            }
        } else {
            item {
                DiscoveryStatusCard(
                    isScanning = isScanning,
                    discoveredCount = discoveredDevices.size,
                    filteredCount = filteredDevices.size,
                    onToggleScan = {
                        if (isScanning) {
                            viewModel.onEvent(DeviceDiscoveryEvent.StopDiscovery)
                        } else {
                            startAuthorizedDiscovery()
                        }
                    }
                )
            }

            if (filteredDevices.isEmpty()) {
                item {
                    EmptyDevicesCard(
                        isScanning = isScanning,
                        onScan = ::startAuthorizedDiscovery
                    )
                }
            } else {
                items(filteredDevices, key = { it.id }) { device ->
                    IOSDeviceRowCard(
                        device = device,
                        devSettings = devSettings,
                        productSessions = productSessions,
                        onConnect = { viewModel.onEvent(DeviceDiscoveryEvent.ConnectToDevice(device)) },
                        onFileTransfer = { action ->
                            val target = DiscoveryPeerLaunchTarget.from(device, action)
                            navController.navigate(Screen.FileTransfer.routeFor(target)) {
                                launchSingleTop = true
                            }
                        },
                        onRemoteDesktop = { action ->
                            val target = DiscoveryPeerLaunchTarget.from(device, action)
                            navController.navigate(Screen.RemoteControl.routeFor(target)) {
                                launchSingleTop = true
                            }
                        },
                        onRefresh = { viewModel.onEvent(DeviceDiscoveryEvent.RefreshDevices) }
                    )
                }
            }
        }

        localNodeStopError?.let { error ->
            item {
                LiquidGlassSurface(
                    modifier = Modifier.fillMaxWidth(),
                    tintColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.22f),
                    contentPadding = PaddingValues(12.dp)
                ) {
                    Text(
                        text = error,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }
        }
    }
}

@Composable
private fun LocalNetworkPermissionCard(
    permissionWasDenied: Boolean,
    onRequestPermission: () -> Unit,
    onOpenSettings: () -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        opticalDepth = 18.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.18f),
        tintAlpha = 0.18f,
        borderAlpha = 0.20f,
        highlightAlpha = 0.10f,
        edgeGlowAlpha = 0.07f,
        contentPadding = PaddingValues(16.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Wifi,
                    contentDescription = null,
                    tint = IOSParityTokens.ColorTokens.CyanAccent
                )
                Spacer(modifier = Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = t("允许局域网发现", "Allow Local Network Discovery", "ローカルネットワーク検出を許可"),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = t(
                            "用于发现并连接同一网络中的 iPhone、iPad 和 Mac。不会请求位置、蓝牙或附近设备权限。",
                            "Used to discover and connect to iPhone, iPad, and Mac on your network. Location, Bluetooth, and nearby-device access are not requested.",
                            "同じネットワーク上の iPhone、iPad、Mac の検出と接続に使用します。位置情報、Bluetooth、付近のデバイス権限は要求しません。"
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = onRequestPermission) {
                    Text(t("允许访问", "Allow Access", "アクセスを許可"))
                }
                if (permissionWasDenied) {
                    OutlinedButton(onClick = onOpenSettings) {
                        Text(t("打开系统设置", "Open Settings", "設定を開く"))
                    }
                }
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
            ScanRadarIcon(isScanning = isScanning, size = 42.dp)
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

/**
 * Radar-style scan indicator: a cyan glyph with two outward-pulsing rings while scanning,
 * settling into a static Wi-Fi-off glyph when paused. Mirrors the iOS device-discovery
 * scanning affordance.
 */
@Composable
private fun ScanRadarIcon(
    isScanning: Boolean,
    size: Dp
) {
    val accent = IOSParityTokens.ColorTokens.CyanAccent
    if (!isScanning) {
        Box(
            modifier = Modifier
                .size(size)
                .background(
                    Brush.linearGradient(
                        colors = listOf(accent.copy(alpha = 0.22f), accent.copy(alpha = 0.10f))
                    ),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Filled.WifiOff,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(size * 0.46f)
            )
        }
        return
    }

    val transition = rememberInfiniteTransition(label = "radar")
    val pulse1 by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1800, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "pulse1"
    )
    val pulse2 by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1800, delayMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "pulse2"
    )

    Box(
        modifier = Modifier.size(size),
        contentAlignment = Alignment.Center
    ) {
        // Outward-pulsing rings.
        listOf(pulse1, pulse2).forEach { p ->
            Box(
                modifier = Modifier
                    .size(size)
                    .scale(0.55f + p * 0.45f)
                    .alpha((1f - p).coerceIn(0f, 1f) * 0.6f)
                    .background(Color.Transparent, CircleShape)
                    .border(
                        width = 1.5.dp,
                        color = accent.copy(alpha = 0.9f),
                        shape = CircleShape
                    )
            )
        }
        // Core glyph.
        Box(
            modifier = Modifier
                .size(size * 0.62f)
                .background(
                    Brush.linearGradient(
                        colors = listOf(accent.copy(alpha = 0.45f), accent.copy(alpha = 0.22f))
                    ),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Filled.Wifi,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(size * 0.32f)
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
            if (isScanning) {
                // Radar/scan animation while we are actively searching an empty network.
                ScanRadarIcon(isScanning = true, size = 64.dp)
            } else {
                Icon(
                    imageVector = Icons.Filled.Devices,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.52f),
                    modifier = Modifier.size(46.dp)
                )
            }
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
    productSessions: List<ProductSessionAuthority>,
    onConnect: () -> Unit,
    onFileTransfer: (DiscoveryPeerAction) -> Unit,
    onRemoteDesktop: (DiscoveryPeerAction) -> Unit,
    onRefresh: () -> Unit
) {
    val accent = device.type.iconTint()
    val productSession = DiscoveryPeerActionProjection.productSessionFor(device, productSessions)
    val actions = DiscoveryPeerActionProjection.actionsFor(device, devSettings, productSession)
    val connectability = DiscoveredPeerConnectability.classify(device)
    val handshakeAction = actions.firstOrNull { it.kind == DiscoveryPeerActionKind.Handshake }
    val routedActions = actions.filter { it.kind != DiscoveryPeerActionKind.Handshake }
    val hasEnabledAction = actions.any { it.enabled }
    val statusLabel = when {
        device.isConnected -> t("已连接", "Connected", "接続済み")
        hasEnabledAction -> t("可操作", "Ready", "操作可能")
        actions.isNotEmpty() -> t("需开启", "Disabled", "無効")
        else -> t("仅发现", "Discovery Only", "検出のみ")
    }
    val statusColor = when {
        device.isConnected -> Color(0xFF34C759)
        hasEnabledAction -> Color.White.copy(alpha = 0.72f)
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
        Column {
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
                    if (actions.isEmpty()) {
                        Text(
                            text = t(
                                "该设备当前没有可拨打的互通服务端点",
                                "This peer does not currently expose a dialable interop service endpoint",
                                "このピアは現在、接続可能な相互接続サービスを公開していません"
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
                                Text(
                                    text = capability.displayName(),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = accent,
                                    modifier = Modifier
                                        .background(
                                            color = accent.copy(alpha = 0.15f),
                                            shape = RoundedCornerShape(999.dp)
                                        )
                                        .padding(horizontal = 8.dp, vertical = 3.dp)
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
                    enabled = handshakeAction?.enabled == true && connectability.isConnectable
                ) {
                    Icon(Icons.Filled.Bolt, contentDescription = null)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        when {
                            device.isConnected -> t("已连接", "Connected", "接続済み")
                            !connectability.isConnectable -> t("不可连接", "Unavailable", "接続不可")
                            handshakeAction != null -> t("握手", "Handshake", "ハンドシェイク")
                            else -> t("不支持", "Unsupported", "未対応")
                        }
                    )
                }
            }

            connectability.primaryReason?.takeIf { !device.isConnected }?.let { reason ->
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = reason.reasonText(),
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFFFF9F0A),
                    maxLines = 2
                )
            }

            if (routedActions.isNotEmpty()) {
                Spacer(modifier = Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    routedActions.forEach { action ->
                        OutlinedButton(
                            onClick = {
                                when (action.kind) {
                                    DiscoveryPeerActionKind.FileTransfer -> onFileTransfer(action)
                                    DiscoveryPeerActionKind.RemoteDesktop -> onRemoteDesktop(action)
                                    DiscoveryPeerActionKind.Handshake -> onConnect()
                                }
                            },
                            modifier = Modifier.weight(1f),
                            enabled = action.enabled
                        ) {
                            Icon(action.kind.icon(), contentDescription = null)
                            Spacer(modifier = Modifier.width(6.dp))
                            Text(action.kind.label())
                        }
                    }
                }
            }
        }
    }
}

private fun signalTint(signal: Int): Color = when {
    signal >= -60 -> Color(0xFF34C759)
    signal >= -75 -> Color(0xFFFF9F0A)
    else -> Color(0xFFFF453A)
}

@Composable
private fun PeerNotConnectableReason.reasonText(): String = when (this) {
    PeerNotConnectableReason.PORT_INFORMATION_MISSING -> t(
        "该对端未提供可用端口信息，无法连接",
        "This peer advertises no usable port, so it can't be connected",
        "このピアは利用可能なポート情報を提供していないため接続できません"
    )
    PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING -> t(
        "该对端缺少身份指纹，无法连接",
        "This peer is missing an identity fingerprint, so it can't be connected",
        "このピアは識別フィンガープリントが無いため接続できません"
    )
    PeerNotConnectableReason.IDENTITY_FINGERPRINT_TOO_LONG -> t(
        "该对端身份指纹超出长度上限，无法连接",
        "This peer's identity fingerprint exceeds the size limit, so it can't be connected",
        "このピアの識別フィンガープリントは長さ制限を超えているため接続できません"
    )
    PeerNotConnectableReason.IDENTITY_FINGERPRINT_MALFORMED -> t(
        "该对端身份指纹格式不符，无法连接",
        "This peer's identity fingerprint is malformed, so it can't be connected",
        "このピアの識別フィンガープリントの形式が不正なため接続できません"
    )
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

private fun DiscoveryPeerActionKind.icon(): ImageVector = when (this) {
    DiscoveryPeerActionKind.Handshake -> Icons.Filled.Bolt
    DiscoveryPeerActionKind.FileTransfer -> Icons.Filled.Folder
    DiscoveryPeerActionKind.RemoteDesktop -> Icons.Filled.Computer
}

private fun DiscoveryPeerActionKind.label(): String = when (this) {
    DiscoveryPeerActionKind.Handshake -> resolveLocalizedText("握手", "Handshake", "ハンドシェイク")
    DiscoveryPeerActionKind.FileTransfer -> resolveLocalizedText("文件", "Files", "ファイル")
    DiscoveryPeerActionKind.RemoteDesktop -> resolveLocalizedText("远控", "Remote", "遠隔操作")
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
