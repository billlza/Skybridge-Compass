package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.LockReset
import androidx.compose.material.icons.filled.ManageAccounts
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection

/**
 * "账户 / Account" grouped section — extracted verbatim from SettingsScreen.kt.
 * Sign-in status + remember-login + account-center navigation are wired exactly as before.
 */
@Composable
fun AccountSettingsSection(
    isAuthenticated: Boolean,
    appSettings: AppSettings,
    onLogout: () -> Unit,
    onRememberLoginChange: (Boolean) -> Unit,
    onOpenAccountCenter: () -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    GroupedGlassSection(title = t("账户", "Account", "アカウント")) {
        GroupedGlassRow(
            title = t("登录状态", "Sign-in Status", "ログイン状態"),
            subtitle = if (isAuthenticated) {
                t("已登录", "Signed In", "ログイン済み")
            } else {
                t("未登录", "Signed Out", "未ログイン")
            },
            icon = Icons.Default.AccountCircle
        ) {
            if (isAuthenticated) {
                TextButton(onClick = onLogout) { Text(t("登出", "Sign Out", "ログアウト")) }
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
                onCheckedChange = onRememberLoginChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("账户中心", "Account Center", "アカウントセンター"),
            subtitle = t("查看主账号信息与切换账号", "View the primary account and switch accounts", "メインアカウントの確認と切り替え"),
            icon = Icons.Default.ManageAccounts,
            onClick = onOpenAccountCenter
        ) {
            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
