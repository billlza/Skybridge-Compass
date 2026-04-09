package com.skybridge.compass.auth

import android.content.Context
import android.util.Log
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.android.data.SupabaseSessionStore
import com.skybridge.compass.supabase.SupabaseClientFactory
import com.skybridge.compass.supabase.SupabaseConfigException
import com.skybridge.compass.supabase.SupabaseConfigValidationResult
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.shared.account.NebulaIDGenerator
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.request
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.isSuccess
import io.ktor.http.contentType
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.qualifiers.ApplicationContext

enum class SignUpOutcome {
    Authenticated,
    EmailVerificationRequired
}

/**
 * 认证仓库
 * - 封装 Supabase 登录/注册/短信验证码/OIDC(Nebula) 登录
 * - 提供当前用户资料读取，并尝试从 identities 中补齐 Nebula ID 与头像
 */
@Singleton
class AuthRepository @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val clientFactory: SupabaseClientFactory,
    private val httpClient: HttpClient,
    private val json: Json
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val sessionStatusFlow = MutableStateFlow<SessionStatus>(SessionStatus.NotAuthenticated())
    val sessionStatus: StateFlow<SessionStatus> = sessionStatusFlow.asStateFlow()

    private var supabaseClient: io.github.jan.supabase.SupabaseClient? = null
    private var sessionJob: Job? = null
    private var currentConfig: SupabaseConfig? = null
    private val sessionStore = SupabaseSessionStore(context)

    init {
        scope.launch {
            AppSettingsStore.observeRememberLogin(context).collect { enabled ->
                syncSessionPersistence(enabled)
            }
        }
    }

    private fun requireSupabase(): io.github.jan.supabase.SupabaseClient {
        val config = SupabaseConfigStore.requireConfig(context)
        val existing = supabaseClient
        if (existing != null && currentConfig == config) {
            return existing
        }
        val created = clientFactory.create(config)
        supabaseClient = created
        currentConfig = config
        sessionJob?.cancel()
        sessionJob = scope.launch {
            created.auth.sessionStatus.collect { status ->
                sessionStatusFlow.value = status
                when (status) {
                    is SessionStatus.Authenticated -> syncSessionPersistence()
                    is SessionStatus.NotAuthenticated -> sessionStore.clear()
                    else -> Unit
                }
            }
        }
        return created
    }

    private fun supabaseOrNull(): io.github.jan.supabase.SupabaseClient? {
        return try {
            requireSupabase()
        } catch (_: SupabaseConfigException) {
            sessionStatusFlow.value = SessionStatus.NotAuthenticated()
            null
        }
    }

    fun currentAccessTokenOrNull(): String? {
        return runCatching { supabaseOrNull()?.auth?.currentSessionOrNull()?.accessToken }.getOrNull()
    }

    fun currentUserIdOrNull(): String? {
        return runCatching { supabaseOrNull()?.auth?.currentUserOrNull()?.id }.getOrNull()
    }

    private fun config(): SupabaseConfig = SupabaseConfigStore.requireConfig(context)

    /**
     * 从本地存储恢复会话（如已启用自动加载，此方法安全幂等）。
     * 为兼容不同库版本，这里做轻量探测而不依赖特定 API。
     */
    suspend fun loadSessionFromStorage(forceRefresh: Boolean = false) {
        try {
            if (!AppSettingsStore.observeRememberLogin(context).first()) {
                sessionStore.clear()
                return
            }
            val supabase = supabaseOrNull() ?: return
            restoreSessionIntoClientIfPossible(supabase)
            if (supabase.auth.currentSessionOrNull() != null) {
                if (forceRefresh) {
                    // 触发一次 /auth/v1/user 调用以确保令牌与状态更新；异常忽略。
                    runCatching { fetchUserInfoFromSupabase() }.getOrNull()
                }
                // 会话恢复后尽量补齐 Nebula/头像（避免必须重新登录才能看到 macOS 上传的头像）。
                runCatching { syncNebulaIdFromIdentitiesIfMissing() }.getOrNull()
            }
        } catch (_: Throwable) {
            // 忽略恢复异常，保持幂等
        }
    }

    private suspend fun syncSessionPersistence(rememberLoginEnabled: Boolean? = null) {
        val shouldRemember = rememberLoginEnabled ?: AppSettingsStore.observeRememberLogin(context).first()
        if (!shouldRemember) {
            sessionStore.clear()
            return
        }

        val session = runCatching {
            supabaseClient?.auth?.currentSessionOrNull() ?: supabaseOrNull()?.auth?.currentSessionOrNull()
        }.getOrNull()

        if (session != null) {
            sessionStore.save(session)
        }
    }

    suspend fun login(email: String, password: String) {
        val config = config()
        val supabase = requireSupabase()
        val url = "${config.url}/auth/v1/token?grant_type=password"
        val payload = buildJsonObject {
            put("email", JsonPrimitive(email.trim()))
            put("password", JsonPrimitive(password))
        }

        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers {
                append(HttpHeaders.Authorization, "Bearer ${config.anonKey}")
                append("apikey", config.anonKey)
            }
        }
        if (!resp.status.isSuccess()) throw RuntimeException(supabaseErrorMessage(resp, "邮箱登录失败"))

        val session = parseSessionFromAuthResponse(resp, "邮箱登录")
        supabase.auth.importSession(session)
        sessionStore.save(session)

        // 登录后资料补齐改为后台异步，避免阻塞登录主流程（iOS/mac 语义：先进入，再补齐资料）。
        scope.launch {
            runCatching { syncNebulaIdFromIdentitiesIfMissing() }
        }
    }

    suspend fun signUp(email: String, password: String): SignUpOutcome {
        val config = config()
        val supabase = requireSupabase()
        // 生成星云ID，与 Mac 版本保持一致
        val nebulaIdInfo = try {
            NebulaIDGenerator.shared.generateUserRegistrationID()
        } catch (e: Exception) {
            Log.e("AuthRepository", "Failed to generate NebulaID", e)
            null
        }

        val url = "${config.url}/auth/v1/signup"
        val safeDisplayName = email.trim().substringBefore('@').ifBlank { "User" }
        val payload = buildJsonObject {
            put("email", JsonPrimitive(email.trim()))
            put("password", JsonPrimitive(password))
            put("data", buildJsonObject {
                put("display_name", JsonPrimitive(safeDisplayName))
                put("registration_source", JsonPrimitive("SkyBridge Compass Android"))
                nebulaIdInfo?.let {
                    put("nebula_id", JsonPrimitive(it.fullId))
                    put("nebula_id_raw", JsonPrimitive(it.rawId.toString()))
                    put("nebula_id_generated_at", JsonPrimitive(it.generatedAt))
                }
            })
        }

        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers {
                append(HttpHeaders.Authorization, "Bearer ${config.anonKey}")
                append("apikey", config.anonKey)
            }
        }
        if (!resp.status.isSuccess()) throw RuntimeException(supabaseErrorMessage(resp, "注册失败"))

        val bodyText: String = runCatching { resp.body<String>() }.getOrDefault("")
        val obj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
        val accessToken = obj?.get("access_token")?.jsonPrimitive?.contentOrNull

        // 邮箱验证开启时，Supabase 仅返回 user，不返回 session
        if (accessToken.isNullOrBlank()) {
            Log.i("AuthRepository", "Sign up created account; waiting for email verification.")
            return SignUpOutcome.EmailVerificationRequired
        }

        val session = parseSessionFromJsonObject(obj, "注册")
        supabase.auth.importSession(session)
        sessionStore.save(session)

        // Best-effort: mirror macOS by also saving nebula_id into `rest/v1/users` when a session exists.
        val userId = supabase.auth.currentUserOrNull()?.id
        if (userId != null && nebulaIdInfo != null) {
            runCatching { saveNebulaIdToUsersTable(userId, nebulaIdInfo.fullId, session.accessToken) }
        }

        Log.i("AuthRepository", "User registered with NebulaID: ${nebulaIdInfo?.fullId}")
        return SignUpOutcome.Authenticated
    }

    /** 发送手机短信验证码（直接调用 GoTrue 端点） */
    suspend fun sendPhoneOtp(phone: String, createUser: Boolean = false) {
        val config = config()
        val url = "${config.url}/auth/v1/otp"

        // 如果是创建新用户，预生成 NebulaID
        val nebulaIdInfo = if (createUser) {
            try {
                NebulaIDGenerator.shared.generateUserRegistrationID()
            } catch (e: Exception) {
                Log.e("AuthRepository", "Failed to generate NebulaID for phone signup", e)
                null
            }
        } else null

        val payload = buildJsonObject {
            put("phone", JsonPrimitive(phone))
            put("type", JsonPrimitive("sms"))
            put("create_user", JsonPrimitive(createUser))
            // 在创建用户时包含 NebulaID
            if (createUser && nebulaIdInfo != null) {
                put("data", buildJsonObject {
                    put("registration_source", JsonPrimitive("SkyBridge Compass Android"))
                    put("nebula_id", JsonPrimitive(nebulaIdInfo.fullId))
                    put("nebula_id_raw", JsonPrimitive(nebulaIdInfo.rawId.toString()))
                    put("nebula_id_generated_at", JsonPrimitive(nebulaIdInfo.generatedAt))
                })
            }
        }
        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers { append(HttpHeaders.Authorization, "Bearer ${config.anonKey}") }
        }
        if (!resp.status.isSuccess()) throw RuntimeException("发送短信验证码失败: ${resp.status}")

        if (createUser && nebulaIdInfo != null) {
            Log.i("AuthRepository", "Phone OTP sent for new user with NebulaID: ${nebulaIdInfo.fullId}")
        }
    }

    /** 验证手机短信验证码并建立会话（GoTrue 端点） */
    suspend fun verifyPhoneOtpSms(phone: String, code: String) {
        val config = config()
        val url = "${config.url}/auth/v1/verify"
        val payload = buildJsonObject {
            put("phone", JsonPrimitive(phone))
            put("token", JsonPrimitive(code))
            put("type", JsonPrimitive("sms"))
        }
        val supabase = requireSupabase()
        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers { append(HttpHeaders.Authorization, "Bearer ${config.anonKey}") }
        }
        if (!resp.status.isSuccess()) throw RuntimeException("短信验证码验证失败: ${resp.status}")

        val bodyText: String = resp.body()
        val obj = json.parseToJsonElement(bodyText).jsonObject
        val accessToken = obj["access_token"]?.jsonPrimitive?.content
        val refreshToken = obj["refresh_token"]?.jsonPrimitive?.content
        val expiresIn = obj["expires_in"]?.jsonPrimitive?.content?.toLongOrNull() ?: 3600L
        val tokenType = obj["token_type"]?.jsonPrimitive?.content ?: "bearer"
        if (accessToken.isNullOrBlank()) throw RuntimeException("验证成功但未返回 access_token")

        // 建立 Supabase 会话，保证全局状态与 UI 联动
        val session = UserSession(
            accessToken = accessToken,
            refreshToken = refreshToken ?: "",
            expiresIn = expiresIn,
            tokenType = tokenType,
            user = null
        )
        supabase.auth.importSession(session)
        sessionStore.save(session)

        // 后台补齐资料，不阻塞 OTP 登录态建立。
        scope.launch {
            runCatching { syncNebulaIdFromIdentitiesIfMissing() }
        }
    }

    /** OIDC: 使用外部 Nebula 提供的 ID Token 登录（GoTrue 端点） */
    suspend fun loginWithNebulaIdToken(idToken: String, providerName: String = "nebula", nonce: String? = null) {
        val providerDisplayName = providerName.replaceFirstChar { it.uppercase() }
        val config = config()
        val url = "${config.url}/auth/v1/token?grant_type=id_token"
        val payload = buildJsonObject {
            put("provider", JsonPrimitive(providerName))
            put("id_token", JsonPrimitive(idToken))
            nonce?.let { put("nonce", JsonPrimitive(it)) }
        }
        val supabase = requireSupabase()
        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers {
                append(HttpHeaders.Authorization, "Bearer ${config.anonKey}")
                append("apikey", config.anonKey)
            }
        }
        if (!resp.status.isSuccess()) throw RuntimeException(supabaseErrorMessage(resp, "$providerDisplayName 登录失败"))

        val session = parseSessionFromAuthResponse(resp, "$providerDisplayName 登录")
        supabase.auth.importSession(session)
        sessionStore.save(session)

        // 第三方登录后资料补齐后台执行，避免前台等待超时。
        scope.launch {
            runCatching { syncNebulaIdFromIdentitiesIfMissing() }
        }
    }

    suspend fun loginWithGoogleIdToken(idToken: String, nonce: String? = null) {
        loginWithNebulaIdToken(
            idToken = idToken,
            providerName = "google",
            nonce = nonce
        )
    }

    suspend fun logout() {
        val supabase = supabaseOrNull() ?: return
        try { supabase.auth.signOut() } catch (_: Throwable) {}
        sessionStore.clear()
    }

    private suspend fun restoreSessionIntoClientIfPossible(client: io.github.jan.supabase.SupabaseClient) {
        // If already authenticated, don't overwrite.
        if (client.auth.currentSessionOrNull() != null) return
        val stored = sessionStore.load() ?: return
        runCatching { client.auth.importSession(stored) }.onFailure {
            // If stored session is invalid/corrupted, clear it.
            sessionStore.clear()
        }
    }

    suspend fun resetPassword(email: String) {
        val config = config()
        val url = "${config.url}/auth/v1/recover"
        val payload = buildJsonObject {
            put("email", JsonPrimitive(email.trim()))
        }
        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers {
                append(HttpHeaders.Authorization, "Bearer ${config.anonKey}")
                append("apikey", config.anonKey)
            }
        }
        if (!resp.status.isSuccess()) throw RuntimeException(supabaseErrorMessage(resp, "重置密码邮件发送失败"))
    }

    /**
     * 校验当前 Supabase 配置有效性（请求 auth/v1/settings）
     */
    suspend fun validateSupabaseConfiguration(): SupabaseConfigValidationResult {
        val config = config()
        val url = "${config.url}/auth/v1/settings"
        return try {
            val resp = httpClient.get(url) {
                headers {
                    append(HttpHeaders.Authorization, "Bearer ${config.anonKey}")
                    append("apikey", config.anonKey)
                }
            }
            val code = resp.status.value
            val ok = (code in 200..399) || code == 401 || code == 404
            SupabaseConfigValidationResult(
                isValid = ok,
                message = if (ok) {
                    "Supabase 配置有效"
                } else {
                    "Supabase 健康检查失败: HTTP $code"
                }
            )
        } catch (e: Exception) {
            SupabaseConfigValidationResult(
                isValid = false,
                message = "网络请求失败: ${e.message ?: "未知错误"}"
            )
        }
    }

    /**
     * 获取当前用户的展示资料：昵称/邮箱/手机号/头像/Nebula ID。
     * - 优先从当前会话的 JWT payload 和 userMetadata 中取值
     * - 若缺失 Nebula/头像，则调用 /auth/v1/user 补齐 identities
     */
    suspend fun getCurrentUserProfile(): AccountStore.AccountProfile? {
        val supabase = supabaseOrNull() ?: return null
        val user: UserInfo = supabase.auth.currentUserOrNull() ?: return null
        val session = supabase.auth.currentSessionOrNull()

        var displayName: String? = null
        var avatarUrl: String? = null
        var nebulaId: String? = null

        // 从 JWT 提取常用字段
        val jwt = session?.accessToken
        if (!jwt.isNullOrBlank()) {
            runCatching { decodeJwtPayload(jwt) }.getOrNull()?.let { payload ->
                displayName = payload.stringOrNull("full_name")
                    ?: payload.stringOrNull("name")
                    ?: payload.stringOrNull("preferred_username")
                    ?: displayName
                avatarUrl = payload.stringOrNull("avatar_url")
                    ?: payload.stringOrNull("picture")
                    ?: avatarUrl
                // 注意：JWT 的 sub 为 Supabase 用户 ID，不当作 Nebula ID；仅保留 nebula_id/nebulaId
                nebulaId = payload.stringOrNull("nebula_id")
                    ?: payload.stringOrNull("nebulaId")
                    ?: nebulaId
            }
        }

        // 从 user metadata 兜底
        runCatching {
            val meta = user.userMetadata
            val metaObj = when (meta) {
                is JsonObject -> meta
                is JsonElement -> meta.jsonObject
                else -> null
            }
            if (metaObj != null) {
                displayName = metaObj.stringOrNull("display_name")
                    ?: metaObj.stringOrNull("full_name")
                    ?: metaObj.stringOrNull("name")
                    ?: displayName
                avatarUrl = metaObj.stringOrNull("avatar_url")
                    ?: metaObj.stringOrNull("avatar")
                    ?: metaObj.stringOrNull("picture")
                    ?: avatarUrl
                nebulaId = metaObj.stringOrNull("nebula_id")
                    ?: metaObj.stringOrNull("nebulaId")
                    ?: nebulaId
            }
        }.getOrNull()

        // identities 补齐 Nebula/头像（兼容 OIDC 常见字段）
        if (nebulaId.isNullOrBlank() || avatarUrl.isNullOrBlank()) {
            runCatching {
                val info = fetchUserInfoFromSupabase()
                val apiMeta = info["user_metadata"] as? JsonObject
                if (apiMeta != null) {
                    displayName = apiMeta.stringOrNull("display_name")
                        ?: apiMeta.stringOrNull("full_name")
                        ?: apiMeta.stringOrNull("name")
                        ?: displayName
                    avatarUrl = apiMeta.stringOrNull("avatar_url")
                        ?: apiMeta.stringOrNull("avatar")
                        ?: apiMeta.stringOrNull("picture")
                        ?: avatarUrl
                    val metaNebula = apiMeta.stringOrNull("nebula_id") ?: apiMeta.stringOrNull("nebulaId")
                    if (isGeneratedNebulaId(metaNebula)) {
                        nebulaId = metaNebula
                    } else if (nebulaId.isNullOrBlank()) {
                        nebulaId = metaNebula ?: nebulaId
                    }
                }
                val identities = info["identities"]?.let { it as? JsonArray } ?: JsonArray(emptyList())
                val nebulaIdentity = identities
                    .map { it.jsonObject }
                    .firstOrNull { obj ->
                        val p = obj["provider"]?.jsonPrimitive?.content?.lowercase()
                        p == "nebula" || p == "oidc" || p == "keycloak"
                    }
                val identityData = nebulaIdentity?.get("identity_data")?.jsonObject
                if (identityData != null) {
                    nebulaId = nebulaId
                        ?: identityData.stringOrNull("nebula_id")
                        ?: identityData.stringOrNull("nebulaId")
                        ?: identityData.stringOrNull("id")
                        ?: identityData.stringOrNull("sub")
                    avatarUrl = avatarUrl
                        ?: identityData.stringOrNull("avatar_url")
                        ?: identityData.stringOrNull("avatar")
                        ?: identityData.stringOrNull("picture")
                        ?: identityData.stringOrNull("image_url")
                }
            }.getOrNull()
        }

        // macOS-like: prefer profiles table if present (username/avatar/nebula_id)
        runCatching {
            val row = fetchProfileRowFromPostgrest(user.id)
            if (row != null) {
                // Prefer server profile values when present
                displayName = row.stringOrNull("display_name")
                    ?: row.stringOrNull("full_name")
                    ?: row.stringOrNull("username")
                    ?: displayName
                avatarUrl = row.stringOrNull("avatar_url") ?: avatarUrl
                nebulaId = row.stringOrNull("nebula_id")
                    ?: row.stringOrNull("nebulaId")
                    ?: nebulaId
            }
        }.getOrNull()

        // macOS-like: if nebula_id isn't in metadata/profiles, check `users` table.
        if (nebulaId.isNullOrBlank() || !isGeneratedNebulaId(nebulaId)) {
            runCatching { fetchNebulaIdFromUsersTable(user.id) }.getOrNull()?.let { nid ->
                nebulaId = nid
            }
        }

        // Pro release behavior: UI “星云ID” uses Supabase user.id when no explicit nebula_id exists.
        if (nebulaId.isNullOrBlank()) {
            nebulaId = user.id
        }

        // Normalize avatar_url for cross-platform interop: older macOS builds may store "/storage/..." paths.
        avatarUrl = normalizeAvatarUrl(avatarUrl)

        // Best-effort: if the stored avatar_url is not readable on this device (private bucket / stale url),
        // treat it as missing so we can attempt recovery.
        if (!avatarUrl.isNullOrBlank()) {
            val candidate = avatarUrl
            val ok = runCatching { isAvatarUrlReadable(candidate) }.getOrNull()
            if (ok == false) {
                avatarUrl = null
            }
        }

        // If macOS uploaded an avatar but metadata/profiles didn't persist (or we are on a fresh device),
        // best-effort probe the canonical Storage object location and repair metadata.
        var repairedAvatar = false
        if (avatarUrl.isNullOrBlank() && session != null) {
            val recoveredPublic = runCatching { probePublicAvatarUrl(user.id) }.getOrNull()
            if (!recoveredPublic.isNullOrBlank()) {
                avatarUrl = recoveredPublic
                runCatching { updateUserMetadata(mapOf("avatar_url" to recoveredPublic)) }
                repairedAvatar = true
            } else {
                // Private bucket fallback: create a signed URL for UI display (do not persist).
                avatarUrl = runCatching { createSignedAvatarUrl(user.id) }.getOrNull()
            }
        }

        val name = displayName
            ?: user.email
            ?: user.phone
            ?: user.id

        val profile = AccountStore.AccountProfile(
            id = user.id,
            displayName = name,
            email = user.email,
            phone = user.phone,
            avatarUrl = avatarUrl,
            nebulaId = nebulaId
        )

        if (repairedAvatar) {
            runCatching { upsertProfilesRow(profile) }
        }

        return profile
    }

    /**
     * 登录后尝试从 identities 中补齐缺失的 Nebula/头像，并直接刷新 AccountStore。
     * 如果用户完全没有 NebulaID，则生成一个新的并更新用户元数据。
     */
    suspend fun syncNebulaIdFromIdentitiesIfMissing() {
        runCatching {
            val profile = getCurrentUserProfile() ?: return
            if (isGeneratedNebulaId(profile.nebulaId) && !profile.avatarUrl.isNullOrBlank()) {
                AccountStore.setPrimaryAccount(profile)
                runCatching { upsertProfilesRow(profile) }
                return
            }

            var nebulaId = profile.nebulaId?.takeIf { isGeneratedNebulaId(it) }
            var avatarUrl = profile.avatarUrl

            // 先尝试从 identities 获取
            val info = fetchUserInfoFromSupabase()
            val identities = info["identities"]?.let { it as? JsonArray } ?: JsonArray(emptyList())
            val nebulaIdentity = identities.firstOrNull {
                it.jsonObject["provider"]?.jsonPrimitive?.content == "nebula"
            }?.jsonObject
            val identityData = nebulaIdentity?.get("identity_data")?.jsonObject

            nebulaId = nebulaId
                ?: identityData?.let {
                    it.stringOrNull("nebula_id")
                        ?: it.stringOrNull("nebulaId")
                        ?: it.stringOrNull("id")
                        ?: it.stringOrNull("sub")
                }

            avatarUrl = avatarUrl
                ?: identityData?.let {
                    it.stringOrNull("avatar_url")
                        ?: it.stringOrNull("avatar")
                        ?: it.stringOrNull("picture")
                        ?: it.stringOrNull("image_url")
                }

            avatarUrl = normalizeAvatarUrl(avatarUrl)

            // 如果仍然没有 NebulaID，生成一个新的并更新用户元数据
            if (nebulaId.isNullOrBlank()) {
                try {
                    val newNebulaId = NebulaIDGenerator.shared.generateUserRegistrationID()
                    nebulaId = newNebulaId.fullId

                    // 更新 Supabase 用户元数据
                    updateUserMetadata(mapOf(
                        "registration_source" to "SkyBridge Compass Android",
                        "nebula_id" to newNebulaId.fullId,
                        "nebula_id_raw" to newNebulaId.rawId.toString(),
                        "nebula_id_generated_at" to newNebulaId.generatedAt
                    ))

                    Log.i("AuthRepository", "Generated and saved NebulaID for existing user: ${newNebulaId.fullId}")
                } catch (e: Exception) {
                    Log.e("AuthRepository", "Failed to generate NebulaID for existing user", e)
                }
            }

            val updated = profile.copy(
                nebulaId = nebulaId,
                avatarUrl = avatarUrl
            )
            AccountStore.setPrimaryAccount(updated)
            runCatching { upsertProfilesRow(updated) }
            runCatching { saveNebulaIdToUsersTableIfPossible(updated) }
        }.getOrElse { /* 忽略补齐异常，不影响登录流程 */ }
    }

    private fun normalizeAvatarUrl(raw: String?): String? {
        val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (value.startsWith("http://") || value.startsWith("https://")) return value

        val base = runCatching { config().url.trimEnd('/') }.getOrNull() ?: return value
        return when {
            value.startsWith("/") -> base + value
            value.startsWith("storage/") -> "$base/$value"
            value.startsWith("storage/v1/") -> "$base/$value"
            else -> value
        }
    }

    private fun isSignedStorageUrl(rawUrl: String?): Boolean {
        val url = rawUrl?.trim()?.lowercase() ?: return false
        return url.contains("/storage/v1/object/sign/")
    }

    private fun persistentAvatarUrlOrNull(rawUrl: String?): String? {
        val url = rawUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (isSignedStorageUrl(url)) null else url
    }

    /**
     * Probe the standard Supabase Storage path used by macOS for avatars:
     * - Bucket: `avatars`
     * - Object: `{userId}.jpg`
     *
     * Returns the public URL when the object exists; otherwise null.
     */
    private suspend fun probePublicAvatarUrl(userId: String): String? {
        val cfg = config()
        val base = cfg.url.trimEnd('/')
        val url = "$base/storage/v1/object/public/avatars/${userId}.jpg"

        val head = runCatching {
            httpClient.request(url) {
                method = HttpMethod.Head
                headers { append("apikey", cfg.anonKey) }
            }
        }.getOrNull()
        if (head != null && head.status.isSuccess()) return url

        // Some deployments may not support HEAD; fallback to a minimal GET probe.
        val get = runCatching {
            httpClient.get(url) {
                headers {
                    append("apikey", cfg.anonKey)
                    append(HttpHeaders.Range, "bytes=0-0")
                }
            }
        }.getOrNull()
        return if (get != null && get.status.isSuccess()) url else null
    }

    /**
     * Create a signed URL for a (possibly private) avatar object.
     *
     * Signed URLs are intended for UI display only and must not be persisted into
     * `user_metadata.avatar_url` / `profiles.avatar_url` because they expire.
     */
    private suspend fun createSignedAvatarUrl(
        userId: String,
        expiresInSeconds: Int = 60 * 60 * 24 * 7
    ): String? {
        val cfg = config()
        val base = cfg.url.trimEnd('/')
        val supabase = supabaseOrNull() ?: return null
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return null

        val url = "$base/storage/v1/object/sign/avatars/${userId}.jpg"
        val payload = buildJsonObject {
            put("expiresIn", JsonPrimitive(expiresInSeconds))
        }
        val resp = runCatching {
            httpClient.post(url) {
                contentType(ContentType.Application.Json)
                setBody(payload)
                headers {
                    append(HttpHeaders.Authorization, "Bearer $accessToken")
                    append("apikey", cfg.anonKey)
                }
            }
        }.getOrNull() ?: return null

        if (!resp.status.isSuccess()) return null

        val bodyText: String = resp.body()
        val obj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull() ?: return null
        val signed = obj.stringOrNull("signedURL")
            ?: obj.stringOrNull("signedUrl")
            ?: obj.stringOrNull("signed_url")
            ?: return null
        return normalizeAvatarUrl(signed)
    }

    private suspend fun isAvatarUrlReadable(url: String): Boolean {
        val cfg = config()
        // Best-effort HEAD probe; some endpoints may not support it.
        val head = runCatching {
            httpClient.request(url) {
                method = HttpMethod.Head
                headers { append("apikey", cfg.anonKey) }
            }
        }.getOrNull()
        if (head != null && head.status.isSuccess()) return true

        val get = runCatching {
            httpClient.get(url) {
                headers {
                    append("apikey", cfg.anonKey)
                    append(HttpHeaders.Range, "bytes=0-0")
                }
            }
        }.getOrNull()
        return get != null && get.status.isSuccess()
    }

    /**
     * 更新用户元数据
     */
    private suspend fun updateUserMetadata(metadata: Map<String, Any>) {
        val config = config()
        val url = "${config.url}/auth/v1/user"
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken
            ?: throw IllegalStateException("No active session")

        val payload = buildJsonObject {
            put("data", buildJsonObject {
                metadata.forEach { (key, value) ->
                    when (value) {
                        is String -> put(key, JsonPrimitive(value))
                        is Number -> put(key, JsonPrimitive(value))
                        is Boolean -> put(key, JsonPrimitive(value))
                        else -> put(key, JsonPrimitive(value.toString()))
                    }
                }
            })
        }

        val resp = httpClient.put(url) {
            contentType(ContentType.Application.Json)
            setBody(payload)
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
            }
        }

        if (!resp.status.isSuccess()) {
            Log.w("AuthRepository", "Failed to update user metadata: ${resp.status}")
        }
    }

    /** 拉取完整用户信息（含 identities） */
    private suspend fun fetchUserInfoFromSupabase(): JsonObject {
        val config = config()
        val url = "${config.url}/auth/v1/user"
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken
            ?: throw IllegalStateException("No active session")
        val resp = httpClient.get(url) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
            }
        }
        val bodyText: String = resp.body()
        return json.parseToJsonElement(bodyText).jsonObject
    }

    /**
     * Fetch profile row from PostgREST `public.profiles` table (macOS parity).
     *
     * Supports both conventions:
     * - `profiles.id == auth.users.id` (preferred)
     * - `profiles.user_id == auth.users.id` (legacy)
     */
    private suspend fun fetchProfileRowFromPostgrest(userId: String): JsonObject? {
        val config = config()
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken
            ?: return null

        suspend fun fetchBy(filter: String): JsonObject? {
            val url = "${config.url}/rest/v1/profiles?$filter&select=username,display_name,full_name,phone_number,nebula_id,avatar_url&limit=1"
            val respText: String = httpClient.get(url) {
                headers {
                    append(HttpHeaders.Authorization, "Bearer $accessToken")
                    append("apikey", config.anonKey)
                }
            }.body()
            val arr = runCatching { json.parseToJsonElement(respText).jsonArray }.getOrNull() ?: return null
            return arr.firstOrNull()?.jsonObject
        }

        // Try primary key `id` first, then `user_id`
        return fetchBy("id=eq.$userId") ?: fetchBy("user_id=eq.$userId")
    }

    /**
     * Fetch nebula_id from PostgREST `public.users` table (macOS parity).
     *
     * Some flows (notably macOS phone registration) may persist nebula_id only in this table.
     */
    private suspend fun fetchNebulaIdFromUsersTable(userId: String): String? {
        val config = config()
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return null

        val url = "${config.url}/rest/v1/users?select=nebula_id&id=eq.$userId&limit=1"
        val respText: String = httpClient.get(url) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
            }
        }.body()

        val arr = runCatching { json.parseToJsonElement(respText).jsonArray }.getOrNull() ?: return null
        val nid = arr.firstOrNull()?.jsonObject?.stringOrNull("nebula_id")
        return nid?.takeIf { isGeneratedNebulaId(it) }
    }

    /**
     * Upsert `public.profiles` row for the current user (best-effort, non-blocking errors).
     * This lets macOS/iOS/Android all see consistent username/avatar/nebula_id.
     */
    private suspend fun upsertProfilesRow(profile: AccountStore.AccountProfile) {
        val config = config()
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return

        val url = "${config.url}/rest/v1/profiles?on_conflict=id"
        val payload = buildJsonObject {
            put("id", profile.id)
            put("display_name", profile.displayName)
            profile.phone?.let { put("phone_number", it) }
            persistentAvatarUrlOrNull(profile.avatarUrl)?.let { put("avatar_url", it) }
            profile.nebulaId?.takeIf { isGeneratedNebulaId(it) }?.let { put("nebula_id", it) }
        }

        val resp = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
                append("Prefer", "resolution=merge-duplicates")
                append("Prefer", "return=minimal")
            }
            setBody(payload)
        }

        if (!resp.status.isSuccess()) {
            Log.d("AuthRepository", "profiles upsert failed: ${resp.status}")
        }
    }

    /** Base64 解码 JWT payload 为 JsonObject */
    private fun decodeJwtPayload(jwt: String): JsonObject {
        val parts = jwt.split('.')
        val payloadPart = parts.getOrNull(1) ?: return JsonObject(emptyMap())
        val padded = payloadPart.padEnd(((payloadPart.length + 3) / 4) * 4, '=')
        val bytes = java.util.Base64.getUrlDecoder().decode(padded)
        val text = String(bytes, Charsets.UTF_8)
        return json.parseToJsonElement(text).jsonObject
    }

    /** 从 JsonObject 安全读取 String 字段 */
    private fun JsonObject.stringOrNull(key: String): String? {
        val el = this[key] ?: return null
        val prim = el as? JsonPrimitive ?: return null
        return prim.content
    }

    private fun isGeneratedNebulaId(value: String?): Boolean {
        if (value.isNullOrBlank()) return false
        // Expected format: NEBULA-YYYY-XXXXXXXXXXXX (base36, padded to 12).
        val re = Regex("^NEBULA-\\d{4}-[0-9A-Z]{12}$")
        return re.matches(value.trim())
    }

    /** Best-effort PostgREST PATCH to `public.users` (macOS parity). */
    private suspend fun saveNebulaIdToUsersTable(userId: String, nebulaId: String, accessToken: String) {
        if (!isGeneratedNebulaId(nebulaId)) return

        val config = config()
        val url = "${config.url}/rest/v1/users?id=eq.$userId"
        val payload = buildJsonObject {
            put("nebula_id", JsonPrimitive(nebulaId))
            put("updated_at", JsonPrimitive(Instant.now().toString()))
        }

        val resp = httpClient.patch(url) {
            contentType(ContentType.Application.Json)
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
                append("Prefer", "return=representation")
            }
            setBody(payload)
        }

        if (!resp.status.isSuccess()) {
            Log.d("AuthRepository", "users nebula_id patch failed: ${resp.status}")
        }
    }

    private suspend fun saveNebulaIdToUsersTableIfPossible(profile: AccountStore.AccountProfile) {
        val nebulaId = profile.nebulaId ?: return
        if (!isGeneratedNebulaId(nebulaId)) return

        val supabase = supabaseOrNull() ?: return
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return
        runCatching { saveNebulaIdToUsersTable(profile.id, nebulaId, accessToken) }
    }

    private suspend fun parseSessionFromAuthResponse(
        response: HttpResponse,
        action: String
    ): UserSession {
        val text = runCatching { response.body<String>() }.getOrDefault("")
        val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            ?: throw RuntimeException("$action 失败：服务端返回不可解析响应")
        return parseSessionFromJsonObject(obj, action)
    }

    private fun parseSessionFromJsonObject(
        obj: JsonObject?,
        action: String
    ): UserSession {
        if (obj == null) throw RuntimeException("$action 失败：服务端响应为空")
        val accessToken = obj["access_token"]?.jsonPrimitive?.contentOrNull
        val refreshToken = obj["refresh_token"]?.jsonPrimitive?.contentOrNull
        val expiresIn = obj["expires_in"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 3600L
        val tokenType = obj["token_type"]?.jsonPrimitive?.contentOrNull ?: "bearer"
        if (accessToken.isNullOrBlank()) {
            throw RuntimeException("$action 失败：服务端未返回 access_token")
        }
        return UserSession(
            accessToken = accessToken,
            refreshToken = refreshToken ?: "",
            expiresIn = expiresIn,
            tokenType = tokenType,
            user = null
        )
    }

    private suspend fun supabaseErrorMessage(
        response: HttpResponse,
        fallbackPrefix: String
    ): String {
        val body = runCatching { response.body<String>() }.getOrDefault("")
        val parsed = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull()
        val serverMessage = parsed?.stringOrNull("msg")
            ?: parsed?.stringOrNull("message")
            ?: parsed?.stringOrNull("error_description")
            ?: parsed?.stringOrNull("error")

        val normalized = when {
            response.status.value == 429 -> "请求过于频繁，请稍后再试。"
            response.status.value in 500..599 -> "服务器暂时不可用，请稍后重试。"
            serverMessage?.contains("invalid login credentials", ignoreCase = true) == true ->
                "邮箱或密码错误，请检查后重试。"
            serverMessage?.contains("email not confirmed", ignoreCase = true) == true ->
                "邮箱尚未验证，请先完成邮箱验证。"
            serverMessage?.contains("network", ignoreCase = true) == true ->
                "网络异常，请检查网络连接后重试。"
            !serverMessage.isNullOrBlank() -> serverMessage
            else -> null
        }
        return normalized?.let { "$fallbackPrefix：$it" }
            ?: "$fallbackPrefix：HTTP ${response.status.value}"
    }

}
