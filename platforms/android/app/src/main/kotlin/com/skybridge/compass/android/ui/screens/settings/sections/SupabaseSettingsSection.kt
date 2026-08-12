package com.skybridge.compass.android.ui.screens.settings.sections

import android.content.Intent
import android.provider.Settings
import androidx.biometric.BiometricManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.android.data.SupabaseConfigState
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.supabase.SupabaseConfigValidationResult
import kotlinx.coroutines.launch

/**
 * "云服务 / Cloud Services" — the Supabase configuration section, extracted verbatim from
 * SettingsScreen.kt.
 *
 * The Activity-bound biometric flows ([SupabaseConfigStore.saveWithBiometrics],
 * [SupabaseConfigStore.unlockWithBiometrics], [SupabaseConfigStore.provisionManagedDefaults]) require a
 * [FragmentActivity] and therefore stay inline here, unchanged. The non-Activity pieces (state
 * observation, `reset`, `managedDefaults`) are routed through the ViewModel via the callbacks below.
 *
 * @param onReset clears the persisted config (ViewModel delegates to SupabaseConfigStore.reset);
 *                invokes the supplied `() -> Unit` once the reset coroutine completes so this section
 *                can update its inline message exactly like the original `scope.launch { reset(); ... }`.
 * @param hasManagedDefaults mirrors `SupabaseConfigStore.managedDefaults() != null` for the
 *                           "Use Default" button enablement.
 * @param onValidate runs `authViewModel.validateSupabaseConfiguration()`; returns (isValid, message?).
 */
