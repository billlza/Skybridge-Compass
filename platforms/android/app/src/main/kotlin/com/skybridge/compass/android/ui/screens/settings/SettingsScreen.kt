package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_JA
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.data.APP_LANGUAGE_ZH
import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.android.data.SupabaseConfigState
import com.skybridge.compass.android.config.FeatureFlags
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.data.NetworkSettings
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.skybridge.compass.auth.AuthViewModel
import com.skybridge.compass.android.i18n.resolveLanguageLabel
import com.skybridge.compass.android.i18n.resolveLocalizedText
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.fragment.app.FragmentActivity
import android.content.Intent
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import androidx.biometric.BiometricManager

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val authCode = remember(context) {
        BiometricManager.from(context).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
        )
    }
    fun openCredentialSettings() {
        runCatching {
            val intent =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Intent(Settings.ACTION_BIOMETRIC_ENROLL).apply {
                        putExtra(
                            Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                            BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
                        )
                    }
                } else {
                    Intent(Settings.ACTION_SECURITY_SETTINGS)
                }
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
    
    // 从 DataStore 观察应用设置（持久化）
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    val netSettings by NetworkSettingsStore.observe(context).collectAsState(initial = NetworkSettings())
    val supabaseState by SupabaseConfigStore.observeState(context)
        .collectAsState(initial = SupabaseConfigState.Missing)
    
    val authViewModel: AuthViewModel = hiltViewModel()
    val authUiState by authViewModel.uiState.collectAsState()
    val powerManager = remember(context) {
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    }
    
    var portStartInput by remember { mutableStateOf(netSettings.portRangeStart.toString()) }
    var portEndInput by remember { mutableStateOf(netSettings.portRangeEnd.toString()) }
    var discoveryTimeoutSecInput by remember { mutableStateOf((netSettings.discoveryTimeoutMs / 1000).toString()) }
    var maxReconnectInput by remember { mutableStateOf(netSettings.maxReconnectAttempts.toString()) }
    var supabaseMessage by remember { mutableStateOf<String?>(null) }
    var supabaseMessageIsError by remember { mutableStateOf(false) }
    var supabaseValidating by remember { mutableStateOf(false) }
    var supabaseUrlInput by remember { mutableStateOf("") }
    var supabaseAnonKeyInput by remember { mutableStateOf("") }
    var networkAdvancedExpanded by rememberSaveable { mutableStateOf(false) }
    var supabaseExpanded by rememberSaveable { mutableStateOf(false) }

    // iOS-like inline "apply" feedback
    val haptics = LocalHapticFeedback.current
    var portsSavedAtMs by remember { mutableLongStateOf(0L) }
    var discoverySavedAtMs by remember { mutableLongStateOf(0L) }
    var reconnectSavedAtMs by remember { mutableLongStateOf(0L) }
    
    LaunchedEffect(netSettings) {
        portStartInput = netSettings.portRangeStart.toString()
        portEndInput = netSettings.portRangeEnd.toString()
        discoveryTimeoutSecInput = (netSettings.discoveryTimeoutMs / 1000).toString()
        maxReconnectInput = netSettings.maxReconnectAttempts.toString()
    }

    LaunchedEffect(supabaseState) {
        when (val st = supabaseState) {
            is SupabaseConfigState.Available -> {
                supabaseMessage = null
                supabaseUrlInput = st.config.url
                supabaseAnonKeyInput = ""
            }
            SupabaseConfigState.Missing -> {
                supabaseUrlInput = SupabaseConfigStore.managedDefaults()?.url ?: ""
                supabaseAnonKeyInput = ""
            }
            SupabaseConfigState.Locked -> Unit
        }
    }

    val shouldShowBatteryOptimizationCard = remember(
        appSettings.showBatteryOptimizationWarning,
        powerManager
    ) {
        appSettings.showBatteryOptimizationWarning &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    val securitySettingItems = listOf(
        Setting(
            title = t("设备认证", "Device Authentication", "デバイス認証"),
            description = t("要求设备配对认证", "Require device pairing authentication", "デバイスのペアリング認証を必須にする"),
            icon = Icons.Default.Lock,
            route = com.skybridge.compass.android.ui.navigation.Screen.DeviceAuthentication.route
        ),
        Setting(
            title = t("数据加密", "Encryption", "データ暗号化"),
            description = t("传输数据加密设置", "Manage transport encryption settings", "通信データの暗号化設定を管理する"),
            icon = Icons.Default.Lock,
            route = com.skybridge.compass.android.ui.navigation.Screen.EncryptionSettings.route
        ),
        Setting(
            title = t("访问控制", "Access Control", "アクセス制御"),
            description = t("管理设备访问权限", "Manage device access permissions", "デバイスのアクセス権限を管理する"),
            icon = Icons.Default.Settings,
            route = com.skybridge.compass.android.ui.navigation.Screen.AccessControl.route
        ),
        Setting(
            title = t("隐私设置", "Privacy", "プライバシー"),
            description = t("控制数据收集和使用", "Control data collection and usage", "データ収集と利用を制御する"),
            icon = Icons.Default.Lock,
            route = com.skybridge.compass.android.ui.navigation.Screen.PrivacySettings.route
        )
    )

    val aboutSettingItems = listOf(
        Setting(
            title = t("版本信息", "Version Info", "バージョン情報"),
            description = t("查看应用版本和更新", "View app version and build details", "アプリのバージョンとビルド情報を確認する"),
            icon = Icons.Default.Info,
            value = BuildConfig.VERSION_NAME,
            route = com.skybridge.compass.android.ui.navigation.Screen.VersionInfo.route
        ),
        Setting(
            title = t("帮助与支持", "Help & Support", "ヘルプとサポート"),
            description = t("获取使用帮助和技术支持", "Open documentation and support options", "利用ガイドとサポート窓口を開く"),
            icon = Icons.Default.Info,
            route = com.skybridge.compass.android.ui.navigation.Screen.HelpSupport.route
        ),
        Setting(
            title = t("反馈建议", "Feedback", "フィードバック"),
            description = t("提交问题反馈和功能建议", "Send bug reports and feature ideas", "不具合報告や機能提案を送信する"),
            icon = Icons.AutoMirrored.Filled.Send,
            route = com.skybridge.compass.android.ui.navigation.Screen.Feedback.route
        ),
        Setting(
            title = t("开源许可", "Open Source Licenses", "オープンソースライセンス"),
            description = t("查看开源组件许可信息", "Review open-source component licenses", "オープンソースコンポーネントのライセンスを確認する"),
            icon = Icons.Default.Info,
            route = com.skybridge.compass.android.ui.navigation.Screen.OpenSourceLicenses.route
        )
    )
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp)
    ) {
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = t("设置", "Settings", "設定"),
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = t(
                "连接、安全、外观与高级配置",
                "Connections, security, appearance, and advanced configuration",
                "接続・セキュリティ・外観・高度な設定"
            ),
            style = MaterialTheme.typography.bodyMedium,
            color = Color.White.copy(alpha = 0.72f)
        )
        
        Spacer(modifier = Modifier.height(16.dp))
        
        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Apple-like grouped sections (first-pass): 常规 + 账户
            item {
                GroupedGlassSection(title = t("常规", "General", "一般")) {
                    GroupedGlassRow(
                        title = t("深色模式", "Dark Mode", "ダークモード"),
                        subtitle = t("使用深色主题界面", "Use the dark app appearance", "ダークテーマの外観を使う"),
                        icon = Icons.Default.DarkMode
                    ) {
                        Switch(
                            checked = appSettings.darkMode,
                            onCheckedChange = { enabled -> scope.launch { AppSettingsStore.setDarkMode(context, enabled) } }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("语言", "Language", "言語"),
                        subtitle = t("选择应用显示语言；默认跟随系统", "Choose the app display language; default follows the system", "アプリの表示言語を選択します。既定ではシステムに従います"),
                        icon = Icons.Default.Public
                    ) {
                        Text(
                            text = resolveLanguageLabel(appSettings.appLanguage, "中文", "English", "日本語"),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 52.dp, end = 12.dp, bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        AppLanguageSelector(
                            selectedLanguage = appSettings.appLanguage,
                            onLanguageSelected = { language ->
                                scope.launch { AppSettingsStore.setAppLanguage(context, language) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("自动连接", "Auto Connect", "自動接続"),
                        subtitle = t(
                            "发现页只有一个可连接设备时自动发起连接",
                            "Auto-connect when exactly one reachable device is found on the discovery screen",
                            "デバイス発見画面で接続可能な端末が1台だけ見つかったときに自動接続する"
                        ),
                        icon = Icons.Default.Bolt
                    ) {
                        Switch(
                            checked = appSettings.autoConnect,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setAutoConnect(context, enabled) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("通知", "Notifications", "通知"),
                        subtitle = t("接收连接和状态通知", "Receive connection and status notifications", "接続状態の通知を受け取る"),
                        icon = Icons.Default.Notifications
                    ) {
                        Switch(
                            checked = appSettings.notificationsEnabled,
                            onCheckedChange = { enabled -> scope.launch { AppSettingsStore.setNotifications(context, enabled) } }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("动态取色", "Dynamic Color", "ダイナミックカラー"),
                        subtitle = t("跟随系统壁纸提取主题色", "Derive accent colors from the system wallpaper", "システム壁紙からアクセントカラーを取得する"),
                        icon = Icons.Default.Palette
                    ) {
                        Switch(
                            checked = appSettings.useDynamicColor,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setUseDynamicColor(context, enabled) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("触觉反馈", "Haptic Feedback", "触覚フィードバック"),
                        subtitle = t("切换标签和应用参数时使用轻触反馈", "Use light haptics when switching tabs and applying changes", "タブ切替や設定適用時に軽い触覚フィードバックを使う"),
                        icon = Icons.Default.Vibration
                    ) {
                        Switch(
                            checked = appSettings.hapticFeedback,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setHapticFeedback(context, enabled) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("保持屏幕常亮", "Keep Screen Awake", "画面を常時点灯"),
                        subtitle = t("使用 SkyBridge Compass 时阻止屏幕自动熄灭", "Prevent the screen from turning off while using SkyBridge Compass", "SkyBridge Compass の使用中に画面が消灯しないようにする"),
                        icon = Icons.Default.StayCurrentPortrait
                    ) {
                        Switch(
                            checked = appSettings.keepScreenOn,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setKeepScreenOn(context, enabled) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("电池优化提醒", "Battery Optimization Warning", "バッテリー最適化の警告"),
                        subtitle = t("提示关闭系统电池优化，避免后台连接被系统中断", "Warn when Android battery optimization may interrupt background connections", "Android の電池最適化がバックグラウンド接続を中断する可能性がある場合に警告する"),
                        icon = Icons.Default.BatteryAlert
                    ) {
                        Switch(
                            checked = appSettings.showBatteryOptimizationWarning,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setBatteryOptimizationWarning(context, enabled) }
                            }
                        )
                    }
                }
            }

            if (shouldShowBatteryOptimizationCard) {
                item {
                    LiquidGlassSurface(
                        modifier = Modifier.fillMaxWidth(),
                        blurRadius = 0.dp,
                        tintColor = MaterialTheme.colorScheme.error.copy(alpha = 0.08f),
                        tintAlpha = 0.08f,
                        borderAlpha = 0.14f,
                        highlightAlpha = 0.02f,
                        edgeGlowAlpha = 0.02f,
                        contentPadding = PaddingValues(16.dp)
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                text = t("建议关闭电池优化", "Battery optimization should be disabled", "バッテリー最適化を無効にすることを推奨"),
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                text = t("否则后台发现、文件传输和远控连接可能被系统暂停。", "Otherwise device discovery, file transfer, and remote-control sessions may be paused in the background.", "無効にしない場合、バックグラウンドでのデバイス検出、ファイル転送、リモート接続が停止されることがあります。"),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            TextButton(
                                onClick = {
                                    val intent = Intent(
                                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                        Uri.parse("package:${context.packageName}")
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    runCatching { context.startActivity(intent) }
                                        .onFailure {
                                            runCatching {
                                                context.startActivity(
                                                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                                )
                                            }
                                        }
                                }
                            ) {
                                Text(t("打开系统电池设置", "Open Battery Settings", "バッテリー設定を開く"))
                            }
                        }
                    }
                }
            }

            item {
                GroupedGlassSection(title = t("账户", "Account", "アカウント")) {
                    GroupedGlassRow(
                        title = t("登录状态", "Sign-in Status", "ログイン状態"),
                        subtitle = if (authUiState.isAuthenticated) {
                            t("已登录", "Signed In", "ログイン済み")
                        } else {
                            t("未登录", "Signed Out", "未ログイン")
                        },
                        icon = Icons.Default.AccountCircle
                    ) {
                        if (authUiState.isAuthenticated) {
                            TextButton(onClick = { authViewModel.logout() }) { Text(t("登出", "Sign Out", "ログアウト")) }
                        } else {
                            Text(
                                text = t("请返回主页登录", "Return to the home screen to sign in", "ホーム画面に戻ってログインしてください"),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("记住登录 / 自动登录", "Remember Login / Auto Sign-in", "ログイン状態を保持 / 自動ログイン"),
                        subtitle = t("重新打开应用时自动恢复上次登录状态", "Restore your last signed-in session when reopening the app", "アプリを再度開いたときに前回のログイン状態を復元する"),
                        icon = Icons.Default.LockReset
                    ) {
                        Switch(
                            checked = appSettings.rememberLogin,
                            onCheckedChange = { enabled ->
                                scope.launch { AppSettingsStore.setRememberLogin(context, enabled) }
                            }
                        )
                    }
                    GroupedGlassDivider()
                    GroupedGlassRow(
                        title = t("账户中心", "Account Center", "アカウントセンター"),
                        subtitle = t("查看主账号信息与切换账号", "View the primary account and switch accounts", "メインアカウントの確認と切り替え"),
                    icon = Icons.Default.ManageAccounts,
                    onClick = {
                        navController.navigate(com.skybridge.compass.android.ui.navigation.Screen.AccountCenter.route)
                    }
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // Network Settings (grouped, iOS-like inline editors)
            item {
                GroupedGlassSection(title = t("网络", "Network", "ネットワーク")) {
                    GroupedGlassRow(
                        title = t("连接参数", "Connection Parameters", "接続パラメータ"),
                        subtitle = t(
                            "端口 ${netSettings.portRangeStart}-${netSettings.portRangeEnd} · 超时 ${netSettings.discoveryTimeoutMs / 1000}s · 重试 ${netSettings.maxReconnectAttempts}",
                            "Ports ${netSettings.portRangeStart}-${netSettings.portRangeEnd} · Timeout ${netSettings.discoveryTimeoutMs / 1000}s · Retries ${netSettings.maxReconnectAttempts}",
                            "ポート ${netSettings.portRangeStart}-${netSettings.portRangeEnd} ・ タイムアウト ${netSettings.discoveryTimeoutMs / 1000}s ・ 再試行 ${netSettings.maxReconnectAttempts}"
                        ),
                        icon = Icons.Default.Tune,
                        onClick = { networkAdvancedExpanded = !networkAdvancedExpanded }
                    ) {
                        TextButton(onClick = { networkAdvancedExpanded = !networkAdvancedExpanded }) {
                            Text(if (networkAdvancedExpanded) t("收起", "Collapse", "閉じる") else t("展开", "Expand", "展開"))
                        }
                    }

                    AnimatedVisibility(visible = networkAdvancedExpanded) {
                        Column {
                            GroupedGlassDivider()

                            GroupedGlassRow(
                                title = t("端口范围", "Port Range", "ポート範囲"),
                                subtitle = t(
                                    "当前: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}",
                                    "Current: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}",
                                    "現在: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}"
                                ),
                                icon = Icons.Default.Settings
                            ) {
                                val portsDirty =
                                    portStartInput != netSettings.portRangeStart.toString() ||
                                        portEndInput != netSettings.portRangeEnd.toString()

                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    CompactInlineNumberField(
                                        value = portStartInput,
                                        placeholder = t("起始", "Start", "開始"),
                                        onValueChange = {
                                            portsSavedAtMs = 0L
                                            portStartInput = it.filter { ch -> ch.isDigit() }.take(5)
                                        }
                                    )
                                    Text("—", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    CompactInlineNumberField(
                                        value = portEndInput,
                                        placeholder = t("结束", "End", "終了"),
                                        onValueChange = {
                                            portsSavedAtMs = 0L
                                            portEndInput = it.filter { ch -> ch.isDigit() }.take(5)
                                        }
                                    )
                                    InlineSavedIndicator(savedAtMs = portsSavedAtMs)
                                    InlineApplyButton(
                                        enabled = portsDirty,
                                        onClick = {
                                            if (appSettings.hapticFeedback) {
                                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            }
                                            scope.launch {
                                                val start = portStartInput.toIntOrNull() ?: netSettings.portRangeStart
                                                val end = portEndInput.toIntOrNull() ?: netSettings.portRangeEnd
                                                NetworkSettingsStore.setPortRange(context, start, end)
                                                portsSavedAtMs = System.currentTimeMillis()
                                                delay(1100)
                                                portsSavedAtMs = 0L
                                            }
                                        }
                                    )
                                }
                            }

                            GroupedGlassDivider()

                            GroupedGlassRow(
                                title = t("发现超时", "Discovery Timeout", "探索タイムアウト"),
                                subtitle = t(
                                    "当前: ${netSettings.discoveryTimeoutMs / 1000} 秒",
                                    "Current: ${netSettings.discoveryTimeoutMs / 1000} sec",
                                    "現在: ${netSettings.discoveryTimeoutMs / 1000} 秒"
                                ),
                                icon = Icons.Default.Timer
                            ) {
                                val discoveryDirty =
                                    discoveryTimeoutSecInput != (netSettings.discoveryTimeoutMs / 1000).toString()

                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    CompactInlineNumberField(
                                        value = discoveryTimeoutSecInput,
                                        placeholder = t("秒", "Sec", "秒"),
                                        onValueChange = {
                                            discoverySavedAtMs = 0L
                                            discoveryTimeoutSecInput = it.filter { ch -> ch.isDigit() }.take(4)
                                        }
                                    )
                                    InlineSavedIndicator(savedAtMs = discoverySavedAtMs)
                                    InlineApplyButton(
                                        enabled = discoveryDirty,
                                        onClick = {
                                            if (appSettings.hapticFeedback) {
                                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            }
                                            scope.launch {
                                                val sec =
                                                    discoveryTimeoutSecInput.toLongOrNull()
                                                        ?: (netSettings.discoveryTimeoutMs / 1000)
                                                NetworkSettingsStore.setDiscoveryTimeoutMs(context, sec * 1000L)
                                                discoverySavedAtMs = System.currentTimeMillis()
                                                delay(1100)
                                                discoverySavedAtMs = 0L
                                            }
                                        }
                                    )
                                }
                            }

                            GroupedGlassDivider()

                            GroupedGlassRow(
                                title = t("连接重试", "Reconnect Attempts", "再接続回数"),
                                subtitle = t(
                                    "当前: ${netSettings.maxReconnectAttempts} 次",
                                    "Current: ${netSettings.maxReconnectAttempts}",
                                    "現在: ${netSettings.maxReconnectAttempts} 回"
                                ),
                                icon = Icons.Default.Refresh
                            ) {
                                val reconnectDirty =
                                    maxReconnectInput != netSettings.maxReconnectAttempts.toString()

                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    CompactInlineNumberField(
                                        value = maxReconnectInput,
                                        placeholder = t("次数", "Count", "回数"),
                                        onValueChange = {
                                            reconnectSavedAtMs = 0L
                                            maxReconnectInput = it.filter { ch -> ch.isDigit() }.take(2)
                                        }
                                    )
                                    InlineSavedIndicator(savedAtMs = reconnectSavedAtMs)
                                    InlineApplyButton(
                                        enabled = reconnectDirty,
                                        onClick = {
                                            if (appSettings.hapticFeedback) {
                                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            }
                                            scope.launch {
                                                val attempts = maxReconnectInput.toIntOrNull() ?: netSettings.maxReconnectAttempts
                                                NetworkSettingsStore.setMaxReconnectAttempts(context, attempts)
                                                reconnectSavedAtMs = System.currentTimeMillis()
                                                delay(1100)
                                                reconnectSavedAtMs = 0L
                                            }
                                        }
                                    )
                                }
                            }

                            GroupedGlassDivider()
                        }
                    }

                    GroupedGlassRow(
                        title = t("跨网 WebRTC", "Cross-network WebRTC", "クロスネットワーク WebRTC"),
                        subtitle = if (netSettings.webrtcEnabled) {
                            t("已启用 · ${netSettings.webrtcSignalingUrl}", "Enabled · ${netSettings.webrtcSignalingUrl}", "有効 · ${netSettings.webrtcSignalingUrl}")
                        } else {
                            t("已关闭", "Disabled", "無効")
                        },
                        icon = Icons.Default.Public,
                        onClick = {
                            navController.navigate(com.skybridge.compass.android.ui.navigation.Screen.WebRtcSettings.route)
                        }
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowForward,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            
            // Security Settings (grouped, iOS-like)
            item {
                GroupedGlassSection(title = t("安全", "Security", "セキュリティ")) {
                    securitySettingItems.forEachIndexed { idx, setting ->
                        GroupedGlassRow(
                            title = setting.title,
                            subtitle = setting.description,
                            icon = setting.icon,
                            onClick = {
                                setting.route?.let { navController.navigate(it) }
                            }
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (idx != securitySettingItems.lastIndex) {
                            GroupedGlassDivider()
                        }
                    }
                }
            }

            // Supabase Config (grouped)
            item {
                GroupedGlassSection(title = t("云服务", "Cloud Services", "クラウドサービス")) {
                    val statusText = when (val state = supabaseState) {
                        is SupabaseConfigState.Available -> t("已配置: ${state.config.url}", "Configured: ${state.config.url}", "設定済み: ${state.config.url}")
                        SupabaseConfigState.Locked -> t("已加密锁定，请解锁后使用云功能", "Encrypted and locked. Unlock it to use cloud features.", "暗号化されてロックされています。クラウド機能を使うにはロック解除してください。")
                        SupabaseConfigState.Missing -> t("未配置（云功能不可用）", "Not configured (cloud features unavailable)", "未設定（クラウド機能は利用不可）")
                    }

                    GroupedGlassRow(
                        title = t("Supabase 配置", "Supabase Configuration", "Supabase 設定"),
                        subtitle = statusText,
                        icon = Icons.Default.CloudSync,
                        onClick = { supabaseExpanded = !supabaseExpanded }
                    ) {
                        TextButton(onClick = { supabaseExpanded = !supabaseExpanded }) {
                            Text(if (supabaseExpanded) t("收起", "Collapse", "閉じる") else t("配置", "Configure", "設定"))
                        }
                    }

                    AnimatedVisibility(visible = supabaseExpanded) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Text(
                                text = t("Supabase 端点与匿名 Key（Keystore + 生物识别）", "Supabase endpoint and anon key (Keystore + biometrics)", "Supabase エンドポイントと anon key（Keystore + 生体認証）"),
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Medium
                            )
                            Spacer(modifier = Modifier.height(8.dp))

                            OutlinedTextField(
                                value = supabaseUrlInput,
                                onValueChange = { supabaseUrlInput = it },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true,
                                label = { Text("SUPABASE_URL") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                                placeholder = { Text("https://your-project.supabase.co") }
                            )

                            OutlinedTextField(
                                value = supabaseAnonKeyInput,
                                onValueChange = { supabaseAnonKeyInput = it },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true,
                                label = { Text("SUPABASE_ANON_KEY") },
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                placeholder = { Text(t("匿名 Key（建议粘贴）", "Anon key (paste recommended)", "anon key（貼り付け推奨）")) }
                            )

                            supabaseMessage?.let { msg ->
                                Spacer(modifier = Modifier.height(6.dp))
                                Text(
                                    text = msg,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = if (supabaseMessageIsError) MaterialTheme.colorScheme.error
                                    else MaterialTheme.colorScheme.primary
                                )
                            }
                            val activity = context as? FragmentActivity
                            Row(
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    if (supabaseState == SupabaseConfigState.Locked) {
                                        TextButton(onClick = {
                                            if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                                supabaseMessage = t("Supabase 配置无效：未启用锁屏(PIN/图案/密码)或未录入生物识别", "Supabase configuration is unavailable because screen lock or biometrics are not enabled.", "画面ロックまたは生体認証が有効でないため、Supabase 設定を利用できません。")
                                                supabaseMessageIsError = true
                                                openCredentialSettings()
                                                return@TextButton
                                            }
                                            if (activity == null) {
                                                supabaseMessage = t("无法获取 Activity，无法解锁", "Unable to access the Activity, so unlocking is unavailable.", "Activity を取得できないため、ロック解除できません。")
                                                supabaseMessageIsError = true
                                            } else {
                                                SupabaseConfigStore.unlockWithBiometrics(activity) { result ->
                                                    result.onSuccess {
                                                        supabaseMessage = t("已解锁 Supabase 配置", "Supabase configuration unlocked.", "Supabase 設定のロックを解除しました。")
                                                        supabaseMessageIsError = false
                                                    }.onFailure { err ->
                                                        supabaseMessage = err.message ?: t("解锁失败", "Failed to unlock configuration.", "設定のロック解除に失敗しました。")
                                                        supabaseMessageIsError = true
                                                    }
                                                }
                                            }
                                        }) { Text(t("解锁", "Unlock", "ロック解除")) }
                                    }

                                    Button(onClick = {
                                        if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                            supabaseMessage = t("需要启用锁屏(PIN/图案/密码)或录入生物识别后才能安全保存", "Enable screen lock or biometrics before securely saving the configuration.", "設定を安全に保存するには、画面ロックまたは生体認証を有効にしてください。")
                                            supabaseMessageIsError = true
                                            openCredentialSettings()
                                            return@Button
                                        }
                                        if (activity == null) {
                                            supabaseMessage = t("无法获取 Activity，无法保存", "Unable to access the Activity, so saving is unavailable.", "Activity を取得できないため、保存できません。")
                                            supabaseMessageIsError = true
                                        } else {
                                            SupabaseConfigStore.saveWithBiometrics(
                                                activity = activity,
                                                config = SupabaseConfig(url = supabaseUrlInput, anonKey = supabaseAnonKeyInput)
                                            ) { result ->
                                                result.onSuccess {
                                                    supabaseMessage = t("已保存并加密存储", "Saved and encrypted.", "保存して暗号化しました。")
                                                    supabaseMessageIsError = false
                                                }.onFailure { err ->
                                                    supabaseMessage = err.message ?: t("保存失败", "Failed to save configuration.", "設定の保存に失敗しました。")
                                                    supabaseMessageIsError = true
                                                }
                                            }
                                        }
                                    }) { Text(t("保存", "Save", "保存")) }

                                    OutlinedButton(
                                        enabled = SupabaseConfigStore.managedDefaults() != null,
                                        onClick = {
                                            if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                                supabaseMessage = t("需要启用锁屏(PIN/图案/密码)或录入生物识别后才能安全保存", "Enable screen lock or biometrics before securely saving the configuration.", "設定を安全に保存するには、画面ロックまたは生体認証を有効にしてください。")
                                                supabaseMessageIsError = true
                                                openCredentialSettings()
                                                return@OutlinedButton
                                            }
                                            if (activity == null) {
                                                supabaseMessage = t("无法获取 Activity，无法启用默认配置", "Unable to access the Activity, so default configuration cannot be enabled.", "Activity を取得できないため、既定設定を有効にできません。")
                                                supabaseMessageIsError = true
                                            } else {
                                                SupabaseConfigStore.provisionManagedDefaults(activity) { result ->
                                                    result.onSuccess {
                                                        supabaseMessage = t("已启用默认配置并加密保存", "Default configuration enabled and encrypted.", "既定設定を有効にして暗号化保存しました。")
                                                        supabaseMessageIsError = false
                                                    }.onFailure { err ->
                                                        supabaseMessage = err.message ?: t("启用失败", "Failed to enable default configuration.", "既定設定の有効化に失敗しました。")
                                                        supabaseMessageIsError = true
                                                    }
                                                }
                                            }
                                        }
                                    ) { Text(t("使用默认", "Use Default", "既定値を使用")) }
                                }

                                TextButton(onClick = {
                                    scope.launch {
                                        SupabaseConfigStore.reset(context)
                                        supabaseMessage = t("已清除 Supabase 配置", "Supabase configuration cleared.", "Supabase 設定を消去しました。")
                                        supabaseMessageIsError = false
                                    }
                                }) {
                                    Text(t("清除", "Clear", "消去"))
                                }
                            }
                            if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                Spacer(modifier = Modifier.height(8.dp))
                                TextButton(onClick = { openCredentialSettings() }) { Text(t("去系统设置启用锁屏/生物识别", "Open system settings to enable screen lock / biometrics", "システム設定で画面ロック / 生体認証を有効にする")) }
                            }
                            Spacer(modifier = Modifier.height(8.dp))
                            Button(
                                onClick = {
                                    scope.launch {
                                        supabaseValidating = true
                                        try {
                                            val result = authViewModel.validateSupabaseConfiguration()
                                            supabaseMessage = result.message ?: if (result.isValid) {
                                                t("配置有效", "Configuration is valid.", "設定は有効です。")
                                            } else {
                                                t("配置无效", "Configuration is invalid.", "設定は無効です。")
                                            }
                                            supabaseMessageIsError = !result.isValid
                                        } catch (e: Throwable) {
                                            supabaseMessage = e.message ?: t("验证失败", "Validation failed.", "検証に失敗しました。")
                                            supabaseMessageIsError = true
                                        } finally {
                                            supabaseValidating = false
                                        }
                                    }
                                },
                                enabled = supabaseState is SupabaseConfigState.Available && !supabaseValidating,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(if (supabaseValidating) t("验证中...", "Validating...", "検証中...") else t("验证配置", "Validate Configuration", "設定を検証"))
                            }
                        }
                    }
                }
            }
            
            // Developer Settings 与 About 保持不变
            item {
                Text(
                    text = t("深度开发设置", "Advanced Developer Settings", "開発者向け詳細設定"),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            }
            
            item {
                SettingSwitchCard(
                    title = t("屏幕镜像", "Screen Mirroring", "画面ミラーリング"),
                    description = t("启用屏幕镜像模块", "Enable the screen mirroring module", "画面ミラーリング機能を有効にする"),
                    icon = Icons.Default.Settings,
                    checked = devSettings.enableScreenMirroring,
                    onCheckedChange = { enabled ->
                        scope.launch {
                            DeveloperSettingsStore.setEnableScreenMirroring(context, enabled)
                            FeatureFlags.ENABLE_SCREEN_MIRRORING = enabled
                        }
                    }
                )
            }
            
            item {
                SettingSwitchCard(
                    title = t("远程控制", "Remote Control", "リモート操作"),
                    description = t("启用远程控制模块", "Enable the remote control module", "リモート操作機能を有効にする"),
                    icon = Icons.Default.Settings,
                    checked = devSettings.enableRemoteControl,
                    onCheckedChange = { enabled ->
                        scope.launch {
                            DeveloperSettingsStore.setEnableRemoteControl(context, enabled)
                            FeatureFlags.ENABLE_REMOTE_CONTROL = enabled
                        }
                    }
                )
            }
            
            item {
                SettingSwitchCard(
                    title = t("文件传输", "File Transfer", "ファイル転送"),
                    description = t("启用文件传输模块", "Enable the file transfer module", "ファイル転送機能を有効にする"),
                    icon = Icons.Default.Folder,
                    checked = devSettings.enableFileTransfer,
                    onCheckedChange = { enabled ->
                        scope.launch {
                            DeveloperSettingsStore.setEnableFileTransfer(context, enabled)
                            FeatureFlags.ENABLE_FILE_TRANSFER = enabled
                        }
                    }
                )
            }
            
            // About
            item {
                Text(
                    text = t("关于", "About", "情報"),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            }
            
            items(aboutSettingItems) { setting ->
                SettingCard(
                    setting = setting,
                    onClick = {
                        setting.route?.let { navController.navigate(it) }
                    }
                )
            }
        }
    }
}

@Composable
private fun CompactInlineNumberField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit
) {
    // iOS-like inline editor: small pill field
    androidx.compose.material3.TextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        placeholder = { Text(placeholder, style = MaterialTheme.typography.labelSmall) },
        textStyle = MaterialTheme.typography.labelLarge,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.10f),
            unfocusedContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.08f),
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            cursorColor = MaterialTheme.colorScheme.primary
        ),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        modifier = Modifier.width(84.dp)
    )
}

@Composable
private fun InlineApplyButton(
    enabled: Boolean,
    onClick: () -> Unit
) {
    LiquidGlassSurface(
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        blurRadius = 0.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = if (enabled) 0.14f else 0.08f),
        tintAlpha = if (enabled) 0.14f else 0.08f,
        borderAlpha = if (enabled) 0.14f else 0.08f,
        highlightAlpha = if (enabled) 0.06f else 0.0f,
        edgeGlowAlpha = if (enabled) 0.05f else 0.0f,
        shadowElevation = if (enabled) 10.dp else 0.dp,
        contentPadding = PaddingValues(0.dp),
        onClick = if (enabled) onClick else null,
        modifier = Modifier.size(34.dp)
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = if (enabled) {
                    resolveLocalizedText("保存", "Save", "保存")
                } else {
                    resolveLocalizedText("已是最新", "Already up to date", "最新の状態です")
                },
                tint = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

@Composable
private fun InlineSavedIndicator(savedAtMs: Long) {
    AnimatedVisibility(
        visible = savedAtMs > 0L,
        enter = fadeIn(),
        exit = fadeOut()
    ) {
        Text(
            text = resolveLocalizedText("已保存", "Saved", "保存済み"),
            style = MaterialTheme.typography.labelSmall,
            color = Color(0xFF34C759) // iOS-like system green
        )
    }
}

@Composable
fun SettingSwitchCard(
    title: String,
    description: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.14f),
        tintAlpha = 0.14f,
        borderAlpha = 0.14f,
        highlightAlpha = 0.06f,
        edgeGlowAlpha = 0.05f,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // iOS-like icon tile
            LiquidGlassSurface(
                shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
                blurRadius = 0.dp,
                tintColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f),
                tintAlpha = 0.16f,
                borderAlpha = 0.12f,
                highlightAlpha = 0.06f,
                edgeGlowAlpha = 0.04f,
                shadowElevation = 0.dp,
                contentPadding = PaddingValues(10.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Switch(checked = checked, onCheckedChange = onCheckedChange)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingCard(
    setting: Setting,
    onClick: () -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        blurRadius = 24.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        tintAlpha = 0.28f,
        borderWidth = 1.dp,
        borderAlpha = 0.35f,
        highlightAlpha = 0.22f,
        edgeGlowAlpha = 0.16f
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = setting.icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp)
            )
            
            Spacer(modifier = Modifier.width(16.dp))
            
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = setting.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = setting.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            
            if (setting.value != null) {
                Text(
                    text = setting.value,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(modifier = Modifier.width(8.dp))
            }
            
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

data class Setting(
    val title: String,
    val description: String,
    val icon: ImageVector,
    val value: String? = null,
    val route: String? = null
)

@Composable
private fun AppLanguageSelector(
    selectedLanguage: String,
    onLanguageSelected: (String) -> Unit
) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        LanguageOptionChip(
            label = resolveLanguageLabel(APP_LANGUAGE_SYSTEM, "系统", "System", "システム"),
            selected = selectedLanguage == APP_LANGUAGE_SYSTEM,
            onClick = { onLanguageSelected(APP_LANGUAGE_SYSTEM) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "中文",
            selected = selectedLanguage == APP_LANGUAGE_ZH,
            onClick = { onLanguageSelected(APP_LANGUAGE_ZH) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "EN",
            selected = selectedLanguage == APP_LANGUAGE_EN,
            onClick = { onLanguageSelected(APP_LANGUAGE_EN) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "日本語",
            selected = selectedLanguage == APP_LANGUAGE_JA,
            onClick = { onLanguageSelected(APP_LANGUAGE_JA) },
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun LanguageOptionChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    LiquidGlassSurface(
        modifier = modifier,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        blurRadius = 0.dp,
        tintColor = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.20f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.10f),
        tintAlpha = if (selected) 0.20f else 0.10f,
        borderAlpha = if (selected) 0.20f else 0.10f,
        highlightAlpha = if (selected) 0.08f else 0.04f,
        edgeGlowAlpha = if (selected) 0.06f else 0.02f,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
        onClick = onClick
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
        )
    }
}

@Preview(showBackground = true)
@Composable
fun SettingsScreenPreview() {
    SkyBridgeCompassTheme {
        SettingsScreen(navController = rememberNavController())
    }
}
