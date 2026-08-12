package com.skybridge.compass.auth

import android.content.Context
import android.util.Log
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.android.data.SupabaseSessionStore
import com.skybridge.compass.android.data.SupabaseSessionAuthorityMismatchException
import com.skybridge.compass.android.data.SupabaseSessionStoreCorruptionException
import com.skybridge.compass.supabase.SupabaseClientFactory
import com.skybridge.compass.supabase.SupabasePostgrestUrls
import com.skybridge.compass.supabase.SupabaseConfigException
import com.skybridge.compass.supabase.SupabaseConfigValidationResult
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.shared.account.NebulaIDGenerator
import com.skybridge.compass.shared.account.NebulaId
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import io.ktor.http.contentType
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.qualifiers.ApplicationContext

enum class SignUpOutcome {
    Authenticated,
    EmailVerificationRequired
}

sealed interface SignOutOutcome {
    data object LocalOnly : SignOutOutcome
    data object RevokedRemotely : SignOutOutcome
    data class LocalOnlyAfterRemoteFailure(val reason: String) : SignOutOutcome
    data class LocalOnlyAfterClientCleanupFailure(val reason: String) : SignOutOutcome
    data class LocalOnlyAfterRemoteAndClientCleanupFailure(
        val remoteReason: String,
        val clientCleanupReason: String
    ) : SignOutOutcome
}

internal fun combineSignOutOutcomes(
    remoteOutcome: SignOutOutcome,
    clientCleanupFailure: String?
): SignOutOutcome = when {
    clientCleanupFailure == null -> remoteOutcome
    remoteOutcome is SignOutOutcome.LocalOnlyAfterRemoteFailure ->
        SignOutOutcome.LocalOnlyAfterRemoteAndClientCleanupFailure(
            remoteReason = remoteOutcome.reason,
            clientCleanupReason = clientCleanupFailure
        )
    else -> SignOutOutcome.LocalOnlyAfterClientCleanupFailure(clientCleanupFailure)
}

class AuthSessionSnapshot internal constructor(
    val authority: String,
    val accessToken: String,
    val subject: String?,
    val expiresAtEpochMs: Long
)

sealed interface AuthCredentialStateFailure {
    data class SessionPersistenceFailed(val reason: String) : AuthCredentialStateFailure
    data class SessionCleanupFailed(val reason: String) : AuthCredentialStateFailure
}

class SupabaseSessionImportException(
    message: String,
    cause: Throwable
) : IllegalStateException(message, cause)

