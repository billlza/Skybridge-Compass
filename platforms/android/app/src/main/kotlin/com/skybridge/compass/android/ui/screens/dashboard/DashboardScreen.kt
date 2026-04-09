package com.skybridge.compass.android.ui.screens.dashboard

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.shared.account.AccountStore
import java.util.Locale

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun DashboardScreen(
    navController: NavController,
    viewModel: DashboardViewModel = hiltViewModel()
) {
    val state = viewModel.uiState
    val profile = AccountStore.primaryAccount.collectAsState().value
    val context = androidx.compose.ui.platform.LocalContext.current
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())

    val quickActions = buildList {
        add(QuickAction(t("扫描网络", "Scan Network", "ネットワークをスキャン"), Icons.Filled.Search, Screen.DeviceDiscovery.route, Color(0xFF00BCD4)))
        if (devSettings.enableFileTransfer) {
            add(QuickAction(t("发送文件", "Send File", "ファイル送信"), Icons.AutoMirrored.Filled.Send, Screen.FileTransfer.route, Color(0xFFAF52DE)))
        }
        if (devSettings.enableRemoteControl) {
            add(QuickAction(t("远程桌面", "Remote Desktop", "リモートデスクトップ"), Icons.Filled.Computer, Screen.RemoteControl.route, Color(0xFF0A84FF)))
        }
        add(QuickAction(t("扫码连接", "Scan to Connect", "コードを読み取って接続"), Icons.Filled.Devices, Screen.DeviceDiscovery.route, Color(0xFF00C7BE)))
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        contentPadding = PaddingValues(top = 10.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            DashboardTopBar(
                userDisplayName = profile?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?: profile?.email
                    ?: t("用户", "User", "ユーザー"),
                isRefreshing = state.isLoading,
                onOpenAccount = {
                    navController.navigate(Screen.AccountCenter.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                },
                onOpenScanner = {
                    navController.navigate(Screen.DeviceDiscovery.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                },
                onRefresh = viewModel::refresh,
                onOpenSettings = {
                    navController.navigate(Screen.Settings.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                }
            )
        }

        item { WelcomeCard(state = state) }

        if (state.activeSessions > 0 || state.dataTransferredLabel != "0 MB") {
            item { TransferStatusCard(state = state) }
        }

        item { WeatherCard(weather = state.weather, onRefresh = viewModel::refresh) }
        item { StatsSection(state = state) }

        item {
            QuickActionsSection(
                actions = quickActions,
                onClick = { route ->
                    navController.navigate(route) {
                        popUpTo(navController.graph.startDestinationId) { saveState = true }
                        launchSingleTop = true
                        restoreState = true
                    }
                }
            )
        }

        item {
            RecentDevicesSection(
                devices = state.recentDevices,
                onViewAll = {
                    navController.navigate(Screen.DeviceDiscovery.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                }
            )
        }

        if (state.activeConnections.isNotEmpty()) {
            item { ActiveConnectionsSection(connections = state.activeConnections) }
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Top Bar
// ──────────────────────────────────────────────────────────────

@Composable
private fun DashboardTopBar(
    userDisplayName: String,
    isRefreshing: Boolean,
    onOpenAccount: () -> Unit,
    onOpenScanner: () -> Unit,
    onRefresh: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val initial = userDisplayName.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "U"

    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(28.dp),
        blurRadius = 0.dp,
        tintColor = Color(0xFF12182A),
        tintAlpha = 0.76f,
        borderAlpha = 0.15f,
        highlightAlpha = 0.02f,
        edgeGlowAlpha = 0.01f,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onOpenAccount)
                    .padding(start = 2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .background(Color.White.copy(alpha = 0.08f), CircleShape)
                        .border(
                            width = 1.dp,
                            brush = Brush.linearGradient(
                                colors = listOf(Color.White.copy(alpha = 0.18f), Color.Transparent),
                                start = Offset.Zero,
                                end = Offset(100f, 100f)
                            ),
                            shape = CircleShape
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = initial,
                        style = MaterialTheme.typography.labelLarge,
                        color = Color.White.copy(alpha = 0.7f),
                        fontWeight = FontWeight.SemiBold
                    )
                }

                Spacer(modifier = Modifier.width(10.dp))

                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(
                        text = "SkyBridge Compass",
                        style = MaterialTheme.typography.labelLarge,
                        color = Color.White.copy(alpha = 0.92f),
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DashboardIconCircleButton(
                    icon = Icons.Filled.Refresh,
                    contentDescription = t("刷新", "Refresh", "更新"),
                    onClick = onRefresh,
                    trailing = {
                        if (isRefreshing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(13.dp),
                                strokeWidth = 1.6.dp,
                                color = Color.White.copy(alpha = 0.90f)
                            )
                        }
                    }
                )
                DashboardIconCircleButton(
                    icon = Icons.Filled.Search,
                    contentDescription = t("扫描设备", "Scan Devices", "デバイスをスキャン"),
                    onClick = onOpenScanner
                )
                DashboardIconCircleButton(
                    icon = Icons.Filled.Settings,
                    contentDescription = t("设置", "Settings", "設定"),
                    onClick = onOpenSettings
                )
            }
        }
    }
}

@Composable
private fun DashboardIconCircleButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    trailing: @Composable (() -> Unit)? = null
) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .background(Color.White.copy(alpha = 0.06f), CircleShape)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(Color.White.copy(alpha = 0.10f), Color.Transparent),
                    start = Offset.Zero,
                    end = Offset(100f, 100f)
                ),
                shape = CircleShape
            )
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = Color.White.copy(alpha = 0.7f),
            modifier = Modifier.size(16.dp)
        )
        trailing?.invoke()
    }
}

