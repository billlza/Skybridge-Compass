package com.yunqiao.sinan.manager

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.yunqiao.sinan.data.auth.AccountTier
import com.yunqiao.sinan.data.auth.LoginMethod
import com.yunqiao.sinan.data.auth.RegistrationRequest
import com.yunqiao.sinan.data.auth.UserAccount
import android.os.Build
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class UserAccountManager(context: Context) {
    private val appContext = context.applicationContext
    private val preferences: SharedPreferences = createSecurePreferences(appContext)
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private val accountsSerializer = ListSerializer(UserAccount.serializer())
    private val keyAccounts = "accounts"
    private val keyLastNubulaId = "last_nubula_id"
    private val legacyKeyLastNebulaId = "last_nebula_id"
    private val legacyKeyLastStarId = "last_star_id"
    private val keyLastUser = "last_user_id"
    private var cachedAccounts: MutableList<UserAccount> = loadAccounts()
    private var lastNubulaId: Long = preferences.getLong(
        keyLastNubulaId,
        preferences.getLong(
            legacyKeyLastNebulaId,
            preferences.getLong(legacyKeyLastStarId, 99999L)
        )
    )
    private val _currentUser = MutableStateFlow(loadLastAuthenticatedUser())
    val currentUser: StateFlow<UserAccount?> = _currentUser

    suspend fun registerAccount(request: RegistrationRequest): UserAccount {
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                validateRegistration(request)
                val normalizedPhone = normalizePhone(request.phoneNumber)
                val normalizedEmail = normalizeEmail(request.email)
                val normalizedStarAccount = normalizeStarAccount(request.starAccount)
                val normalizedGoogleAccount = normalizeEmail(request.googleAccount)
                ensureUniqueAccount(normalizedPhone, normalizedEmail, normalizedStarAccount, normalizedGoogleAccount)
                val account = createAccount(normalizedPhone, normalizedEmail, normalizedStarAccount, normalizedGoogleAccount, request.password, request.tier)
                cachedAccounts.add(account)
                persistAccounts()
                _currentUser.value = account
                account
            }
        }
    }

    suspend fun authenticate(method: LoginMethod, identifier: String, secret: String): UserAccount {
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                val accounts = cachedAccounts
                val normalizedSecret = hashSecret(secret)
                val target = when (method) {
                    LoginMethod.PHONE -> accounts.firstOrNull { it.phoneNumber == normalizePhone(identifier) }
                    LoginMethod.EMAIL -> accounts.firstOrNull { it.email == normalizeEmail(identifier) }
                    LoginMethod.STAR_ACCOUNT -> accounts.firstOrNull { it.starAccount == normalizeStarAccount(identifier) || it.nubulaId.toString() == identifier.trim() }
                    LoginMethod.GOOGLE -> accounts.firstOrNull { it.googleAccount == normalizeEmail(identifier) }
                } ?: throw IllegalArgumentException("账号不存在")
                if (target.passwordHash != normalizedSecret) throw IllegalArgumentException("凭证错误")
                preferences.edit { putLong(keyLastUser, target.nubulaId) }
                _currentUser.value = target
                target
            }
        }
    }

    fun logout() {
        preferences.edit { remove(keyLastUser) }
        _currentUser.value = null
    }

    suspend fun updateAccountTier(nubulaId: Long, tier: AccountTier): UserAccount {
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                val index = cachedAccounts.indexOfFirst { it.nubulaId == nubulaId }
                if (index == -1) throw IllegalArgumentException("账号不存在")
                val updated = cachedAccounts[index].copy(tier = tier)
                cachedAccounts[index] = updated
                persistAccounts()
                if (_currentUser.value?.nubulaId == nubulaId) {
                    _currentUser.value = updated
                }
                updated
            }
        }
    }

    private fun validateRegistration(request: RegistrationRequest) {
        if (request.password.length < 8) throw IllegalArgumentException("密码长度不能少于8位")
        val hasContact = !request.phoneNumber.isNullOrBlank() || !request.email.isNullOrBlank()
        if (!hasContact) throw IllegalArgumentException("手机号或邮箱至少填写一项")
    }

    private fun ensureUniqueAccount(phone: String?, email: String?, starAccount: String?, googleAccount: String?) {
        if (phone != null && cachedAccounts.any { it.phoneNumber == phone }) throw IllegalStateException("手机号已注册")
        if (email != null && cachedAccounts.any { it.email == email }) throw IllegalStateException("邮箱已注册")
        if (starAccount != null && cachedAccounts.any { it.starAccount == starAccount }) throw IllegalStateException("星云账号已存在")
        if (googleAccount != null && cachedAccounts.any { it.googleAccount == googleAccount }) throw IllegalStateException("Google账号已绑定")
    }

    private fun createAccount(phone: String?, email: String?, starAccount: String?, googleAccount: String?, password: String, tier: AccountTier): UserAccount {
        lastNubulaId += 1
        val resolvedStarAccount = starAccount ?: "Nubula$lastNubulaId"
        val resolvedGoogleAccount = googleAccount ?: email
        val account = UserAccount(
            phoneNumber = phone,
            email = email,
            starAccount = resolvedStarAccount,
            googleAccount = resolvedGoogleAccount,
            passwordHash = hashSecret(password),
            nubulaId = lastNubulaId,
            tier = tier,
            createdAt = System.currentTimeMillis()
        )
        return account
    }

    private fun persistAccounts() {
        val snapshot = cachedAccounts.sortedBy { it.nubulaId }
        preferences.edit {
            putString(keyAccounts, json.encodeToString(accountsSerializer, snapshot))
            putLong(keyLastNubulaId, lastNubulaId)
            remove(legacyKeyLastNebulaId)
            remove(legacyKeyLastStarId)
            val current = _currentUser.value
            if (current != null) {
                putLong(keyLastUser, current.nubulaId)
            }
        }
        cachedAccounts = snapshot.toMutableList()
    }

    private fun loadAccounts(): MutableList<UserAccount> {
        val raw = preferences.getString(keyAccounts, null) ?: return mutableListOf()
        return runCatching { json.decodeFromString(accountsSerializer, raw).toMutableList() }.getOrDefault(mutableListOf())
    }

    private fun loadLastAuthenticatedUser(): UserAccount? {
        val nubulaId = preferences.getLong(keyLastUser, -1L)
        if (nubulaId <= 0) return null
        return cachedAccounts.firstOrNull { it.nubulaId == nubulaId }
    }

    private fun normalizePhone(phone: String?): String? {
        if (phone.isNullOrBlank()) return null
        val digits = phone.filter { it.isDigit() }
        return if (digits.isEmpty()) null else digits
    }

    private fun normalizeEmail(email: String?): String? {
        if (email.isNullOrBlank()) return null
        return email.trim().lowercase(Locale.ROOT)
    }

    private fun normalizeStarAccount(account: String?): String? {
        if (account.isNullOrBlank()) return null
        return account.trim()
    }

    private fun hashSecret(secret: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(secret.toByteArray())
        return bytes.joinToString("") { String.format(Locale.ROOT, "%02x", it) }
    }

    private fun createSecurePreferences(context: Context): SharedPreferences {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return runCatching {
                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    context,
                    "nebula_user_accounts",
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            }.getOrElse {
                context.getSharedPreferences("nebula_user_accounts", Context.MODE_PRIVATE)
            }
        }
        return context.getSharedPreferences("nebula_user_accounts", Context.MODE_PRIVATE)
    }
}
