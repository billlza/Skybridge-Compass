package com.yunqiao.sinan.ui.screen

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.data.DeviceStatusManager
import com.yunqiao.sinan.data.NavigationItem
import com.yunqiao.sinan.data.navigationItems
import com.yunqiao.sinan.data.rememberDeviceStatusManager
import com.yunqiao.sinan.ui.component.DeviceStatusBar
import com.yunqiao.sinan.ui.component.MainWeatherWidget
import com.yunqiao.sinan.ui.component.SideNavigation
import com.yunqiao.sinan.ui.theme.LocalThemeIsDark
import com.yunqiao.sinan.ui.theme.ModernGlassColors
import com.yunqiao.sinan.ui.theme.ModernShapes
import com.yunqiao.sinan.weather.UnifiedWeatherManager
import com.yunqiao.sinan.weather.UnifiedWeatherState
import com.yunqiao.sinan.weather.WeatherConfig
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    onThemeChange: ((Boolean, Boolean) -> Unit)? = null
) {
    var selectedRoute by remember { mutableStateOf("system_monitor") }
    val deviceStatusManager = rememberDeviceStatusManager()
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val colorScheme = MaterialTheme.colorScheme
    val isDarkTheme = LocalThemeIsDark.current
    
    // 天气管理器 - 安全初始化
    val context = LocalContext.current
    val weatherManager = remember { 
        try {
            UnifiedWeatherManager.getInstance(context)
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
    val weatherState by (weatherManager?.unifiedWeatherState?.collectAsState() ?: remember { mutableStateOf(UnifiedWeatherState()) })
    val weatherConfig by (weatherManager?.weatherConfig?.collectAsState() ?: remember { mutableStateOf(WeatherConfig()) })
    
    // 背景动画
    val infiniteTransition = rememberInfiniteTransition(label = "background")
    val backgroundOffset by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(4000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "background_offset"
    )
    
    // 使用现代化的抽屉式导航
    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            // 现代化侧边栏
            SideNavigation(
                navigationItems = navigationItems,
                selectedRoute = selectedRoute,
                onItemClick = { route ->
                    selectedRoute = route
                    scope.launch {
                        drawerState.close()
                    }
                },
                onThemeChange = onThemeChange,
                modifier = Modifier.fillMaxSize()
            )
        }
    ) {
        // 主内容区域 - 现代化设计
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = colorScheme.background
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        brush = if (isDarkTheme) {
                            Brush.radialGradient(
                                colors = listOf(
                                    colorScheme.surface,
                                    colorScheme.background,
                                    colorScheme.surfaceVariant
                                ),
                                center = androidx.compose.ui.geometry.Offset(
                                    x = backgroundOffset * 1000f,
                                    y = backgroundOffset * 800f
                                )
                            )
                        } else {
                            Brush.linearGradient(
                                colors = listOf(
                                    colorScheme.surfaceContainerHighest,
                                    colorScheme.surface,
                                    colorScheme.surfaceContainer
                                )
                            )
                        }
                    )
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 24.dp, vertical = 16.dp)
                ) {
                    // 现代化顶部栏
                    ModernTopAppBar(
                        selectedRoute = selectedRoute,
                        onMenuClick = {
                            scope.launch {
                                if (drawerState.isClosed) {
                                    drawerState.open()
                                } else {
                                    drawerState.close()
                                }
                            }
                        },
                        deviceStatusManager = deviceStatusManager,
                        weatherSummary = weatherManager?.getWeatherSummary() ?: com.yunqiao.sinan.weather.WeatherSummary(),
                        showWeather = weatherConfig.showInMainScreen,
                        onWeatherClick = {
                            selectedRoute = "weather_center"
                        }
                    )
                    
                    Spacer(modifier = Modifier.height(24.dp))
                    
                    // 主内容区域
                    ModernMainContentArea(
                        selectedRoute = selectedRoute,
                        deviceStatusManager = deviceStatusManager,
                        onNavigate = { route -> selectedRoute = route },
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        }
    }
}