// ──────────────────────────────────────────────────────────────
// Welcome Card (iOS: welcomeSection)
// ──────────────────────────────────────────────────────────────

@Composable
private fun WelcomeCard(state: DashboardUiState) {
    val networkStatusText = if (state.isOffline) localizedText("离线", "Offline", "オフライン") else localizedText("在线", "Online", "オンライン")
    val networkColor = if (state.isOffline) Color(0xFFFF453A) else Color(0xFF34C759)
    val chipName = when {
        Build.SUPPORTED_ABIS.any { it.contains("arm64", ignoreCase = true) } -> "ARM64"
        Build.SUPPORTED_ABIS.isNotEmpty() -> Build.SUPPORTED_ABIS.first().uppercase(Locale.getDefault())
        else -> "CPU"
    }

    IOSGlassCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Device icon in glass circle (iOS: .ultraThinMaterial circle)
            Box(
                modifier = Modifier
                    .size(60.dp)
                    .background(Color.White.copy(alpha = 0.12f), CircleShape)
                    .border(
                        width = 1.dp,
                        brush = Brush.linearGradient(
                            colors = listOf(Color.White.copy(alpha = 0.20f), Color.Transparent),
                            start = Offset.Zero,
                            end = Offset(100f, 100f)
                        ),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Smartphone,
                    contentDescription = null,
                    tint = Color(0xFF6FD9FF),
                    modifier = Modifier.size(28.dp)
                )
            }

            Spacer(modifier = Modifier.width(16.dp))

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = Build.MODEL,
                    style = MaterialTheme.typography.titleMedium,
                    color = Color.White,
                    maxLines = 1,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = "${Build.MODEL} · $chipName",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.7f),
                    maxLines = 1
                )
                Text(
                    text = "Android ${Build.VERSION.RELEASE}",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.7f)
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(networkColor, CircleShape)
                            .shadow(
                                elevation = 3.dp,
                                shape = CircleShape,
                                ambientColor = networkColor.copy(alpha = 0.5f),
                                spotColor = networkColor.copy(alpha = 0.5f)
                            )
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = networkStatusText,
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }

            // PQC Badge (iOS: green lock + green gradient border)
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(16.dp))
                    .border(
                        width = 1.dp,
                        brush = Brush.linearGradient(
                            colors = listOf(
                                Color(0xFF34C759).copy(alpha = 0.4f),
                                Color.Transparent
                            ),
                            start = Offset.Zero,
                            end = Offset(100f, 100f)
                        ),
                        shape = RoundedCornerShape(16.dp)
                    )
                    .padding(horizontal = 10.dp, vertical = 8.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Lock,
                    contentDescription = null,
                    tint = Color(0xFF34C759),
                    modifier = Modifier.size(22.dp)
                )
                Text(
                    text = "PQC",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color(0xFF34C759),
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp
                )
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Transfer Status Card (iOS: transferOverviewSection)
// ──────────────────────────────────────────────────────────────

