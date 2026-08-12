package com.skybridge.compass.android.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.skybridge.compass.android.discovery.DiscoveryLaunchTargetRoute
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
import com.skybridge.compass.android.ui.screens.settings.RemoteDesktopStreamSettingsScreen
import com.skybridge.compass.android.ui.screens.settings.WebRtcSettingsScreen
import com.skybridge.compass.android.ui.screens.settings.HelpSupportScreen
import com.skybridge.compass.android.ui.screens.settings.FeedbackScreen
import com.skybridge.compass.android.ui.screens.settings.OpenSourceLicensesScreen
import com.skybridge.compass.android.ui.screens.settings.VersionInfoScreen
import com.skybridge.compass.android.ui.screens.account.AccountCenterScreen
import com.skybridge.compass.android.ui.screens.filetransfer.FileTransferScreen
import com.skybridge.compass.android.ui.screens.securityprompts.IncomingTransferReviewScreen
import com.skybridge.compass.android.ui.screens.securityprompts.PairingTrustReviewScreen
import com.skybridge.compass.android.ui.screens.pairing.PibPairingScreen

@Composable
fun SkyBridgeNavigation(navController: NavHostController) {
    NavHost(
        navController = navController,
        startDestination = Screen.Dashboard.route
    ) {
        composable(Screen.Dashboard.route) {
            NavigationDestination(Screen.Dashboard.route) {
                DashboardScreen(navController = navController)
            }
        }
        
        composable(Screen.DeviceDiscovery.route) {
            NavigationDestination(Screen.DeviceDiscovery.route) {
                DeviceDiscoveryScreen(navController = navController)
            }
        }
        
        composable(Screen.ScreenMirroring.route) {
            NavigationDestination(Screen.ScreenMirroring.route) {
                ScreenMirroringScreen(navController = navController)
            }
        }
        
        composable(
            route = Screen.RemoteControl.routePattern,
            arguments = discoveryLaunchTargetNavArguments()
        ) { backStackEntry ->
            val parsedTarget = backStackEntry.parseDiscoveryLaunchTarget()
            NavigationDestination(Screen.RemoteControl.route) {
                RemoteControlScreen(
                    navController = navController,
                    initialLanTarget = parsedTarget.getOrNull(),
                    launchTargetError = parsedTarget.exceptionOrNull()?.message
                )
            }
        }

        composable(Screen.PibPairing.route) {
            PibPairingScreen(navController = navController)
        }
        
        composable(
            route = Screen.FileTransfer.routePattern,
            arguments = discoveryLaunchTargetNavArguments()
        ) { backStackEntry ->
            val parsedTarget = backStackEntry.parseDiscoveryLaunchTarget()
            NavigationDestination(Screen.FileTransfer.route) {
                FileTransferScreen(
                    navController = navController,
                    initialTarget = parsedTarget.getOrNull(),
                    launchTargetError = parsedTarget.exceptionOrNull()?.message
                )
            }
        }
        
        composable(Screen.Settings.route) {
            NavigationDestination(Screen.Settings.route) {
                SettingsScreen(navController = navController)
            }
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
        composable(Screen.RemoteDesktopStreamSettings.route) {
            RemoteDesktopStreamSettingsScreen(navController = navController)
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

@Composable
private fun NavigationDestination(
    route: String,
    content: @Composable () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag(NavigationSemantics.destination(route))
    ) {
        content()
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
    object RemoteControl : Screen("remote_control", "远程控制", "Remote Control", "リモート操作") {
        val routePattern: String = DiscoveryLaunchTargetRoute.patternFor(route)
        fun routeFor(target: com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget): String =
            DiscoveryLaunchTargetRoute.routeFor(route, target)
    }
    object PibPairing : Screen("pairing/pib_sas", "配对 Mac", "Pair with Mac", "Mac とペアリング")
    object FileTransfer : Screen("file_transfer", "文件传输", "File Transfer", "ファイル転送") {
        val routePattern: String = DiscoveryLaunchTargetRoute.patternFor(route)
        fun routeFor(target: com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget): String =
            DiscoveryLaunchTargetRoute.routeFor(route, target)
    }
    object Settings : Screen("settings", "设置", "Settings", "設定")
    object AccountCenter : Screen("account_center", "账户中心", "Account Center", "アカウントセンター")
    
    // 设置子页面
    object DeviceAuthentication : Screen("settings/device_auth", "设备认证", "Device Authentication", "デバイス認証")
    object EncryptionSettings : Screen("settings/encryption", "数据加密", "Data Encryption", "データ暗号化")
    object AccessControl : Screen("settings/access_control", "访问控制", "Access Control", "アクセス制御")
    object PrivacySettings : Screen("settings/privacy", "隐私设置", "Privacy Settings", "プライバシー設定")
    object WebRtcSettings : Screen("settings/webrtc", "跨网 WebRTC", "Cross-Network WebRTC", "クロスネットワーク WebRTC")
    object RemoteDesktopStreamSettings : Screen("settings/stream", "画面流设置", "Stream Settings", "ストリーム設定")
    object HelpSupport : Screen("settings/help", "帮助与支持", "Help & Support", "ヘルプとサポート")
    object Feedback : Screen("settings/feedback", "反馈建议", "Feedback", "フィードバック")
    object OpenSourceLicenses : Screen("settings/licenses", "开源许可", "Open Source Licenses", "オープンソースライセンス")
    object VersionInfo : Screen("settings/version", "版本信息", "Version Info", "バージョン情報")

    // Security prompts
    object IncomingTransferReview : Screen("security/incoming_transfer_review/{transferId}", "来件确认", "Incoming Transfer Review", "受信ファイル確認")
    object PairingTrustReview : Screen("security/pairing_trust_review/{requestId}", "设备信任确认", "Trusted Device Review", "デバイス信頼確認")
}

private fun discoveryLaunchTargetNavArguments() =
    DiscoveryLaunchTargetRoute.argumentNames.map { name ->
        navArgument(name) {
            type = NavType.StringType
            nullable = true
            defaultValue = null
        }
    }

private fun androidx.navigation.NavBackStackEntry.parseDiscoveryLaunchTarget() =
    DiscoveryLaunchTargetRoute.parse(
        DiscoveryLaunchTargetRoute.argumentNames.associateWith { name ->
            arguments?.getString(name)
        }
    )
