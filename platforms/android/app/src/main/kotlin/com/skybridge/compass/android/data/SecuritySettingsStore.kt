package com.skybridge.compass.android.data

import android.content.Context
import android.os.Build
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.skybridge.compass.core.p2p.resolveRequestedHandshakeMinimumTierRaw
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException

private val Context.securitySettingsDataStore by preferencesDataStore(name = "security_settings")

private fun defaultEnforcePqcHandshake(): Boolean = Build.VERSION.SDK_INT >= 33

private fun defaultAllowClassicFallbackForCompatibility(): Boolean =
    Build.VERSION.SDK_INT in 33..35

private fun defaultPqcMinimumTier(): String = when {
    Build.VERSION.SDK_INT >= 36 ->
        resolveRequestedHandshakeMinimumTierRaw(
            requestedMinimumTierRaw = "nativePQC",
            requirePqc = true
        )
    Build.VERSION.SDK_INT >= 33 ->
        resolveRequestedHandshakeMinimumTierRaw(
            requestedMinimumTierRaw = "liboqsPQC",
            requirePqc = true
        )
    else -> "classic"
}

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
                if (e is IOException) emit(emptyPreferences()) else throw e
            }
            .map { prefs ->
                SecuritySettings(
                    requirePairing = prefs[KEY_REQUIRE_PAIRING] ?: true,
                    autoTrustKnownDevices = prefs[KEY_AUTO_TRUST] ?: false,
                    pairingTimeoutSec = (prefs[KEY_PAIRING_TIMEOUT_SEC] ?: 30).coerceIn(5, 600),

                    encryptionEnabled = prefs[KEY_ENCRYPTION_ENABLED] ?: true,
                    encryptionAlgorithm = prefs[KEY_ENCRYPTION_ALGORITHM] ?: "AES-256-GCM",
                    pqcEnabled = prefs[KEY_PQC_ENABLED] ?: true,
                    enforcePqcHandshake = prefs[KEY_ENFORCE_PQC_HANDSHAKE] ?: defaultEnforcePqcHandshake(),
                    allowClassicFallbackForCompatibility = prefs[KEY_ALLOW_CLASSIC_FALLBACK] ?: defaultAllowClassicFallbackForCompatibility(),
                    pqcMinimumTier = prefs[KEY_PQC_MINIMUM_TIER] ?: defaultPqcMinimumTier(),
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
        context.securitySettingsDataStore.edit { it[KEY_ENCRYPTION_ENABLED] = enabled }
    }

    suspend fun setEncryptionAlgorithm(context: Context, algorithm: String) {
        context.securitySettingsDataStore.edit { it[KEY_ENCRYPTION_ALGORITHM] = algorithm }
    }

    suspend fun setPqcEnabled(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_PQC_ENABLED] = enabled }
    }

    suspend fun setEnforcePqcHandshake(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ENFORCE_PQC_HANDSHAKE] = enabled }
    }

    suspend fun setAllowClassicFallbackForCompatibility(context: Context, enabled: Boolean) {
        context.securitySettingsDataStore.edit { it[KEY_ALLOW_CLASSIC_FALLBACK] = enabled }
    }

    suspend fun setPqcMinimumTier(context: Context, tier: String) {
        val normalized = when (tier) {
            "nativePQC", "liboqsPQC", "classic" -> tier
            else -> defaultPqcMinimumTier()
        }
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
