package com.skybridge.compass.android.data

import android.content.Context
import android.os.Build
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.skybridge.compass.core.p2p.resolveRequestedHandshakeMinimumTierRaw
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

private val Context.securitySettingsDataStore by preferencesDataStore(name = "security_settings")

private fun defaultEnforcePqcHandshake(): Boolean = true

private fun defaultAllowClassicFallbackForCompatibility(): Boolean = false

private fun defaultPqcMinimumTier(): String =
    resolveRequestedHandshakeMinimumTierRaw(
        requestedMinimumTierRaw = "nativePQC",
        requirePqc = true
    )

internal fun localQPeriaptSupported(): Boolean =
    QPeriaptPlatformPolicy.isLocalAndroidSupported(
        QPeriaptPlatformPolicy.androidPlatformVersion(
            release = Build.VERSION.RELEASE,
            sdkInt = Build.VERSION.SDK_INT
        )
    )

internal fun normalizePqcMinimumTier(
    tier: String,
    qPeriaptSupported: Boolean = localQPeriaptSupported()
): String {
    val normalized = when (tier) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW, "nativePQC", "liboqsPQC", "classic" -> tier
        else -> throw IllegalArgumentException("unsupported PQC minimum tier")
    }
    if (normalized == P2PQPeriaptKem.MINIMUM_TIER_RAW) {
        require(qPeriaptSupported) {
            "Q-Periapt requires Android 16+ / API 36+"
        }
    }
    return normalized
}

/** Q-Periapt 的平台前提文本所需的最低 Android 版本（与 [QPeriaptPlatformPolicy] 的判定一致）。 */
internal const val Q_PERIAPT_MIN_ANDROID_RELEASE: Int = 16

/** Q-Periapt 的平台前提所需最低 API 等级。 */
internal const val Q_PERIAPT_MIN_ANDROID_API: Int = 36

/**
 * 读取持久化的最低安全等级（R7.9 的**读取面**）。
 *
 * 与写入面 [normalizePqcMinimumTier] 的关键差别：**本函数永不抛出**。
 *
 * R7.9 要求「低于所需平台版本的项，其持久化值不参与运行时行为判定」。此前这里直接复用写入面的
 * `normalizePqcMinimumTier`，于是当持久化值为 `q-periapt` 而本机不满足 Android 16+/API 36+ 时
 * 会抛 `IllegalArgumentException`；该调用位于 `observe()` 的 `map` 内，异常会摧毁整个
 * security settings 流（不只是这一项）。这条路径是**可达的**：云端设置同步会把新机器上保存的
 * 值下发到旧机器（`CloudUserSettingsSyncManager`），备份恢复与系统降级同理。
 *
 * 正确语义是「该值不参与判定」，即**回落到平台可支持的默认值**，而不是让读取失败：
 * - 平台前提不满足的 `q-periapt` → [defaultPqcMinimumTier]（`nativePQC`，仍是 PQC，不降级到 classic）；
 * - 无法识别的等级字符串（未来版本写入的值）→ 同样回落，保证旧版本不会因前向值崩溃。
 *
 * 写入面仍然严格拒绝不满足前提的取值，因此这里的回落不会成为绕过前提的通道。
 */
internal fun readStoredPqcMinimumTier(
    tier: String?,
    qPeriaptSupported: Boolean = localQPeriaptSupported()
): String {
    if (tier == null) return defaultPqcMinimumTier()
    return runCatching { normalizePqcMinimumTier(tier, qPeriaptSupported) }
        .getOrElse { defaultPqcMinimumTier() }
}

/**
 * 某个持久化等级在本机是否因平台前提而**不参与**运行时判定（R7.9）。
 *
 * 供界面呈现前提文本与测试断言使用；判定与 [readStoredPqcMinimumTier] 的回落条件同源。
 */
internal fun pqcMinimumTierIsGatedByPlatform(
    tier: String?,
    qPeriaptSupported: Boolean = localQPeriaptSupported()
): Boolean = tier == P2PQPeriaptKem.MINIMUM_TIER_RAW && !qPeriaptSupported

