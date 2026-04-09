package com.skybridge.compass.android.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.screens.dashboard.DashboardScreen
import com.skybridge.compass.android.ui.screens.devicediscovery.DeviceDiscoveryScreen
import com.skybridge.compass.android.ui.screens.remotecontrol.RemoteControlScreen
import com.skybridge.compass.android.ui.screens.screenmirroring.ScreenMirroringScreen
import com.skybridge.compass.android.ui.screens.settings.SettingsScreen
import com.skybridge.compass.android.ui.screens.settings.DeviceAuthenticationScreen
import com.skybridge.compass.android.ui.screens.settings.EncryptionSettingsScreen
import com.skybridge.compass.android.ui.screens.settings.AccessControlScreen
import com.skybridge.compass.android.ui.screens.settings.PrivacySettingsScreen
import com.skybridge.compass.android.ui.screens.settings.WebRtcSettingsScreen
import com.skybridge.compass.android.ui.screens.settings.HelpSupportScreen
import com.skybridge.compass.android.ui.screens.settings.FeedbackScreen
import com.skybridge.compass.android.ui.screens.settings.OpenSourceLicensesScreen
import com.skybridge.compass.android.ui.screens.settings.VersionInfoScreen
import com.skybridge.compass.android.ui.screens.account.AccountCenterScreen
import com.skybridge.compass.android.ui.screens.filetransfer.FileTransferScreen
import com.skybridge.compass.android.ui.screens.securityprompts.IncomingTransferReviewScreen
import com.skybridge.compass.android.ui.screens.securityprompts.PairingTrustReviewScreen

@Composable
fun SkyBridgeNavigation(navController: NavHostController) {
    NavHost(
        navController = navController,
        startDestination = Screen.Dashboard.route
    ) {
        composable(Screen.Dashboard.route) {
            DashboardScreen(navController = navController)
        }
        
        composable(Screen.DeviceDiscovery.route) {
            DeviceDiscoveryScreen(navController = navController)
        }
        
        composable(Screen.ScreenMirroring.route) {
            ScreenMirroringScreen(navController = navController)
        }
        
        composable(Screen.RemoteControl.route) {
            RemoteControlScreen(navController = navController)
        }
        
        composable(Screen.FileTransfer.route) {
            FileTransferScreen(navController = navController)
        }
        
        composable(Screen.Settings.route) {
            SettingsScreen(navController = navController)
        }
        composable(Screen.AccountCenter.route) {
            AccountCenterScreen(navController = navController)
        }
        
        // 设置子页面
        composable(Screen.DeviceAuthentication.route) {
            DeviceAuthenticationScreen(navController = navController)
        }
        composable(Screen.EncryptionSettings.route) {
            EncryptionSettingsScreen(navController = navController)
        }
        composable(Screen.AccessControl.route) {
            AccessControlScreen(navController = navController)
        }
        composable(Screen.PrivacySettings.route) {
            PrivacySettingsScreen(navController = navController)
        }
        composable(Screen.WebRtcSettings.route) {
            WebRtcSettingsScreen(navController = navController)
        }
        composable(Screen.HelpSupport.route) {
            HelpSupportScreen(navController = navController)
        }
        composable(Screen.Feedback.route) {
            FeedbackScreen(navController = navController)
        }
        composable(Screen.OpenSourceLicenses.route) {
            OpenSourceLicensesScreen(navController = navController)
        }
        composable(Screen.VersionInfo.route) {
            VersionInfoScreen(navController = navController)
        }

        // Security prompts (opened from system notification actions)
        composable(
            route = Screen.IncomingTransferReview.route,
            arguments = listOf(navArgument("transferId") { type = NavType.StringType })
        ) { backStackEntry ->
            val transferId = backStackEntry.arguments?.getString("transferId")
            if (transferId != null) {
                IncomingTransferReviewScreen(navController = navController, transferId = transferId)
            }
        }
        composable(
            route = Screen.PairingTrustReview.route,
            arguments = listOf(navArgument("requestId") { type = NavType.StringType })
        ) { backStackEntry ->
            val requestId = backStackEntry.arguments?.getString("requestId")
            if (requestId != null) {
                PairingTrustReviewScreen(navController = navController, requestId = requestId)
            }
        }
    }
}

sealed class Screen(
    val route: String,
    zhTitle: String,
    enTitle: String,
    jaTitle: String
) {
    val title: String = resolveLocalizedText(zhTitle, enTitle, jaTitle)

    object Dashboard : Screen("dashboard", "仪表板", "Dashboard", "ダッシュボード")
    object DeviceDiscovery : Screen("device_discovery", "设备发现", "Device Discovery", "デバイス検出")
    object ScreenMirroring : Screen("screen_mirroring", "屏幕镜像", "Screen Mirroring", "画面ミラーリング")
    object RemoteControl : Screen("remote_control", "远程控制", "Remote Control", "リモート操作")
    object FileTransfer : Screen("file_transfer", "文件传输", "File Transfer", "ファイル転送")
    object Settings : Screen("settings", "设置", "Settings", "設定")
    object AccountCenter : Screen("account_center", "账户中心", "Account Center", "アカウントセンター")
    
    // 设置子页面
    object DeviceAuthentication : Screen("settings/device_auth", "设备认证", "Device Authentication", "デバイス認証")
    object EncryptionSettings : Screen("settings/encryption", "数据加密", "Data Encryption", "データ暗号化")
    object AccessControl : Screen("settings/access_control", "访问控制", "Access Control", "アクセス制御")
    object PrivacySettings : Screen("settings/privacy", "隐私设置", "Privacy Settings", "プライバシー設定")
    object WebRtcSettings : Screen("settings/webrtc", "跨网 WebRTC", "Cross-Network WebRTC", "クロスネットワーク WebRTC")
    object HelpSupport : Screen("settings/help", "帮助与支持", "Help & Support", "ヘルプとサポート")
    object Feedback : Screen("settings/feedback", "反馈建议", "Feedback", "フィードバック")
    object OpenSourceLicenses : Screen("settings/licenses", "开源许可", "Open Source Licenses", "オープンソースライセンス")
    object VersionInfo : Screen("settings/version", "版本信息", "Version Info", "バージョン情報")

    // Security prompts
    object IncomingTransferReview : Screen("security/incoming_transfer_review/{transferId}", "来件确认", "Incoming Transfer Review", "受信ファイル確認")
    object PairingTrustReview : Screen("security/pairing_trust_review/{requestId}", "设备信任确认", "Trusted Device Review", "デバイス信頼確認")
}
