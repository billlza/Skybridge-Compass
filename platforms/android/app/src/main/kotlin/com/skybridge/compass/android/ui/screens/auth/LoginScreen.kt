@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.ui.screens.auth

import android.app.Activity
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.biometric.BiometricManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.util.PatternsCompat
import androidx.fragment.app.FragmentActivity
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.skybridge.compass.android.ui.theme.IOSParityTokens
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_JA
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.data.APP_LANGUAGE_ZH
import com.skybridge.compass.android.data.SupabaseConfigState
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.android.i18n.resolveLanguageLabel
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.auth.AuthUiState
import com.skybridge.compass.auth.AuthViewModel
import com.skybridge.compass.auth.LoginMethod
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(
    modifier: Modifier = Modifier,
    viewModel: AuthViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val uiState: AuthUiState by viewModel.uiState.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = context as? FragmentActivity
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    val scope = rememberCoroutineScope()
    val supabaseState by SupabaseConfigStore.observeState(context)
        .collectAsState(initial = SupabaseConfigState.Missing)
    val googleClientId = BuildConfig.GOOGLE_WEB_CLIENT_ID.trim()
    val googleConfigured = googleClientId.isNotBlank()

    var email by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var phone by rememberSaveable { mutableStateOf("") }
    var phoneCode by rememberSaveable { mutableStateOf("") }
    var isRegistering by rememberSaveable { mutableStateOf(false) }
    var restoreAttempted by rememberSaveable { mutableStateOf(false) }
    var localError by remember { mutableStateOf<String?>(null) }
    var localInfo by remember { mutableStateOf<String?>(null) }
    var supabaseMessage by remember { mutableStateOf<String?>(null) }
    var supabaseMessageIsError by remember { mutableStateOf(false) }

    val authCode = remember(context) {
        BiometricManager.from(context).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        )
    }

    fun showError(message: String) {
        localInfo = null
        localError = message
    }

    fun showInfo(message: String) {
        localError = null
        localInfo = message
    }

    fun openCredentialSettings() {
        runCatching {
            val intent = Intent(Settings.ACTION_BIOMETRIC_ENROLL).apply {
                putExtra(
                    Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                    BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
                )
            }
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    val ensureCloudReady: (() -> Unit) -> Unit = { action ->
        when (supabaseState) {
            is SupabaseConfigState.Available -> action()
            SupabaseConfigState.Missing -> {
                if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                    supabaseMessage = t(
                        "请先启用锁屏/PIN/生物识别，再启用云配置。",
                        "Enable screen lock, PIN, or biometrics before enabling cloud configuration.",
                        "クラウド設定を有効にする前に、画面ロック、PIN、または生体認証を有効にしてください。"
                    )
                    supabaseMessageIsError = true
                    openCredentialSettings()
                } else if (activity == null) {
                    supabaseMessage = t(
                        "无法获取 Activity，无法启用云配置。",
                        "Unable to access the Activity, so cloud configuration cannot be enabled.",
                        "Activity を取得できないため、クラウド設定を有効にできません。"
                    )
                    supabaseMessageIsError = true
                } else {
                    SupabaseConfigStore.provisionManagedDefaults(activity) { result ->
                        result.onSuccess {
                            supabaseMessage = t("云配置已启用。", "Cloud configuration is enabled.", "クラウド設定を有効にしました。")
                            supabaseMessageIsError = false
                            action()
                        }.onFailure { err ->
                            supabaseMessage = err.message ?: t(
                                "启用云配置失败",
                                "Failed to enable cloud configuration.",
                                "クラウド設定の有効化に失敗しました。"
                            )
                            supabaseMessageIsError = true
                        }
                    }
                }
            }
            SupabaseConfigState.Locked -> {
                if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                    supabaseMessage = t(
                        "请先启用锁屏/PIN/生物识别，再解锁云配置。",
                        "Enable screen lock, PIN, or biometrics before unlocking cloud configuration.",
                        "クラウド設定をロック解除する前に、画面ロック、PIN、または生体認証を有効にしてください。"
                    )
                    supabaseMessageIsError = true
                    openCredentialSettings()
                } else if (activity == null) {
                    supabaseMessage = t(
                        "无法获取 Activity，无法解锁云配置。",
                        "Unable to access the Activity, so cloud configuration cannot be unlocked.",
                        "Activity を取得できないため、クラウド設定をロック解除できません。"
                    )
                    supabaseMessageIsError = true
                } else {
                    SupabaseConfigStore.unlockWithBiometrics(activity) { result ->
                        result.onSuccess {
                            supabaseMessage = t("云配置已解锁。", "Cloud configuration is unlocked.", "クラウド設定のロックを解除しました。")
                            supabaseMessageIsError = false
                            action()
                        }.onFailure { err ->
                            supabaseMessage = err.message ?: t(
                                "解锁云配置失败",
                                "Failed to unlock cloud configuration.",
                                "クラウド設定のロック解除に失敗しました。"
                            )
                            supabaseMessageIsError = true
                        }
                    }
                }
            }
        }
    }

    val googleLoginLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode != Activity.RESULT_OK) {
                showError(t("Google 登录已取消。", "Google sign-in was cancelled.", "Google ログインはキャンセルされました。"))
                return@rememberLauncherForActivityResult
            }
            val data = result.data
            if (data == null) {
                showError(
                    t(
                        "Google 登录失败：未返回登录结果。",
                        "Google sign-in failed: no sign-in result was returned.",
                        "Google ログインに失敗しました：ログイン結果が返されませんでした。"
                    )
                )
                return@rememberLauncherForActivityResult
            }
            try {
                val task = GoogleSignIn.getSignedInAccountFromIntent(data)
                val account = task.getResult(ApiException::class.java)
                val idToken = account.idToken
                if (idToken.isNullOrBlank()) {
                    showError(
                        t(
                            "Google 登录失败：未获取到 ID Token，请检查 Google OAuth 配置。",
                            "Google sign-in failed: no ID token was returned. Check the Google OAuth configuration.",
                            "Google ログインに失敗しました：ID トークンを取得できませんでした。Google OAuth 設定を確認してください。"
                        )
                    )
                } else {
                    localError = null
                    localInfo = null
                    viewModel.loginGoogle(idToken)
                }
            } catch (e: ApiException) {
                showError(
                    t(
                        "Google 登录失败（${e.statusCode}）：${e.localizedMessage ?: "请重试"}",
                        "Google sign-in failed (${e.statusCode}): ${e.localizedMessage ?: "Please try again."}",
                        "Google ログインに失敗しました（${e.statusCode}）：${e.localizedMessage ?: "再試行してください。"}"
                    )
                )
            } catch (e: Throwable) {
                showError(
                    t(
                        "Google 登录失败：${e.message ?: "未知错误"}",
                        "Google sign-in failed: ${e.message ?: "Unknown error"}",
                        "Google ログインに失敗しました：${e.message ?: "不明なエラー"}"
                    )
                )
            }
        }

    fun startGoogleSignIn() {
        if (!googleConfigured) {
            showError(
                t(
                    "未配置 GOOGLE_WEB_CLIENT_ID，无法使用 Google 登录。",
                    "GOOGLE_WEB_CLIENT_ID is not configured, so Google sign-in is unavailable.",
                    "GOOGLE_WEB_CLIENT_ID が設定されていないため、Google ログインは利用できません。"
                )
            )
            return
        }
        if (activity == null) {
            showError(
                t(
                    "无法获取 Activity，无法启动 Google 登录。",
                    "Unable to access the Activity, so Google sign-in cannot start.",
                    "Activity を取得できないため、Google ログインを開始できません。"
                )
            )
            return
        }
        val gso = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestIdToken(googleClientId)
            .build()
        val client = GoogleSignIn.getClient(activity, gso)
        googleLoginLauncher.launch(client.signInIntent)
    }

    val isEmailValid = remember(email) { PatternsCompat.EMAIL_ADDRESS.matcher(email.trim()).matches() }
    val isPasswordValid = remember(password) { password.length >= 6 }
    val normalizedPhone = remember(phone) {
        phone.trim()
            .replace(" ", "")
            .replace("-", "")
            .replace("(", "")
            .replace(")", "")
    }
    val isPhoneValid = remember(normalizedPhone) {
        Regex("^\\+?[0-9]{7,15}$").matches(normalizedPhone)
    }
    val isPhoneCodeValid = remember(phoneCode) { phoneCode.trim().length >= 4 }

    LaunchedEffect(supabaseState, appSettings.rememberLogin, uiState.isAuthenticated) {
        val cloudReady = supabaseState is SupabaseConfigState.Available
        if (!appSettings.rememberLogin || uiState.isAuthenticated) {
            restoreAttempted = false
            return@LaunchedEffect
        }
        if (cloudReady && !restoreAttempted) {
            restoreAttempted = true
            viewModel.tryRestoreSession(forceRefresh = true)
        }
    }

    val errorMessage = localError ?: uiState.errorMessage
    val infoMessage = localInfo ?: uiState.infoMessage

    val textFieldColors = TextFieldDefaults.colors(
        focusedContainerColor = Color.White.copy(alpha = 0.1f),
        unfocusedContainerColor = Color.White.copy(alpha = 0.1f),
        disabledContainerColor = Color.White.copy(alpha = 0.06f),
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
        focusedTextColor = Color.White,
        unfocusedTextColor = Color.White,
        focusedPlaceholderColor = Color.White.copy(alpha = 0.72f),
        unfocusedPlaceholderColor = Color.White.copy(alpha = 0.72f),
        focusedLeadingIconColor = Color.White.copy(alpha = 0.72f),
        unfocusedLeadingIconColor = Color.White.copy(alpha = 0.72f),
        cursorColor = IOSParityTokens.ColorTokens.CyanAccent
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        Color(0xFF0E1026),
                        Color(0xFF171433),
                        Color(0xFF0A1D38)
                    )
                )
            )
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(top = 44.dp, bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            androidx.compose.material3.Icon(
                imageVector = Icons.Default.Public,
                contentDescription = null,
                tint = IOSParityTokens.ColorTokens.CyanAccent,
                modifier = Modifier.size(80.dp)
            )
            Spacer(modifier = Modifier.height(14.dp))
            Text(
                text = "SkyBridge Compass",
                style = MaterialTheme.typography.headlineMedium,
                color = Color.White,
                fontWeight = FontWeight.Bold
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = t(
                    "跨平台设备管理与远程控制",
                    "Cross-platform device management and remote control",
                    "クロスプラットフォームのデバイス管理とリモート操作"
                ),
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.68f)
            )

            Spacer(modifier = Modifier.height(16.dp))
            LoginPreferenceCard {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text(
                        text = t("登录方式", "Sign-in Method", "ログイン方法"),
                        style = MaterialTheme.typography.titleSmall,
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        LoginLanguageChip(
                            label = t("邮箱", "Email", "メール"),
                            selected = uiState.method == LoginMethod.EmailPassword,
                            onClick = {
                                localError = null
                                localInfo = null
                                viewModel.setMethod(LoginMethod.EmailPassword)
                            }
                        )
                        LoginLanguageChip(
                            label = t("短信", "SMS", "SMS"),
                            selected = uiState.method == LoginMethod.PhoneOtp,
                            onClick = {
                                localError = null
                                localInfo = null
                                viewModel.setMethod(LoginMethod.PhoneOtp)
                            }
                        )
                    }
                    if (uiState.method == LoginMethod.PhoneOtp) {
                        Text(
                            text = if (isRegistering) {
                                t(
                                    "短信验证码注册会在需要时自动创建新账号。",
                                    "SMS sign-up will create a new account when needed.",
                                    "SMS 登録では必要に応じて新しいアカウントを作成します。"
                                )
                            } else {
                                t(
                                    "短信验证码登录会使用你当前的手机号账号。",
                                    "SMS sign-in uses your existing phone-based account.",
                                    "SMS ログインでは既存の電話番号アカウントを使用します。"
                                )
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.68f)
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))
            LoginPreferenceCard {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text(
                        text = t("语言", "Language", "言語"),
                        style = MaterialTheme.typography.titleSmall,
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold
                    )
                    LoginLanguageSelector(
                        selectedLanguage = appSettings.appLanguage,
                        onLanguageSelected = { language ->
                            scope.launch { AppSettingsStore.setAppLanguage(context, language) }
                        }
                    )
                }
            }

            Spacer(modifier = Modifier.height(28.dp))

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                if (uiState.method == LoginMethod.EmailPassword) {
                    TextField(
                        value = email,
                        onValueChange = {
                            email = it
                            localError = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { androidx.compose.material3.Icon(Icons.Default.Email, null) },
                        placeholder = { Text(t("邮箱", "Email", "メールアドレス")) },
                        shape = RoundedCornerShape(12.dp),
                        colors = textFieldColors
                    )
                    TextField(
                        value = password,
                        onValueChange = {
                            password = it
                            localError = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { androidx.compose.material3.Icon(Icons.Default.Lock, null) },
                        placeholder = { Text(t("密码", "Password", "パスワード")) },
                        shape = RoundedCornerShape(12.dp),
                        visualTransformation = PasswordVisualTransformation(),
                        colors = textFieldColors
                    )
                } else {
                    TextField(
                        value = phone,
                        onValueChange = {
                            phone = it
                            localError = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { androidx.compose.material3.Icon(Icons.Default.Phone, null) },
                        placeholder = { Text(t("手机号", "Phone Number", "電話番号")) },
                        shape = RoundedCornerShape(12.dp),
                        colors = textFieldColors
                    )
                    TextField(
                        value = phoneCode,
                        onValueChange = {
                            phoneCode = it
                            localError = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { androidx.compose.material3.Icon(Icons.Default.Lock, null) },
                        placeholder = {
                            Text(
                                if (uiState.otpSent) {
                                    t("短信验证码", "SMS Code", "SMS コード")
                                } else {
                                    t("先发送验证码", "Send code first", "先にコードを送信")
                                }
                            )
                        },
                        shape = RoundedCornerShape(12.dp),
                        colors = textFieldColors
                    )
                }
            }

            Spacer(modifier = Modifier.height(14.dp))
            LoginPreferenceCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = t("下次自动登录", "Auto sign in next time", "次回から自動ログイン"),
                            style = MaterialTheme.typography.titleSmall,
                            color = Color.White,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = t(
                                "登录成功后记住本机，下次打开应用自动恢复登录状态",
                                "After a successful sign-in, remember this device and restore your session automatically next time",
                                "ログイン成功後、この端末を記憶し、次回は自動でログイン状態を復元します"
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.68f)
                        )
                    }
                    Switch(
                        checked = appSettings.rememberLogin,
                        onCheckedChange = { enabled ->
                            scope.launch { AppSettingsStore.setRememberLogin(context, enabled) }
                        }
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            val canSubmit = when (uiState.method) {
                LoginMethod.EmailPassword -> !uiState.loading && isEmailValid && isPasswordValid
                LoginMethod.PhoneOtp -> !uiState.loading && isPhoneValid && (!uiState.otpSent || isPhoneCodeValid)
                LoginMethod.NebulaIdToken -> false
            }
            Button(
                onClick = {
                    localError = null
                    localInfo = null
                    ensureCloudReady {
                        when (uiState.method) {
                            LoginMethod.EmailPassword -> {
                                if (isRegistering) {
                                    viewModel.register(email.trim(), password)
                                } else {
                                    viewModel.login(email.trim(), password)
                                }
                            }
                            LoginMethod.PhoneOtp -> {
                                if (uiState.otpSent) {
                                    viewModel.verifyPhoneOtp(normalizedPhone, phoneCode.trim())
                                } else {
                                    viewModel.sendPhoneOtp(normalizedPhone, createUser = isRegistering)
                                }
                            }
                            LoginMethod.NebulaIdToken -> Unit
                        }
                    }
                },
                enabled = canSubmit,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(12.dp),
                contentPadding = PaddingValues(0.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent
                )
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .alpha(if (canSubmit) 1f else 0.6f)
                        .background(
                            Brush.horizontalGradient(
                                listOf(
                                    IOSParityTokens.ColorTokens.CyanAccent,
                                    IOSParityTokens.ColorTokens.PurpleAccent
                                )
                            ),
                            RoundedCornerShape(12.dp)
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    if (uiState.loading) {
                        CircularProgressIndicator(
                            color = Color.White,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(20.dp)
                        )
                    } else {
                        Text(
                            text = when (uiState.method) {
                                LoginMethod.EmailPassword -> {
                                    if (isRegistering) {
                                        t("注册", "Sign Up", "登録")
                                    } else {
                                        t("登录", "Sign In", "ログイン")
                                    }
                                }
                                LoginMethod.PhoneOtp -> {
                                    if (uiState.otpSent) {
                                        if (isRegistering) {
                                            t("验证并注册", "Verify & Sign Up", "確認して登録")
                                        } else {
                                            t("验证并登录", "Verify & Sign In", "確認してログイン")
                                        }
                                    } else {
                                        if (isRegistering) {
                                            t("发送注册验证码", "Send Sign-up Code", "登録コードを送信")
                                        } else {
                                            t("发送登录验证码", "Send Sign-in Code", "ログインコードを送信")
                                        }
                                    }
                                }
                                LoginMethod.NebulaIdToken -> t("登录", "Sign In", "ログイン")
                            },
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))
            TextButton(
                onClick = {
                    isRegistering = !isRegistering
                    localError = null
                    localInfo = null
                    if (uiState.method == LoginMethod.PhoneOtp) {
                        phoneCode = ""
                        viewModel.setMethod(LoginMethod.PhoneOtp)
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = if (isRegistering) {
                        t("已有账号？登录", "Already have an account? Sign in", "アカウントをお持ちですか？ ログイン")
                    } else {
                        t("没有账号？注册", "No account yet? Sign up", "アカウントがありませんか？ 登録")
                    },
                    color = IOSParityTokens.ColorTokens.CyanAccent
                )
            }

            if (uiState.method == LoginMethod.PhoneOtp && uiState.otpSent) {
                TextButton(
                    enabled = !uiState.loading && isPhoneValid,
                    onClick = {
                        localError = null
                        localInfo = null
                        ensureCloudReady {
                            viewModel.sendPhoneOtp(normalizedPhone, createUser = isRegistering)
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        t("重新发送验证码", "Resend Code", "コードを再送"),
                        color = IOSParityTokens.ColorTokens.CyanAccent
                    )
                }
            }

            if (!isRegistering && uiState.method == LoginMethod.EmailPassword) {
                TextButton(
                    enabled = !uiState.loading && isEmailValid,
                    onClick = {
                        localError = null
                        localInfo = null
                        ensureCloudReady {
                            viewModel.resetPassword(email.trim())
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(t("忘记密码", "Forgot Password", "パスワードを忘れた場合"), color = IOSParityTokens.ColorTokens.CyanAccent)
                }
            }

            Spacer(modifier = Modifier.height(18.dp))
            AuthDivider()
            Spacer(modifier = Modifier.height(18.dp))

            // Nebula 安全登录（OAuth 2.1 + PKCE，系统浏览器）— iOS parity (Apple+Nebula → Google+Nebula on Android).
            val nebulaConfigured = viewModel.isNebulaConfigured
            Button(
                onClick = {
                    localError = null
                    localInfo = null
                    ensureCloudReady { viewModel.loginNebulaOAuth(context, register = isRegistering) }
                },
                enabled = !uiState.loading && nebulaConfigured,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                contentPadding = PaddingValues(0.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent
                )
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .alpha(if (nebulaConfigured) 1f else 0.55f)
                        .background(
                            // iOS uses an indigo→blue gradient for Nebula; SecondaryIndigo/PrimaryBlue
                            // are the shared iOS-parity tokens for exactly .indigo / .blue.
                            Brush.horizontalGradient(
                                listOf(
                                    IOSParityTokens.ColorTokens.SecondaryIndigo,
                                    IOSParityTokens.ColorTokens.PrimaryBlue
                                )
                            ),
                            RoundedCornerShape(14.dp)
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        androidx.compose.material3.Icon(
                            imageVector = Icons.Default.Public,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(20.dp)
                        )
                        Text(
                            text = if (isRegistering) {
                                t("使用 Nebula 安全注册", "Sign up with Nebula", "Nebula で安全に登録")
                            } else {
                                t("使用 Nebula 安全登录", "Continue with Nebula", "Nebula で続行")
                            },
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White
                        )
                    }
                }
            }

            Text(
                text = if (nebulaConfigured) {
                    t(
                        "Nebula 登录将在系统浏览器中完成，授权与二次验证均不在 App 内处理。",
                        "Nebula sign-in completes in your system browser; authorization and MFA stay outside the app.",
                        "Nebula ログインはシステムブラウザーで完了します。認可と二段階認証はアプリ内では処理されません。"
                    )
                } else {
                    t(
                        "Nebula 配置缺失：请先提供 NEBULA_BASE_URL / NEBULA_CLIENT_ID。",
                        "Nebula configuration is missing: provide NEBULA_BASE_URL / NEBULA_CLIENT_ID first.",
                        "Nebula 設定がありません：先に NEBULA_BASE_URL / NEBULA_CLIENT_ID を設定してください。"
                    )
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (nebulaConfigured) Color.White.copy(alpha = 0.68f) else IOSParityTokens.ColorTokens.WarningOrange,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
            )

            Spacer(modifier = Modifier.height(10.dp))

            OutlinedButton(
                onClick = {
                    localError = null
                    localInfo = null
                    ensureCloudReady { startGoogleSignIn() }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = Color.White.copy(alpha = 0.1f),
                    contentColor = Color.White
                ),
                border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.3f))
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "G",
                        color = IOSParityTokens.ColorTokens.CyanAccent,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Text(t("使用 Google 登录", "Continue with Google", "Google で続行"))
                }
            }

            Spacer(modifier = Modifier.height(10.dp))

            OutlinedButton(
                onClick = { viewModel.signInAsGuest() },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = Color.White.copy(alpha = 0.1f),
                    contentColor = Color.White
                ),
                border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.3f))
            ) {
                Text(t("以游客身份继续", "Continue as Guest", "ゲストとして続行"))
            }

            if (supabaseState !is SupabaseConfigState.Available) {
                Spacer(modifier = Modifier.height(12.dp))
                AuthMessageCard(
                    message = when (supabaseState) {
                        SupabaseConfigState.Missing -> t(
                            "云配置未启用，首次登录会自动启用。",
                            "Cloud configuration is not enabled yet. It will be enabled during the first sign-in.",
                            "クラウド設定はまだ有効ではありません。初回ログイン時に有効になります。"
                        )
                        SupabaseConfigState.Locked -> t(
                            "云配置已锁定，登录前将先解锁。",
                            "Cloud configuration is locked and will be unlocked before sign-in.",
                            "クラウド設定はロックされており、ログイン前にロック解除されます。"
                        )
                        is SupabaseConfigState.Available -> t(
                            "云配置已就绪。",
                            "Cloud configuration is ready.",
                            "クラウド設定の準備ができています。"
                        )
                    },
                    background = Color.White.copy(alpha = 0.08f),
                    textColor = Color.White.copy(alpha = 0.88f)
                )
            }

            errorMessage?.let { err ->
                Spacer(modifier = Modifier.height(14.dp))
                AuthMessageCard(
                    message = err,
                    background = Color(0x50FF6B6B),
                    textColor = Color(0xFFFFD7D7)
                )
            }

            infoMessage?.let { info ->
                Spacer(modifier = Modifier.height(10.dp))
                AuthMessageCard(
                    message = info,
                    background = Color(0x4034C759),
                    textColor = Color(0xFFD8FFE3)
                )
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }
}

@Composable
private fun AuthDivider() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(Color.White.copy(alpha = 0.2f))
        )
        Text(
            text = resolveLocalizedText("或者", "Or", "または"),
            color = Color.White.copy(alpha = 0.66f),
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = 12.dp)
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(Color.White.copy(alpha = 0.2f))
        )
    }
}

