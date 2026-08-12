package com.skybridge.compass.android.ui.screens.settings

import android.content.Intent
import android.os.Build
import androidx.core.net.toUri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.i18n.resolveLocalizedText

/**
 * 帮助与支持页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpSupportScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("帮助与支持", "Help & Support", "ヘルプとサポート")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    onClick = {
                        val intent = Intent(Intent.ACTION_VIEW, "https://skybridge.app/docs".toUri())
                        context.startActivity(intent)
                    }
                ) {
                    ListItem(
                        headlineContent = { Text(t("在线文档", "Online Docs", "オンラインドキュメント")) },
                        supportingContent = { Text(t("查看完整使用指南", "Open the full user guide", "完全な利用ガイドを開く")) },
                        leadingContent = { Icon(Icons.Default.Info, null) }
                    )
                }
            }
            
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    onClick = {
                        val intent = Intent(Intent.ACTION_VIEW, "https://skybridge.app/faq".toUri())
                        context.startActivity(intent)
                    }
                ) {
                    ListItem(
                        headlineContent = { Text(t("常见问题", "FAQ", "よくある質問")) },
                        supportingContent = { Text(t("查看常见问题解答", "Open frequently asked questions", "よくある質問を開く")) },
                        leadingContent = { Icon(Icons.Default.Info, null) }
                    )
                }
            }
            
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    onClick = {
                        val intent = Intent(Intent.ACTION_SENDTO).apply {
                            data = "mailto:support@skybridge.app".toUri()
                            putExtra(Intent.EXTRA_SUBJECT, t("SkyBridge Compass 支持请求", "SkyBridge Compass Support Request", "SkyBridge Compass サポート依頼"))
                        }
                        context.startActivity(intent)
                    }
                ) {
                    ListItem(
                        headlineContent = { Text(t("联系支持", "Contact Support", "サポートに連絡")) },
                        supportingContent = { Text(t("发送邮件给技术支持团队", "Send an email to the support team", "サポートチームにメールを送る")) },
                        leadingContent = { Icon(Icons.Default.Email, null) }
                    )
                }
            }
        }
    }
}

/**
 * 反馈建议页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedbackScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    var feedbackType by remember { mutableStateOf("bug") }
    var feedbackText by remember { mutableStateOf("") }
    var includeDeviceInfo by remember { mutableStateOf(true) }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("反馈建议", "Feedback", "フィードバック")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(t("反馈类型", "Feedback Type", "フィードバック種別"), fontWeight = FontWeight.Medium)
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterChip(
                    selected = feedbackType == "bug",
                    onClick = { feedbackType = "bug" },
                    label = { Text(t("问题反馈", "Bug Report", "不具合報告")) }
                )
                FilterChip(
                    selected = feedbackType == "feature",
                    onClick = { feedbackType = "feature" },
                    label = { Text(t("功能建议", "Feature Idea", "機能提案")) }
                )
                FilterChip(
                    selected = feedbackType == "other",
                    onClick = { feedbackType = "other" },
                    label = { Text(t("其他", "Other", "その他")) }
                )
            }
            
            OutlinedTextField(
                value = feedbackText,
                onValueChange = { feedbackText = it },
                label = { Text(t("详细描述", "Detailed Description", "詳細説明")) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp),
                maxLines = 10
            )
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(
                    checked = includeDeviceInfo,
                    onCheckedChange = { includeDeviceInfo = it }
                )
                Text(t("包含设备信息（帮助我们更好地定位问题）", "Include device information (helps us investigate the issue)", "デバイス情報を含める（問題調査に役立ちます）"))
            }
            
            Spacer(modifier = Modifier.weight(1f))
            
            Button(
                onClick = {
                    val subject = when (feedbackType) {
                        "bug" -> t("[Bug] SkyBridge Compass 问题反馈", "[Bug] SkyBridge Compass Feedback", "[Bug] SkyBridge Compass 不具合報告")
                        "feature" -> t("[Feature] SkyBridge Compass 功能建议", "[Feature] SkyBridge Compass Feature Request", "[Feature] SkyBridge Compass 機能提案")
                        else -> t("[Feedback] SkyBridge Compass 反馈", "[Feedback] SkyBridge Compass Feedback", "[Feedback] SkyBridge Compass フィードバック")
                    }
                    val body = buildString {
                        append(feedbackText)
                        if (includeDeviceInfo) {
                            append("\n\n---\n")
                            append("${t("设备", "Device", "デバイス")}: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}\n")
                            append("Android: ${android.os.Build.VERSION.RELEASE}\n")
                            append("App: ${BuildConfig.VERSION_NAME}")
                        }
                    }
                    val intent = Intent(Intent.ACTION_SENDTO).apply {
                        data = "mailto:feedback@skybridge.app".toUri()
                        putExtra(Intent.EXTRA_SUBJECT, subject)
                        putExtra(Intent.EXTRA_TEXT, body)
                    }
                    context.startActivity(intent)
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = feedbackText.isNotBlank()
            ) {
                Text(t("提交反馈", "Send Feedback", "フィードバックを送信"))
            }
        }
    }
}

/**
 * 开源许可页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OpenSourceLicensesScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    val webRtcNotice = remember(context) {
        context.assets.open("third_party_licenses/webrtc-sdk.txt")
            .bufferedReader()
            .use { it.readText() }
    }
    val licenses = listOf(
        License("Kotlin", "Apache 2.0", "JetBrains"),
        License("Jetpack Compose", "Apache 2.0", "Google"),
        License("OkHttp", "Apache 2.0", "Square"),
        License("Kotlinx Serialization", "Apache 2.0", "JetBrains"),
        License("Hilt", "Apache 2.0", "Google"),
        License("Kotest", "Apache 2.0", "Kotest"),
        License("liboqs", "MIT", "Open Quantum Safe"),
        License("Bouncy Castle", "MIT", "Legion of the Bouncy Castle"),
        License("WebRTC Android SDK", "BSD-3-Clause / MIT", "WebRTC project authors / WebRTC SDKs")
    )
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("开源许可", "Open Source Licenses", "オープンソースライセンス")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            item {
                Text(
                    t("本应用使用了以下开源组件：", "This app uses the following open-source components:", "このアプリでは次のオープンソースコンポーネントを使用しています。"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(8.dp))
            }
            
            items(licenses) { license ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    ListItem(
                        headlineContent = { Text(license.name) },
                        supportingContent = { Text("${license.author} · ${license.type}") }
                    )
                }
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            "WebRTC Android SDK",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            t(
                                "完整第三方许可与归属声明",
                                "Complete third-party license and attribution notice",
                                "完全なサードパーティーライセンスと帰属表示"
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(webRtcNotice, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

private data class License(
    val name: String,
    val type: String,
    val author: String
)

/**
 * 版本信息页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VersionInfoScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("版本信息", "Version Info", "バージョン情報")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Spacer(modifier = Modifier.height(32.dp))
            
            Icon(
                Icons.Default.Settings,
                contentDescription = null,
                modifier = Modifier.size(80.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            
            Text(
                "SkyBridge Compass",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold
            )
            
            Text(
                t(
                    "版本 ${BuildConfig.VERSION_NAME} (Build ${BuildConfig.VERSION_CODE})",
                    "Version ${BuildConfig.VERSION_NAME} (Build ${BuildConfig.VERSION_CODE})",
                    "バージョン ${BuildConfig.VERSION_NAME} (Build ${BuildConfig.VERSION_CODE})"
                ),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    InfoRow(t("应用版本", "App Version", "アプリバージョン"), BuildConfig.VERSION_NAME)
                    InfoRow(t("构建号", "Build", "ビルド"), BuildConfig.VERSION_CODE.toString())
                    InfoRow(t("协议版本", "Protocol Version", "プロトコルバージョン"), "2.0")
                    InfoRow(t("最低 Android", "Minimum Android", "最低 Android"), "16 (API 36)")
                }
            }
            
            Spacer(modifier = Modifier.weight(1f))
            
            Text(
                "© 2026 SkyBridge Team",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontWeight = FontWeight.Medium)
    }
}
