package com.skybridge.compass.android.ui.screens.dashboard

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
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
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.BlurOn
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Dehaze
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockClock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbCloudy
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.ui.components.IOSGlassCard
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.components.iosPlatformAccent
import com.skybridge.compass.android.ui.navigation.NavigationSemantics
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.theme.IOSParityTokens
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.android.weather.AirQualityLevel
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

    // Coarse location is only ever requested from the weather card's own affordance, so the
    // dashboard never prompts unless the user asked for a precise reading.
    val locationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { viewModel.onLocationPermissionChanged() }

    // iOS parity: all four quick actions are always available — file transfer and remote
    // desktop are shipping features, so they no longer hinge on the developer feature-flags
    // (matching the now-ungated bottom-nav tabs).
    val quickActions = listOf(
        QuickAction(
            id = NavigationSemantics.ACTION_SCAN_NETWORK,
            title = t("扫描网络", "Scan Network", "ネットワークをスキャン"),
            icon = Icons.Filled.Search,
            route = Screen.DeviceDiscovery.route,
            color = IOSParityTokens.ColorTokens.CyanAccent
        ),
        QuickAction(
            id = NavigationSemantics.ACTION_SEND_FILE,
            title = t("发送文件", "Send File", "ファイル送信"),
            icon = Icons.AutoMirrored.Filled.Send,
            route = Screen.FileTransfer.route,
            color = IOSParityTokens.ColorTokens.PurpleAccent
        ),
        QuickAction(
            id = NavigationSemantics.ACTION_REMOTE_DESKTOP,
            title = t("远程桌面", "Remote Desktop", "リモートデスクトップ"),
            icon = Icons.Filled.Computer,
            route = Screen.RemoteControl.route,
            color = IOSParityTokens.ColorTokens.PrimaryBlue
        ),
        QuickAction(
            id = NavigationSemantics.ACTION_CROSS_NETWORK,
            title = t("跨网连接", "Cross-Network", "クロスネット接続"),
            icon = Icons.Filled.Devices,
            route = Screen.DeviceDiscovery.route,
            color = Color(0xFF00C7BE)
        )
    )

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(NavigationSemantics.DASHBOARD_SCROLL)
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
                onOpenNotifications = {
                    // No standalone notification center on Android; the account/activity
                    // surface is where pending pairing + transfer events land.
                    navController.navigate(Screen.AccountCenter.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                }
            )
        }

        item { WelcomeCard(state = state) }

        state.liveTransfer?.let { transfer ->
            item { LiveTransferBanner(transfer = transfer) }
        }

        item {
            WeatherCard(
                weather = state.weather,
                onRefresh = viewModel::refresh,
                onEnableWeather = viewModel::enableRealTimeWeather,
                onRequestLocationPermission = {
                    locationPermissionLauncher.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
                }
            )
        }
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
    onOpenNotifications: () -> Unit
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
                        modifier = Modifier.testTag(NavigationSemantics.DASHBOARD_TITLE),
                        style = MaterialTheme.typography.labelLarge,
                        color = Color.White.copy(alpha = 0.92f),
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            // Trailing actions mirror iOS: refresh + notification bell + QR-scan
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
                    icon = Icons.Filled.Notifications,
                    contentDescription = t("通知", "Notifications", "通知"),
                    onClick = onOpenNotifications
                )
                DashboardIconCircleButton(
                    icon = Icons.Filled.QrCodeScanner,
                    contentDescription = t("扫码连接", "Scan to Connect", "コードを読み取って接続"),
                    onClick = onOpenScanner
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
        Build.SUPPORTED_ABIS.isNotEmpty() -> Build.SUPPORTED_ABIS.first().uppercase(Locale.ROOT)
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

            // Security badge — 4-state, mirrors iOS securityBadgePresentation
            // (PQC=green lock.shield.fill / Classic=blue lock.fill / 待确认=orange lock / 离线=gray lock.slash)
            SecurityBadgeView(badge = state.securityBadge)
        }
    }
}

