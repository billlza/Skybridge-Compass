package com.skybridge.compass.auth

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.jan.supabase.auth.status.SessionStatus
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.serialization.json.Json
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.io.IOException
import javax.inject.Inject
import com.skybridge.compass.shared.notifications.NotificationCenter
import com.skybridge.compass.shared.notifications.NotificationEvent
import com.skybridge.compass.shared.notifications.NotificationModule
import com.skybridge.compass.shared.notifications.NotificationSeverity
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.supabase.SupabaseConfigException
import com.skybridge.compass.supabase.SupabaseConfigLockedException
import com.skybridge.compass.supabase.SupabaseConfigMissingException
import com.skybridge.compass.supabase.SupabaseConfigValidationResult
import com.skybridge.compass.android.data.SupabaseSessionAuthorityMismatchException
import com.skybridge.compass.android.data.SupabaseSessionStoreCorruptionException
import com.skybridge.compass.android.i18n.resolveLocalizedText

enum class LoginMethod { EmailPassword, PhoneOtp, NebulaIdToken }

enum class ProfileSyncStatus {
    Idle,
    Syncing,
    Synced,
    Failed
}

data class AuthUiState(
    val isAuthenticated: Boolean = false,
    val isGuestMode: Boolean = false,
    val loading: Boolean = false,
    val errorMessage: String? = null,
    val infoMessage: String? = null,
    val otpSent: Boolean = false,
    val method: LoginMethod = LoginMethod.EmailPassword,
    val profileSyncStatus: ProfileSyncStatus = ProfileSyncStatus.Idle,
    val profileSyncMessage: String? = null
)

