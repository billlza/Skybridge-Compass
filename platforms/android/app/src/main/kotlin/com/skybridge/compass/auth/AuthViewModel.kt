package com.skybridge.compass.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.jan.supabase.auth.status.SessionStatus
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.FlowPreview
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
import kotlinx.coroutines.withTimeoutOrNull
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
import com.skybridge.compass.android.i18n.resolveLocalizedText

enum class LoginMethod { EmailPassword, PhoneOtp, NebulaIdToken }

data class AuthUiState(
    val isAuthenticated: Boolean = false,
    val isGuestMode: Boolean = false,
    val loading: Boolean = false,
    val errorMessage: String? = null,
    val infoMessage: String? = null,
    val otpSent: Boolean = false,
    val method: LoginMethod = LoginMethod.EmailPassword
)

@OptIn(FlowPreview::class)
@HiltViewModel
class AuthViewModel @Inject constructor(
    private val repository: AuthRepository
) : ViewModel() {

    private fun t(zh: String, en: String, ja: String): String =
        resolveLocalizedText(zh, en, ja)

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
                        try {
                            repository.getCurrentUserProfile()?.let { AccountStore.setPrimaryAccount(it) }
                        } catch (_: Throwable) {
                            /* ignore */
                        }
                    } else if (!guest) {
                        try { AccountStore.clearPrimaryAccount() } catch (_: Throwable) {}
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
            runCatching {
                repository.loadSessionFromStorage(forceRefresh = forceRefresh)
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
                            isAuthenticated = true,
                            isGuestMode = false,
                            errorMessage = null,
                            infoMessage = null
                        )
                    }
                    lastError = null
                    break
                } catch (e: Throwable) {
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
                    isAuthenticated = it.isAuthenticated || lastError == null,
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
            } catch (e: Throwable) {
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
            } catch (e: Throwable) {
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
                        isAuthenticated = true,
                        isGuestMode = false,
                        errorMessage = null,
                        infoMessage = null,
                        otpSent = false
                    )
                }
            } catch (e: Throwable) {
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
                        isAuthenticated = true,
                        isGuestMode = false,
                        errorMessage = null
                    )
                }
            } catch (e: Throwable) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
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
                        isAuthenticated = true,
                        isGuestMode = false,
                        errorMessage = null
                    )
                }
            } catch (e: Throwable) {
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
                    )
                )
            }
        }
    }

    fun logout() {
        viewModelScope.launch {
            try {
                guestMode.value = false
                repository.logout()
                // 立即反映登出，避免因 debounce 延迟导致体验不一致
                _uiState.update { it.copy(isAuthenticated = false, isGuestMode = false, infoMessage = null) }
                // 清空主账号
                AccountStore.clearPrimaryAccount()
            NotificationCenter.post(
                NotificationEvent(
                    title = t("已登出", "Signed Out", "ログアウト済み"),
                    message = t(
                        "您已退出 SkyBridge Compass",
                        "You have signed out of SkyBridge Compass.",
                        "SkyBridge Compass からログアウトしました。"
                    ),
                    module = NotificationModule.AUTH,
                    severity = NotificationSeverity.INFO
                )
            )
            } catch (_: Throwable) {
                // 忽略登出异常，保持幂等
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
            } catch (e: Throwable) {
                _uiState.update { it.copy(loading = false, errorMessage = humanReadableError(e)) }
            }
        }
    }

    suspend fun validateSupabaseConfiguration(): SupabaseConfigValidationResult {
        return repository.validateSupabaseConfiguration()
    }

    private fun isTransientNetworkError(e: Throwable): Boolean =
        e is HttpRequestTimeoutException ||
        e is TimeoutCancellationException ||
        e is IOException

    private fun warmUpProfileAsync() {
        viewModelScope.launch {
            val profile = withTimeoutOrNull(8_000L) { repository.getCurrentUserProfile() }
            profile?.let { AccountStore.setPrimaryAccount(it) }
        }
    }

    private fun humanReadableError(e: Throwable): String {
        return when (e) {
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