data class SecuritySettings(
    // Device authentication
    val requirePairing: Boolean = true,
    val autoTrustKnownDevices: Boolean = false,
    val pairingTimeoutSec: Int = 30,

    // Encryption
    val encryptionEnabled: Boolean = true,
    val encryptionAlgorithm: String = "AES-256-GCM",
    val pqcEnabled: Boolean = true,
    val enforcePqcHandshake: Boolean = defaultEnforcePqcHandshake(),
    val allowClassicFallbackForCompatibility: Boolean = defaultAllowClassicFallbackForCompatibility(),
    val pqcMinimumTier: String = defaultPqcMinimumTier(),
    val requireSecureEnclavePoP: Boolean = false,

    // Access control
    val allowScreenMirroring: Boolean = true,
    val allowFileTransfer: Boolean = true,
    /** Auto-accept inbound transfers from trusted (pinned) devices. */
    val autoAcceptTrustedDevices: Boolean = false,
    /** Ask before overwriting an existing file when saving inbound transfers. */
    val confirmOverwriteOnInbound: Boolean = true,
    val allowRemoteControl: Boolean = false,
    /** Require explicit user confirmation before allowing remote control sessions. */
    val remoteControlRequireConfirmation: Boolean = true,
    val allowClipboardSync: Boolean = true,

    // Privacy
    val collectAnalytics: Boolean = false,
    val shareUsageData: Boolean = false,
    val showDeviceName: Boolean = true
)

object SecuritySettingsStore {
    private val KEY_REQUIRE_PAIRING = booleanPreferencesKey("require_pairing")
    private val KEY_AUTO_TRUST = booleanPreferencesKey("auto_trust_known_devices")
    private val KEY_PAIRING_TIMEOUT_SEC = intPreferencesKey("pairing_timeout_sec")

    private val KEY_ENCRYPTION_ENABLED = booleanPreferencesKey("encryption_enabled")
    private val KEY_ENCRYPTION_ALGORITHM = stringPreferencesKey("encryption_algorithm")
    private val KEY_PQC_ENABLED = booleanPreferencesKey("pqc_enabled")
    private val KEY_ENFORCE_PQC_HANDSHAKE = booleanPreferencesKey("enforce_pqc_handshake")
    private val KEY_ALLOW_CLASSIC_FALLBACK = booleanPreferencesKey("allow_classic_fallback_for_compatibility")
    private val KEY_PQC_MINIMUM_TIER = stringPreferencesKey("pqc_minimum_tier")
    private val KEY_REQUIRE_SECURE_ENCLAVE_POP = booleanPreferencesKey("require_secure_enclave_pop")

    private val KEY_ALLOW_SCREEN_MIRRORING = booleanPreferencesKey("allow_screen_mirroring")
    private val KEY_ALLOW_FILE_TRANSFER = booleanPreferencesKey("allow_file_transfer")
    private val KEY_AUTO_ACCEPT_TRUSTED_DEVICES = booleanPreferencesKey("auto_accept_trusted_devices")
    private val KEY_CONFIRM_OVERWRITE_ON_INBOUND = booleanPreferencesKey("confirm_overwrite_on_inbound")
    private val KEY_ALLOW_REMOTE_CONTROL = booleanPreferencesKey("allow_remote_control")
    private val KEY_REMOTE_CONTROL_REQUIRE_CONFIRMATION = booleanPreferencesKey("remote_control_require_confirmation")
    private val KEY_ALLOW_CLIPBOARD_SYNC = booleanPreferencesKey("allow_clipboard_sync")

    private val KEY_COLLECT_ANALYTICS = booleanPreferencesKey("collect_analytics")
    private val KEY_SHARE_USAGE_DATA = booleanPreferencesKey("share_usage_data")
    private val KEY_SHOW_DEVICE_NAME = booleanPreferencesKey("show_device_name")