@Composable
private fun TransferStatusCard(state: DashboardUiState) {
    val isActive = state.activeSessions > 0
    val statusIcon = if (isActive) Icons.AutoMirrored.Filled.Send else Icons.Filled.Folder
    val statusColor = if (isActive) Color(0xFF0A84FF) else Color(0xFF34C759)
    val statusText = if (isActive) {
        t("正在进行 ${state.activeSessions} 个会话", "${state.activeSessions} active sessions", "${state.activeSessions} 件のセッション進行中")
    } else {
        t("最近同步已完成", "Recent sync completed", "最近の同期が完了しました")
    }
    val subtitle = t(
        "累计传输 ${state.dataTransferredLabel} · 网络 ${state.networkQuality}",
        "Transferred ${state.dataTransferredLabel} · Network ${state.networkQuality}",
        "転送量 ${state.dataTransferredLabel} ・ ネットワーク ${state.networkQuality}"
    )

    IOSGlassCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(statusColor.copy(alpha = 0.2f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = statusIcon,
                    contentDescription = null,
                    tint = statusColor,
                    modifier = Modifier.size(18.dp)
                )
            }

            Spacer(modifier = Modifier.width(16.dp))

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.65f),
                    maxLines = 1
                )
            }

            Text(
                text = if (isActive) t("进行中", "Active", "進行中") else t("正常", "Normal", "正常"),
                style = MaterialTheme.typography.labelSmall,
                color = statusColor,
                modifier = Modifier
                    .background(statusColor.copy(alpha = 0.15f), RoundedCornerShape(999.dp))
                    .padding(horizontal = 10.dp, vertical = 4.dp)
            )
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Weather Card (iOS: WeatherCardView)
// ──────────────────────────────────────────────────────────────

@Composable
private fun WeatherCard(
    weather: DashboardWeatherCardState,
    onRefresh: () -> Unit
) {
    IOSGlassCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.width(80.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .background(Color.White.copy(alpha = 0.11f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = weather.icon.toImageVector(),
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.92f),
                        modifier = Modifier.size(28.dp)
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = weather.temperatureText,
                    style = MaterialTheme.typography.headlineSmall,
                    color = Color.White,
                    fontWeight = FontWeight.Thin
                )
            }

            Spacer(modifier = Modifier.width(16.dp))

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = weather.locationText,
                            style = MaterialTheme.typography.titleSmall,
                            color = Color.White,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = weather.conditionText,
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.7f)
                        )
                    }
                    WeatherRefreshButton(onClick = onRefresh)
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    WeatherMetricBadge(icon = Icons.Filled.WaterDrop, value = weather.humidityText)
                    WeatherMetricBadge(icon = Icons.Filled.Air, value = weather.windText)
                }

                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = weather.sourceText,
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.56f),
                        fontSize = 9.sp
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = weather.updatedText,
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.56f),
                        fontSize = 9.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun WeatherRefreshButton(onClick: () -> Unit) {
    val refreshDescription = localizedText("刷新天气", "Refresh Weather", "天気を更新")
    Box(
        modifier = Modifier
            .size(28.dp)
            .background(Color(0xFF1E2537).copy(alpha = 0.62f), CircleShape)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = Icons.Filled.Refresh,
            contentDescription = refreshDescription,
            tint = Color.White.copy(alpha = 0.9f),
            modifier = Modifier.size(12.dp)
        )
    }
}

@Composable
private fun WeatherMetricBadge(icon: ImageVector, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .background(Color(0xFF1E2537).copy(alpha = 0.62f), RoundedCornerShape(999.dp))
            .padding(horizontal = 6.dp, vertical = 3.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color(0xFF00BCD4),
            modifier = Modifier.size(10.dp)
        )
        Text(
            text = value,
            style = MaterialTheme.typography.labelSmall,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

// ──────────────────────────────────────────────────────────────
// Stats Section (iOS: StatCardView - icon top-left, value bottom)
// ──────────────────────────────────────────────────────────────

@Composable
private fun StatsSection(state: DashboardUiState) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        StatCard(
            modifier = Modifier.weight(1f),
            title = localizedText("发现与连接", "Discovery & Connections", "検出と接続"),
            value = "${state.connectedDevices} / ${state.activeSessions}",
            icon = Icons.Filled.Wifi,
            accentColor = Color(0xFF00BCD4)
        )
        StatCard(
            modifier = Modifier.weight(1f),
            title = localizedText("传输与性能", "Transfers & Performance", "転送とパフォーマンス"),
            value = "${state.dataTransferredLabel.replace(" MB", "")} / ${state.networkQuality}",
            icon = Icons.Filled.Speed,
            accentColor = Color(0xFFAF52DE)
        )
    }
}

