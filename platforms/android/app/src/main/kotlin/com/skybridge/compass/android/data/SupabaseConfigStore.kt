@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.edit
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.supabase.SupabaseConfigInvalidException
import com.skybridge.compass.supabase.SupabaseConfigLockedException
import com.skybridge.compass.supabase.SupabaseConfigMissingException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URI
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SupabaseConfig(
    val url: String,
    val anonKey: String
)

internal fun canonicalSupabaseProjectOrigin(raw: String): String {
    val candidate = raw.trim()
    require(candidate.isNotEmpty()) { "Supabase project origin is empty" }
    val parsed = URI(candidate)
    require(!parsed.isOpaque) { "Supabase project origin must be hierarchical" }
    require(parsed.scheme?.lowercase(Locale.ROOT) == "https") {
        "Supabase project origin must use HTTPS"
    }
    require(parsed.rawUserInfo == null) { "Supabase project origin must not contain user info" }
    require(parsed.rawQuery == null) { "Supabase project origin must not contain a query" }
    require(parsed.rawFragment == null) { "Supabase project origin must not contain a fragment" }
    require(parsed.rawPath.isNullOrEmpty() || parsed.rawPath == "/") {
        "Supabase project origin must not contain a path"
    }
    val host = requireNotNull(parsed.host?.takeIf { it.isNotBlank() }) {
        "Supabase project origin host is missing"
    }
    require(parsed.port == -1 || parsed.port in 1..65535) {
        "Supabase project origin port is invalid"
    }
    val canonicalPort = parsed.port.takeUnless { it == 443 } ?: -1
    return URI(
        "https",
        null,
        host.lowercase(Locale.ROOT),
        canonicalPort,
        null,
        null,
        null
    ).toASCIIString()
}

sealed class SupabaseConfigState {
    data object Missing : SupabaseConfigState()
    data object Locked : SupabaseConfigState()
    data class Available(val config: SupabaseConfig) : SupabaseConfigState()
}

object SupabaseConfigStore {
    private const val TAG = "SupabaseConfigStore"
    private const val PREFS_NAME = "sb_supabase_secure"
    private const val KEY_CIPHERTEXT = "supabase_ciphertext"
    private const val KEY_IV = "supabase_iv"
    private const val KEY_LAST_UNLOCKED = "supabase_last_unlocked_at"
    private const val KEY_ALIAS = "SkyBridge.Supabase.Config"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_LENGTH = 128

    @Volatile
    private var cachedConfig: SupabaseConfig? = null

    fun observeState(context: Context): Flow<SupabaseConfigState> = callbackFlow {
        val prefs = prefs(context)
        val emitState = {
            trySend(currentState(context, prefs)).isSuccess
        }
        emitState()
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
            emitState()
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }.distinctUntilChanged()

    fun requireConfig(context: Context): SupabaseConfig {
        cachedConfig?.let { return it }
        if (hasEncryptedConfig(prefs(context))) {
            throw SupabaseConfigLockedException()
        }
        managedDefaults()?.let {
            cachedConfig = it
            return it
        }
        throw SupabaseConfigMissingException()
    }

    fun managedDefaults(): SupabaseConfig? {
        val url = BuildConfig.SUPABASE_URL.trim().removeSuffix("/")
        val anonKey = BuildConfig.SUPABASE_ANON_KEY.trim()
        if (url.isBlank() || anonKey.isBlank()) return null
        return runCatching { normalizeConfig(SupabaseConfig(url = url, anonKey = anonKey)) }
            .onFailure { Log.e(TAG, "Built-in Supabase config is invalid", it) }
            .getOrNull()
    }

    fun provisionManagedDefaults(
        activity: FragmentActivity,
        onResult: (Result<Unit>) -> Unit
    ) {
        val defaults = managedDefaults()
        if (defaults == null) {
            onResult(
                Result.failure(
                    SupabaseConfigInvalidException(
                        resolveLocalizedText(
                            "未配置内置 Supabase 参数",
                            "Built-in Supabase parameters are not configured",
                            "組み込み Supabase パラメータが設定されていません"
                        )
                    )
                )
            )
            return
        }
        saveWithBiometrics(activity, defaults, onResult)
    }