@Composable
fun SupabaseSettingsSection(
    supabaseState: SupabaseConfigState,
    authCode: Int,
    hasManagedDefaults: Boolean,
    onReset: (onDone: () -> Unit) -> Unit,
    onValidate: suspend () -> SupabaseConfigValidationResult,
    onConfigurationAvailable: () -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var supabaseMessage by remember { mutableStateOf<String?>(null) }
    var supabaseMessageIsError by remember { mutableStateOf(false) }
    var supabaseValidating by remember { mutableStateOf(false) }
    var supabaseUrlInput by remember { mutableStateOf("") }
    var supabaseAnonKeyInput by remember { mutableStateOf("") }
    var supabaseExpanded by rememberSaveable { mutableStateOf(false) }

    fun openCredentialSettings() {
        runCatching {
            val intent = Intent(Settings.ACTION_BIOMETRIC_ENROLL).apply {
                putExtra(
                    Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                    BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
                )
            }
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    LaunchedEffect(supabaseState) {
        when (val st = supabaseState) {
            is SupabaseConfigState.Available -> {
                supabaseMessage = null
                supabaseUrlInput = st.config.url
                supabaseAnonKeyInput = ""
            }
            SupabaseConfigState.Missing -> {
                supabaseUrlInput = SupabaseConfigStore.managedDefaults()?.url ?: ""
                supabaseAnonKeyInput = ""
            }
            SupabaseConfigState.Locked -> Unit
        }
    }

    GroupedGlassSection(title = t("云服务", "Cloud Services", "クラウドサービス")) {
        val statusText = when (val state = supabaseState) {
            is SupabaseConfigState.Available -> t("已配置: ${state.config.url}", "Configured: ${state.config.url}", "設定済み: ${state.config.url}")
            SupabaseConfigState.Locked -> t("已加密锁定，请解锁后使用云功能", "Encrypted and locked. Unlock it to use cloud features.", "暗号化されてロックされています。クラウド機能を使うにはロック解除してください。")
            SupabaseConfigState.Missing -> t("未配置（云功能不可用）", "Not configured (cloud features unavailable)", "未設定（クラウド機能は利用不可）")
        }

        GroupedGlassRow(
            title = t("Supabase 配置", "Supabase Configuration", "Supabase 設定"),
            subtitle = statusText,
            icon = Icons.Default.CloudSync,
            onClick = { supabaseExpanded = !supabaseExpanded }
        ) {
            TextButton(onClick = { supabaseExpanded = !supabaseExpanded }) {
                Text(if (supabaseExpanded) t("收起", "Collapse", "閉じる") else t("配置", "Configure", "設定"))
            }
        }

        AnimatedVisibility(visible = supabaseExpanded) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = t("Supabase 端点与匿名 Key（Keystore + 生物识别）", "Supabase endpoint and anon key (Keystore + biometrics)", "Supabase エンドポイントと anon key（Keystore + 生体認証）"),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium
                )
                Spacer(modifier = Modifier.height(8.dp))

                OutlinedTextField(
                    value = supabaseUrlInput,
                    onValueChange = { supabaseUrlInput = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("SUPABASE_URL") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    placeholder = { Text("https://your-project.supabase.co") }
                )

                OutlinedTextField(
                    value = supabaseAnonKeyInput,
                    onValueChange = { supabaseAnonKeyInput = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("SUPABASE_ANON_KEY") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    placeholder = { Text(t("匿名 Key（建议粘贴）", "Anon key (paste recommended)", "anon key（貼り付け推奨）")) }
                )

                supabaseMessage?.let { msg ->
                    Spacer(modifier = Modifier.height(6.dp))
                    Text(
                        text = msg,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (supabaseMessageIsError) MaterialTheme.colorScheme.error
                        else MaterialTheme.colorScheme.primary
                    )
                }
                val activity = context as? FragmentActivity
                Row(
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (supabaseState == SupabaseConfigState.Locked) {
                            TextButton(onClick = {
                                if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                    supabaseMessage = t("Supabase 配置无效：未启用锁屏(PIN/图案/密码)或未录入生物识别", "Supabase configuration is unavailable because screen lock or biometrics are not enabled.", "画面ロックまたは生体認証が有効でないため、Supabase 設定を利用できません。")
                                    supabaseMessageIsError = true
                                    openCredentialSettings()
                                    return@TextButton
                                }
                                if (activity == null) {
                                    supabaseMessage = t("无法获取 Activity，无法解锁", "Unable to access the Activity, so unlocking is unavailable.", "Activity を取得できないため、ロック解除できません。")
                                    supabaseMessageIsError = true
                                } else {
                                    SupabaseConfigStore.unlockWithBiometrics(activity) { result ->
                                        result.onSuccess {
                                            supabaseMessage = t("已解锁 Supabase 配置", "Supabase configuration unlocked.", "Supabase 設定のロックを解除しました。")
                                            supabaseMessageIsError = false
                                            onConfigurationAvailable()
                                        }.onFailure { err ->
                                            supabaseMessage = err.message ?: t("解锁失败", "Failed to unlock configuration.", "設定のロック解除に失敗しました。")
                                            supabaseMessageIsError = true
                                        }
                                    }
                                }
                            }) { Text(t("解锁", "Unlock", "ロック解除")) }
                        }

                        Button(onClick = {
                            if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                supabaseMessage = t("需要启用锁屏(PIN/图案/密码)或录入生物识别后才能安全保存", "Enable screen lock or biometrics before securely saving the configuration.", "設定を安全に保存するには、画面ロックまたは生体認証を有効にしてください。")
                                supabaseMessageIsError = true
                                openCredentialSettings()
                                return@Button
                            }
                            if (activity == null) {
                                supabaseMessage = t("无法获取 Activity，无法保存", "Unable to access the Activity, so saving is unavailable.", "Activity を取得できないため、保存できません。")
                                supabaseMessageIsError = true
                            } else {
                                SupabaseConfigStore.saveWithBiometrics(
                                    activity = activity,
                                    config = SupabaseConfig(url = supabaseUrlInput, anonKey = supabaseAnonKeyInput)
                                ) { result ->
                                    result.onSuccess {
                                        supabaseMessage = t("已保存并加密存储", "Saved and encrypted.", "保存して暗号化しました。")
                                        supabaseMessageIsError = false
                                        onConfigurationAvailable()
                                    }.onFailure { err ->
                                        supabaseMessage = err.message ?: t("保存失败", "Failed to save configuration.", "設定の保存に失敗しました。")
                                        supabaseMessageIsError = true
                                    }
                                }
                            }
                        }) { Text(t("保存", "Save", "保存")) }

                        OutlinedButton(
                            enabled = hasManagedDefaults,
                            onClick = {
                                if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                                    supabaseMessage = t("需要启用锁屏(PIN/图案/密码)或录入生物识别后才能安全保存", "Enable screen lock or biometrics before securely saving the configuration.", "設定を安全に保存するには、画面ロックまたは生体認証を有効にしてください。")
                                    supabaseMessageIsError = true
                                    openCredentialSettings()
                                    return@OutlinedButton
                                }
                                if (activity == null) {
                                    supabaseMessage = t("无法获取 Activity，无法启用默认配置", "Unable to access the Activity, so default configuration cannot be enabled.", "Activity を取得できないため、既定設定を有効にできません。")
                                    supabaseMessageIsError = true
                                } else {
                                    SupabaseConfigStore.provisionManagedDefaults(activity) { result ->
                                        result.onSuccess {
                                            supabaseMessage = t("已启用默认配置并加密保存", "Default configuration enabled and encrypted.", "既定設定を有効にして暗号化保存しました。")
                                            supabaseMessageIsError = false
                                            onConfigurationAvailable()
                                        }.onFailure { err ->
                                            supabaseMessage = err.message ?: t("启用失败", "Failed to enable default configuration.", "既定設定の有効化に失敗しました。")
                                            supabaseMessageIsError = true
                                        }
                                    }
                                }
                            }
                        ) { Text(t("使用默认", "Use Default", "既定値を使用")) }
                    }

                    TextButton(onClick = {
                        onReset {
                            supabaseMessage = t("已清除 Supabase 配置", "Supabase configuration cleared.", "Supabase 設定を消去しました。")
                            supabaseMessageIsError = false
                        }
                    }) {
                        Text(t("清除", "Clear", "消去"))
                    }
                }
                if (authCode != BiometricManager.BIOMETRIC_SUCCESS) {
                    Spacer(modifier = Modifier.height(8.dp))
                    TextButton(onClick = { openCredentialSettings() }) { Text(t("去系统设置启用锁屏/生物识别", "Open system settings to enable screen lock / biometrics", "システム設定で画面ロック / 生体認証を有効にする")) }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = {
                        scope.launch {
                            supabaseValidating = true
                            try {
                                val result = onValidate()
                                supabaseMessage = result.message ?: if (result.isValid) {
                                    t("配置有效", "Configuration is valid.", "設定は有効です。")
                                } else {
                                    t("配置无效", "Configuration is invalid.", "設定は無効です。")
                                }
                                supabaseMessageIsError = !result.isValid
                            } catch (e: Throwable) {
                                supabaseMessage = e.message ?: t("验证失败", "Validation failed.", "検証に失敗しました。")
                                supabaseMessageIsError = true
                            } finally {
                                supabaseValidating = false
                            }
                        }
                    },
                    enabled = supabaseState is SupabaseConfigState.Available && !supabaseValidating,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (supabaseValidating) t("验证中...", "Validating...", "検証中...") else t("验证配置", "Validate Configuration", "設定を検証"))
                }
            }
        }
    }
}