/**
 * 现代化顶部应用栏
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModernTopAppBar(
    selectedRoute: String,
    onMenuClick: () -> Unit,
    deviceStatusManager: DeviceStatusManager,
    weatherSummary: com.yunqiao.sinan.weather.WeatherSummary,
    showWeather: Boolean = true,
    onWeatherClick: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    
    // 按钮动画
    val menuButtonScale by animateFloatAsState(
        targetValue = 1f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "menu_scale"
    )
    
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // 第一行：菜单按钮 + 标题 + 设备状态
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 现代化菜单按钮
            Surface(
                onClick = onMenuClick,
                modifier = Modifier
                    .size(56.dp)
                    .graphicsLayer {
                        scaleX = menuButtonScale
                        scaleY = menuButtonScale
                    },
                shape = CircleShape,
                color = colorScheme.primaryContainer,
                tonalElevation = 6.dp
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize()
                ) {
                    Icon(
                        imageVector = Icons.Default.Menu,
                        contentDescription = "打开菜单",
                        tint = colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(24.dp)
                    )
                }
            }
            
            Spacer(modifier = Modifier.width(20.dp))
            
            // 页面标题区域
            Column(
                modifier = Modifier.weight(1f)
            ) {
                val pageTitle = when (selectedRoute) {
                    "main_control" -> "主控制台"
                    "system_monitor" -> "系统监控"
                    "weather_center" -> "天气中心"
                    "weather_settings" -> "天气设置"
                    "ai_assistant" -> "AI智能助手"
                    "remote_desktop" -> "远程桌面"
                    "file_transfer" -> "文件传输"
                    "device_discovery" -> "设备发现"
                    "node6_dashboard" -> "Node 6 控制台"
                    "user_settings" -> "用户设置"
                    else -> "云桥司南"
                }
                
                Text(
                    text = pageTitle,
                    style = MaterialTheme.typography.headlineMedium,
                    color = colorScheme.onSurface,
                    fontWeight = FontWeight.Bold
                )
                
                Text(
                    text = "SkyBridge Compass",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colorScheme.onSurface.copy(alpha = 0.7f)
                )
            }
            
            // 设备状态栏（简化版）
            Surface(
                shape = ModernShapes.large,
                color = colorScheme.surfaceContainer,
                tonalElevation = 2.dp
            ) {
                DeviceStatusBar(
                    modifier = Modifier.padding(12.dp),
                    deviceStatusManager = deviceStatusManager
                )
            }
        }
        
        // 第二行：天气组件（如果启用）
        if (showWeather && selectedRoute != "weather_center" && selectedRoute != "weather_settings") {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = ModernShapes.large,
                color = colorScheme.surfaceContainer,
                tonalElevation = 4.dp,
                onClick = onWeatherClick
            ) {
                MainWeatherWidget(
                    weatherSummary = weatherSummary,
                    onWeatherClick = onWeatherClick,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    isCompact = false
                )
            }
        }
    }
}

/**
 * 现代化主内容区域
 */
@Composable
fun ModernMainContentArea(
    selectedRoute: String,
    deviceStatusManager: DeviceStatusManager,
    onNavigate: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    
    // 内容切换动画
    val contentTransition = remember {
        spring<Float>(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        )
    }
    
    Surface(
        modifier = modifier.fillMaxSize(),
        shape = ModernShapes.extraLarge,
        color = colorScheme.surfaceContainer.copy(alpha = 0.7f),
        tonalElevation = 8.dp
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(ModernShapes.extraLarge)
                .padding(24.dp)
        ) {
            when (selectedRoute) {
                "main_control" -> {
                    // 主控制台页面
                    MainControlScreen(
                        modifier = Modifier.fillMaxSize(),
                        deviceStatusManager = deviceStatusManager,
                        onNavigate = onNavigate
                    )
                }
                "weather_center" -> {
                    // 天气中心页面
                    WeatherCenterScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "weather_settings" -> {
                    // 天气设置页面
                    WeatherSettingsScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "ai_assistant" -> {
                    // AI助手页面
                    AIAssistantScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "node6_dashboard" -> {
                    // Node 6 控制台
                    Node6DashboardScreen(
                        modifier = Modifier.fillMaxSize(),
                        onNavigate = onNavigate
                    )
                }
                "system_monitor" -> {
                    // 系统监控页面 - 使用真实数据
                    SystemMonitorScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "device_discovery" -> {
                    // 设备发现页面 - 使用真实扫描
                    DeviceDiscoveryScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "remote_desktop" -> {
                    // 远程桌面页面 - 集成WebRTC和QUIC
                    RemoteDesktopScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "file_transfer" -> {
                    FileTransferScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                "user_settings" -> {
                    UserSettingsScreen(
                        modifier = Modifier.fillMaxSize()
                    )
                }
                else -> {
                    // 其他页面的现代化占位符
                    ModernPlaceholderContent(
                        selectedRoute = selectedRoute,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
        }
    }
}

/**
 * 现代化占位符内容
 */
@Composable
fun ModernPlaceholderContent(
    selectedRoute: String,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    
    // 动画效果
    val infiniteTransition = rememberInfiniteTransition(label = "placeholder")
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 0.8f,
        animationSpec = infiniteRepeatable(
            animation = tween(2000, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "alpha"
    )
    
    Box(
        modifier = modifier,
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            val title = when (selectedRoute) {
                "file_transfer" -> "文件传输"
                "user_settings" -> "用户设置"
                else -> "未知页面"
            }
            
            // 占位符图标
            Surface(
                modifier = Modifier
                    .size(80.dp)
                    .graphicsLayer { this.alpha = alpha },
                shape = CircleShape,
                color = colorScheme.primary.copy(alpha = 0.2f)
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize()
                ) {
                    Text(
                        text = "🛠",
                        style = MaterialTheme.typography.displayMedium
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(24.dp))
            
            Text(
                text = title,
                style = MaterialTheme.typography.headlineLarge,
                color = colorScheme.onSurface,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            Text(
                text = "功能正在开发中...",
                style = MaterialTheme.typography.bodyLarge,
                color = colorScheme.onSurface.copy(alpha = 0.7f),
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(32.dp))
            
            // 现代化加载指示器
            LinearProgressIndicator(
                modifier = Modifier.width(120.dp),
                color = colorScheme.primary,
                trackColor = colorScheme.surfaceVariant
            )
        }
    }
}
