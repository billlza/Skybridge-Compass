package com.skybridge.compass.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.skybridge.compass.android.ui.navigation.Screen

import com.skybridge.compass.shared.notifications.NotificationCenter
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.LaunchedEffect
import com.skybridge.compass.android.notifications.SystemNotifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.platform.LocalDensity
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.draw.clip
import androidx.compose.ui.window.Popup
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.shared.account.AccountStore

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun TopActionBar(navController: NavHostController) {
    var showNotifications by remember { mutableStateOf(false) }
    val context = LocalContext.current
    LaunchedEffect(Unit) { SystemNotifier.init(context) }
    val notifications = NotificationCenter.history.collectAsState().value
    val unreadCount by NotificationCenter.unreadCount.collectAsState()
    val profile = AccountStore.primaryAccount.collectAsState().value
    var showUserDetails by remember { mutableStateOf(false) }

    LiquidGlassSurface(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(30.dp),
        blurRadius = 0.dp,
        tintColor = Color(0xFF1B1F29).copy(alpha = 0.14f),
        tintAlpha = 0.14f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.05f,
        edgeGlowAlpha = 0.04f,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(54.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            // User badge (single top glass; replaces the separate GlobalUserBadgeTopLeft overlay)
            val displayName = profile?.displayName ?: (profile?.email ?: t("未登录", "Not Signed In", "未ログイン"))
            val initial = displayName.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
            LiquidGlassSurface(
                shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
                blurRadius = 0.dp,
                tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.12f),
                tintAlpha = 0.12f,
                borderAlpha = 0.12f,
                highlightAlpha = 0.05f,
                edgeGlowAlpha = 0.03f,
                shadowElevation = 0.dp,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                onClick = { showUserDetails = true }
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val avatarUrl = profile?.avatarUrl
                    if (!avatarUrl.isNullOrBlank()) {
                        AsyncImage(
                            model = ImageRequest.Builder(context)
                                .data(avatarUrl)
                                .crossfade(true)
                                .build(),
                            contentDescription = null,
                            modifier = Modifier
                                .size(26.dp)
                                .clip(CircleShape)
                        )
                    } else {
                        androidx.compose.material3.Surface(
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.22f),
                            shape = CircleShape,
                            modifier = Modifier.size(26.dp)
                        ) {
                            Box(modifier = Modifier.fillMaxSize()) {
                                Text(
                                    text = initial,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onPrimary,
                                    modifier = Modifier.align(Alignment.Center)
                                )
                            }
                        }
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = displayName,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                BadgedBox(badge = {
                    if (unreadCount > 0) {
                        Badge { Text("$unreadCount") }
                    }
                }) {
                    GlassCircleButton(
                        onClick = { showNotifications = !showNotifications },
                        contentDescription = t("通知", "Notifications", "通知")
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Notifications,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }

                Spacer(modifier = Modifier.width(8.dp))

                GlassCircleButton(
                    onClick = { navController.navigate(Screen.Settings.route) },
                    contentDescription = t("设置", "Settings", "設定")
                ) {
                    Icon(
                        imageVector = Icons.Filled.Settings,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurface
                    )
                }

                DropdownMenu(expanded = showNotifications, onDismissRequest = { showNotifications = false }) {
                    DropdownMenuItem(
                        text = { Text(t("全部已读", "Mark All Read", "すべて既読")) },
                        onClick = { NotificationCenter.markAllRead(); showNotifications = false }
                    )
                    DropdownMenuItem(
                        text = { Text(t("清空通知", "Clear Notifications", "通知をクリア")) },
                        onClick = { NotificationCenter.clear(); showNotifications = false }
                    )
                    if (notifications.isEmpty()) {
                        DropdownMenuItem(
                            text = { Text(t("暂无通知", "No Notifications", "通知はありません")) },
                            onClick = { showNotifications = false },
                            enabled = false
                        )
                        DropdownMenuItem(
                            text = { Text(t("打开设置", "Open Settings", "設定を開く")) },
                            onClick = { navController.navigate(Screen.Settings.route); showNotifications = false }
                        )
                    } else {
                        notifications.forEach { n ->
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(n.title)
                                            if (n.message.isNotBlank()) {
                                                Text(n.message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            }
                                        }
                                        IconButton(onClick = { NotificationCenter.remove(n.id) }) {
                                            Icon(Icons.Default.Delete, contentDescription = t("删除", "Delete", "削除"))
                                        }
                                    }
                                },
                                onClick = { NotificationCenter.markRead(n.id); showNotifications = false }
                            )
                        }
                    }
                }
            }
        }
    }

    if (showUserDetails) {
        val density = LocalDensity.current
        // Popup aligned under the top bar on the left (iOS-like)
        val offset = with(density) { IntOffset(16.dp.roundToPx(), 68.dp.roundToPx()) }
        Popup(alignment = Alignment.TopStart, offset = offset, onDismissRequest = { showUserDetails = false }) {
            val displayName = profile?.displayName ?: (profile?.email ?: t("未登录", "Not Signed In", "未ログイン"))
            val initial = displayName.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
            LiquidGlassSurface(
                blurRadius = 0.dp,
                tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.16f),
                tintAlpha = 0.16f,
                borderAlpha = 0.16f,
                highlightAlpha = 0.06f,
                edgeGlowAlpha = 0.04f,
                shadowElevation = 0.dp,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val avatarUrl = profile?.avatarUrl
                        if (!avatarUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = ImageRequest.Builder(context)
                                    .data(avatarUrl)
                                    .crossfade(true)
                                    .build(),
                                contentDescription = null,
                                modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                            )
                        } else {
                            androidx.compose.material3.Surface(
                                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.22f),
                                shape = CircleShape,
                                modifier = Modifier.size(40.dp)
                            ) {
                                Box(modifier = Modifier.fillMaxSize()) {
                                    Text(
                                        text = initial,
                                        style = MaterialTheme.typography.titleSmall,
                                        color = MaterialTheme.colorScheme.onPrimary,
                                        modifier = Modifier.align(Alignment.Center)
                                    )
                                }
                            }
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        Column {
                            Text(displayName, style = MaterialTheme.typography.titleSmall)
                            val email = profile?.email ?: "-"
                            Text("${t("邮箱：", "Email: ", "メール: ")}$email", style = MaterialTheme.typography.bodySmall)
                            val idShort = profile?.nebulaId?.let { if (it.length > 12) "${it.take(6)}...${it.takeLast(4)}" else it } ?: "-"
                            Text("NebulaID：$idShort", style = MaterialTheme.typography.bodySmall)
                        }
                    }

                    @Suppress("DEPRECATION")
                    val clipboard = LocalClipboardManager.current
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        androidx.compose.material3.TextButton(onClick = {
                            profile?.email?.let { clipboard.setText(AnnotatedString(it)) }
                            showUserDetails = false
                        }) { Text(t("复制邮箱", "Copy Email", "メールをコピー")) }
                        androidx.compose.material3.TextButton(
                            onClick = {
                                profile?.nebulaId?.let { clipboard.setText(AnnotatedString(it)) }
                                showUserDetails = false
                            },
                            enabled = (profile?.nebulaId?.isNotBlank() == true)
                        ) { Text(t("复制 NebulaID", "Copy NebulaID", "NebulaID をコピー")) }
                        androidx.compose.material3.TextButton(onClick = {
                            showUserDetails = false
                            navController.navigate(Screen.AccountCenter.route)
                        }) { Text(t("账户中心", "Account Center", "アカウントセンター")) }
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassCircleButton(
    onClick: () -> Unit,
    contentDescription: String,
    content: @Composable () -> Unit
) {
    LiquidGlassSurface(
        shape = CircleShape,
        blurRadius = 0.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.10f),
        tintAlpha = 0.10f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.05f,
        edgeGlowAlpha = 0.03f,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(10.dp),
        onClick = onClick
    ) {
        Box(
            modifier = Modifier.size(22.dp),
            contentAlignment = Alignment.Center
        ) {
            content()
        }
    }
}