    fun observe(context: Context): Flow<SecuritySettings> =
        context.securitySettingsDataStore.data
            .catch { e ->
                throw e
            }
            .map { prefs ->
                SecuritySettings(
                    requirePairing = prefs[KEY_REQUIRE_PAIRING] ?: true,
                    autoTrustKnownDevices = prefs[KEY_AUTO_TRUST] ?: false,
                    pairingTimeoutSec = (prefs[KEY_PAIRING_TIMEOUT_SEC] ?: 30).coerceIn(5, 600),

                    encryptionEnabled = true,
                    encryptionAlgorithm = prefs[KEY_ENCRYPTION_ALGORITHM] ?: "AES-256-GCM",
                    pqcEnabled = true,
                    enforcePqcHandshake = prefs[KEY_ENFORCE_PQC_HANDSHAKE] ?: defaultEnforcePqcHandshake(),
                    allowClassicFallbackForCompatibility = prefs[KEY_ALLOW_CLASSIC_FALLBACK] ?: defaultAllowClassicFallbackForCompatibility(),
                    pqcMinimumTier = readStoredPqcMinimumTier(prefs[KEY_PQC_MINIMUM_TIER]),
                    requireSecureEnclavePoP = prefs[KEY_REQUIRE_SECURE_ENCLAVE_POP] ?: false,

                    allowScreenMirroring = prefs[KEY_ALLOW_SCREEN_MIRRORING] ?: true,
                    allowFileTransfer = prefs[KEY_ALLOW_FILE_TRANSFER] ?: true,
                    autoAcceptTrustedDevices = prefs[KEY_AUTO_ACCEPT_TRUSTED_DEVICES] ?: false,
                    confirmOverwriteOnInbound = prefs[KEY_CONFIRM_OVERWRITE_ON_INBOUND] ?: true,
                    allowRemoteControl = prefs[KEY_ALLOW_REMOTE_CONTROL] ?: false,
                    remoteControlRequireConfirmation = prefs[KEY_REMOTE_CONTROL_REQUIRE_CONFIRMATION] ?: true,
                    allowClipboardSync = prefs[KEY_ALLOW_CLIPBOARD_SYNC] ?: true,

                    collectAnalytics = prefs[KEY_COLLECT_ANALYTICS] ?: false,
                    shareUsageData = prefs[KEY_SHARE_USAGE_DATA] ?: false,
                    showDeviceName = prefs[KEY_SHOW_DEVICE_NAME] ?: true
                )
            }

    suspend fun setRequirePairing(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_REQUIRE_PAIRING] = enabled }
    }

    suspend fun setAutoTrustKnownDevices(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_AUTO_TRUST] = enabled }
    }

    suspend fun setPairingTimeoutSec(context: Context, seconds: Int) {
        context.securitySettingsDataStore.edit { it[KEY_PAIRING_TIMEOUT_SEC] = seconds.coerceIn(5, 600) }
    }

    suspend fun setEncryptionEnabled(context: Context, enabled: Boolean) {
        require(enabled) { "transport encryption cannot be disabled" }
        context.securitySettingsDataStore.edit { it[KEY_ENCRYPTION_ENABLED] = true }
    }

    suspend fun setEncryptionAlgorithm(context: Context, algorithm: String) {
        context.securitySettingsDataStore.edit { it[KEY_ENCRYPTION_ALGORITHM] = algorithm }
    }

    suspend fun setPqcEnabled(context: Context, enabled: Boolean) {
        require(enabled) { "PQC cannot be disabled for this product line" }
        context.securitySettingsDataStore.edit { it[KEY_PQC_ENABLED] = true }
    }

    suspend fun setEnforcePqcHandshake(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ENFORCE_PQC_HANDSHAKE] = enabled }
    }

    suspend fun setAllowClassicFallbackForCompatibility(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_CLASSIC_FALLBACK] = enabled }
    }

    suspend fun setPqcMinimumTier(context: Context, tier: String) {
        val normalized = normalizePqcMinimumTier(tier)
        context.securitySettingsDataStore.edit { it[KEY_PQC_MINIMUM_TIER] = normalized }
    }

    suspend fun setRequireSecureEnclavePoP(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_REQUIRE_SECURE_ENCLAVE_POP] = enabled }
    }

    suspend fun setAllowScreenMirroring(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_SCREEN_MIRRORING] = enabled }
    }

    suspend fun setAllowFileTransfer(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_FILE_TRANSFER] = enabled }
    }

    suspend fun setAutoAcceptTrustedDevices(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_AUTO_ACCEPT_TRUSTED_DEVICES] = enabled }
    }

    suspend fun setConfirmOverwriteOnInbound(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_CONFIRM_OVERWRITE_ON_INBOUND] = enabled }
    }

    suspend fun setAllowRemoteControl(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_REMOTE_CONTROL] = enabled }
    }

    suspend fun setRemoteControlRequireConfirmation(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_REMOTE_CONTROL_REQUIRE_CONFIRMATION] = enabled }
    }

    suspend fun setAllowClipboardSync(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_CLIPBOARD_SYNC] = enabled }
    }

    suspend fun setCollectAnalytics(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_COLLECT_ANALYTICS] = enabled }
    }

    suspend fun setShareUsageData(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_SHARE_USAGE_DATA] = enabled }
    }

    suspend fun setShowDeviceName(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_SHOW_DEVICE_NAME] = enabled }
    }
}
