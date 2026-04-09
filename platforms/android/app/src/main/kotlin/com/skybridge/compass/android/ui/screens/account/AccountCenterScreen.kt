package com.skybridge.compass.android.ui.screens.account

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.sp
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
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.navigation.Screen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountCenterScreen(navController: NavController) {
    val authViewModel: AuthViewModel = hiltViewModel()
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
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = {
                // 切换账号：登出并跳转登录页
                authViewModel.logout()
                navController.navigate(Screen.Settings.route) // 先回设置防止空路由
            }) {
                Text(switchAccountLabel)
            }

            OutlinedButton(onClick = { AccountStore.clearPrimaryAccount() }) {
                Text(clearAccountLabel)
            }
        }
    }
}