    fun saveWithBiometrics(
        activity: FragmentActivity,
        config: SupabaseConfig,
        onResult: (Result<Unit>) -> Unit
    ) {
        val normalized = runCatching { normalizeConfig(config) }.getOrElse { error ->
            onResult(Result.failure(error))
            return
        }
        val authCheck = canAuthenticate(activity)
        if (authCheck != BiometricManager.BIOMETRIC_SUCCESS) {
            onResult(Result.failure(SupabaseConfigInvalidException(biometricErrorMessage(authCheck))))
            return
        }
        val promptInfo = buildPromptInfo(
            title = resolveLocalizedText("保存 Supabase 配置", "Save Supabase Configuration", "Supabase 設定を保存"),
            subtitle = resolveLocalizedText(
                "使用生物识别或设备凭证进行加密保存",
                "Encrypt and save with biometrics or device credentials",
                "生体認証または端末認証情報で暗号化して保存"
            )
        )

        // IMPORTANT: Keystore key creation + Cipher init can be slow; never do it on the main thread.
        activity.lifecycleScope.launch {
            val cipher = runCatching {
                withContext(Dispatchers.IO) { cipherForEncryption() }
            }.getOrElse { err ->
                onResult(Result.failure(err))
                return@launch
            }

            val executor = ContextCompat.getMainExecutor(activity)
            val prompt = BiometricPrompt(activity, executor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    val crypto = result.cryptoObject?.cipher
                    if (crypto == null) {
                        onResult(
                            Result.failure(
                                SupabaseConfigInvalidException(
                                    resolveLocalizedText("加密器初始化失败", "Failed to initialize encryptor", "暗号化器の初期化に失敗しました")
                                )
                            )
                        )
                        return
                    }
                    activity.lifecycleScope.launch {
                        val (encrypted, iv) = runCatching {
                            withContext(Dispatchers.IO) {
                                val payload = encodeConfig(normalized)
                                val encryptedBytes = crypto.doFinal(payload)
                                encryptedBytes to crypto.iv
                            }
                        }.getOrElse { e ->
                            Log.e(TAG, "Supabase config encrypt failed", e)
                            onResult(Result.failure(e))
                            return@launch
                        }

                        runCatching {
                            withContext(Dispatchers.IO) {
                                val prefs = prefs(activity)
                                val ciphertext = Base64.encodeToString(encrypted, Base64.NO_WRAP)
                                val encodedIv = Base64.encodeToString(iv, Base64.NO_WRAP)
                                prefs.edit(commit = true) {
                                    putString(KEY_CIPHERTEXT, ciphertext)
                                    putString(KEY_IV, encodedIv)
                                    putLong(KEY_LAST_UNLOCKED, System.currentTimeMillis())
                                }
                                check(prefs.getString(KEY_CIPHERTEXT, null) == ciphertext) {
                                    "Failed to persist Supabase encrypted config ciphertext"
                                }
                                check(prefs.getString(KEY_IV, null) == encodedIv) {
                                    "Failed to persist Supabase encrypted config IV"
                                }
                            }
                        }.onFailure { e ->
                            Log.e(TAG, "Supabase prefs write failed", e)
                            onResult(Result.failure(e))
                            return@launch
                        }

                        cachedConfig = normalized
                        onResult(Result.success(Unit))
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onResult(Result.failure(SupabaseConfigInvalidException(errString.toString())))
                }
            })

            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        }
    }

    fun unlockWithBiometrics(
        activity: FragmentActivity,
        onResult: (Result<SupabaseConfig>) -> Unit
    ) {
        val prefs = prefs(activity)
        if (!hasEncryptedConfig(prefs)) {
            onResult(Result.failure(SupabaseConfigMissingException()))
            return
        }
        val authCheck = canAuthenticate(activity)
        if (authCheck != BiometricManager.BIOMETRIC_SUCCESS) {
            onResult(Result.failure(SupabaseConfigInvalidException(biometricErrorMessage(authCheck))))
            return
        }

        val cipherText = prefs.getString(KEY_CIPHERTEXT, null)
        val ivText = prefs.getString(KEY_IV, null)
        if (cipherText.isNullOrBlank() || ivText.isNullOrBlank()) {
            onResult(Result.failure(SupabaseConfigMissingException()))
            return
        }
        val encrypted = Base64.decode(cipherText, Base64.NO_WRAP)
        val iv = Base64.decode(ivText, Base64.NO_WRAP)
        val promptInfo = buildPromptInfo(
            title = resolveLocalizedText("解锁 Supabase 配置", "Unlock Supabase Configuration", "Supabase 設定を解除"),
            subtitle = resolveLocalizedText(
                "使用生物识别或设备凭证解锁",
                "Unlock with biometrics or device credentials",
                "生体認証または端末認証情報でロック解除"
            )
        )
        // IMPORTANT: Keystore Cipher init can be slow; do it off the main thread.
        activity.lifecycleScope.launch {
            val cipher = runCatching {
                withContext(Dispatchers.IO) { cipherForDecryption(iv) }
            }.getOrElse { err ->
                onResult(Result.failure(err))
                return@launch
            }

            val executor = ContextCompat.getMainExecutor(activity)
            val prompt = BiometricPrompt(activity, executor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    val crypto = result.cryptoObject?.cipher
                    if (crypto == null) {
                        onResult(
                            Result.failure(
                                SupabaseConfigInvalidException(
                                    resolveLocalizedText("解密器初始化失败", "Failed to initialize decryptor", "復号器の初期化に失敗しました")
                                )
                            )
                        )
                        return
                    }
                    activity.lifecycleScope.launch {
                        val config = runCatching {
                            withContext(Dispatchers.IO) {
                                val decrypted = crypto.doFinal(encrypted)
                                decodeConfig(decrypted)
                            }
                        }.getOrElse { e ->
                            Log.e(TAG, "Supabase config decrypt failed", e)
                            onResult(
                                Result.failure(
                                    SupabaseConfigInvalidException(
                                        resolveLocalizedText(
                                            "解密失败，请重新保存配置",
                                            "Decryption failed. Please save the configuration again.",
                                            "復号に失敗しました。設定を再保存してください。"
                                        )
                                    )
                                )
                            )
                            return@launch
                        }

                        cachedConfig = config
                        runCatching {
                            withContext(Dispatchers.IO) {
                                prefs.edit(commit = true) {
                                    putLong(KEY_LAST_UNLOCKED, System.currentTimeMillis())
                                }
                            }
                        }
                        onResult(Result.success(config))
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onResult(Result.failure(SupabaseConfigInvalidException(errString.toString())))
                }
            })

            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        }
    }

    suspend fun reset(context: Context) {
        cachedConfig = null
        withContext(Dispatchers.IO) {
            prefs(context).edit(commit = true) {
                remove(KEY_CIPHERTEXT)
                remove(KEY_IV)
                remove(KEY_LAST_UNLOCKED)
            }
        }
    }

    private fun currentState(context: Context, prefs: SharedPreferences): SupabaseConfigState {
        cachedConfig?.let { return SupabaseConfigState.Available(it) }
        if (hasEncryptedConfig(prefs)) return SupabaseConfigState.Locked
        managedDefaults()?.let {
            cachedConfig = it
            return SupabaseConfigState.Available(it)
        }
        return SupabaseConfigState.Missing
    }

    private fun hasEncryptedConfig(prefs: SharedPreferences): Boolean {
        return prefs.contains(KEY_CIPHERTEXT) && prefs.contains(KEY_IV)
    }

    private fun prefs(context: Context): SharedPreferences {
        return context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun normalizeConfig(config: SupabaseConfig): SupabaseConfig {
        val rawUrl = config.url.trim()
        val anonKey = config.anonKey.trim()
        if (rawUrl.isBlank() || anonKey.isBlank()) {
            throw SupabaseConfigInvalidException(
                resolveLocalizedText(
                    "URL 或 Anon Key 为空",
                    "URL or anon key is empty",
                    "URL または Anon Key が空です"
                )
            )
        }
        val url = runCatching { canonicalSupabaseProjectOrigin(rawUrl) }.getOrElse {
            throw SupabaseConfigInvalidException(
                resolveLocalizedText(
                    "Supabase URL 无效",
                    "Supabase URL is invalid",
                    "Supabase URL が無効です"
                )
            )
        }
        return SupabaseConfig(url = url, anonKey = anonKey)
    }

    private fun encodeConfig(config: SupabaseConfig): ByteArray {
        val json = JSONObject()
            .put("url", config.url)
            .put("anonKey", config.anonKey)
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    private fun decodeConfig(bytes: ByteArray): SupabaseConfig {
        val json = JSONObject(String(bytes, Charsets.UTF_8))
        val url = json.optString("url").trim().removeSuffix("/")
        val anonKey = json.optString("anonKey").trim()
        return normalizeConfig(SupabaseConfig(url = url, anonKey = anonKey))
    }

    private fun canAuthenticate(context: Context): Int {
        return BiometricManager.from(context).canAuthenticate(authenticators())
    }

    private fun authenticators(): Int =
        BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL

    private fun buildPromptInfo(title: String, subtitle: String): BiometricPrompt.PromptInfo {
        return BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(authenticators())
            .build()
    }

    private fun biometricErrorMessage(code: Int): String {
        return when (code) {
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> resolveLocalizedText(
                "设备不支持生物识别",
                "This device does not support biometrics",
                "この端末は生体認証に対応していません"
            )
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> resolveLocalizedText(
                "生物识别硬件不可用",
                "Biometric hardware is unavailable",
                "生体認証ハードウェアは利用できません"
            )
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> resolveLocalizedText(
                "未启用锁屏(PIN/图案/密码)或未录入生物识别",
                "Screen lock or biometrics are not set up",
                "画面ロックまたは生体認証が設定されていません"
            )
            else -> resolveLocalizedText(
                "生物识别不可用 (code=$code)",
                "Biometrics unavailable (code=$code)",
                "生体認証は利用できません (code=$code)"
            )
        }
    }

    private fun cipherForEncryption(): Cipher {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        return cipher
    }

    private fun cipherForDecryption(iv: ByteArray): Cipher {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val spec = GCMParameterSpec(GCM_TAG_LENGTH, iv)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), spec)
        return cipher
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(
                0,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
            )
            .setInvalidatedByBiometricEnrollment(true)
            .build()

        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }
}
