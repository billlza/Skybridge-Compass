package com.skybridge.compass.android.ui.screens.account

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import coil.compose.AsyncImage
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.auth.AuthViewModel
import com.skybridge.compass.auth.ProfileSyncStatus
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.navigation.Screen
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh

internal enum class AccountProfileCompleteness {
    Complete,
    MissingAvatar,
    MissingNebulaId,
    MissingAvatarAndNebulaId
}

internal fun accountProfileCompleteness(
    profile: AccountStore.AccountProfile?
): AccountProfileCompleteness? {
    if (profile == null) return null
    val missingAvatar = profile.avatarUrl.isNullOrBlank()
    val missingNebulaId = profile.nebulaId.isNullOrBlank()
    return when {
        missingAvatar && missingNebulaId -> AccountProfileCompleteness.MissingAvatarAndNebulaId
        missingAvatar -> AccountProfileCompleteness.MissingAvatar
        missingNebulaId -> AccountProfileCompleteness.MissingNebulaId
        else -> AccountProfileCompleteness.Complete
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountCenterScreen(navController: NavController) {
    val authViewModel: AuthViewModel = hiltViewModel()
    val authState by authViewModel.uiState.collectAsState()
    val profile by AccountStore.primaryAccount.collectAsState()
    val title = localizedText("账户中心", "Account Center", "アカウントセンター")
    val primaryAccountLabel = localizedText("主账号", "Primary Account", "メインアカウント")
    val emptyAccountLabel = localizedText("暂无主账号，请登录后使用。", "No primary account yet. Please sign in first.", "メインアカウントがありません。先にログインしてください。")
    val avatarDescription = localizedText("头像", "Avatar", "アバター")
    val nicknamePrefix = localizedText("昵称：", "Nickname: ", "ニックネーム: ")
    val emailPrefix = localizedText("邮箱：", "Email: ", "メール: ")
    val phonePrefix = localizedText("手机号：", "Phone: ", "電話番号: ")
    val switchAccountLabel = localizedText("切换账号", "Switch Account", "アカウントを切り替える")
    val clearAccountLabel = localizedText("移除账号数据", "Remove Account Data", "アカウントデータを削除")
    val refreshProfileLabel = localizedText("刷新资料", "Refresh Profile", "プロフィールを更新")
    val syncingProfileLabel = localizedText("正在同步云端资料…", "Syncing cloud profile...", "クラウドプロフィールを同期中…")
    val syncedButMissingAvatar = localizedText(
        "云端资料已同步，但没有头像地址；请检查 Supabase user_profiles.avatar_url 或身份 metadata。",
        "Cloud profile synced, but no avatar URL was returned. Check Supabase user_profiles.avatar_url or identity metadata.",
        "クラウドプロフィールは同期済みですが、アバター URL が返されていません。Supabase user_profiles.avatar_url または ID メタデータを確認してください。"
    )
    val syncedButMissingNebulaId = localizedText(
        "云端资料已同步，但没有规范 Nebula ID；请检查身份 metadata、user_profiles.nebula_id、profiles/users.nebula_id。",
        "Cloud profile synced, but no canonical Nebula ID was returned. Check identity metadata, user_profiles.nebula_id, and profiles/users.nebula_id.",
        "クラウドプロフィールは同期済みですが、正規 Nebula ID が返されていません。ID メタデータ、user_profiles.nebula_id、profiles/users.nebula_id を確認してください。"
    )
    val syncedButMissingBoth = localizedText(
        "云端资料已同步，但头像与 Nebula ID 都缺失；请检查 Supabase profile projection、RLS 与身份 metadata。",
        "Cloud profile synced, but both avatar and Nebula ID are missing. Check Supabase profile projection, RLS, and identity metadata.",
        "クラウドプロフィールは同期済みですが、アバターと Nebula ID がどちらもありません。Supabase profile projection、RLS、ID メタデータを確認してください。"
    )
    val profileCompleteness = accountProfileCompleteness(profile)
    val profileStatusMessage = when (authState.profileSyncStatus) {
        ProfileSyncStatus.Syncing -> syncingProfileLabel
        ProfileSyncStatus.Failed -> authState.profileSyncMessage
        ProfileSyncStatus.Synced -> when (profileCompleteness) {
            AccountProfileCompleteness.MissingAvatar -> syncedButMissingAvatar
            AccountProfileCompleteness.MissingNebulaId -> syncedButMissingNebulaId
            AccountProfileCompleteness.MissingAvatarAndNebulaId -> syncedButMissingBoth
            AccountProfileCompleteness.Complete, null -> null
        }
        ProfileSyncStatus.Idle -> null
    }
    val profileStatusIsError = authState.profileSyncStatus == ProfileSyncStatus.Failed ||
        (authState.profileSyncStatus == ProfileSyncStatus.Synced &&
            profileCompleteness != AccountProfileCompleteness.Complete &&
            profileCompleteness != null)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold
        )

        Spacer(modifier = Modifier.height(16.dp))

        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
            blurRadius = 0.dp,
            tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.18f),
            tintAlpha = 0.18f,
            borderAlpha = 0.14f,
            highlightAlpha = 0.06f,
            edgeGlowAlpha = 0.04f,
            contentPadding = PaddingValues(16.dp)
        ) {
            Column(Modifier.fillMaxWidth()) {
                Text(text = primaryAccountLabel, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Spacer(modifier = Modifier.height(8.dp))
                if (profile == null) {
                    Text(text = emptyAccountLabel)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AsyncImage(
                            model = profile?.avatarUrl,
                            contentDescription = avatarDescription,
                            modifier = Modifier
                                .size(56.dp)
                                .clip(CircleShape)
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(text = "$nicknamePrefix${profile?.displayName ?: "-"}")
                            Text(text = "$emailPrefix${profile?.email ?: "-"}")
                            Text(text = "$phonePrefix${profile?.phone ?: "-"}")
                            Text(text = "Nebula ID：${profile?.nebulaId ?: "-"}")
                        }
                    }
                }
                profileStatusMessage?.let { message ->
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (profileStatusIsError) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Button(
                onClick = { authViewModel.refreshProfile() },
                enabled = authState.profileSyncStatus != ProfileSyncStatus.Syncing,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.Refresh, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(refreshProfileLabel)
            }

            Button(
                onClick = {
                    // 切换账号：登出并跳转登录页
                    authViewModel.logout()
                    navController.navigate(Screen.Settings.route) // 先回设置防止空路由
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(switchAccountLabel)
            }

            OutlinedButton(
                onClick = { authViewModel.logout() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(clearAccountLabel)
            }
        }
    }
}
