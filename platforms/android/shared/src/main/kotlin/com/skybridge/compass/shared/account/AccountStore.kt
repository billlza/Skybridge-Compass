package com.skybridge.compass.shared.account

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.URLEncoder
import java.net.URLDecoder

/**
 * 统一账号存储（基础骨架）
 * - 维护当前主账号（Primary Account）
 * - 后续将接入平台安全存储（EncryptedSharedPreferences/Keychain 等）
 */
object AccountStore {
    data class AccountProfile(
        val id: String,
        val displayName: String,
        val email: String? = null,
        val phone: String? = null,
        val avatarUrl: String? = null,
        val nebulaId: String? = null
    )

    private val _primaryAccount = MutableStateFlow<AccountProfile?>(null)
    val primaryAccount: StateFlow<AccountProfile?> = _primaryAccount.asStateFlow()

    /** 存储实现（由平台注入） */
    interface AccountStorage {
        fun save(encoded: String?)
        fun load(): String?
    }

    private var storage: AccountStorage? = null

    /** 平台注入存储并尝试加载已持久化的主账号 */
    fun attachStorage(storage: AccountStorage) {
        this.storage = storage
        storage.load()?.let { encoded ->
            decode(encoded)?.let { _primaryAccount.value = it }
        }
    }

    fun setPrimaryAccount(profile: AccountProfile) {
        _primaryAccount.value = profile
        storage?.save(encode(profile))
    }

    fun clearPrimaryAccount() {
        _primaryAccount.value = null
        storage?.save(null)
    }

    // 轻量编码/解码，避免引入依赖
    private fun encode(p: AccountProfile): String {
        fun e(v: String?) = URLEncoder.encode(v ?: "", Charsets.UTF_8)
        return listOf(p.id, e(p.displayName), e(p.email), e(p.phone), e(p.avatarUrl), e(p.nebulaId)).joinToString("|")
    }

    private fun decode(s: String): AccountProfile? {
        val parts = s.split("|")
        if (parts.isEmpty()) return null
        val id = parts.getOrNull(0) ?: return null
        fun d(i: Int) = parts.getOrNull(i)?.let { URLDecoder.decode(it, Charsets.UTF_8) } ?: ""
        return AccountProfile(
            id = id,
            displayName = d(1),
            email = d(2).ifEmpty { null },
            phone = d(3).ifEmpty { null },
            avatarUrl = d(4).ifEmpty { null },
            // 兼容旧版本（无 nebulaId 字段时返回空字符串）
            nebulaId = d(5).ifEmpty { null }
        )
    }
}