@Composable
private fun SecurityBadgeView(badge: DashboardSecurityBadge) {
    val badgeColor = IOSParityTokens.SecurityBadge.color(badge.tone)
    val badgeIcon = when (badge.tone) {
        IOSParityTokens.SecurityBadgeTone.VerifiedPqc -> Icons.Filled.GppGood
        IOSParityTokens.SecurityBadgeTone.Classic -> Icons.Filled.Lock
        IOSParityTokens.SecurityBadgeTone.Pending -> Icons.Filled.LockClock
        IOSParityTokens.SecurityBadgeTone.Offline -> Icons.Filled.LockOpen
    }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(16.dp))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        badgeColor.copy(alpha = 0.4f),
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
            imageVector = badgeIcon,
            contentDescription = badge.label,
            tint = badgeColor,
            modifier = Modifier
                .size(22.dp)
                .shadow(
                    elevation = 4.dp,
                    shape = CircleShape,
                    ambientColor = badgeColor.copy(alpha = 0.4f),
                    spotColor = badgeColor.copy(alpha = 0.4f)
                )
        )
        Text(
            text = badge.label,
            style = MaterialTheme.typography.labelSmall,
            color = badgeColor,
            fontWeight = FontWeight.Bold,
            fontSize = 10.sp
        )
    }
}

// ──────────────────────────────────────────────────────────────
// Live Transfer Banner (iOS: transferOverviewSection / LiveTransferBannerView)
// Active  → animated gradient progress bar + speed
// Idle    → last-result chip (success / fail)
// ──────────────────────────────────────────────────────────────

@Composable
private fun LiveTransferBanner(transfer: DashboardLiveTransfer) {
    val accent = if (transfer.isActive) IOSParityTokens.ColorTokens.PrimaryBlue
        else if (transfer.succeeded) IOSParityTokens.ColorTokens.SuccessGreen
        else IOSParityTokens.ColorTokens.ErrorRed
    val leadingIcon = when {
        transfer.isActive -> Icons.AutoMirrored.Filled.Send
        transfer.succeeded -> Icons.Filled.CheckCircle
        else -> Icons.Filled.ErrorOutline
    }

    IOSGlassCard {
        Column(modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .background(accent.copy(alpha = 0.2f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = leadingIcon,
                        contentDescription = null,
                        tint = accent,
                        modifier = Modifier.size(18.dp)
                    )
                }

                Spacer(modifier = Modifier.width(16.dp))

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = transfer.title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = transfer.detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.65f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                if (transfer.isActive && transfer.speedText.isNotBlank()) {
                    Text(
                        text = transfer.speedText,
                        style = MaterialTheme.typography.labelSmall,
                        color = accent,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .background(accent.copy(alpha = 0.15f), RoundedCornerShape(999.dp))
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    )
                } else if (!transfer.isActive) {
                    Text(
                        text = if (transfer.succeeded) t("完成", "Done", "完了") else t("失败", "Failed", "失敗"),
                        style = MaterialTheme.typography.labelSmall,
                        color = accent,
                        modifier = Modifier
                            .background(accent.copy(alpha = 0.15f), RoundedCornerShape(999.dp))
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    )
                }
            }

            if (transfer.isActive) {
                Spacer(modifier = Modifier.height(12.dp))
                AnimatedTransferProgressBar(accent = accent)
            }
        }
    }
}

/**
 * Indeterminate animated gradient bar. Aggregate telemetry has no per-file percentage, so the
 * bar sweeps a moving cyan -> blue gradient to convey "in flight" without faking fixed progress.
 */
@Composable
private fun AnimatedTransferProgressBar(accent: Color) {
    val transition = rememberInfiniteTransition(label = "transferSweep")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1400, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "sweep"
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(6.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = 0.08f))
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(
                    Brush.horizontalGradient(
                        colorStops = arrayOf(
                            ((phase - 0.3f).coerceIn(0f, 1f)) to Color.Transparent,
                            phase.coerceIn(0f, 1f) to accent,
                            ((phase + 0.3f).coerceIn(0f, 1f)) to IOSParityTokens.ColorTokens.CyanAccent,
                            1f to Color.Transparent
                        )
                    )
                )
        )
    }
}

