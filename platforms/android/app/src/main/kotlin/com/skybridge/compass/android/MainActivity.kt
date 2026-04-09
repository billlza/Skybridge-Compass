package com.skybridge.compass.android

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.compose.rememberNavController
import dagger.hilt.android.AndroidEntryPoint
import com.skybridge.compass.android.permissions.PermissionManager
import com.skybridge.compass.android.ui.components.BottomNavigationBar
import com.skybridge.compass.android.ui.components.IOSBackgroundEffectsViewModel
import com.skybridge.compass.android.ui.components.IOSDashboardAnimatedBackground
import com.skybridge.compass.android.ui.components.TopActionBar
import com.skybridge.compass.android.ui.navigation.SkyBridgeNavigation
import com.skybridge.compass.android.ui.performance.PerformanceMonitorEffect
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.android.account.AndroidAccountStorage
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.auth.AuthRepository
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager
import com.skybridge.compass.discovery.data.services.P2PLocalNodeService
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json
import javax.inject.Inject
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.material3.Text
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpOffset
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.window.Popup
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.unit.IntOffset
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.i18n.AppLanguageRuntime

@AndroidEntryPoint
class MainActivity : FragmentActivity() {
    private lateinit var permissionManager: PermissionManager
    @Inject lateinit var authRepository: AuthRepository
    @Inject lateinit var httpClient: HttpClient
    @Inject lateinit var json: Json
    @Inject lateinit var p2pLocalNodeService: P2PLocalNodeService
    private var cloudSettingsSync: CloudUserSettingsSyncManager? = null
    private var pendingNavRoute: String? by mutableStateOf(null)
    private var forceVisualTestMode: Boolean by mutableStateOf(false)

