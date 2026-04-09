@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.account

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.skybridge.compass.shared.account.AccountStore

/**
 * Android 端账号持久化实现（EncryptedSharedPreferences）。
 * 使用 AES256-GCM 加密，密钥由 Android Keystore 保护。
 */
class AndroidAccountStorage(private val context: Context) : AccountStore.AccountStorage {

    @Suppress("DEPRECATION")
    private val prefs: SharedPreferences by lazy {
        try {
            // 创建或获取主密钥
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            // 创建加密的 SharedPreferences
            EncryptedSharedPreferences.create(
                context,
                ENCRYPTED_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            // 如果加密存储创建失败（极少数设备），回退到普通存储并记录警告
            Log.w(TAG, "Failed to create EncryptedSharedPreferences, falling back to regular SharedPreferences", e)
            context.getSharedPreferences(FALLBACK_PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    override fun save(encoded: String?) {
        val edit = prefs.edit()
        if (encoded == null) {
            edit.remove(KEY_PRIMARY_ACCOUNT)
        } else {
            edit.putString(KEY_PRIMARY_ACCOUNT, encoded)
        }
        edit.apply()
    }

    override fun load(): String? = prefs.getString(KEY_PRIMARY_ACCOUNT, null)

    companion object {
        private const val TAG = "AndroidAccountStorage"
        private const val ENCRYPTED_PREFS_NAME = "sb_account_store_encrypted"
        private const val FALLBACK_PREFS_NAME = "sb_account_store"
        private const val KEY_PRIMARY_ACCOUNT = "primary_account"
    }
}
