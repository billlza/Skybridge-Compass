package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.biometric.BiometricManager
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import android.content.Context
import android.os.PowerManager
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.screens.settings.sections.AboutSettingsSectionGrouped
import com.skybridge.compass.android.ui.screens.settings.sections.AccountSettingsSection
import com.skybridge.compass.android.ui.screens.settings.sections.BatteryOptimizationCard
import com.skybridge.compass.android.ui.screens.settings.sections.DeveloperSettingsSectionGrouped
import com.skybridge.compass.android.ui.screens.settings.sections.GeneralSettingsSection
import com.skybridge.compass.android.ui.screens.settings.sections.NetworkSettingsSection
import com.skybridge.compass.android.ui.screens.settings.sections.SecuritySettingsSection
import com.skybridge.compass.android.ui.screens.settings.sections.SupabaseSettingsSection
import com.skybridge.compass.android.ui.screens.settings.sections.rememberAboutSettingItems
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.auth.AuthViewModel

/**
 * Settings root. Previously a single ~1187-line composable that mixed General / Account / Network /
 * Security / Supabase / Developer / About logic with all of the DataStore reads and writes.
 *
 * Now a slim orchestrator:
 * - All persisted state + update intents live in [SettingsViewModel] (DataStore-backed StateFlows).
 * - Each visual group is its own focused section composable under `settings/sections/`.
 *
 * Behavior is preserved exactly: identical sections in identical order, identical wiring of every
 * real setting, the same battery-optimization gating, and the same Activity-bound Supabase biometric
 * flows (which stay in [SupabaseSettingsSection] because they need a FragmentActivity).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    navController: NavController,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val context = LocalContext.current

    val appSettings by viewModel.appSettings.collectAsStateWithLifecycle()
    val devSettings by viewModel.developerSettings.collectAsStateWithLifecycle()
    val netSettings by viewModel.networkSettings.collectAsStateWithLifecycle()
    val networkValidationErrors by viewModel.networkValidationErrors.collectAsStateWithLifecycle()
    // R7.12：写入失败记录（按 controlId 索引）。用于呈现「保存未生效」并回滚文本框本地状态。
    val saveFailures by viewModel.saveFailures.collectAsStateWithLifecycle()
    val supabaseState by viewModel.supabaseState.collectAsStateWithLifecycle()

    val authViewModel: AuthViewModel = hiltViewModel()
    val authUiState by authViewModel.uiState.collectAsStateWithLifecycle()

    val authCode = remember(context) {
        BiometricManager.from(context).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
        )
    }
    val powerManager = remember(context) {
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    }

    val shouldShowBatteryOptimizationCard = remember(
        appSettings.showBatteryOptimizationWarning,
        powerManager
    ) {
        appSettings.showBatteryOptimizationWarning &&
            !powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    val aboutSettingItems = rememberAboutSettingItems()

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
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = t(
                "连接、安全、外观与高级配置",
                "Connections, security, appearance, and advanced configuration",
                "接続・セキュリティ・外観・高度な設定"
            ),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                bottom = com.skybridge.compass.android.ui.theme.IOSParityTokens.SpacingTokens.SettingsBottomClearance
            ),
            verticalArrangement = Arrangement.spacedBy(
                com.skybridge.compass.android.ui.theme.IOSParityTokens.SpacingTokens.SectionGap
            )
        ) {
            item {
                GeneralSettingsSection(
                    appSettings = appSettings,
                    onDarkModeChange = viewModel::setDarkMode,
                    onLanguageSelected = viewModel::setAppLanguage,
                    onAutoConnectChange = viewModel::setAutoConnect,
                    onNotificationsChange = viewModel::setNotifications,
                    onUseDynamicColorChange = viewModel::setUseDynamicColor,
                    onHapticFeedbackChange = viewModel::setHapticFeedback,
                    onKeepScreenOnChange = viewModel::setKeepScreenOn,
                    onBatteryOptimizationWarningChange = viewModel::setBatteryOptimizationWarning,
                    onRealTimeWeatherChange = viewModel::setRealTimeWeatherEnabled
                )
            }

            if (shouldShowBatteryOptimizationCard) {
                item {
                    BatteryOptimizationCard()
                }
            }

            item {
                AccountSettingsSection(
                    isAuthenticated = authUiState.isAuthenticated,
                    appSettings = appSettings,
                    onLogout = { authViewModel.logout() },
                    onRememberLoginChange = viewModel::setRememberLogin,
                    onOpenAccountCenter = {
                        navController.navigate(Screen.AccountCenter.route)
                    }
                )
            }

            item {
                NetworkSettingsSection(
                    netSettings = netSettings,
                    hapticFeedbackEnabled = appSettings.hapticFeedback,
                    validationErrors = networkValidationErrors,
                    saveFailures = saveFailures,
                    onSetPortRange = viewModel::setPortRangeFromInput,
                    onSetDiscoveryTimeoutSec = viewModel::setDiscoveryTimeoutSecFromInput,
                    onSetMaxReconnectAttempts = viewModel::setMaxReconnectAttemptsFromInput,
                    onClearValidationError = { fields -> viewModel.clearNetworkValidationError(*fields) },
                    onOpenWebRtcSettings = {
                        navController.navigate(Screen.WebRtcSettings.route)
                    }
                )
            }

            item {
                SecuritySettingsSection(
                    onNavigate = { route -> navController.navigate(route) }
                )
            }

            item {
                SupabaseSettingsSection(
                    supabaseState = supabaseState,
                    authCode = authCode,
                    hasManagedDefaults = viewModel.managedSupabaseDefaults() != null,
                    onReset = { onDone -> viewModel.resetSupabaseConfig(onDone) },
                    onValidate = { authViewModel.validateSupabaseConfiguration() },
                    onConfigurationAvailable = { authViewModel.tryRestoreSession(forceRefresh = true) }
                )
            }

            item {
                DeveloperSettingsSectionGrouped(
                    developerSettings = devSettings,
                    onScreenMirroringChange = viewModel::setEnableScreenMirroring,
                    onRemoteControlChange = viewModel::setEnableRemoteControl,
                    onFileTransferChange = viewModel::setEnableFileTransfer
                )
            }

            item {
                AboutSettingsSectionGrouped(
                    aboutSettingItems = aboutSettingItems,
                    onNavigate = { route -> navController.navigate(route) }
                )
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
fun SettingsScreenPreview() {
    SkyBridgeCompassTheme {
        SettingsScreen(navController = rememberNavController())
    }
}