// ──────────────────────────────────────────────────────────────
// Weather Card (macOS: WeatherDashboardCard / iOS: WeatherCardView)
// ──────────────────────────────────────────────────────────────

@Composable
private fun WeatherCard(
    weather: DashboardWeatherCardState,
    onRefresh: () -> Unit,
    onEnableWeather: () -> Unit,
    onRequestLocationPermission: () -> Unit
) {
    IOSGlassCard {
        Box(modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
            when (weather) {
                is DashboardWeatherCardState.Resolving -> WeatherPlaceholderRow(
                    icon = Icons.Filled.Cloud,
                    iconTint = Color.White.copy(alpha = 0.5f),
                    title = t("实时天气", "Real-Time Weather", "リアルタイム天気"),
                    message = t("正在读取设置…", "Reading settings…", "設定を読み込んでいます…")
                )

                is DashboardWeatherCardState.Disabled -> WeatherPlaceholderRow(
                    icon = Icons.Filled.CloudOff,
                    iconTint = Color.White.copy(alpha = 0.68f),
                    title = weather.title,
                    message = weather.message,
                    action = weather.actionLabel to onEnableWeather,
                    actionIcon = Icons.Filled.MyLocation
                )

                is DashboardWeatherCardState.Loading -> WeatherPlaceholderRow(
                    icon = Icons.Filled.Cloud,
                    iconTint = IOSParityTokens.ColorTokens.CyanAccent,
                    title = weather.title,
                    message = weather.message,
                    showProgress = true
                )

                is DashboardWeatherCardState.Error -> WeatherPlaceholderRow(
                    icon = Icons.Filled.ErrorOutline,
                    iconTint = Color(0xFFFF9F0A),
                    title = weather.title,
                    message = weather.message,
                    action = weather.actionLabel to onRefresh,
                    actionIcon = Icons.Filled.Refresh
                )

                is DashboardWeatherCardState.Ready -> WeatherReadyContent(
                    weather = weather,
                    onRefresh = onRefresh,
                    onRequestLocationPermission = onRequestLocationPermission
                )
            }
        }
    }
}

@Composable
private fun WeatherReadyContent(
    weather: DashboardWeatherCardState.Ready,
    onRefresh: () -> Unit,
    onRequestLocationPermission: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.width(80.dp)
            ) {
                WeatherConditionGlyph(icon = weather.icon)
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = weather.temperatureText,
                    style = MaterialTheme.typography.headlineSmall,
                    color = Color.White,
                    fontWeight = FontWeight.Thin
                )
                weather.feelsLikeText?.let { feelsLike ->
                    Text(
                        text = feelsLike,
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.56f),
                        fontSize = 9.sp
                    )
                }
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
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = weather.conditionText,
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.7f)
                        )
                    }
                    WeatherRefreshButton(
                        isRefreshing = weather.isRefreshing,
                        onClick = onRefresh
                    )
                }

                if (weather.metrics.isNotEmpty()) {
                    WeatherMetricsGrid(metrics = weather.metrics)
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

        weather.staleNotice?.let { notice ->
            WeatherFootnote(icon = Icons.Filled.WifiOff, text = notice, tint = Color(0xFFFF9F0A))
        }

        weather.locationUpgradeLabel?.let { label ->
            WeatherFootnote(
                icon = Icons.Filled.MyLocation,
                text = label,
                tint = IOSParityTokens.ColorTokens.CyanAccent,
                onClick = onRequestLocationPermission
            )
        }
    }
}

@Composable
private fun WeatherConditionGlyph(icon: DashboardWeatherIcon) {
    val accent = icon.accentColor()
    Box(
        modifier = Modifier
            .size(56.dp)
            .background(
                // Radial wash standing in for the macOS card's icon glow.
                Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = 0.30f), Color.Transparent)
                ),
                CircleShape
            ),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon.toImageVector(),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(28.dp)
        )
    }
}