@Composable
private fun StatCard(
    title: String,
    value: String,
    icon: ImageVector,
    accentColor: Color,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .height(130.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(Color(0xFF1E2537).copy(alpha = 0.62f))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.30f),
                        Color.Transparent,
                        accentColor.copy(alpha = 0.18f)
                    ),
                    start = Offset.Zero,
                    end = Offset(500f, 500f)
                ),
                shape = RoundedCornerShape(24.dp)
            )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .height(130.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accentColor,
                modifier = Modifier.size(24.dp)
            )

            Spacer(modifier = Modifier.weight(1f))

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = value,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.7f),
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Quick Actions (iOS: horizontal ScrollView of capsule buttons)
// ──────────────────────────────────────────────────────────────

@Composable
private fun QuickActionsSection(
    actions: List<QuickAction>,
    onClick: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            text = localizedText("快捷操作", "Quick Actions", "クイック操作"),
            style = MaterialTheme.typography.titleMedium,
            color = Color.White.copy(alpha = 0.9f),
            fontWeight = FontWeight.SemiBold
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            actions.forEach { action ->
                QuickActionCapsuleButton(
                    title = action.title,
                    icon = action.icon,
                    color = action.color,
                    onClick = { onClick(action.route) }
                )
            }
        }
    }
}

@Composable
private fun QuickActionCapsuleButton(
    title: String,
    icon: ImageVector,
    color: Color,
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color(0xFF1E2537).copy(alpha = 0.62f))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.30f),
                        Color.Transparent,
                        color.copy(alpha = 0.24f)
                    ),
                    start = Offset.Zero,
                    end = Offset(300f, 300f)
                ),
                shape = RoundedCornerShape(999.dp)
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(20.dp)
        )
        Text(
            text = title,
            style = MaterialTheme.typography.bodyMedium,
            color = Color.White,
            fontWeight = FontWeight.Medium
        )
    }
}

// ──────────────────────────────────────────────────────────────
// Recent Devices (iOS: individual glass rows)
// ──────────────────────────────────────────────────────────────

@Composable
private fun RecentDevicesSection(
    devices: List<DashboardRecentDevice>,
    onViewAll: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = t("附近设备", "Nearby Devices", "近くのデバイス"),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White.copy(alpha = 0.9f),
                fontWeight = FontWeight.SemiBold
            )
            Spacer(modifier = Modifier.weight(1f))
            TextButton(onClick = onViewAll) {
                Text(
                    text = t("查看全部", "View All", "すべて表示"),
                    style = MaterialTheme.typography.labelLarge,
                    color = Color(0xFF00BCD4)
                )
            }
        }

        if (devices.isEmpty()) {
            IOSGlassCard {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 30.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Search,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.4f),
                        modifier = Modifier.size(40.dp)
                    )
                    Text(
                        text = t("未发现设备", "No devices found", "デバイスが見つかりません"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                    Text(
                        text = t("确保设备在同一网络下", "Make sure devices are on the same network", "デバイスが同じネットワーク上にあることを確認してください"),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.4f)
                    )
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                devices.forEach { device ->
                    RecentDeviceRow(device = device)
                }
            }
        }
    }
}

