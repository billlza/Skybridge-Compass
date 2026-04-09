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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.data.SecuritySettingsStore
import kotlinx.coroutines.launch

/**
 * 设备认证设置页面
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceAuthenticationScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by SecuritySettingsStore.observe(context).collectAsState(
        initial = com.skybridge.compass.android.data.SecuritySettings()
    )
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
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setRequirePairing(context, enabled) }
                                }
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
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setAutoTrustKnownDevices(context, enabled) }
                                }
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
                                    scope.launch {
                                        SecuritySettingsStore.setPairingTimeoutSec(context, timeout)
                                    }
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
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setEnforcePqcHandshake(context, enabled) }
                                }
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
                                onCheckedChange = { enabled ->
                                    scope.launch {
                                        SecuritySettingsStore.setAllowClassicFallbackForCompatibility(context, enabled)
                                    }
                                }
                            )
                        }

                        Text(
                            text = t("最低安全等级", "Minimum Security Tier", "最小セキュリティレベル"),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium
                        )
                        val tierOptions = listOf(
                            "nativePQC" to "X-Wing",
                            "liboqsPQC" to "ML-KEM",
                            "classic" to "Classic"
                        )
                        tierOptions.forEach { (tierValue, label) ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = settings.pqcMinimumTier == tierValue,
                                    onClick = {
                                        scope.launch { SecuritySettingsStore.setPqcMinimumTier(context, tierValue) }
                                    }
                                )
                                Text(label)
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("要求 Secure Enclave PoP", "Require Secure Enclave PoP", "Secure Enclave PoP を必須化"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("与 iOS/mac 协议字段保持一致（当前为兼容保留）", "Keep parity with the iOS/mac protocol field (retained for compatibility)", "iOS/mac のプロトコル項目との整合のために保持しています"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.requireSecureEnclavePoP,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setRequireSecureEnclavePoP(context, enabled) }
                                }
                            )
                        }
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
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by SecuritySettingsStore.observe(context).collectAsState(
        initial = com.skybridge.compass.android.data.SecuritySettings()
    )
    
    val algorithms = listOf("AES-128-GCM", "AES-256-GCM", "ChaCha20-Poly1305")
    
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
                                Text(t("启用传输加密", "Enable Transport Encryption", "通信暗号化を有効化"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("所有数据传输使用端到端加密（当前版本始终启用）", "Use end-to-end encryption for all transfers (always enabled in this version)", "すべての転送でエンドツーエンド暗号化を使用します（このバージョンでは常時有効）"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.encryptionEnabled,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setEncryptionEnabled(context, enabled) }
                                }
                            )
                        }
                    }
                }
            }
            
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(t("加密算法", "Encryption Algorithm", "暗号化アルゴリズム"), fontWeight = FontWeight.Medium)
                        Spacer(modifier = Modifier.height(8.dp))
                        algorithms.forEach { algorithm ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = settings.encryptionAlgorithm == algorithm,
                                    onClick = {
                                        scope.launch { SecuritySettingsStore.setEncryptionAlgorithm(context, algorithm) }
                                    }
                                )
                                Text(algorithm)
                            }
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
                                Text(t("后量子加密 (实验性)", "Post-quantum Encryption (Experimental)", "耐量子暗号（実験的）"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("使用 ML-KEM 混合加密保护数据", "Protect data with ML-KEM hybrid encryption", "ML-KEM ハイブリッド暗号でデータを保護します"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.pqcEnabled,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setPqcEnabled(context, enabled) }
                                }
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
fun AccessControlScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by SecuritySettingsStore.observe(context).collectAsState(
        initial = com.skybridge.compass.android.data.SecuritySettings()
    )
    
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
                            scope.launch { SecuritySettingsStore.setAllowScreenMirroring(context, it) }
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(t("文件传输", "File Transfer", "ファイル転送"), t("允许发送和接收文件", "Allow sending and receiving files", "ファイルの送受信を許可"), settings.allowFileTransfer) {
                            scope.launch { SecuritySettingsStore.setAllowFileTransfer(context, it) }
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("自动接收可信设备", "Auto-accept Trusted Devices", "信頼済みデバイスを自動受信"),
                            description = t("来自已信任设备的文件自动接收（仍保存到 Downloads）", "Automatically accept files from trusted devices (still saved to Downloads)", "信頼済みデバイスからのファイルを自動受信します（Downloads に保存されます）"),
                            checked = settings.autoAcceptTrustedDevices,
                            enabled = settings.allowFileTransfer
                        ) {
                            scope.launch { SecuritySettingsStore.setAutoAcceptTrustedDevices(context, it) }
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("覆盖同名文件前询问", "Ask Before Overwriting Duplicate Files", "同名ファイル上書き前に確認"),
                            description = t("保存到 Downloads 遇到同名文件会提示确认", "Ask for confirmation before overwriting duplicate files in Downloads", "Downloads 内の同名ファイルを上書きする前に確認します"),
                            checked = settings.confirmOverwriteOnInbound,
                            enabled = settings.allowFileTransfer
                        ) {
                            scope.launch { SecuritySettingsStore.setConfirmOverwriteOnInbound(context, it) }
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(t("远程控制", "Remote Control", "リモート操作"), t("允许向对端发送鼠标/触控输入", "Allow sending mouse or touch input to the peer", "相手端末へマウス / タッチ入力を送信できます"), settings.allowRemoteControl) {
                            scope.launch { SecuritySettingsStore.setAllowRemoteControl(context, it) }
                        }
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        PermissionRow(
                            title = t("剪贴板同步", "Clipboard Sync", "クリップボード同期"),
                            description = t("允许设备间同步文本剪贴板", "Allow text clipboard sync between devices", "デバイス間でテキストクリップボードを同期します"),
                            checked = settings.allowClipboardSync,
                            enabled = true
                        ) {
                            scope.launch { SecuritySettingsStore.setAllowClipboardSync(context, it) }
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
fun PrivacySettingsScreen(navController: NavController) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by SecuritySettingsStore.observe(context).collectAsState(
        initial = com.skybridge.compass.android.data.SecuritySettings()
    )
    
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
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t("收集分析数据", "Collect Analytics", "分析データを収集"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("帮助我们改进应用体验", "Help us improve the app experience", "アプリ体験の改善に役立てます"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.collectAnalytics,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setCollectAnalytics(context, enabled) }
                                }
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
                                Text(t("分享使用数据", "Share Usage Data", "利用データを共有"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("匿名分享使用统计", "Share anonymized usage statistics", "匿名の利用統計を共有します"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.shareUsageData,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setShareUsageData(context, enabled) }
                                }
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
                                Text(t("显示设备名称", "Show Device Name", "デバイス名を表示"), fontWeight = FontWeight.Medium)
                                Text(
                                    t("在发现列表中显示本机名称", "Show this device name in discovery results", "探索結果にこの端末名を表示します"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = settings.showDeviceName,
                                onCheckedChange = { enabled ->
                                    scope.launch { SecuritySettingsStore.setShowDeviceName(context, enabled) }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}
