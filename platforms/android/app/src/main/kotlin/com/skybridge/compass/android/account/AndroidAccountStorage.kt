@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.account

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
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
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            context.deleteSharedPreferences(LEGACY_PLAINTEXT_PREFS_NAME)
            return@lazy EncryptedSharedPreferences.create(
                context,
                ENCRYPTED_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            throw IllegalStateException("Encrypted account storage is unavailable", e)
        }
    }

    override fun save(encoded: String?) {
        if (encoded == null) {
            prefs.edit(commit = true) {
                remove(KEY_PRIMARY_ACCOUNT)
            }
            check(!prefs.contains(KEY_PRIMARY_ACCOUNT)) { "Failed to clear encrypted account profile" }
        } else {
            prefs.edit(commit = true) {
                putString(KEY_PRIMARY_ACCOUNT, encoded)
            }
            check(prefs.getString(KEY_PRIMARY_ACCOUNT, null) == encoded) {
                "Failed to persist encrypted account profile"
            }
        }
    }

    override fun load(): String? = prefs.getString(KEY_PRIMARY_ACCOUNT, null)

    companion object {
        private const val ENCRYPTED_PREFS_NAME = "sb_account_store_encrypted"
        private const val LEGACY_PLAINTEXT_PREFS_NAME = "sb_account_store"
        private const val KEY_PRIMARY_ACCOUNT = "primary_account"
    }
}