class NebulaIdentityException(
    message: String,
    cause: Throwable? = null
) : RuntimeException(message, cause)

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
    private val json: Json,
    private val profileDataSource: SupabaseProfileDataSource,
    private val profileProjectionDataSource: SupabaseProfileProjectionDataSource,
    private val sessionStore: SupabaseSessionStore
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val sessionStatusFlow = MutableStateFlow<SessionStatus>(SessionStatus.NotAuthenticated())
    val sessionStatus: StateFlow<SessionStatus> = sessionStatusFlow.asStateFlow()
    private val credentialStateFailureFlow = MutableStateFlow<AuthCredentialStateFailure?>(null)
    val credentialStateFailure: StateFlow<AuthCredentialStateFailure?> =
        credentialStateFailureFlow.asStateFlow()

    @Volatile private var supabaseClient: io.github.jan.supabase.SupabaseClient? = null
    @Volatile private var activeSessionSnapshot: AuthSessionSnapshot? = null
    private var sessionJob: Job? = null
    @Volatile private var currentConfig: SupabaseConfig? = null
    private val authMutationMutex = AuthMutationCoordinator()
    private val sessionRestoreMutex = Mutex()
    @Volatile private var initialSessionRestoreAttempted = false

    init {
        scope.launch {
            AppSettingsStore.observeRememberLogin(context).collect { enabled ->
                authMutationMutex.withLock {
                    try {
                        if (enabled) {
                            restoreStoredSessionIfRememberLoginEnabled(
                                rememberLoginEnabled = true,
                                forceRefresh = false,
                                syncProfile = false
                            )
                        }
                        syncSessionPersistence(enabled)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: RuntimeException) {
                        handleRememberLoginReconciliationFailure(enabled, error)
                    }
                }
            }
        }
    }

    private fun requireSupabase(): io.github.jan.supabase.SupabaseClient {
        val config = SupabaseConfigStore.requireConfig(context)
        val existing = supabaseClient
        if (existing != null && currentConfig == config) {
            return existing
        }
        if (existing != null) {
            sessionJob?.cancel()
            supabaseClient = null
            currentConfig = null
            activeSessionSnapshot = null
            sessionStatusFlow.value = SessionStatus.NotAuthenticated()
            AccountStore.clearPrimaryAccount()
            scope.launch {
                try {
                    existing.close()
                } catch (error: RuntimeException) {
                    Log.e("AuthRepository", "Superseded Supabase client could not be closed", error)
                    credentialStateFailureFlow.value =
                        AuthCredentialStateFailure.SessionCleanupFailed(error.javaClass.simpleName)
                }
            }
        }
        val created = clientFactory.create(config)
        supabaseClient = created
        currentConfig = config
        sessionJob?.cancel()
        sessionJob = scope.launch {
            created.auth.sessionStatus.collect { status ->
                authMutationMutex.withLock {
                    if (supabaseClient !== created) {
                        return@withLock
                    }
                    when (status) {
                        is SessionStatus.Authenticated -> {
                            try {
                                syncSessionPersistence(client = created, config = config)
                                if (supabaseClient === created) {
                                    publishSessionSnapshot(config, status.session)
                                    credentialStateFailureFlow.value = null
                                    sessionStatusFlow.value = status
                                }
                            } catch (error: RuntimeException) {
                                failClosedAfterSessionPersistenceFailure(created, error)
                            }
                        }
                        is SessionStatus.NotAuthenticated -> handleNotAuthenticatedStatus()
                        else -> sessionStatusFlow.value = status
                    }
                }
            }
        }
        return created
    }

    private fun supabaseOrNull(): io.github.jan.supabase.SupabaseClient? {
        return try {
            requireSupabase()
        } catch (_: SupabaseConfigException) {
            activeSessionSnapshot = null
            sessionStatusFlow.value = SessionStatus.NotAuthenticated()
            AccountStore.clearPrimaryAccount()
            null
        }
    }

    fun currentAccessTokenOrNull(): String? {
        return currentSessionSnapshotOrNull()?.accessToken
    }

    fun currentUserIdOrNull(): String? {
        return currentSessionSnapshotOrNull()?.subject
    }

    fun currentSessionSnapshotOrNull(expirySkewSeconds: Long = 0L): AuthSessionSnapshot? {
        require(expirySkewSeconds >= 0L) { "Expiry skew must not be negative" }
        val snapshot = activeSessionSnapshot ?: return null
        val minimumExpiry = try {
            Math.addExact(System.currentTimeMillis(), Math.multiplyExact(expirySkewSeconds, 1_000L))
        } catch (error: ArithmeticException) {
            throw IllegalArgumentException("Expiry skew is too large", error)
        }
        val currentAuthority = try {
            SupabaseConfigStore.requireConfig(context).url
        } catch (_: SupabaseConfigException) {
            return null
        }
        return snapshot.takeIf {
            it.authority == currentAuthority && it.expiresAtEpochMs > minimumExpiry
        }
    }

    private fun config(): SupabaseConfig = SupabaseConfigStore.requireConfig(context)

    private fun generateRequiredRegistrationNebulaId(flowName: String): NebulaIDGenerator.NebulaIDInfo {
        return runCatching { NebulaIDGenerator.shared.generateUserRegistrationID() }
            .getOrElse { error ->
                throw NebulaIdentityException(
                    "$flowName requires a canonical Nebula ID before account creation",
                    error
                )
            }
    }

    /**
     * 从本地存储恢复会话（如已启用自动加载，此方法安全幂等）。
     * 为兼容不同库版本，这里做轻量探测而不依赖特定 API。
     */
    suspend fun loadSessionFromStorage(forceRefresh: Boolean = false) {
        authMutationMutex.withLock {
            restoreStoredSessionIfRememberLoginEnabled(
                rememberLoginEnabled = null,
                forceRefresh = forceRefresh,
                syncProfile = true
            )
        }
    }

    private suspend fun syncSessionPersistence(
        rememberLoginEnabled: Boolean? = null,
        client: io.github.jan.supabase.SupabaseClient? = supabaseClient,
        config: SupabaseConfig? = currentConfig
    ) {
        val shouldRemember = rememberLoginEnabled ?: AppSettingsStore.observeRememberLogin(context).first()
        if (!shouldRemember) {
            clearStoredSessionOrThrow()
            initialSessionRestoreAttempted = true
            return
        }

        val session = client?.auth?.currentSessionOrNull()
        val sessionAuthority = config?.url

        if (session != null && sessionAuthority != null) {
            sessionStore.save(session, authority = sessionAuthority)
        }
    }

    private fun publishSessionSnapshot(config: SupabaseConfig, session: UserSession) {
        activeSessionSnapshot = AuthSessionSnapshot(
            authority = config.url,
            accessToken = session.accessToken,
            subject = SupabaseJwtClaims.subjectOrNull(json, session.accessToken),
            expiresAtEpochMs = session.expiresAt.toEpochMilliseconds()
        )
    }

    private fun failClosedAfterSessionPersistenceFailure(
        client: io.github.jan.supabase.SupabaseClient,
        originalError: RuntimeException
    ) {
        Log.e("AuthRepository", "Rotated Supabase session could not be persisted", originalError)
        try {
            clearStoredSessionOrThrow()
        } catch (cleanupError: RuntimeException) {
            originalError.addSuppressed(cleanupError)
        }
        if (supabaseClient === client) {
            supabaseClient = null
            currentConfig = null
            activeSessionSnapshot = null
            sessionJob = null
            initialSessionRestoreAttempted = true
            sessionStatusFlow.value = SessionStatus.NotAuthenticated()
            AccountStore.clearPrimaryAccount()
            credentialStateFailureFlow.value = if (originalError.suppressed.isEmpty()) {
                AuthCredentialStateFailure.SessionPersistenceFailed(originalError.javaClass.simpleName)
            } else {
                AuthCredentialStateFailure.SessionCleanupFailed(originalError.javaClass.simpleName)
            }
        }
        scope.launch {
            try {
                client.close()
            } catch (error: RuntimeException) {
                Log.e("AuthRepository", "Failed Supabase client could not be closed", error)
                credentialStateFailureFlow.value =
                    AuthCredentialStateFailure.SessionCleanupFailed(error.javaClass.simpleName)
            }
        }
    }

    private fun handleRememberLoginReconciliationFailure(
        rememberLoginEnabled: Boolean,
        error: RuntimeException
    ) {
        Log.e("AuthRepository", "Remember-login session reconciliation failed", error)
        val failedClient = supabaseClient
        sessionJob?.cancel()
        sessionJob = null
        supabaseClient = null
        currentConfig = null
        activeSessionSnapshot = null
        initialSessionRestoreAttempted = true
        sessionStatusFlow.value = SessionStatus.NotAuthenticated()
        AccountStore.clearPrimaryAccount()

        val wasRejectedAndCleared =
            (error is SupabaseSessionStoreCorruptionException ||
                error is SupabaseSessionAuthorityMismatchException) &&
                error.suppressed.isEmpty()
        credentialStateFailureFlow.value = when {
            wasRejectedAndCleared -> null
            !rememberLoginEnabled || error.suppressed.isNotEmpty() ->
                AuthCredentialStateFailure.SessionCleanupFailed(error.javaClass.simpleName)
            else -> AuthCredentialStateFailure.SessionPersistenceFailed(error.javaClass.simpleName)
        }
        scope.launch {
            try {
                failedClient?.close()
            } catch (closeError: RuntimeException) {
                Log.e("AuthRepository", "Reconciliation-failed Supabase client could not be closed", closeError)
                credentialStateFailureFlow.value =
                    AuthCredentialStateFailure.SessionCleanupFailed(closeError.javaClass.simpleName)
            }
        }
    }

    private suspend fun commitSession(
        client: io.github.jan.supabase.SupabaseClient,
        config: SupabaseConfig,
        session: UserSession
    ) {
        SupabaseAuthSessionContract.validate(session, "Supabase authentication")
        val rememberLogin = AppSettingsStore.observeRememberLogin(context).first()
        if (rememberLogin) {
            sessionStore.save(session, authority = config.url)
        } else {
            clearStoredSessionOrThrow()
        }
        try {
            client.auth.importSession(session)
            publishSessionSnapshot(config, session)
            credentialStateFailureFlow.value = null
        } catch (error: CancellationException) {
            abortClientAfterUncertainSessionImport(
                client = client,
                originalError = error,
                clearPersistedSession = rememberLogin
            )
            throw error
        } catch (error: Exception) {
            abortClientAfterUncertainSessionImport(
                client = client,
                originalError = error,
                clearPersistedSession = rememberLogin
            )
            throw SupabaseSessionImportException("Supabase session import failed", error)
        }
    }

    private suspend fun abortClientAfterUncertainSessionImport(
        client: io.github.jan.supabase.SupabaseClient,
        originalError: Throwable,
        clearPersistedSession: Boolean
    ) {
        val rollback = rollbackUncertainSessionImport(
            originalError = originalError,
            clearPersistedSession = clearPersistedSession,
            clearPersistedSessionAction = ::clearStoredSessionOrThrow,
            detachClientAction = {
                if (supabaseClient === client) {
                    supabaseClient = null
                    currentConfig = null
                    activeSessionSnapshot = null
                    sessionJob?.cancel()
                    sessionJob = null
                    initialSessionRestoreAttempted = true
                    sessionStatusFlow.value = SessionStatus.NotAuthenticated()
                    AccountStore.clearPrimaryAccount()
                }
            },
            closeClientAction = client::close
        )
        if (rollback.cleanupFailed) {
            credentialStateFailureFlow.value =
                AuthCredentialStateFailure.SessionCleanupFailed(originalError.javaClass.simpleName)
        } else {
            credentialStateFailureFlow.value = null
        }
    }

    suspend fun login(email: String, password: String) = authMutationMutex.withLock {
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
        commitSession(supabase, config, session)

        // 登录后资料补齐改为后台异步，避免阻塞登录主流程（iOS/mac 语义：先进入，再补齐资料）。
        scope.launch {
            syncProfileInBackground("Email login")
        }
    }

    suspend fun signUp(email: String, password: String): SignUpOutcome = authMutationMutex.withLock {
        val config = config()
        val supabase = requireSupabase()
        val nebulaIdInfo = generateRequiredRegistrationNebulaId("Email sign-up")

        val url = "${config.url}/auth/v1/signup"
        val safeDisplayName = email.trim().substringBefore('@').ifBlank { "User" }
        val payload = buildJsonObject {
            put("email", JsonPrimitive(email.trim()))
            put("password", JsonPrimitive(password))
            put("data", buildJsonObject {
                put("display_name", JsonPrimitive(safeDisplayName))
                put("registration_source", JsonPrimitive("SkyBridge Compass Android"))
                put("nebula_id", JsonPrimitive(nebulaIdInfo.fullId))
                put("nebula_id_raw", JsonPrimitive(nebulaIdInfo.rawId.toString()))
                put("nebula_id_generated_at", JsonPrimitive(nebulaIdInfo.generatedAt))
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

        val bodyText: String = resp.body()
        val obj = try {
            json.parseToJsonElement(bodyText).jsonObject
        } catch (error: IllegalArgumentException) {
            throw SupabaseAuthSessionContractException(
                "Registration failed: server returned malformed JSON"
            )
        }
        val accessToken = obj["access_token"]?.jsonPrimitive?.contentOrNull

        // 邮箱验证开启时，Supabase 仅返回 user，不返回 session
        if (accessToken.isNullOrBlank()) {
            SupabaseAuthSessionContract.requirePendingVerificationUser(obj, "Registration")
            Log.i("AuthRepository", "Sign up created account; waiting for email verification.")
            return@withLock SignUpOutcome.EmailVerificationRequired
        }

        val session = parseSessionFromJsonObject(obj, "注册")
        commitSession(supabase, config, session)

        // Best-effort: write the canonical cross-platform projection first, then mirror legacy users.
        val userId = supabase.auth.currentUserOrNull()?.id
            ?: SupabaseJwtClaims.subjectOrNull(json, session.accessToken)
        if (userId != null) {
            val profile = AccountStore.AccountProfile(
                id = userId,
                displayName = safeDisplayName,
                email = email.trim(),
                nebulaId = nebulaIdInfo.fullId
            )
            try {
                profileProjectionDataSource.upsertUserProfile(config, session.accessToken, profile)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w("AuthRepository", "user_profiles upsert failed after sign-up", error)
            }
            try {
                saveNebulaIdToUsersTable(userId, nebulaIdInfo.fullId, session.accessToken)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w("AuthRepository", "users nebula_id mirror failed after sign-up", error)
            }
        }

        Log.i("AuthRepository", "User registered with generated NebulaID metadata")
        return@withLock SignUpOutcome.Authenticated
    }

    /** 发送手机短信验证码（直接调用 GoTrue 端点） */
    suspend fun sendPhoneOtp(phone: String, createUser: Boolean = false) {
        val config = config()
        val url = "${config.url}/auth/v1/otp"

        val nebulaIdInfo = if (createUser) {
            generateRequiredRegistrationNebulaId("Phone sign-up")
        } else {
            null
        }

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
            Log.i("AuthRepository", "Phone OTP sent for new user with generated NebulaID metadata")
        }
    }

    /** 验证手机短信验证码并建立会话（GoTrue 端点） */
    suspend fun verifyPhoneOtpSms(phone: String, code: String) = authMutationMutex.withLock {
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
        val session = SupabaseAuthSessionContract.parse(obj, "短信验证码验证")
        commitSession(supabase, config, session)

        // 后台补齐资料，不阻塞 OTP 登录态建立。
        scope.launch {
            syncProfileInBackground("Phone OTP login")
        }
    }

    /** OIDC: 使用外部 Nebula 提供的 ID Token 登录（GoTrue 端点） */
    suspend fun loginWithNebulaIdToken(
        idToken: String,
        providerName: String = "nebula",
        nonce: String? = null
    ) = authMutationMutex.withLock {
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
        commitSession(supabase, config, session)

        // 第三方登录后资料补齐后台执行，避免前台等待超时。
        scope.launch {
            syncProfileInBackground("OIDC login")
        }
    }

    suspend fun loginWithGoogleIdToken(idToken: String, nonce: String? = null) {
        loginWithNebulaIdToken(
            idToken = idToken,
            providerName = "google",
            nonce = nonce
        )
    }

    suspend fun logout(): SignOutOutcome = authMutationMutex.withLock {
        val client = supabaseClient
        val config = currentConfig
        val accessToken = client?.auth?.currentSessionOrNull()?.accessToken

        // Local revocation is the durable authority. Never wait on the network while a refresh
        // token remains restorable on disk.
        clearStoredSessionOrThrow()
        sessionJob?.cancel()
        sessionJob = null
        supabaseClient = null
        currentConfig = null
        activeSessionSnapshot = null
        initialSessionRestoreAttempted = true
        sessionStatusFlow.value = SessionStatus.NotAuthenticated()
        credentialStateFailureFlow.value = null
        AccountStore.clearPrimaryAccount()

        val clientCleanupFailure = try {
            client?.close()
            null
        } catch (error: CancellationException) {
            throw error
        } catch (error: RuntimeException) {
            Log.e("AuthRepository", "Signed-out Supabase client could not be closed", error)
            error.javaClass.simpleName
        }

        if (config == null || accessToken.isNullOrBlank()) {
            return@withLock clientCleanupFailure?.let {
                SignOutOutcome.LocalOnlyAfterClientCleanupFailure(it)
            } ?: SignOutOutcome.LocalOnly
        }

        val remoteOutcome = try {
            val response = httpClient.post("${config.url}/auth/v1/logout?scope=local") {
                headers {
                    append(HttpHeaders.Authorization, "Bearer $accessToken")
                    append("apikey", config.anonKey)
                }
            }
            if (response.status.isSuccess()) {
                SignOutOutcome.RevokedRemotely
            } else {
                SignOutOutcome.LocalOnlyAfterRemoteFailure("HTTP ${response.status.value}")
            }
        } catch (error: HttpRequestTimeoutException) {
            SignOutOutcome.LocalOnlyAfterRemoteFailure("timeout")
        } catch (error: IOException) {
            SignOutOutcome.LocalOnlyAfterRemoteFailure("network")
        }

        return@withLock combineSignOutOutcomes(remoteOutcome, clientCleanupFailure)
    }

    suspend fun invalidateSessionForConfigurationChange() = authMutationMutex.withLock {
        clearStoredSessionOrThrow()
        val client = supabaseClient
        sessionJob?.cancel()
        sessionJob = null
        supabaseClient = null
        currentConfig = null
        activeSessionSnapshot = null
        initialSessionRestoreAttempted = true
        sessionStatusFlow.value = SessionStatus.NotAuthenticated()
        credentialStateFailureFlow.value = null
        AccountStore.clearPrimaryAccount()
        try {
            client?.close()
        } catch (error: CancellationException) {
            throw error
        } catch (error: RuntimeException) {
            credentialStateFailureFlow.value =
                AuthCredentialStateFailure.SessionCleanupFailed(error.javaClass.simpleName)
            throw IllegalStateException("Supabase client cleanup failed during configuration change", error)
        }
    }

    private suspend fun restoreStoredSessionIfRememberLoginEnabled(
        rememberLoginEnabled: Boolean?,
        forceRefresh: Boolean,
        syncProfile: Boolean
    ): Boolean = sessionRestoreMutex.withLock {
        val shouldRemember = rememberLoginEnabled ?: AppSettingsStore.observeRememberLogin(context).first()
        if (!shouldRemember) {
            clearStoredSessionOrThrow()
            initialSessionRestoreAttempted = true
            return@withLock false
        }

        val supabase = supabaseOrNull()
        if (supabase == null) {
            initialSessionRestoreAttempted = true
            return@withLock false
        }

        val restored = try {
            restoreSessionIntoClientIfPossible(supabase, config())
            supabase.auth.currentSessionOrNull() != null
        } finally {
            initialSessionRestoreAttempted = true
        }

        if (restored && forceRefresh) {
            try {
                fetchUserInfoFromSupabaseLocked()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w("AuthRepository", "Stored Supabase session refresh check failed", error)
            }
        }
        if (restored && syncProfile) {
            try {
                syncNebulaIdFromIdentitiesIfMissingLocked()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w("AuthRepository", "Stored Supabase session profile sync failed", error)
            }
        }
        return@withLock restored
    }

    private suspend fun restoreSessionIntoClientIfPossible(
        client: io.github.jan.supabase.SupabaseClient,
        config: SupabaseConfig
    ) {
        // If already authenticated, don't overwrite.
        if (client.auth.currentSessionOrNull() != null) return
        val stored = try {
            sessionStore.load(expectedAuthority = config.url)
        } catch (error: SupabaseSessionStoreCorruptionException) {
            clearStoredSessionAfterRestoreFailure(error)
            throw error
        } catch (error: SupabaseSessionAuthorityMismatchException) {
            clearStoredSessionAfterRestoreFailure(error)
            throw error
        } ?: return
        try {
            client.auth.importSession(stored)
            publishSessionSnapshot(config, stored)
            credentialStateFailureFlow.value = null
        } catch (error: CancellationException) {
            abortClientAfterUncertainSessionImport(
                client = client,
                originalError = error,
                clearPersistedSession = false
            )
            throw error
        } catch (error: Exception) {
            abortClientAfterUncertainSessionImport(
                client = client,
                originalError = error,
                clearPersistedSession = true
            )
            throw SupabaseSessionImportException("Stored Supabase session import failed", error)
        }
    }

    private fun clearStoredSessionAfterRestoreFailure(originalError: Throwable) {
        try {
            clearStoredSessionOrThrow()
        } catch (cleanupError: RuntimeException) {
            originalError.addSuppressed(cleanupError)
        }
    }

    private fun handleNotAuthenticatedStatus() {
        activeSessionSnapshot = null
        AccountStore.clearPrimaryAccount()
        sessionStatusFlow.value = SessionStatus.NotAuthenticated()
        if (!initialSessionRestoreAttempted) {
            Log.i(
                "AuthRepository",
                "Deferring stored Supabase session clear until startup restore has been attempted"
            )
            return
        }
        try {
            clearStoredSessionOrThrow()
            credentialStateFailureFlow.value = null
        } catch (error: RuntimeException) {
            Log.e("AuthRepository", "Failed to clear a rejected Supabase session", error)
            val rejectedClient = supabaseClient
            supabaseClient = null
            currentConfig = null
            sessionJob = null
            credentialStateFailureFlow.value =
                AuthCredentialStateFailure.SessionCleanupFailed(error.javaClass.simpleName)
            scope.launch {
                try {
                    rejectedClient?.close()
                } catch (closeError: RuntimeException) {
                    Log.e("AuthRepository", "Rejected Supabase client could not be closed", closeError)
                    credentialStateFailureFlow.value =
                        AuthCredentialStateFailure.SessionCleanupFailed(closeError.javaClass.simpleName)
                }
            }
        }
    }

    private fun clearStoredSessionOrThrow() = sessionStore.clear()

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
            val ok = code in 200..299
            SupabaseConfigValidationResult(
                isValid = ok,
                message = if (ok) {
                    "Supabase 配置有效"
                } else {
                    "Supabase 健康检查失败: HTTP $code"
                }
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            SupabaseConfigValidationResult(
                isValid = false,
                message = "网络请求失败: ${e.message ?: "未知错误"}"
            )
        }
    }

    /**
     * 获取当前用户的展示资料：昵称/邮箱/手机号/头像/Nebula ID。
     *
     * Android cannot rely on `currentUserOrNull()` here because the direct GoTrue login endpoints
     * import a session with `user = null`. The access token is authoritative, so the profile data
     * source starts from `/auth/v1/user` and only treats the SDK user as an optional consistency hint.
     */
    suspend fun refreshCurrentAccountProfile(): AccountStore.AccountProfile? =
        authMutationMutex.withLock {
            val owner = activeSessionSnapshot ?: return@withLock null
            val profile = getCurrentUserProfileLocked() ?: return@withLock null
            check(activeSessionSnapshot === owner) {
                "Auth session owner changed during profile refresh"
            }
            AccountStore.setPrimaryAccount(profile)
            profile
        }

    private suspend fun getCurrentUserProfileLocked(): AccountStore.AccountProfile? {
        val supabase = requireSupabase()
        val session = supabase.auth.currentSessionOrNull()
        val accessToken = session?.accessToken?.takeIf { it.isNotBlank() } ?: return null
        val userIdHint = supabase.auth.currentUserOrNull()?.id
            ?: SupabaseJwtClaims.subjectOrNull(json, accessToken)
        return profileDataSource.fetchCurrentProfile(
            config = config(),
            accessToken = accessToken,
            sessionUserIdHint = userIdHint
        )
    }

    /**
     * 登录后刷新 AccountStore，并把当前资料写回 canonical user_profiles 及 legacy profiles/users。
     *
     * Existing users must not get a newly generated Nebula ID here. mac/iOS treat missing remote
     * `nebula_id` as an unsynced state, not as permission to mint a second business identity.
     */
    suspend fun syncNebulaIdFromIdentitiesIfMissing() =
        authMutationMutex.withLock { syncNebulaIdFromIdentitiesIfMissingLocked() }

    private suspend fun syncNebulaIdFromIdentitiesIfMissingLocked() {
        val profile = getCurrentUserProfileLocked() ?: return
        AccountStore.setPrimaryAccount(profile)
        if (!isGeneratedNebulaId(profile.nebulaId)) {
            Log.w("AuthRepository", "Remote profile has no canonical Nebula ID; preserving unsynced state")
        }
        try {
            val accessToken = requireSupabase().auth.currentSessionOrNull()?.accessToken
                ?: throw IllegalStateException("No active session")
            profileProjectionDataSource.upsertUserProfile(config(), accessToken, profile)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("AuthRepository", "user_profiles upsert failed during profile sync", error)
        }
        try {
            upsertProfilesRow(profile)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("AuthRepository", "profiles upsert failed during profile sync", error)
        }
        try {
            saveNebulaIdToUsersTableIfPossible(profile)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("AuthRepository", "users nebula_id patch failed during profile sync", error)
        }
    }

    private suspend fun syncProfileInBackground(flowName: String) {
        try {
            syncNebulaIdFromIdentitiesIfMissing()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("AuthRepository", "$flowName profile sync failed", error)
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

    /** 拉取完整用户信息（含 identities） */
    private suspend fun fetchUserInfoFromSupabaseLocked(): JsonObject {
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
        if (!resp.status.isSuccess()) {
            throw RuntimeException("Supabase 用户信息刷新失败：HTTP ${resp.status.value}")
        }
        return json.parseToJsonElement(bodyText).jsonObject
    }

    /**
     * Upsert `public.profiles` row for the current user (best-effort, non-blocking errors).
     * This lets macOS/iOS/Android all see consistent username/avatar/nebula_id.
     */
    private suspend fun upsertProfilesRow(profile: AccountStore.AccountProfile) {
        val config = config()
        val supabase = requireSupabase()
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return

        val url = SupabasePostgrestUrls.table(
            baseUrl = config.url,
            table = "profiles",
            query = mapOf("on_conflict" to "id")
        )
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
            throw RuntimeException("profiles upsert failed: HTTP ${resp.status.value}")
        }
    }

    /** 从 JsonObject 安全读取 String 字段 */
    private fun JsonObject.stringOrNull(key: String): String? {
        val el = this[key] ?: return null
        val prim = el as? JsonPrimitive ?: return null
        return prim.content
    }

    private fun isGeneratedNebulaId(value: String?): Boolean {
        return NebulaId.parseOrNull(value) != null
    }

    /** Best-effort PostgREST PATCH to `public.users` (macOS parity). */
    private suspend fun saveNebulaIdToUsersTable(userId: String, nebulaId: String, accessToken: String) {
        if (!isGeneratedNebulaId(nebulaId)) return

        val config = config()
        val url = SupabasePostgrestUrls.table(
            baseUrl = config.url,
            table = "users",
            query = mapOf("id" to "eq.$userId")
        )
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
            throw RuntimeException("users nebula_id patch failed: HTTP ${resp.status.value}")
        }
    }

    private suspend fun saveNebulaIdToUsersTableIfPossible(profile: AccountStore.AccountProfile) {
        val nebulaId = profile.nebulaId ?: return
        if (!isGeneratedNebulaId(nebulaId)) return

        val supabase = supabaseOrNull() ?: return
        val accessToken = supabase.auth.currentSessionOrNull()?.accessToken ?: return
        saveNebulaIdToUsersTable(profile.id, nebulaId, accessToken)
    }

    private suspend fun parseSessionFromAuthResponse(
        response: HttpResponse,
        action: String
    ): UserSession {
        val text: String = response.body()
        val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            ?: throw RuntimeException("$action 失败：服务端返回不可解析响应")
        return parseSessionFromJsonObject(obj, action)
    }

    private fun parseSessionFromJsonObject(
        obj: JsonObject?,
        action: String
    ): UserSession {
        if (obj == null) throw RuntimeException("$action 失败：服务端响应为空")
        return SupabaseAuthSessionContract.parse(obj, action)
    }

    private suspend fun supabaseErrorMessage(
        response: HttpResponse,
        fallbackPrefix: String
    ): String {
        val body = responseBodyOrEmpty(response)
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

    private suspend fun responseBodyOrEmpty(response: HttpResponse): String {
        return try {
            response.body()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("AuthRepository", "Supabase error response body could not be read", error)
            ""
        }
    }

}
