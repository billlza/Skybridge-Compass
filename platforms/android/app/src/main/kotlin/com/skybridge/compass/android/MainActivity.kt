package com.skybridge.compass.android

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.util.Log
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
import com.skybridge.compass.android.ui.components.BottomNavigationBar
import com.skybridge.compass.android.ui.components.IOSBackgroundEffectsViewModel
import com.skybridge.compass.android.ui.components.IOSDashboardAnimatedBackground
import com.skybridge.compass.android.ui.components.TopActionBar
import com.skybridge.compass.android.ui.navigation.SkyBridgeNavigation
import com.skybridge.compass.android.ui.navigation.Screen
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
import javax.inject.Inject
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
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
    @Inject lateinit var authRepository: AuthRepository
    private var pendingNavRoute: String? by mutableStateOf(null)
    private var forceVisualTestMode: Boolean by mutableStateOf(false)
    private var forceLoginScreen: Boolean by mutableStateOf(false)

    companion object {
        const val EXTRA_NAV_ROUTE = "skybridge.nav_route"
        const val EXTRA_FORCE_VISUAL_TEST_MODE = "skybridge.force_visual_test_mode"
        const val EXTRA_BYPASS_AUTH_FOR_SCREENSHOT = "skybridge.bypass_auth"
        const val EXTRA_FORCE_LOGIN_SCREEN = "skybridge.force_login_screen"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // 初始化系统通知发布器（渠道与桥接）
        try {
            com.skybridge.compass.android.notifications.SystemNotifier.init(this)
        } catch (t: Throwable) {
            Log.w("SkyBridgeMain", "Failed to initialize system notifier", t)
        }
        // Init security prompt notifications (Review/Decline).
        try {
            SecurityPromptNotifier.init(this)
        } catch (t: Throwable) {
            Log.w("SkyBridgeMain", "Failed to initialize security prompt notifier", t)
        }

        // Account profile contains identifiers and contact fields; encrypted storage is mandatory.
        AccountStore.attachStorage(AndroidAccountStorage(applicationContext))

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
        } catch (t: Throwable) {
            Log.w("SkyBridgeMain", "Failed to post welcome notification", t)
        }

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
                    // 判定见 keepScreenOnWindowFlag（同文件，纯函数、可单元测试）。
                    when (keepScreenOnWindowFlag(appSettings.keepScreenOn)) {
                        KeepScreenOnWindowFlag.ADD ->
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        KeepScreenOnWindowFlag.CLEAR ->
                            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                SkyBridgeCompassApp(
                    securityNavRoute = pendingNavRoute,
                    forceVisualTestMode = forceVisualTestMode,
                    forceLoginScreen = forceLoginScreen
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNavIntent(intent)
    }

    private fun handleNavIntent(intent: Intent?) {
        val visualModeEnabledInThisBuild =
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (visualModeEnabledInThisBuild && intent?.hasExtra(EXTRA_NAV_ROUTE) == true) {
            val requestedRoute = intent.getStringExtra(EXTRA_NAV_ROUTE)
            val resolvedRoute = requestedRoute?.let(::resolveDebugNavigationRoute)
            if (resolvedRoute == null) {
                Log.w("SkyBridgeMain", "Rejected invalid debug navigation route")
            } else {
                pendingNavRoute = resolvedRoute
            }
        }
        when (val review = SecurityPromptNotifier.resolveReviewIntent(intent)) {
            is SecurityPromptNotifier.ReviewIntentResolution.Accepted -> {
                pendingNavRoute = review.route
            }
            is SecurityPromptNotifier.ReviewIntentResolution.Rejected -> {
                Log.w("SkyBridgeMain", "Rejected security review intent: ${review.reason}")
            }
            SecurityPromptNotifier.ReviewIntentResolution.NotPresent -> Unit
        }
        if (visualModeEnabledInThisBuild) {
            if (intent?.hasExtra(EXTRA_FORCE_VISUAL_TEST_MODE) == true) {
                forceVisualTestMode = intent.getBooleanExtra(EXTRA_FORCE_VISUAL_TEST_MODE, false)
            }
            if (intent?.hasExtra(EXTRA_BYPASS_AUTH_FOR_SCREENSHOT) == true) {
                forceVisualTestMode = intent.getBooleanExtra(EXTRA_BYPASS_AUTH_FOR_SCREENSHOT, false)
            }
            if (intent?.hasExtra(EXTRA_FORCE_LOGIN_SCREEN) == true) {
                forceLoginScreen = intent.getBooleanExtra(EXTRA_FORCE_LOGIN_SCREEN, false)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        lifecycleScope.launch {
            val rememberLogin = readRememberLoginPreference(
                read = { AppSettingsStore.observeRememberLogin(applicationContext).first() },
                onFailure = { error ->
                    Log.e("SkyBridgeMain", "Failed to read remember-login preference", error)
                    NotificationCenter.post(
                        NotificationEvent(
                            title = resolveLocalizedText(
                                "无法读取登录设置",
                                "Unable to read sign-in settings",
                                "サインイン設定を読み込めません"
                            ),
                            message = resolveLocalizedText(
                                "已停止自动恢复会话，请检查应用存储。",
                                "Automatic session restore was stopped; check app storage.",
                                "セッションの自動復元を停止しました。アプリストレージを確認してください。"
                            ),
                            module = NotificationModule.SYSTEM,
                            severity = NotificationSeverity.ERROR
                        )
                    )
                }
            ) ?: return@launch
            if (rememberLogin) {
                try {
                    authRepository.loadSessionFromStorage(true)
                    authRepository.syncNebulaIdFromIdentitiesIfMissing()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    Log.w("SkyBridgeMain", "Failed to refresh stored session profile", error)
                }
            }
        }
    }
}

internal fun resolveDebugNavigationRoute(route: String): String? =
    route.takeIf { it in DEBUG_NAVIGATION_ROUTES }

private val DEBUG_NAVIGATION_ROUTES = setOf(
    Screen.Dashboard.route,
    Screen.DeviceDiscovery.route,
    Screen.ScreenMirroring.route,
    Screen.RemoteControl.route,
    Screen.PibPairing.route,
    Screen.FileTransfer.route,
    Screen.Settings.route,
    Screen.AccountCenter.route,
    Screen.DeviceAuthentication.route,
    Screen.EncryptionSettings.route,
    Screen.AccessControl.route,
    Screen.PrivacySettings.route,
    Screen.WebRtcSettings.route,
    Screen.RemoteDesktopStreamSettings.route,
    Screen.HelpSupport.route,
    Screen.Feedback.route,
    Screen.OpenSourceLicenses.route,
    Screen.VersionInfo.route
)

internal suspend fun readRememberLoginPreference(
    read: suspend () -> Boolean,
    onFailure: (Exception) -> Unit
): Boolean? = try {
    read()
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    onFailure(error)
    null
}

/**
 * `keep_screen_on` 的窗口标志判定（R7.2）。
 *
 * 该开关的运行时消费方是 [MainActivity] 的 `LaunchedEffect(appSettings.keepScreenOn)`：开为
 * `addFlags(FLAG_KEEP_SCREEN_ON)`、关为 `clearFlags(FLAG_KEEP_SCREEN_ON)`。判定本身在此提取为纯
 * 函数，使「设置值改变消费方行为」可被单元测试证明，而**不改动任何 UI 节点或屏幕结构**（G2）。
 */
internal enum class KeepScreenOnWindowFlag {
    /** 持有 `FLAG_KEEP_SCREEN_ON`，屏幕在会话期间保持常亮。 */
    ADD,

    /** 清除 `FLAG_KEEP_SCREEN_ON`，回到系统默认息屏策略。 */
    CLEAR
}

/** 设置值 → 窗口标志动作。默认值 `false`（见 `AppSettings.keepScreenOn`）映射为 [KeepScreenOnWindowFlag.CLEAR]。 */
internal fun keepScreenOnWindowFlag(keepScreenOn: Boolean): KeepScreenOnWindowFlag =
    if (keepScreenOn) KeepScreenOnWindowFlag.ADD else KeepScreenOnWindowFlag.CLEAR

@Composable
fun SkyBridgeCompassApp(
    securityNavRoute: String? = null,
    forceVisualTestMode: Boolean = false,
    forceLoginScreen: Boolean = false
) {
    val navController = rememberNavController()
    val authViewModel: com.skybridge.compass.auth.AuthViewModel = androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel()
    val authState = authViewModel.uiState.collectAsState().value

    val canShowAuthenticatedContent =
        !forceLoginScreen && (authState.isAuthenticated || forceVisualTestMode)

    LaunchedEffect(securityNavRoute, canShowAuthenticatedContent) {
        if (canShowAuthenticatedContent && !securityNavRoute.isNullOrBlank()) {
            navController.navigate(securityNavRoute) { launchSingleTop = true }
        }
    }

    // 未登录：仅显示登录界面，不展示导航栏
    // Use a light iOS-like gradient background for login instead of dark starfield
    if (!canShowAuthenticatedContent) {
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

    val backgroundEffectsViewModel: IOSBackgroundEffectsViewModel = hiltViewModel()
    val backgroundUi = backgroundEffectsViewModel.uiState
    PerformanceMonitorEffect(
        context = LocalContext.current,
        lifecycleOwner = LocalLifecycleOwner.current
    )

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