    companion object {
        const val EXTRA_NAV_ROUTE = "skybridge.nav_route"
        const val EXTRA_FORCE_VISUAL_TEST_MODE = "skybridge.force_visual_test_mode"
        const val EXTRA_BYPASS_AUTH_FOR_SCREENSHOT = "skybridge.bypass_auth"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // 初始化系统通知发布器（渠道与桥接）
        try {
            com.skybridge.compass.android.notifications.SystemNotifier.init(this)
        } catch (_: Throwable) {}
        // Init security prompt notifications (Review/Decline).
        try {
            SecurityPromptNotifier.init(this)
        } catch (_: Throwable) {}

        // 挂载账号持久化存储，并加载主账号
        try {
            AccountStore.attachStorage(AndroidAccountStorage(applicationContext))
        } catch (_: Throwable) {}

        // 启动云端设置同步（best-effort；无云配置/未登录则自动空转）
        cloudSettingsSync = CloudUserSettingsSyncManager(
            appContext = applicationContext,
            authRepository = authRepository,
            httpClient = httpClient,
            json = json
        ).also { it.start() }

        // Start LAN control endpoint + Bonjour advertising (best-effort).
        lifecycleScope.launch {
            runCatching { p2pLocalNodeService.start() }
        }

        // 首次启动欢迎提示（历史为空且主账号存在时）
        try {
            if (AccountStore.primaryAccount.value != null && NotificationCenter.history.value.isEmpty()) {
                NotificationCenter.post(
                    NotificationEvent(
                        title = resolveLocalizedText("欢迎使用", "Welcome", "ようこそ"),
                        message = resolveLocalizedText(
                            "欢迎回来，${AccountStore.primaryAccount.value?.displayName}！",
                            "Welcome back, ${AccountStore.primaryAccount.value?.displayName}!",
                            "おかえりなさい、${AccountStore.primaryAccount.value?.displayName}さん！"
                        ),
                        module = NotificationModule.SYSTEM,
                        severity = NotificationSeverity.INFO
                    )
                )
            }
        } catch (_: Throwable) {}

        permissionManager = PermissionManager(this)

        handleNavIntent(intent)
        setContent {
            val context = LocalContext.current
            val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
            LaunchedEffect(appSettings.appLanguage) {
                AppLanguageRuntime.applySetting(appSettings.appLanguage)
            }
            SkyBridgeCompassTheme(
                darkTheme = appSettings.darkMode,
                dynamicColor = appSettings.useDynamicColor
            ) {
                LaunchedEffect(appSettings.keepScreenOn) {
                    if (appSettings.keepScreenOn) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                SkyBridgeCompassApp(
                    securityNavRoute = pendingNavRoute,
                    forceVisualTestMode = forceVisualTestMode
                )
            }
        }

        requestPermissionsIfNeeded()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNavIntent(intent)
    }

    private fun handleNavIntent(intent: Intent?) {
        val visualModeEnabledInThisBuild =
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val route = (
            if (visualModeEnabledInThisBuild) intent?.getStringExtra(EXTRA_NAV_ROUTE) else null
        ) ?: intent?.getStringExtra(SecurityPromptNotifier.EXTRA_NAV_ROUTE)
        if (!route.isNullOrBlank()) {
            pendingNavRoute = route
        }
        if (visualModeEnabledInThisBuild) {
            if (intent?.hasExtra(EXTRA_FORCE_VISUAL_TEST_MODE) == true) {
                forceVisualTestMode = intent.getBooleanExtra(EXTRA_FORCE_VISUAL_TEST_MODE, false)
            }
            if (intent?.hasExtra(EXTRA_BYPASS_AUTH_FOR_SCREENSHOT) == true) {
                forceVisualTestMode = intent.getBooleanExtra(EXTRA_BYPASS_AUTH_FOR_SCREENSHOT, false)
            }
        }
    }

    private fun requestPermissionsIfNeeded() {
        if (!permissionManager.areAllPermissionsGranted()) {
            permissionManager.requestAllPermissions { permissions ->
                val deniedPermissions = permissions.filter { !it.value }.keys
                if (deniedPermissions.isNotEmpty()) {
                    println("Denied permissions: $deniedPermissions")
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        lifecycleScope.launch {
            val rememberLogin = runCatching {
                AppSettingsStore.observeRememberLogin(applicationContext).first()
            }.getOrDefault(false)
            if (rememberLogin) {
                runCatching {
                    authRepository.loadSessionFromStorage(true)
                    authRepository.getCurrentUserProfile()?.let { AccountStore.setPrimaryAccount(it) }
                    authRepository.syncNebulaIdFromIdentitiesIfMissing()
                    authRepository.getCurrentUserProfile()?.let { AccountStore.setPrimaryAccount(it) }
                }
            }
        }
    }
}

@Composable
fun SkyBridgeCompassApp(
    securityNavRoute: String? = null,
    forceVisualTestMode: Boolean = false
) {
    val navController = rememberNavController()
    val backgroundEffectsViewModel: IOSBackgroundEffectsViewModel = hiltViewModel()
    val backgroundUi = backgroundEffectsViewModel.uiState
    val authViewModel: com.skybridge.compass.auth.AuthViewModel = androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel()
    val authState = authViewModel.uiState.collectAsState().value

    LaunchedEffect(securityNavRoute, authState.isAuthenticated, forceVisualTestMode) {
        if ((authState.isAuthenticated || forceVisualTestMode) && !securityNavRoute.isNullOrBlank()) {
            runCatching {
                navController.navigate(securityNavRoute) { launchSingleTop = true }
            }
        }
    }

    PerformanceMonitorEffect(
        context = LocalContext.current,
        lifecycleOwner = LocalLifecycleOwner.current
    )

    // 未登录：仅显示登录界面，不展示导航栏
    // Use a light iOS-like gradient background for login instead of dark starfield
    if (!authState.isAuthenticated && !forceVisualTestMode) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                        colors = listOf(
                            Color(0xFFF2F6FC), // Light blue-gray at top
                            Color(0xFFE8EDF5), // Slightly darker blue-gray
                            Color(0xFFF5F5F7)  // Apple-like warm gray at bottom
                        )
                    )
                )
        ) {
            com.skybridge.compass.android.ui.screens.auth.LoginScreen(viewModel = authViewModel)
        }
        return
    }