@Composable
private fun LoginPreferenceCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
            .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(14.dp))
            .padding(14.dp),
        content = content
    )
}

@Composable
private fun LoginLanguageSelector(
    selectedLanguage: String,
    onLanguageSelected: (String) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        LoginLanguageChip(
            label = resolveLanguageLabel(APP_LANGUAGE_SYSTEM, "系统", "System", "システム"),
            selected = selectedLanguage == APP_LANGUAGE_SYSTEM,
            onClick = { onLanguageSelected(APP_LANGUAGE_SYSTEM) }
        )
        LoginLanguageChip(
            label = "中文",
            selected = selectedLanguage == APP_LANGUAGE_ZH,
            onClick = { onLanguageSelected(APP_LANGUAGE_ZH) }
        )
        LoginLanguageChip(
            label = "EN",
            selected = selectedLanguage == APP_LANGUAGE_EN,
            onClick = { onLanguageSelected(APP_LANGUAGE_EN) }
        )
        LoginLanguageChip(
            label = "日本語",
            selected = selectedLanguage == APP_LANGUAGE_JA,
            onClick = { onLanguageSelected(APP_LANGUAGE_JA) }
        )
    }
}

@Composable
private fun RowScope.LoginLanguageChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier.weight(1f),
        shape = RoundedCornerShape(999.dp),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = if (selected) IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = 0.20f) else Color.White.copy(alpha = 0.06f),
            contentColor = if (selected) IOSParityTokens.ColorTokens.CyanAccent else Color.White
        ),
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = 0.45f) else Color.White.copy(alpha = 0.14f)
        ),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp)
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium
        )
    }
}

@Composable
private fun AuthMessageCard(
    message: String,
    background: Color,
    textColor: Color,
    chipLabel: String? = null
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(background, RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
            .padding(12.dp)
    ) {
        Text(
            text = message,
            color = textColor,
            style = MaterialTheme.typography.bodyMedium
        )
        if (!chipLabel.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = chipLabel,
                color = textColor.copy(alpha = 0.85f),
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}