@Composable
private fun RecentDeviceRow(device: DashboardRecentDevice) {
    val statusText = if (device.isConnected) localizedText("已连接", "Connected", "接続済み") else localizedText("可连接", "Ready to Connect", "接続可能")
    val statusColor = if (device.isConnected) Color(0xFF34C759) else Color.White.copy(alpha = 0.68f)
    val statusBackground = if (device.isConnected) Color(0xFF34C759).copy(alpha = 0.18f) else Color(0xFF1E2537).copy(alpha = 0.62f)
    val platformColor = when {
        device.platformLabel.contains("iOS", ignoreCase = true) -> Color(0xFF00BCD4)
        device.platformLabel.contains("macOS", ignoreCase = true) -> Color(0xFF0A84FF)
        device.platformLabel.contains("Android", ignoreCase = true) -> Color(0xFF34C759)
        device.platformLabel.contains("Windows", ignoreCase = true) -> Color(0xFF0A84FF)
        device.platformLabel.contains("Linux", ignoreCase = true) -> Color(0xFFFF9F0A)
        else -> Color.Gray
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1E2537).copy(alpha = 0.60f))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(Color.White.copy(alpha = 0.24f), Color.Transparent),
                    start = Offset.Zero,
                    end = Offset(500f, 500f)
                ),
                shape = RoundedCornerShape(16.dp)
            )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(
                        brush = Brush.linearGradient(
                            listOf(platformColor.copy(alpha = 0.3f), platformColor.copy(alpha = 0.1f))
                        ),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Devices,
                    contentDescription = null,
                    tint = platformColor,
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(modifier = Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = device.name,
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = statusText,
                        style = MaterialTheme.typography.labelSmall,
                        color = statusColor,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .background(statusBackground, RoundedCornerShape(999.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = device.platformLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                    Text(
                        text = "·",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                    Text(
                        text = device.address,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f),
                        maxLines = 1
                    )
                }
            }

            Text(
                text = "›",
                style = MaterialTheme.typography.titleLarge,
                color = Color.White.copy(alpha = 0.3f)
            )
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Active Connections (iOS: ConnectionRowView)
// ──────────────────────────────────────────────────────────────

@Composable
private fun ActiveConnectionsSection(connections: List<DashboardActiveConnection>) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = localizedText("活跃连接", "Active Connections", "アクティブ接続"),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White.copy(alpha = 0.9f),
                fontWeight = FontWeight.SemiBold
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                text = "${connections.size}",
                style = MaterialTheme.typography.labelMedium,
                color = Color(0xFF00BCD4),
                modifier = Modifier
                    .background(Color(0xFF00BCD4).copy(alpha = 0.15f), RoundedCornerShape(999.dp))
                    .border(1.dp, Color(0xFF00BCD4).copy(alpha = 0.3f), RoundedCornerShape(999.dp))
                    .padding(horizontal = 10.dp, vertical = 4.dp)
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            connections.forEach { connection ->
                ActiveConnectionRow(connection = connection)
            }
        }
    }
}

@Composable
private fun ActiveConnectionRow(connection: DashboardActiveConnection) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1E2537).copy(alpha = 0.60f))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color(0xFF34C759).copy(alpha = 0.30f),
                        Color.Transparent,
                        Color(0xFF34C759).copy(alpha = 0.08f)
                    ),
                    start = Offset.Zero,
                    end = Offset(500f, 500f)
                ),
                shape = RoundedCornerShape(16.dp)
            )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(Color(0xFF34C759).copy(alpha = 0.2f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Computer,
                    contentDescription = null,
                    tint = Color(0xFF34C759),
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = connection.deviceName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White,
                    fontWeight = FontWeight.Medium
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = connection.platformLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                    Text(text = "·", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f))
                    Text(
                        text = connection.protocolLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                    Text(text = "·", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f))
                    Text(
                        text = connection.statusLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f)
                    )
                }
            }
            Text(
                text = "${connection.latencyMs}ms",
                style = MaterialTheme.typography.labelSmall,
                color = Color.White.copy(alpha = 0.58f)
            )
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Shared Glass Card (iOS: .ultraThinMaterial + gradient stroke)
// ──────────────────────────────────────────────────────────────

@Composable
private fun IOSGlassCard(
    modifier: Modifier = Modifier,
    accentColor: Color = Color(0xFF00BCD4),
    cornerRadius: Int = 24,
    content: @Composable () -> Unit
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cornerRadius.dp))
            .background(Color(0xFF1E2537).copy(alpha = 0.62f))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.30f),
                        Color.Transparent,
                        accentColor.copy(alpha = 0.12f)
                    ),
                    start = Offset.Zero,
                    end = Offset(600f, 600f)
                ),
                shape = RoundedCornerShape(cornerRadius.dp)
            )
    ) {
        content()
    }
}

// ──────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────

private fun DashboardWeatherIcon.toImageVector(): ImageVector = when (this) {
    DashboardWeatherIcon.Sunny -> Icons.Filled.WbSunny
    DashboardWeatherIcon.Cloudy -> Icons.Filled.Cloud
    DashboardWeatherIcon.Rainy -> Icons.Filled.Thunderstorm
    DashboardWeatherIcon.Offline -> Icons.Filled.WifiOff
}

private data class QuickAction(
    val title: String,
    val icon: ImageVector,
    val route: String,
    val color: Color
)

@Preview(showBackground = true)
@Composable
private fun DashboardScreenPreview() {
    SkyBridgeCompassTheme {
        DashboardScreen(navController = rememberNavController())
    }
}