    Box(modifier = Modifier.fillMaxSize()) {
        IOSDashboardAnimatedBackground(
            condition = backgroundUi.condition,
            isActive = backgroundUi.isActive,
            modifier = Modifier.fillMaxSize()
        )

        androidx.compose.material3.Scaffold(
            modifier = Modifier.fillMaxSize(),
            containerColor = Color.Transparent,
            // iOS: each tab manages its own navigation bar/title area.
            topBar = {},
            bottomBar = { BottomNavigationBar(navController = navController) }
        ) { innerPadding ->
            Surface(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                color = Color.Transparent
            ) {
                SkyBridgeNavigation(navController = navController)
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
fun SkyBridgeCompassAppPreview() {
    SkyBridgeCompassTheme {
        SkyBridgeCompassApp()
    }
}

@Composable
private fun GlobalUserBadgeTopLeft(navController: androidx.navigation.NavHostController, modifier: Modifier = Modifier) {
    val profile = AccountStore.primaryAccount.collectAsState().value
    var showDetails by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    val displayName = profile?.displayName ?: (profile?.email ?: localizedText("未登录", "Not Signed In", "未ログイン"))
    val emailPrefix = localizedText("邮箱：", "Email: ", "メール: ")
    val copyEmailLabel = localizedText("复制邮箱", "Copy Email", "メールをコピー")
    val copyNebulaLabel = localizedText("复制 NebulaID", "Copy NebulaID", "NebulaID をコピー")
    val openAccountCenterLabel = localizedText("打开账户中心", "Open Account Center", "アカウントセンターを開く")
    val initial = displayName.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    LiquidGlassSurface(
        modifier = modifier,
        blurRadius = 16.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.16f),
        tintAlpha = 0.16f,
        borderWidth = 1.dp,
        borderAlpha = 0.18f,
        highlightAlpha = 0.06f,
        edgeGlowAlpha = 0.04f,
        edgeGlowEnabled = true,
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
        onClick = { showDetails = true }
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            val avatarUrl = profile?.avatarUrl
            if (!avatarUrl.isNullOrBlank()) {
                AsyncImage(
                    model = ImageRequest.Builder(ctx)
                        .data(avatarUrl)
                        .crossfade(true)
                        .build(),
                    contentDescription = null,
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                )
            } else {
                androidx.compose.material3.Surface(
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.25f),
                    shape = CircleShape,
                    modifier = Modifier.size(24.dp)
                ) {
                    Box(modifier = Modifier.fillMaxSize()) {
                        Text(
                            text = initial,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimary,
                            modifier = Modifier
                                .align(androidx.compose.ui.Alignment.Center)
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = displayName,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }

    if (showDetails) {
        val density = LocalDensity.current
        val offset = with(density) { IntOffset(12.dp.roundToPx(), 44.dp.roundToPx()) }
        Popup(alignment = androidx.compose.ui.Alignment.TopStart, offset = offset, onDismissRequest = { showDetails = false }) {
            LiquidGlassSurface(
                blurRadius = 20.dp,
                tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.22f),
                tintAlpha = 0.22f,
                borderWidth = 1.dp,
                borderAlpha = 0.22f,
                highlightAlpha = 0.08f,
                edgeGlowAlpha = 0.06f,
                edgeGlowEnabled = true,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
            ) {
                Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        val detailAvatarUrl = profile?.avatarUrl
                        if (!detailAvatarUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = ImageRequest.Builder(ctx)
                                    .data(detailAvatarUrl)
                                    .crossfade(true)
                                    .build(),
                                contentDescription = null,
                                modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                            )
                        } else {
                            androidx.compose.material3.Surface(
                                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.25f),
                                shape = CircleShape,
                                modifier = Modifier.size(40.dp)
                            ) {
                                Box(modifier = Modifier.fillMaxSize()) {
                                    Text(
                                        text = initial,
                                        style = MaterialTheme.typography.titleSmall,
                                        color = MaterialTheme.colorScheme.onPrimary,
                                        modifier = Modifier.align(androidx.compose.ui.Alignment.Center)
                                    )
                                }
                            }
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        Column {
                            Text(displayName, style = MaterialTheme.typography.titleSmall)
                            val email = profile?.email ?: "-"
                            Text("$emailPrefix$email", style = MaterialTheme.typography.bodySmall)
                            val idShort = profile?.nebulaId?.let { if (it.length > 12) "${it.take(6)}...${it.takeLast(4)}" else it } ?: "-"
                            Text("NebulaID：$idShort", style = MaterialTheme.typography.bodySmall)
                        }
                    }

                    @Suppress("DEPRECATION")
                    val clipboard = LocalClipboardManager.current
                    Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                        androidx.compose.material3.TextButton(onClick = {
                            profile?.email?.let { clipboard.setText(androidx.compose.ui.text.AnnotatedString(it)) }
                            showDetails = false
                        }) { Text(copyEmailLabel) }
                        androidx.compose.material3.TextButton(onClick = {
                            profile?.nebulaId?.let { clipboard.setText(androidx.compose.ui.text.AnnotatedString(it)) }
                            showDetails = false
                        }, enabled = (profile?.nebulaId?.isNotBlank() == true)) { Text(copyNebulaLabel) }
                        androidx.compose.material3.TextButton(onClick = {
                            showDetails = false
                            navController.navigate(com.skybridge.compass.android.ui.navigation.Screen.AccountCenter.route)
                        }) { Text(openAccountCenterLabel) }
                    }
                }
            }
        }
    }
}
