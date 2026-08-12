package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.data.Q_PERIAPT_MIN_ANDROID_API
import com.skybridge.compass.android.data.Q_PERIAPT_MIN_ANDROID_RELEASE
import com.skybridge.compass.android.data.localQPeriaptSupported
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem

/**
 * 设备认证设置页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceAuthenticationScreen(
    navController: NavController,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val settings by viewModel.securitySettings.collectAsState()
    val qPeriaptSupported = remember { localQPeriaptSupported() }
    var pairingTimeout by remember(settings.pairingTimeoutSec) { mutableStateOf(settings.pairingTimeoutSec.toString()) }
    val parsedPairingTimeout = pairingTimeout.toIntOrNull()?.coerceIn(5, 600)
    val timeoutDirty = parsedPairingTimeout != null && parsedPairingTimeout != settings.pairingTimeoutSec
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("设备认证", "Device Authentication", "デバイス認証")) },
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
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("要求配对认证", "Require Pairing Approval", "ペアリング承認を必須にする"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("新设备连接时需要确认配对", "Require approval before a new device can connect", "新しいデバイスが接続する前に承認を求めます"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.requirePairing,
                                onCheckedChange = viewModel::setRequirePairing
                            )
                        }
                    }
                }
            }
            
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("自动信任已知设备", "Auto-trust Known Devices", "既知デバイスを自動信頼"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("之前配对过的设备可自动信任", "Previously paired devices can be trusted automatically", "以前にペアリングしたデバイスを自動で信頼します"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.autoTrustKnownDevices,
                                onCheckedChange = viewModel::setAutoTrustKnownDevices
                            )
                        }
                    }
                }
            }
            
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(t("配对超时时间", "Pairing Timeout", "ペアリングタイムアウト"), fontWeight = FontWeight.Medium)
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedTextField(
                            value = pairingTimeout,
                            onValueChange = { v ->
                                pairingTimeout = v.filter { c -> c.isDigit() }.take(3)
                            },
                            label = { Text(t("秒", "Seconds", "秒")) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = t(
                                    "允许范围 5–600 秒，当前 ${settings.pairingTimeoutSec} 秒",
                                    "Allowed range: 5–600 seconds, current ${settings.pairingTimeoutSec} seconds",
                                    "許容範囲: 5〜600 秒、現在 ${settings.pairingTimeoutSec} 秒"
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            TextButton(
                                enabled = timeoutDirty,
                                onClick = {
                                    val timeout = parsedPairingTimeout ?: return@TextButton
                                    viewModel.setPairingTimeoutSec(timeout)
                                }
                            ) {
                                Text(t("保存", "Save", "保存"))
                            }
                        }
                    }
                }
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(t("握手策略", "Handshake Policy", "ハンドシェイク方針"), fontWeight = FontWeight.Medium)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("强制 PQC 握手", "Require PQC Handshake", "PQC ハンドシェイクを必須化"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("关闭后允许 classic-only 对端直接握手", "When disabled, classic-only peers can complete the handshake directly", "無効にすると classic-only の相手とも直接ハンドシェイクできます"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.enforcePqcHandshake,
                                onCheckedChange = viewModel::setEnforcePqcHandshake
                            )
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("兼容 classic fallback", "Allow Classic Fallback", "Classic フォールバックを許可"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("仅建议旧设备互通时启用", "Only enable this for interoperability with older devices", "旧型デバイスとの互換性が必要な場合のみ有効にしてください"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.allowClassicFallbackForCompatibility,
                                onCheckedChange = viewModel::setAllowClassicFallbackForCompatibility
                            )
                        }

                        Text(
                            text = t("最低安全等级", "Minimum Security Tier", "最小セキュリティレベル"),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium
                        )
                        val tierOptions = listOf(
                            P2PQPeriaptKem.MINIMUM_TIER_RAW to "Q-Periapt (Beta)",
                            "nativePQC" to "X-Wing",
                            "liboqsPQC" to "ML-KEM",
                            "classic" to "Classic"
                        )
                        tierOptions.forEach { (tierValue, label) ->
                            val tierEnabled =
                                tierValue != P2PQPeriaptKem.MINIMUM_TIER_RAW || qPeriaptSupported
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = settings.pqcMinimumTier == tierValue,
                                    enabled = tierEnabled,
                                    onClick = {
                                        if (tierEnabled) {
                                            viewModel.setPqcMinimumTier(tierValue)
                                        }
                                    }
                                )
                                // R7.9（任务 15.7）：平台前提不满足时，除了不可修改，还必须**呈现说明
                                // 所需最低平台版本的前提文本**。前提文本直接拼进既有标签的字符串里，
                                // 不新增任何节点——行、容器与嵌套层级保持不变（G2 / G6）。
                                val prerequisiteSuffix = if (tierEnabled) {
                                    ""
                                } else {
                                    t(
                                        "（需要 Android $Q_PERIAPT_MIN_ANDROID_RELEASE+ / API $Q_PERIAPT_MIN_ANDROID_API+，当前设备不支持，该项取值不参与运行时判定）",
                                        " (requires Android $Q_PERIAPT_MIN_ANDROID_RELEASE+ / API $Q_PERIAPT_MIN_ANDROID_API+; unsupported on this device, so this value does not affect runtime)",
                                        "（Android $Q_PERIAPT_MIN_ANDROID_RELEASE+ / API $Q_PERIAPT_MIN_ANDROID_API+ が必要です。この端末では非対応のため、この値は実行時に反映されません）"
                                    )
                                }
                                Text(
                                    text = label + prerequisiteSuffix,
                                    color = if (tierEnabled) {
                                        MaterialTheme.colorScheme.onSurface
                                    } else {
                                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                                    }
                                )
                            }
                        }

                        // NOTE: The "Require Secure Enclave PoP" control was removed from the UI.
                        // The protocol documents this field as NOT enforced (P2PHandshakeWire.kt:35),
                        // so presenting a toggle that takes no effect was misleading. The on-wire
                        // field and its DataStore key are preserved as-is for cross-platform compat
                        // (still threaded into the handshake policy signature + cloud settings sync).
                    }
                }
            }
        }
    }
}

/**
 * 数据加密设置页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EncryptionSettingsScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("数据加密", "Encryption", "データ暗号化")) },
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
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("传输加密", "Transport Encryption", "通信暗号化"), fontWeight = FontWeight.Medium)
                                Text(
                                    t(
                                        "所有数据传输使用端到端加密。由跨平台传输契约固定为始终启用，不可关闭。",
                                        "All transfers use end-to-end encryption. Fixed to always-on by the cross-platform transport contract; cannot be turned off.",
                                        "すべての転送でエンドツーエンド暗号化を使用します。クロスプラットフォームの転送契約により常時有効で固定され、無効にできません。"
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            // R7.6: fixed, unchangeable value presented as read-only text instead of
                            // an inert disabled switch. Leaf-internal replacement of the trailing
                            // slot only — the row, its card/column/row containers and every nesting
                            // level are untouched (G2 / R11.3).
                            Text(
                                text = t("始终启用", "Always On", "常時有効"),
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }
            }
            
            item {
                // The transport always uses AES-256-GCM per the canonical cross-platform suite
                // contract; the algorithm is not selectable cross-platform, so this is shown as a
                // read-only fact rather than an inert picker.
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(t("加密算法", "Encryption Algorithm", "暗号化アルゴリズム"), fontWeight = FontWeight.Medium)
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "AES-256-GCM",
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            t(
                                "由跨平台密码套件固定，不可单独选择。",
                                "Fixed by the cross-platform cipher suite; not individually selectable.",
                                "クロスプラットフォームの暗号スイートで固定され、個別に選択できません。"
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("后量子加密", "Post-quantum Encryption", "耐量子暗号"), fontWeight = FontWeight.Medium)
                                Text(
                                    t(
                                        "使用 ML-KEM 混合加密保护数据。由跨平台握手套件固定为始终启用，不可关闭。",
                                        "Protect data with ML-KEM hybrid encryption. Fixed to always-on by the cross-platform handshake suite; cannot be turned off.",
                                        "ML-KEM ハイブリッド暗号でデータを保護します。クロスプラットフォームのハンドシェイクスイートにより常時有効で固定され、無効にできません。"
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            // R7.6: same leaf-internal replacement as the transport row above.
                            Text(
                                text = t("始终启用", "Always On", "常時有効"),
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * 访问控制设置页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccessControlScreen(
    navController: NavController,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val settings by viewModel.securitySettings.collectAsState()
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("访问控制", "Access Control", "アクセス制御")) },
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
                Text(
                    t("允许本机执行以下操作：", "Allow this device to perform the following actions:", "この端末で次の操作を許可します："),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
            }
            
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        PermissionRow(t("屏幕镜像", "Screen Mirroring", "画面ミラーリング"), t("允许查看对端屏幕（远程桌面）", "Allow viewing the peer's screen (remote desktop)", "相手端末の画面表示（リモートデスクトップ）を許可"), settings.allowScreenMirroring) {
                            viewModel.setAllowScreenMirroring(it)
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(t("文件传输", "File Transfer", "ファイル転送"), t("允许发送和接收文件", "Allow sending and receiving files", "ファイルの送受信を許可"), settings.allowFileTransfer) {
                            viewModel.setAllowFileTransfer(it)
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("自动接收可信设备", "Auto-accept Trusted Devices", "信頼済みデバイスを自動受信"),
                            description = t("来自已信任设备的文件自动接收（仍保存到 Downloads）", "Automatically accept files from trusted devices (still saved to Downloads)", "信頼済みデバイスからのファイルを自動受信します（Downloads に保存されます）"),
                            checked = settings.autoAcceptTrustedDevices,
                            enabled = settings.allowFileTransfer
                        ) {
                            viewModel.setAutoAcceptTrustedDevices(it)
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("覆盖同名文件前询问", "Ask Before Overwriting Duplicate Files", "同名ファイル上書き前に確認"),
                            description = t("保存到 Downloads 遇到同名文件会提示确认", "Ask for confirmation before overwriting duplicate files in Downloads", "Downloads 内の同名ファイルを上書きする前に確認します"),
                            checked = settings.confirmOverwriteOnInbound,
                            enabled = settings.allowFileTransfer
                        ) {
                            viewModel.setConfirmOverwriteOnInbound(it)
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(t("远程控制", "Remote Control", "リモート操作"), t("允许向对端发送鼠标/触控输入", "Allow sending mouse or touch input to the peer", "相手端末へマウス / タッチ入力を送信できます"), settings.allowRemoteControl) {
                            viewModel.setAllowRemoteControl(it)
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("剪贴板同步", "Clipboard Sync", "クリップボード同期"),
                            description = t("允许设备间同步文本剪贴板", "Allow text clipboard sync between devices", "デバイス間でテキストクリップボードを同期します"),
                            checked = settings.allowClipboardSync,
                            enabled = true
                        ) {
                            viewModel.setAllowClipboardSync(it)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PermissionRow(
    title: String,
    description: String,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

/**
 * 隐私设置页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PrivacySettingsScreen(
    navController: NavController,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val settings by viewModel.securitySettings.collectAsState()
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("隐私设置", "Privacy", "プライバシー")) },
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
            // NOTE: "Collect Analytics" and "Share Usage Data" controls were removed — there is no
            // analytics SDK or backend in this app, so the toggles did nothing. Their DataStore keys
            // are retained for cloud-settings-sync schema compatibility but are no longer presented.

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("显示设备名称", "Show Device Name", "デバイス名を表示"), fontWeight = FontWeight.Medium)
                                Text(
                                    t(
                                        "关闭后在 Bonjour/NSD 广播中使用匿名名称，仍可被发现连接",
                                        "When off, advertise an anonymized name in Bonjour/NSD discovery (still discoverable)",
                                        "オフのとき Bonjour/NSD 広告では匿名名を使用します（引き続き検出可能）"
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.showDeviceName,
                                onCheckedChange = viewModel::setShowDeviceName
                            )
                        }
                    }
                }
            }
        }
    }
}