@OptIn(FlowPreview::class)
@HiltViewModel
class AuthViewModel @Inject constructor(
    private val repository: AuthRepository,
    httpClient: HttpClient,
    json: Json
) : ViewModel() {

    private fun t(zh: String, en: String, ja: String): String =
        resolveLocalizedText(zh, en, ja)

    /** Nebula OAuth 2.1 + PKCE launcher (mirrors iOS NebulaPublicClientOAuth). */
    private val nebulaOAuth = NebulaPublicClientOAuth(httpClient, json)

    /** Mirrors iOS `SkyBridgeServerConfig.hasNebulaConfiguration` for UI gating. */
    val isNebulaConfigured: Boolean get() = NebulaOAuthConfig.isConfigured

    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState
    private val guestMode = MutableStateFlow(false)

    init {
        // 监听会话状态变化，并对瞬时抖动进行消抑
        viewModelScope.launch {
            combine(
                repository.sessionStatus.map { it is SessionStatus.Authenticated }.distinctUntilChanged(),
                guestMode
            ) { authed, guest -> authed to guest }
                .distinctUntilChanged()
                .debounce(350) // 防止短时刷新导致 UI 闪断（同时避免“卡在登录页”观感）
                .collect { (authed, guest) ->
                    _uiState.update {
                        it.copy(
                            isAuthenticated = authed || guest,
                            isGuestMode = guest
                        )
                    }
                    if (authed) {
                        AccountStore.clearPrimaryAccount()
                        try {
                            val profile = repository.refreshCurrentAccountProfile()
                            if (profile != null) {
                                markProfileSyncSuccess()
                            } else {
                                recordProfileSyncFailure(
                                    SupabaseProfileException(
                                        kind = SupabaseProfileException.Kind.Unauthenticated,
                                        message = t(
                                            "当前会话没有可用的 Supabase access token。",
                                            "The current session has no usable Supabase access token.",
                                            "現在のセッションには使用可能な Supabase access token がありません。"
                                        )
                                    )
                                )
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            recordProfileSyncFailure(e)
                        }
                    } else if (!guest) {
                        AccountStore.clearPrimaryAccount()
                        _uiState.update {
                            it.copy(
                                profileSyncStatus = ProfileSyncStatus.Idle,
                                profileSyncMessage = null
                            )
                        }
                    }
                }
        }
        viewModelScope.launch {
            repository.credentialStateFailure.collect { failure ->
                failure ?: return@collect
                _uiState.update {
                    it.copy(
                        errorMessage = when (failure) {
                            is AuthCredentialStateFailure.SessionPersistenceFailed -> t(
                                "安全会话存储失败，当前登录已终止；请修复设备安全存储后重新登录。",
                                "Secure session storage failed, so the current sign-in was ended. Repair device secure storage and sign in again.",
                                "安全なセッション保存に失敗したため、現在のログインを終了しました。端末の安全なストレージを修復して再度ログインしてください。"
                            )
                            is AuthCredentialStateFailure.SessionCleanupFailed -> t(
                                "无法确认已清除本机登录凭据；请勿将此设备视为已安全退出。",
                                "Local sign-in credentials could not be confirmed as cleared. Do not treat this device as safely signed out.",
                                "端末上のログイン資格情報が消去されたことを確認できません。この端末を安全にログアウト済みとは見なさないでください。"
                            )
                        },
                        infoMessage = null
                    )
                }
            }
        }
    }

    /**
     * Try to restore persisted Supabase session after app restart.
     *
     * Typical scenario:
     * - Cloud config is locked at boot -> user taps "解锁云配置"
     * - After unlock, call this to import stored session and skip manual login
     */
    fun tryRestoreSession(forceRefresh: Boolean = true) {
        viewModelScope.launch {
            try {
                repository.loadSessionFromStorage(forceRefresh = forceRefresh)
                warmUpProfileAsync()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                AccountStore.clearPrimaryAccount()
                _uiState.update { it.copy(errorMessage = humanReadableError(error), infoMessage = null) }
            }
        }
    }

    fun setMethod(method: LoginMethod) {
        _uiState.update {
            it.copy(
                method = method,
                errorMessage = null,
                infoMessage = null,
                otpSent = false
            )
        }
    }

    fun login(email: String, password: String) {
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            var attempt = 0
            val maxAttempts = 1
            var lastError: Throwable? = null
            while (attempt < maxAttempts) {
                try {
                    repository.login(email, password)
                    warmUpProfileAsync()
                    NotificationCenter.post(
                        NotificationEvent(
                            title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                            message = t(
                                "您已成功登录 SkyBridge Compass",
                                "You have successfully signed in to SkyBridge Compass.",
                                "SkyBridge Compass へのログインに成功しました。"
                            ),
                            module = NotificationModule.AUTH,
                            severity = NotificationSeverity.SUCCESS
                        )
                    )
                    _uiState.update {
                        it.copy(
                            loading = false,
                            isGuestMode = false,
                            errorMessage = null,
                            infoMessage = null
                        )
                    }
                    lastError = null
                    break
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    lastError = e
                    if (isTransientNetworkError(e) && attempt < maxAttempts - 1) {
                        // 指数退避：1s, 2s
                        delay(1000L shl attempt)
                        attempt += 1
                        continue
                    }
                    break
                }
            }
            _uiState.update {
                it.copy(
                    loading = false,
                    infoMessage = null,
                    errorMessage = lastError?.let { err -> humanReadableError(err) }
                )
            }
        }
    }

    fun register(email: String, password: String) {
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                when (repository.signUp(email, password)) {
                    SignUpOutcome.Authenticated -> {
                        warmUpProfileAsync()
                        NotificationCenter.post(
                            NotificationEvent(
                                title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                                message = t(
                                    "注册并登录成功",
                                    "Sign-up completed and you are now signed in.",
                                    "登録が完了し、ログインしました。"
                                ),
                                module = NotificationModule.AUTH,
                                severity = NotificationSeverity.SUCCESS
                            )
                        )
                        _uiState.update {
                            it.copy(
                                loading = false,
                                infoMessage = t(
                                    "注册成功并已登录。",
                                    "Registration completed and you are now signed in.",
                                    "登録が完了し、ログインしました。"
                                ),
                                errorMessage = null
                            )
                        }
                    }
                    SignUpOutcome.EmailVerificationRequired -> {
                        _uiState.update {
                            it.copy(
                                loading = false,
                                errorMessage = null,
                                infoMessage = t(
                                    "注册成功！请先验证邮箱，再返回登录。",
                                    "Registration succeeded. Verify your email, then come back to sign in.",
                                    "登録が完了しました。メールを確認してから再度ログインしてください。"
                                )
                            )
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e), infoMessage = null) }
            }
        }
    }

    fun sendPhoneOtp(phone: String, createUser: Boolean = false) {
        viewModelScope.launch {
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                repository.sendPhoneOtp(phone, createUser)
                _uiState.update {
                    it.copy(
                        otpSent = true,
                        loading = false,
                        infoMessage = if (createUser) {
                            t(
                                "验证码已发送，请输入短信验证码完成注册。",
                                "Verification code sent. Enter the SMS code to finish sign-up.",
                                "確認コードを送信しました。SMS コードを入力して登録を完了してください。"
                            )
                        } else {
                            t(
                                "验证码已发送，请输入短信验证码继续登录。",
                                "Verification code sent. Enter the SMS code to continue signing in.",
                                "確認コードを送信しました。SMS コードを入力してログインを続けてください。"
                            )
                        }
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
            }
        }
    }

    fun verifyPhoneOtp(phone: String, code: String) {
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                repository.verifyPhoneOtpSms(phone, code)
                warmUpProfileAsync()
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                        message = t(
                            "手机号登录成功",
                            "Phone sign-in succeeded.",
                            "電話番号でのログインに成功しました。"
                        ),
                        module = NotificationModule.AUTH,
                        severity = NotificationSeverity.SUCCESS
                    )
                )
                _uiState.update {
                    it.copy(
                        loading = false,
                        isGuestMode = false,
                        errorMessage = null,
                        infoMessage = null,
                        otpSent = false
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
            }
        }
    }

    fun loginNebula(idToken: String, providerName: String = "nebula", nonce: String? = null) {
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                repository.loginWithNebulaIdToken(idToken, providerName, nonce)
                warmUpProfileAsync()
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                        message = t(
                            "Nebula 身份登录成功",
                            "Nebula identity sign-in succeeded.",
                            "Nebula ID でのログインに成功しました。"
                        ),
                        module = NotificationModule.AUTH,
                        severity = NotificationSeverity.SUCCESS
                    )
                )
                _uiState.update {
                    it.copy(
                        loading = false,
                        isGuestMode = false,
                        errorMessage = null
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
            }
        }
    }

    /**
     * Full Nebula sign-in / sign-up via the system browser (OAuth 2.1 + PKCE), mirroring
     * iOS `signInWithNebulaBrowser` / `registerWithNebulaBrowser`:
     *  1. Launch Chrome Custom Tabs to the Nebula authorize URL (PKCE S256).
     *  2. Capture the `skybridge://auth/nebula` redirect, exchange the code for an OIDC id_token.
     *  3. Hand the id_token to Supabase (`grant_type=id_token`, provider=nebula) to establish the session.
     *
     * The whole OAuth dance is driven from here (ViewModel) — never inline in the Composable.
     */
    fun loginNebulaOAuth(context: Context, register: Boolean = false) {
        if (!NebulaOAuthConfig.isConfigured) {
            _uiState.update {
                it.copy(
                    loading = false,
                    errorMessage = t(
                        "Nebula 未配置：请先提供 NEBULA_BASE_URL 与 NEBULA_CLIENT_ID。",
                        "Nebula is not configured. Provide NEBULA_BASE_URL and NEBULA_CLIENT_ID first.",
                        "Nebula が未設定です。先に NEBULA_BASE_URL と NEBULA_CLIENT_ID を設定してください。"
                    ),
                    infoMessage = null
                )
            }
            return
        }
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                val tokens = nebulaOAuth.authenticate(context, register)
                // Reuse the existing token-consumer; provider stays "nebula" for Supabase id_token grant.
                repository.loginWithNebulaIdToken(tokens.idToken, providerName = "nebula")
                warmUpProfileAsync()
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                        message = t(
                            "Nebula 身份登录成功",
                            "Nebula identity sign-in succeeded.",
                            "Nebula ID でのログインに成功しました。"
                        ),
                        module = NotificationModule.AUTH,
                        severity = NotificationSeverity.SUCCESS
                    )
                )
                _uiState.update {
                    it.copy(
                        loading = false,
                        isGuestMode = false,
                        errorMessage = null
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e), infoMessage = null) }
            }
        }
    }

    fun loginGoogle(idToken: String, nonce: String? = null) {
        viewModelScope.launch {
            guestMode.value = false
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                repository.loginWithGoogleIdToken(idToken, nonce)
                warmUpProfileAsync()
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("欢迎登录", "Welcome Back", "ログインへようこそ"),
                        message = t(
                            "Google 登录成功",
                            "Google sign-in succeeded.",
                            "Google ログインに成功しました。"
                        ),
                        module = NotificationModule.AUTH,
                        severity = NotificationSeverity.SUCCESS
                    )
                )
                _uiState.update {
                    it.copy(
                        loading = false,
                        isGuestMode = false,
                        errorMessage = null
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e), infoMessage = null) }
            }
        }
    }

    fun signInAsGuest() {
        viewModelScope.launch {
            guestMode.value = true
            AccountStore.setPrimaryAccount(
                AccountStore.AccountProfile(
                    id = "guest",
                    displayName = t("游客模式", "Guest Mode", "ゲストモード")
                )
            )
            _uiState.update {
                it.copy(
                    isAuthenticated = true,
                    isGuestMode = true,
                    loading = false,
                    errorMessage = null,
                    infoMessage = t(
                        "已进入游客模式（云同步与账号功能已禁用）。",
                        "Guest mode is active. Cloud sync and account features are disabled.",
                        "ゲストモードに入りました。クラウド同期とアカウント機能は無効です。"
                    ),
                    profileSyncStatus = ProfileSyncStatus.Idle,
                    profileSyncMessage = null
                )
            }
        }
    }

    fun logout() {
        viewModelScope.launch {
            try {
                guestMode.value = false
                val outcome = repository.logout()
                // 立即反映登出，避免因 debounce 延迟导致体验不一致
                val remoteWarning = when (outcome) {
                    is SignOutOutcome.LocalOnlyAfterRemoteFailure -> t(
                        "已在此设备安全退出；服务端会话撤销失败（${outcome.reason}），其访问令牌将在过期后失效。",
                        "Signed out safely on this device. Server-side revocation failed (${outcome.reason}); its access token remains valid until expiry.",
                        "この端末では安全にログアウトしました。サーバー側の失効に失敗しました（${outcome.reason}）。アクセストークンは有効期限まで有効です。"
                    )
                    is SignOutOutcome.LocalOnlyAfterClientCleanupFailure -> t(
                        "本机持久化登录已清除，但认证客户端清理失败（${outcome.reason}）；请完全关闭应用后再继续。",
                        "Persisted sign-in was cleared, but the auth client could not be cleaned up (${outcome.reason}). Fully close the app before continuing.",
                        "保存されたログイン情報は消去されましたが、認証クライアントのクリーンアップに失敗しました（${outcome.reason}）。続行する前にアプリを完全に終了してください。"
                    )
                    is SignOutOutcome.LocalOnlyAfterRemoteAndClientCleanupFailure -> t(
                        "本机持久化登录已清除，但服务端撤销失败（${outcome.remoteReason}），且认证客户端清理失败（${outcome.clientCleanupReason}）；请完全关闭应用，远端访问令牌仍可能有效至过期。",
                        "Persisted sign-in was cleared, but server revocation failed (${outcome.remoteReason}) and auth-client cleanup failed (${outcome.clientCleanupReason}). Fully close the app; the remote access token may remain valid until expiry.",
                        "保存されたログイン情報は消去されましたが、サーバー側の失効（${outcome.remoteReason}）と認証クライアントのクリーンアップ（${outcome.clientCleanupReason}）の両方に失敗しました。アプリを完全に終了してください。リモートのアクセストークンは有効期限まで有効な可能性があります。"
                    )
                    SignOutOutcome.LocalOnly,
                    SignOutOutcome.RevokedRemotely -> null
                }
                _uiState.update {
                    it.copy(
                        isAuthenticated = false,
                        isGuestMode = false,
                        errorMessage = null,
                        infoMessage = remoteWarning
                    )
                }
                _uiState.update {
                    it.copy(
                        profileSyncStatus = ProfileSyncStatus.Idle,
                        profileSyncMessage = null
                    )
                }
                // 清空主账号
                AccountStore.clearPrimaryAccount()
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("已登出", "Signed Out", "ログアウト済み"),
                        message = remoteWarning ?: t(
                            "您已退出 SkyBridge Compass",
                            "You have signed out of SkyBridge Compass.",
                            "SkyBridge Compass からログアウトしました。"
                        ),
                        module = NotificationModule.AUTH,
                        severity = if (remoteWarning == null) {
                            NotificationSeverity.INFO
                        } else {
                            NotificationSeverity.WARNING
                        }
                    )
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e), infoMessage = null) }
                NotificationCenter.post(
                    NotificationEvent(
                        title = t("登出失败", "Sign Out Failed", "ログアウト失敗"),
                        message = humanReadableError(e),
                        module = NotificationModule.AUTH,
                        severity = NotificationSeverity.ERROR
                    )
                )
            }
        }
    }

    fun resetPassword(email: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(loading = true, errorMessage = null, infoMessage = null) }
            try {
                repository.resetPassword(email)
                _uiState.update {
                    it.copy(
                        loading = false,
                        errorMessage = null,
                        infoMessage = t(
                            "重置密码邮件已发送，请检查邮箱。",
                            "Password reset email sent. Please check your inbox.",
                            "パスワード再設定メールを送信しました。受信箱をご確認ください。"
                        )
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
            }
        }
    }

    suspend fun validateSupabaseConfiguration(): SupabaseConfigValidationResult {
        return repository.validateSupabaseConfiguration()
    }

    fun refreshProfile() {
        warmUpProfileAsync()
    }

    private fun isTransientNetworkError(e: Throwable): Boolean =
        e is HttpRequestTimeoutException ||
        e is TimeoutCancellationException ||
        e is IOException

    private fun warmUpProfileAsync() {
        viewModelScope.launch {
            if (!guestMode.value) {
                AccountStore.clearPrimaryAccount()
            }
            _uiState.update {
                val previousProfileMessage = it.profileSyncMessage
                it.copy(
                    profileSyncStatus = ProfileSyncStatus.Syncing,
                    profileSyncMessage = null,
                    infoMessage = if (previousProfileMessage != null && it.infoMessage == previousProfileMessage) {
                        null
                    } else {
                        it.infoMessage
                    }
                )
            }
            try {
                val profile = withTimeout(8_000L) { repository.refreshCurrentAccountProfile() }
                if (profile != null) {
                    markProfileSyncSuccess()
                } else {
                    recordProfileSyncFailure(
                        SupabaseProfileException(
                            kind = SupabaseProfileException.Kind.Unauthenticated,
                            message = t(
                                "当前会话没有可用的 Supabase access token。",
                                "The current session has no usable Supabase access token.",
                                "現在のセッションには使用可能な Supabase access token がありません。"
                            )
                        )
                    )
                }
            } catch (e: TimeoutCancellationException) {
                recordProfileSyncFailure(e)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                recordProfileSyncFailure(e)
            }
        }
    }

    private fun markProfileSyncSuccess() {
        _uiState.update {
            val previousProfileMessage = it.profileSyncMessage
            it.copy(
                profileSyncStatus = ProfileSyncStatus.Synced,
                profileSyncMessage = null,
                infoMessage = if (previousProfileMessage != null && it.infoMessage == previousProfileMessage) {
                    null
                } else {
                    it.infoMessage
                }
            )
        }
    }

    private fun recordProfileSyncFailure(error: Throwable) {
        if (!guestMode.value) {
            AccountStore.clearPrimaryAccount()
        }
        val detail = humanReadableError(error)
        val message = t(
            "登录成功，但云端资料同步失败：$detail",
            "Signed in, but cloud profile sync failed: $detail",
            "ログインしましたが、クラウドプロフィール同期に失敗しました: $detail"
        )
        _uiState.update { state ->
            val updated = state.copy(
                profileSyncStatus = ProfileSyncStatus.Failed,
                profileSyncMessage = message
            )
            if (updated.errorMessage != null) updated else updated.copy(infoMessage = message)
        }
        NotificationCenter.post(
            NotificationEvent(
                title = t("资料同步失败", "Profile Sync Failed", "プロフィール同期失敗"),
                message = message,
                module = NotificationModule.AUTH,
                severity = NotificationSeverity.WARNING
            )
        )
    }

    private fun humanReadableError(e: Throwable): String {
        return when (e) {
            is SupabaseProfileException -> when (e.kind) {
                SupabaseProfileException.Kind.Unauthenticated -> t(
                    "未找到有效登录会话，请重新登录。",
                    "No valid sign-in session was found. Sign in again.",
                    "有効なログインセッションが見つかりません。再度ログインしてください。"
                )
                SupabaseProfileException.Kind.HttpStatus -> e.message ?: t(
                    "云端资料请求失败。",
                    "Cloud profile request failed.",
                    "クラウドプロフィールリクエストに失敗しました。"
                )
                SupabaseProfileException.Kind.InvalidResponse -> e.message ?: t(
                    "云端资料返回格式无效。",
                    "Cloud profile returned an invalid response.",
                    "クラウドプロフィールの応答形式が無効です。"
                )
                SupabaseProfileException.Kind.SessionUserMismatch -> t(
                    "当前会话与云端用户不一致，请重新登录。",
                    "The local session does not match the cloud user. Sign in again.",
                    "ローカルセッションとクラウドユーザーが一致しません。再度ログインしてください。"
                )
            }
            is SupabaseConfigMissingException -> t(
                "未配置 Supabase，请在设置中配置后再试。",
                "Supabase is not configured. Configure it in Settings and try again.",
                "Supabase が未設定です。設定で構成してから再試行してください。"
            )
            is SupabaseConfigLockedException -> t(
                "Supabase 配置已锁定，请先在设置中解锁。",
                "Supabase configuration is locked. Unlock it in Settings first.",
                "Supabase 設定はロックされています。先に設定画面でロック解除してください。"
            )
            is SupabaseConfigException -> e.message ?: t(
                "Supabase 配置异常",
                "Supabase configuration error.",
                "Supabase 設定エラーです。"
            )
            is SupabaseSessionAuthorityMismatchException -> if (e.suppressed.isNotEmpty()) {
                t(
                    "保存的登录会话属于旧版或另一个 Supabase 项目，但无法确认已从本机清除；请先修复设备安全存储。",
                    "The saved session belongs to a legacy or different Supabase project, but could not be confirmed as cleared. Repair device secure storage first.",
                    "保存されたセッションは旧形式または別の Supabase プロジェクトに属し、端末から消去されたことを確認できません。先に端末の安全なストレージを修復してください。"
                )
            } else {
                t(
                    "保存的登录会话属于旧版或另一个 Supabase 项目，请重新登录。",
                    "The saved session belongs to a legacy or different Supabase project. Sign in again.",
                    "保存されたセッションは旧形式または別の Supabase プロジェクトのものです。再度ログインしてください。"
                )
            }
            is SupabaseSessionStoreCorruptionException -> if (e.suppressed.isNotEmpty()) {
                t(
                    "保存的登录会话已损坏，但无法确认已从本机清除；请先修复设备安全存储。",
                    "The saved sign-in session is corrupted, but could not be confirmed as cleared. Repair device secure storage first.",
                    "保存されたログインセッションは破損しており、端末から消去されたことを確認できません。先に端末の安全なストレージを修復してください。"
                )
            } else {
                t(
                    "保存的登录会话已损坏并被清除，请重新登录。",
                    "The saved sign-in session was corrupted and has been cleared. Sign in again.",
                    "保存されたログインセッションが破損していたため消去しました。再度ログインしてください。"
                )
            }
            is NebulaIdentityException -> t(
                "账号身份生成失败，请稍后重试。",
                "Account identity generation failed. Please try again later.",
                "アカウント ID の生成に失敗しました。しばらくしてからもう一度お試しください。"
            )
            is HttpRequestTimeoutException, is TimeoutCancellationException -> t(
                "网络请求超时，请检查网络或稍后重试。",
                "The network request timed out. Check your connection and try again later.",
                "ネットワークリクエストがタイムアウトしました。接続を確認して、後でもう一度お試しください。"
            )
            is IOException -> t(
                "网络连接异常，请检查网络或代理设置。",
                "A network connection error occurred. Check your network or proxy settings.",
                "ネットワーク接続エラーが発生しました。ネットワークまたはプロキシ設定を確認してください。"
            )
            else -> e.message ?: t(
                "请求失败，请稍后重试。",
                "The request failed. Please try again later.",
                "リクエストに失敗しました。しばらくしてからもう一度お試しください。"
            )
        }
    }
}