/** Two-column metric grid matching the macOS card's `LazyVGrid`. */
@Composable
private fun WeatherMetricsGrid(metrics: List<DashboardWeatherMetric>) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        metrics.chunked(2).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                row.forEach { metric ->
                    WeatherMetricBadge(
                        metric = metric,
                        modifier = Modifier.weight(1f)
                    )
                }
                if (row.size == 1) {
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun WeatherRefreshButton(isRefreshing: Boolean, onClick: () -> Unit) {
    val refreshDescription = localizedText("刷新天气", "Refresh Weather", "天気を更新")
    val rotation by rememberInfiniteTransition(label = "weather-refresh").animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "weather-refresh-rotation"
    )

    Box(
        modifier = Modifier
            .size(28.dp)
            .background(Color(0xFF1E2537).copy(alpha = 0.62f), CircleShape)
            .clip(CircleShape)
            .clickable(enabled = !isRefreshing, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = Icons.Filled.Refresh,
            contentDescription = refreshDescription,
            tint = Color.White.copy(alpha = if (isRefreshing) 0.5f else 0.9f),
            modifier = Modifier
                .size(12.dp)
                .rotate(if (isRefreshing) rotation else 0f)
        )
    }
}

@Composable
private fun WeatherMetricBadge(
    metric: DashboardWeatherMetric,
    modifier: Modifier = Modifier
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier
            .background(Color(0xFF1E2537).copy(alpha = 0.62f), RoundedCornerShape(999.dp))
            .padding(horizontal = 7.dp, vertical = 4.dp)
    ) {
        Icon(
            imageVector = metric.kind.toImageVector(),
            contentDescription = null,
            tint = metric.airQualityLevel?.toColor() ?: Color(0xFF00BCD4),
            modifier = Modifier.size(10.dp)
        )
        Text(
            text = metric.label,
            style = MaterialTheme.typography.labelSmall,
            color = Color.White.copy(alpha = 0.6f),
            fontSize = 9.sp,
            maxLines = 1
        )
        Text(
            text = metric.value,
            style = MaterialTheme.typography.labelSmall,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun WeatherFootnote(
    icon: ImageVector,
    text: String,
    tint: Color,
    onClick: (() -> Unit)? = null
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .background(tint.copy(alpha = 0.10f), RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(12.dp)
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = Color.White.copy(alpha = 0.82f),
            fontSize = 10.sp
        )
    }
}

/** Shared layout for the resolving / disabled / loading / error branches. */
@Composable
private fun WeatherPlaceholderRow(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    message: String,
    showProgress: Boolean = false,
    action: Pair<String, () -> Unit>? = null,
    actionIcon: ImageVector = Icons.Filled.Refresh
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Box(
            modifier = Modifier.size(56.dp),
            contentAlignment = Alignment.Center
        ) {
            if (showProgress) {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    strokeWidth = 2.dp,
                    color = iconTint
                )
            } else {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = iconTint,
                    modifier = Modifier.size(34.dp)
                )
            }
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = Color.White,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.68f),
                fontSize = 11.sp
            )
            action?.let { (label, onClick) ->
                Spacer(modifier = Modifier.height(2.dp))
                WeatherFootnote(
                    icon = actionIcon,
                    text = label,
                    tint = IOSParityTokens.ColorTokens.CyanAccent,
                    onClick = onClick
                )
            }
        }
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
            modifier = Modifier
                .weight(1f)
                .testTag(NavigationSemantics.DASHBOARD_DISCOVERY_STAT),
            title = localizedText("发现与连接", "Discovery & Connections", "検出と接続"),
            value = "${state.connectedDevices} / ${state.activeSessions}",
            icon = Icons.Filled.Wifi,
            accentColor = Color(0xFF00BCD4)
        )
        StatCard(
            modifier = Modifier
                .weight(1f)
                .testTag(NavigationSemantics.DASHBOARD_TRANSFER_STAT),
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
                    actionId = action.id,
                    title = action.title,
                    icon = action.icon,
                    route = action.route,
                    color = action.color,
                    onClick = { onClick(action.route) }
                )
            }
        }
    }
}

