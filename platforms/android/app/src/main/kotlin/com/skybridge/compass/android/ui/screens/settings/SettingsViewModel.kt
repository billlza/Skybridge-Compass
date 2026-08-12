package com.skybridge.compass.android.ui.screens.settings

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.data.SupabaseConfigState
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.auth.AuthRepository
import com.skybridge.compass.core.data.NetworkSettingField
import com.skybridge.compass.core.data.NetworkSettingRejection
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.data.rejectionOrNull
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Owns the DataStore-backed settings state and update intents that previously lived inline as
 * `collectAsState`/`scope.launch { ...Store.set(...) }` calls inside the ~1187-line SettingsScreen
 * composable.
 *
 * Behavior is preserved exactly:
 * - Every [StateFlow] is sourced from the same `Store.observe(...)` flow with the same default value
 *   the composable previously passed to `collectAsState(initial = ...)`.
 * - Every intent delegates to the identical `Store.set...(appContext, ...)` suspend call the
 *   composable previously invoked from `scope.launch { ... }`.
 * - The developer toggles persist to `DeveloperSettingsStore` only. The former in-memory
 *   `FeatureFlags.ENABLE_*` mirror was removed under R7.10: it had no read sites anywhere in the
 *   repository and was never rehydrated at startup, so it changed no runtime behavior.
 *
 * Activity-bound biometric flows (Supabase save / unlock / provisionManagedDefaults) are NOT moved
 * here: they require a [androidx.fragment.app.FragmentActivity] and stay in the composable exactly as
 * before. The ViewModel only owns the non-Activity pieces of Supabase (state observation + reset +
 * managedDefaults lookup) so the screen no longer reaches into the store object for those.
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    private val authRepository: AuthRepository
) : ViewModel() {

    val appSettings: StateFlow<AppSettings> =
        AppSettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())

    val developerSettings: StateFlow<DeveloperSettings> =
        DeveloperSettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, DeveloperSettings())

    val networkSettings: StateFlow<NetworkSettings> =
        NetworkSettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, NetworkSettings())

    val securitySettings: StateFlow<SecuritySettings> =
        SecuritySettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, SecuritySettings())

    val supabaseState: StateFlow<SupabaseConfigState> =
        SupabaseConfigStore.observeState(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, SupabaseConfigState.Missing)

    // region App settings intents (was AppSettingsStore.set...(context, ...) in scope.launch {})

    fun setDarkMode(enabled: Boolean) {
        persistSetting("general.dark-mode") { AppSettingsStore.setDarkMode(appContext, enabled) }
    }

    fun setAppLanguage(language: String) {
        persistSetting("general.app-language") { AppSettingsStore.setAppLanguage(appContext, language) }
    }

    fun setAutoConnect(enabled: Boolean) {
        persistSetting("general.auto-connect") { AppSettingsStore.setAutoConnect(appContext, enabled) }
    }

    fun setNotifications(enabled: Boolean) {
        persistSetting("general.notifications") { AppSettingsStore.setNotifications(appContext, enabled) }
    }

    fun setUseDynamicColor(enabled: Boolean) {
        persistSetting("general.dynamic-color") { AppSettingsStore.setUseDynamicColor(appContext, enabled) }
    }

    fun setHapticFeedback(enabled: Boolean) {
        persistSetting("general.haptic-feedback") { AppSettingsStore.setHapticFeedback(appContext, enabled) }
    }

    fun setKeepScreenOn(enabled: Boolean) {
        persistSetting("general.keep-screen-on") { AppSettingsStore.setKeepScreenOn(appContext, enabled) }
    }

    fun setBatteryOptimizationWarning(enabled: Boolean) {
        persistSetting("general.battery-opt-warning") { AppSettingsStore.setBatteryOptimizationWarning(appContext, enabled) }
    }

    /**
     * The weather subsystem observes this key directly, so flipping it is the only action needed:
     * `WeatherRepository` starts or tears down location + network work off the persisted value.
     */
    fun setRealTimeWeatherEnabled(enabled: Boolean) {
        persistSetting("general.real-time-weather") { AppSettingsStore.setRealTimeWeatherEnabled(appContext, enabled) }
    }

    fun setRememberLogin(enabled: Boolean) {
        persistSetting("account.remember-login") { AppSettingsStore.setRememberLogin(appContext, enabled) }
    }

    // endregion

    // region Network settings intents (was NetworkSettingsStore.set...(context, ...) in scope.launch {})

    /**
     * R7.8 先校验后写入：三项网络输入接收文本框**原始字符串**，空/非数值/越界一律拒绝保存，
     * 并把「含最小与最大值」的提示写入 [networkValidationErrors]；被拒绝时不触碰持久化值。
     * 接受时清除该字段的错误提示。
     */
    private val _networkValidationErrors =
        MutableStateFlow<Map<NetworkSettingField, NetworkSettingRejection>>(emptyMap())

    val networkValidationErrors: StateFlow<Map<NetworkSettingField, NetworkSettingRejection>> =
        _networkValidationErrors.asStateFlow()

    /**
     * 三项网络输入同时受 R7.8（校验）与 R7.12（写入失败）约束，二者是**不同**的失败类别：
     * 校验拒绝走 [networkValidationErrors]（提示含最小/最大值），写入抛出走 [saveFailures]
     * （提示「保存未生效」）。绝不能把校验拒绝报成保存失败——那会掩盖真正的范围提示。
     */
    fun setPortRangeFromInput(rawStart: String, rawEnd: String) {
        persistSetting("network.port-range-start") {
            val result = NetworkSettingsStore.setPortRangeFromInput(appContext, rawStart, rawEnd)
            recordNetworkValidation(
                fields = listOf(
                    NetworkSettingField.PORT_RANGE_START,
                    NetworkSettingField.PORT_RANGE_END
                ),
                rejection = result.rejectionOrNull()
            )
        }
    }

    fun setDiscoveryTimeoutMsFromInput(rawTimeoutMs: String) {
        persistSetting("network.discovery-timeout") {
            val result = NetworkSettingsStore.setDiscoveryTimeoutMsFromInput(appContext, rawTimeoutMs)
            recordNetworkValidation(
                fields = listOf(NetworkSettingField.DISCOVERY_TIMEOUT_MS),
                rejection = result.rejectionOrNull()
            )
        }
    }

    /**
     * 该行文本框以**秒**为单位，这里换算成毫秒后交给同一个校验面。
     * 空或非数值时**原样透传**，让数据层给出 Empty / NotNumeric 拒绝，而不是被换算掩盖。
     */
    fun setDiscoveryTimeoutSecFromInput(rawSeconds: String) {
        val trimmed = rawSeconds.trim()
        val seconds = trimmed.toLongOrNull()
        val rawMs = when {
            seconds == null -> trimmed
            seconds > Long.MAX_VALUE / 1000L -> trimmed
            else -> (seconds * 1000L).toString()
        }
        setDiscoveryTimeoutMsFromInput(rawMs)
    }

    fun setMaxReconnectAttemptsFromInput(rawAttempts: String) {
        persistSetting("network.max-reconnect-attempts") {
            val result = NetworkSettingsStore.setMaxReconnectAttemptsFromInput(appContext, rawAttempts)
            recordNetworkValidation(
                fields = listOf(NetworkSettingField.MAX_RECONNECT_ATTEMPTS),
                rejection = result.rejectionOrNull()
            )
        }
    }

    /** 输入被编辑时清掉上一次的拒绝提示，避免旧错误停留。 */
    fun clearNetworkValidationError(vararg fields: NetworkSettingField) {
        if (fields.isEmpty()) return
        _networkValidationErrors.update { current ->
            if (fields.none { current.containsKey(it) }) current else current - fields.toSet()
        }
    }

    private fun recordNetworkValidation(
        fields: List<NetworkSettingField>,
        rejection: NetworkSettingRejection?
    ) {
        _networkValidationErrors.update { current ->
            val cleared = current - fields.toSet()
            if (rejection == null) cleared else cleared + (rejection.settingField to rejection)
        }
    }

    // endregion

    // region 写入失败与回滚（任务 15.8 / R7.11、R7.12）

    /**
     * 最近一次写入失败的记录，按 `controlId` 索引（R7.12）。
     *
     * 改造前每个 setter 都是裸 `viewModelScope.launch { Store.set(...) }`，DataStore 的
     * `IOException` 会作为未捕获异常逃逸，用户看不到「保存未生效」。现在全部写入都经
     * [persistSetting] 这一道闸门，失败即在此登记。
     */
    private val _saveFailures = MutableStateFlow<Map<String, SettingSaveFailure>>(emptyMap())

    val saveFailures: StateFlow<Map<String, SettingSaveFailure>> = _saveFailures.asStateFlow()

    /**
     * 唯一写入闸门：所有设置项的持久化写入都必须经过这里（R7.11 / R7.12）。
     *
     * - 成功：清除该项此前的失败记录；此时 DataStore 的 `edit` 已挂起至事务提交，
     *   因此消费方的**下一次读取**必然取得新值（R7.11 的后半句由 DataStore 语义保证）。
     * - 失败：登记 [SettingSaveFailure] 而**不**让异常逃逸。持久化值未被改变，
     *   由持久化流驱动的控件（开关/单选）显示值因此天然停留在写入前的值；
     *   文本框类控件由界面依据本条记录丢弃本地编辑状态。
     *
     * 只捕获 [Exception]：`CancellationException` 属于协程正常取消语义，必须继续向上传播，
     * 否则 ViewModel 销毁时的取消会被误报成一次「保存失败」。
     */
    private fun persistSetting(controlId: String, write: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                write()
                clearSaveFailure(controlId)
            } catch (cancellation: kotlinx.coroutines.CancellationException) {
                throw cancellation
            } catch (e: Exception) {
                _saveFailures.update { current ->
                    current + (controlId to SettingSaveFailure(controlId = controlId, cause = e))
                }
            }
        }
    }

    /** 供界面在用户重新编辑或已看到提示后清除失败记录。 */
    fun clearSaveFailure(controlId: String) {
        _saveFailures.update { current ->
            if (current.containsKey(controlId)) current - controlId else current
        }
    }

    fun setWebRtcEnabled(enabled: Boolean) {
        persistSetting("webrtc.enabled") { NetworkSettingsStore.setWebRtcEnabled(appContext, enabled) }
    }

    suspend fun setWebRtcSignalingUrl(url: String) {
        NetworkSettingsStore.setWebRtcSignalingUrl(appContext, url)
    }

    suspend fun setStunServers(servers: List<String>) {
        NetworkSettingsStore.setStunServers(appContext, servers)
    }

    suspend fun setTurnServers(servers: List<String>) {
        NetworkSettingsStore.setTurnServers(appContext, servers)
    }

    // endregion

    // region Security settings intents (was SecuritySettingsStore.set...(context, ...) in composables)

    fun setRequirePairing(enabled: Boolean) {
        persistSetting("device-auth.require-pairing") { SecuritySettingsStore.setRequirePairing(appContext, enabled) }
    }

    fun setAutoTrustKnownDevices(enabled: Boolean) {
        persistSetting("device-auth.auto-trust-known-devices") { SecuritySettingsStore.setAutoTrustKnownDevices(appContext, enabled) }
    }

    fun setPairingTimeoutSec(seconds: Int) {
        persistSetting("device-auth.pairing-timeout-sec") { SecuritySettingsStore.setPairingTimeoutSec(appContext, seconds) }
    }

    fun setEnforcePqcHandshake(enabled: Boolean) {
        persistSetting("device-auth.enforce-pqc-handshake") { SecuritySettingsStore.setEnforcePqcHandshake(appContext, enabled) }
    }

    fun setAllowClassicFallbackForCompatibility(enabled: Boolean) {
        persistSetting("device-auth.allow-classic-fallback") { SecuritySettingsStore.setAllowClassicFallbackForCompatibility(appContext, enabled) }
    }

    fun setPqcMinimumTier(tier: String) {
        persistSetting("device-auth.pqc-minimum-tier") { SecuritySettingsStore.setPqcMinimumTier(appContext, tier) }
    }

    fun setAllowScreenMirroring(enabled: Boolean) {
        persistSetting("access-control.allow-screen-mirroring") { SecuritySettingsStore.setAllowScreenMirroring(appContext, enabled) }
    }

    fun setAllowFileTransfer(enabled: Boolean) {
        persistSetting("access-control.allow-file-transfer") { SecuritySettingsStore.setAllowFileTransfer(appContext, enabled) }
    }

    fun setAutoAcceptTrustedDevices(enabled: Boolean) {
        persistSetting("access-control.auto-accept-trusted-devices") { SecuritySettingsStore.setAutoAcceptTrustedDevices(appContext, enabled) }
    }

    fun setConfirmOverwriteOnInbound(enabled: Boolean) {
        persistSetting("access-control.confirm-overwrite-on-inbound") { SecuritySettingsStore.setConfirmOverwriteOnInbound(appContext, enabled) }
    }

    fun setAllowRemoteControl(enabled: Boolean) {
        persistSetting("access-control.allow-remote-control") { SecuritySettingsStore.setAllowRemoteControl(appContext, enabled) }
    }

    fun setAllowClipboardSync(enabled: Boolean) {
        persistSetting("access-control.allow-clipboard-sync") { SecuritySettingsStore.setAllowClipboardSync(appContext, enabled) }
    }

    fun setShowDeviceName(enabled: Boolean) {
        persistSetting("privacy.show-device-name") { SecuritySettingsStore.setShowDeviceName(appContext, enabled) }
    }

    // endregion

    // region Developer settings intents
    //
    // R7.10：这三个 intent 过去在持久化写入之后，还会把同一个值镜像到进程内的
    // `FeatureFlags.ENABLE_*` 变量。该镜像**全仓无任何读取点**，且进程启动时不从
    // [DeveloperSettingsStore] 回填，因此它既不改变运行时行为，也在重启后回到硬编码的 `true`。
    // 按 R7.10「既不被写入也不被读取的进程内设置镜像变量清零」，镜像变量与其写入点一并移除。
    //
    // 真正的功能门是 [DeveloperSettingsStore] 的三个持久化键，消费方保持不变：
    //  - enable_screen_mirroring → DeviceDiscoveryScreen.kt:843
    //  - enable_remote_control   → RemoteControlScreen.kt:109、DeviceDiscoveryScreen.kt:844
    //  - enable_file_transfer    → FileTransferScreen.kt:94、DeviceDiscoveryScreen.kt:845

    fun setEnableScreenMirroring(enabled: Boolean) {
        persistSetting("developer.enable-screen-mirroring") {
            DeveloperSettingsStore.setEnableScreenMirroring(appContext, enabled)
        }
    }

    fun setEnableRemoteControl(enabled: Boolean) {
        persistSetting("developer.enable-remote-control") {
            DeveloperSettingsStore.setEnableRemoteControl(appContext, enabled)
        }
    }

    fun setEnableFileTransfer(enabled: Boolean) {
        persistSetting("developer.enable-file-transfer") {
            DeveloperSettingsStore.setEnableFileTransfer(appContext, enabled)
        }
    }

    // endregion

    // region Supabase (non-Activity pieces only; biometric save/unlock stay in the composable)

    fun managedSupabaseDefaults() = SupabaseConfigStore.managedDefaults()

    /**
     * Was `scope.launch { SupabaseConfigStore.reset(context); ... }` in the composable.
     *
     * 同样经 [persistSetting] 闸门（R7.12）。这是一次性**动作**而非 45 条清单内的控件
     * （计数规则把「Supabase 解锁/保存/使用默认/清除/验证配置」按动作按钮排除），但它确实写存储，
     * 因此失败必须可见。
     *
     * 顺带修正一处行为：原实现在 `reset` 抛出时 `onDone()` 不会执行且异常直接逃逸，界面既收不到
     * 完成回调也收不到失败提示，表现为「点了没反应」。现在 `onDone()` 只在写入成功后调用，
     * 失败则登记到 [saveFailures]。
     */
    fun resetSupabaseConfig(onDone: () -> Unit) {
        persistSetting(SUPABASE_RESET_CONTROL_ID) {
            authRepository.invalidateSessionForConfigurationChange()
            SupabaseConfigStore.reset(appContext)
            onDone()
        }
    }

    private companion object {
        /** 非清单控件的动作写入 id，见 [resetSupabaseConfig] 的说明。 */
        const val SUPABASE_RESET_CONTROL_ID = "cloud.supabase-reset"
    }

    // endregion
}