@Composable
private fun QuickActionCapsuleButton(
    actionId: String,
    title: String,
    icon: ImageVector,
    route: String,
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
            .testTag(NavigationSemantics.dashboardAction(actionId, route))
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
    val statusColor = if (device.isConnected) IOSParityTokens.ColorTokens.SuccessGreen else Color.White.copy(alpha = 0.68f)
    val statusBackground = if (device.isConnected) IOSParityTokens.ColorTokens.SuccessGreen.copy(alpha = 0.18f) else Color(0xFF1E2537).copy(alpha = 0.62f)
    val platformColor = iosPlatformAccent(device.platformLabel)

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
// Helpers
// ──────────────────────────────────────────────────────────────

private fun DashboardWeatherIcon.toImageVector(): ImageVector = when (this) {
    DashboardWeatherIcon.Sunny -> Icons.Filled.WbSunny
    DashboardWeatherIcon.PartlyCloudy -> Icons.Filled.WbCloudy
    DashboardWeatherIcon.Cloudy -> Icons.Filled.Cloud
    DashboardWeatherIcon.Rainy -> Icons.Filled.WaterDrop
    DashboardWeatherIcon.Snowy -> Icons.Filled.AcUnit
    DashboardWeatherIcon.Foggy -> Icons.Filled.Dehaze
    DashboardWeatherIcon.Haze -> Icons.Filled.BlurOn
    DashboardWeatherIcon.Stormy -> Icons.Filled.Thunderstorm
    DashboardWeatherIcon.Unknown -> Icons.Filled.Cloud
}

/** Condition tint, mirroring the macOS card's `iconColor(for:)` mapping. */
private fun DashboardWeatherIcon.accentColor(): Color = when (this) {
    DashboardWeatherIcon.Sunny -> Color(0xFFFFD60A)
    DashboardWeatherIcon.PartlyCloudy -> Color(0xFFB9C6D8)
    DashboardWeatherIcon.Cloudy -> Color(0xFF9AA6B8)
    DashboardWeatherIcon.Rainy -> Color(0xFF0A84FF)
    DashboardWeatherIcon.Snowy -> Color(0xFF64D2FF)
    DashboardWeatherIcon.Foggy,
    DashboardWeatherIcon.Haze -> Color(0xFF9AA6B8).copy(alpha = 0.7f)
    DashboardWeatherIcon.Stormy -> Color(0xFFBF5AF2)
    DashboardWeatherIcon.Unknown -> Color(0xFF9AA6B8)
}

private fun DashboardWeatherMetricKind.toImageVector(): ImageVector = when (this) {
    DashboardWeatherMetricKind.HUMIDITY -> Icons.Filled.WaterDrop
    DashboardWeatherMetricKind.WIND -> Icons.Filled.Air
    DashboardWeatherMetricKind.VISIBILITY -> Icons.Filled.Visibility
    DashboardWeatherMetricKind.AIR_QUALITY -> Icons.Filled.Spa
}

/** AQI banding colours, matching the macOS card's `aqiColor(aqi:)` ramp. */
private fun AirQualityLevel.toColor(): Color = when (this) {
    AirQualityLevel.GOOD -> Color(0xFF30D158)
    AirQualityLevel.MODERATE -> Color(0xFFFFD60A)
    AirQualityLevel.SENSITIVE -> Color(0xFFFF9F0A)
    AirQualityLevel.UNHEALTHY -> Color(0xFFFF453A)
    AirQualityLevel.VERY_UNHEALTHY -> Color(0xFFBF5AF2)
    AirQualityLevel.HAZARDOUS -> Color(0xFFA2845E)
}

private data class QuickAction(
    val id: String,
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
