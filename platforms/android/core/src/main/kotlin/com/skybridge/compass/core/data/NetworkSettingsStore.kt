package com.skybridge.compass.core.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.skybridge.compass.core.webrtc.SkyBridgeServerConfig
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

// 顶层扩展属性：DataStore 实例
private val Context.networkSettingsDataStore by preferencesDataStore(name = "network_settings")

private val DEFAULT_WEBRTC_SIGNALING_URL = SkyBridgeServerConfig.signalingWebSocketURL
private val DEFAULT_STUN_SERVERS = SkyBridgeServerConfig.defaultStunServers
private val DEFAULT_TURN_SERVERS = SkyBridgeServerConfig.defaultTurnServers

// 网络设置数据结构
data class NetworkSettings(
    val portRangeStart: Int = 8080,
    val portRangeEnd: Int = 8090,
    val discoveryTimeoutMs: Long = 30000L,
    val maxReconnectAttempts: Int = 3,
    val tlsStrictMode: Boolean = true,
    val handshakeEnabled: Boolean = true,
    val encryptionMode: String = "AES_GCM",

    // Cross-network WebRTC
    val webrtcEnabled: Boolean = true,
    val webrtcSignalingUrl: String = DEFAULT_WEBRTC_SIGNALING_URL,
    val stunServers: List<String> = DEFAULT_STUN_SERVERS,
    val turnServers: List<String> = DEFAULT_TURN_SERVERS
)

object NetworkSettingsStore {
    private val KEY_PORT_START = intPreferencesKey("port_range_start")
    private val KEY_PORT_END = intPreferencesKey("port_range_end")
    private val KEY_DISCOVERY_TIMEOUT = longPreferencesKey("discovery_timeout_ms")
    private val KEY_MAX_RECONNECT = intPreferencesKey("max_reconnect_attempts")
    // 新增配置键
    private val KEY_TLS_STRICT = booleanPreferencesKey("tls_strict_mode")
    private val KEY_HANDSHAKE_ENABLED = booleanPreferencesKey("handshake_enabled")
    private val KEY_ENCRYPTION_MODE = stringPreferencesKey("encryption_mode")
    private val KEY_STUN_SERVERS = stringPreferencesKey("stun_servers_csv")
    private val KEY_TURN_SERVERS = stringPreferencesKey("turn_servers_csv")
    private val KEY_CERT_PINS_JSON = stringPreferencesKey("certificate_pins_json")
    private val KEY_WEBRTC_ENABLED = booleanPreferencesKey("webrtc_enabled")
    private val KEY_WEBRTC_SIGNALING_URL = stringPreferencesKey("webrtc_signaling_url")

    fun observe(context: Context): Flow<NetworkSettings> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { prefs ->
            NetworkSettings(
                portRangeStart = prefs[KEY_PORT_START] ?: 8080,
                portRangeEnd = prefs[KEY_PORT_END] ?: 8090,
                discoveryTimeoutMs = prefs[KEY_DISCOVERY_TIMEOUT] ?: 30000L,
                maxReconnectAttempts = prefs[KEY_MAX_RECONNECT] ?: 3,
                tlsStrictMode = readTlsStrictMode(prefs[KEY_TLS_STRICT]),
                handshakeEnabled = readHandshakeEnabled(prefs[KEY_HANDSHAKE_ENABLED]),
                encryptionMode = readEncryptionMode(prefs[KEY_ENCRYPTION_MODE]),
                webrtcEnabled = prefs[KEY_WEBRTC_ENABLED] ?: true,
                webrtcSignalingUrl = NetworkEndpointPolicy.normalizeWebRtcSignalingUrl(
                    prefs[KEY_WEBRTC_SIGNALING_URL] ?: DEFAULT_WEBRTC_SIGNALING_URL
                ),
                stunServers = NetworkEndpointPolicy.normalizeStunServers(parseCsv(prefs[KEY_STUN_SERVERS])),
                turnServers = NetworkEndpointPolicy.normalizeTurnServers(parseCsv(prefs[KEY_TURN_SERVERS]))
            )
        }

    /**
     * 先校验后写入（R7.8）：端口两端各自 ∈ 1..65535 且 `end >= start`。
     *
     * 越界一律**拒绝**并原样返回 [NetworkSettingValidation.Rejected]，此时**不触碰 DataStore**，
     * 原持久化值保持不变。仅在接受时写入；写入前的钳制是存储层兜底，对已校验值为恒等映射。
     */
    suspend fun setPortRange(
        context: Context,
        start: Int,
        end: Int
    ): NetworkSettingValidation<IntRange> {
        return writeIfAccepted(NetworkSettingsValidator.validatePortRange(start, end)) { range ->
            val s = NetworkSettingsStorageBackstop.clampPortStart(range.first)
            val e = NetworkSettingsStorageBackstop.clampPortEnd(s, range.last)
            context.networkSettingsDataStore.edit { prefs ->
                prefs[KEY_PORT_START] = s
                prefs[KEY_PORT_END] = e
            }
        }
    }

    /**
     * 文本框保存入口：接收**原始字符串**，因此空与非数值也能被表达并拒绝（R7.8）。
     * 拒绝时不写入，原持久化值保留。
     */
    suspend fun setPortRangeFromInput(
        context: Context,
        rawStart: String,
        rawEnd: String
    ): NetworkSettingValidation<IntRange> {
        val validation = NetworkSettingsValidator.validatePortRangeInput(rawStart, rawEnd)
        val accepted = validation.acceptedValueOrNull() ?: return validation
        return setPortRange(context, accepted.first, accepted.last)
    }

    /** 先校验后写入（R7.8）：发现超时 ∈ 250..120000ms，越界拒绝且不写入。 */
    suspend fun setDiscoveryTimeoutMs(
        context: Context,
        timeoutMs: Long
    ): NetworkSettingValidation<Long> {
        return writeIfAccepted(
            NetworkSettingsValidator.validateDiscoveryTimeoutMs(timeoutMs)
        ) { accepted ->
            val t = NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(accepted)
            context.networkSettingsDataStore.edit { prefs ->
                prefs[KEY_DISCOVERY_TIMEOUT] = t
            }
        }
    }

    /** 文本框保存入口（毫秒原始字符串）：空/非数值/越界一律拒绝且不写入。 */
    suspend fun setDiscoveryTimeoutMsFromInput(
        context: Context,
        rawTimeoutMs: String
    ): NetworkSettingValidation<Long> {
        val validation = NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(rawTimeoutMs)
        val accepted = validation.acceptedValueOrNull() ?: return validation
        return setDiscoveryTimeoutMs(context, accepted)
    }

    /** 先校验后写入（R7.8）：重连次数 ∈ 0..10，越界拒绝且不写入。 */
    suspend fun setMaxReconnectAttempts(
        context: Context,
        attempts: Int
    ): NetworkSettingValidation<Int> {
        return writeIfAccepted(
            NetworkSettingsValidator.validateMaxReconnectAttempts(attempts)
        ) { accepted ->
            val a = NetworkSettingsStorageBackstop.clampReconnectAttempts(accepted)
            context.networkSettingsDataStore.edit { prefs ->
                prefs[KEY_MAX_RECONNECT] = a
            }
        }
    }

    /** 文本框保存入口：空/非数值/越界一律拒绝且不写入。 */
    suspend fun setMaxReconnectAttemptsFromInput(
        context: Context,
        rawAttempts: String
    ): NetworkSettingValidation<Int> {
        val validation = NetworkSettingsValidator.validateMaxReconnectAttemptsInput(rawAttempts)
        val accepted = validation.acceptedValueOrNull() ?: return validation
        return setMaxReconnectAttempts(context, accepted)
    }

    // TLS 严格模式
    fun observeTlsStrictMode(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { readTlsStrictMode(it[KEY_TLS_STRICT]) }

    suspend fun setTlsStrictMode(context: Context, enabled: Boolean) {
        require(enabled) { "TLS strict mode cannot be disabled" }
        context.networkSettingsDataStore.edit { it[KEY_TLS_STRICT] = true }
    }

    // 握手开关
    fun observeHandshakeEnabled(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { readHandshakeEnabled(it[KEY_HANDSHAKE_ENABLED]) }

    suspend fun setHandshakeEnabled(context: Context, enabled: Boolean) {
        require(enabled) { "transport handshake cannot be disabled" }
        context.networkSettingsDataStore.edit { it[KEY_HANDSHAKE_ENABLED] = true }
    }

    // 加密模式（例如：AES_GCM、AES_CBC 等）
    fun observeEncryptionMode(context: Context): Flow<String> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { readEncryptionMode(it[KEY_ENCRYPTION_MODE]) }

    suspend fun setEncryptionMode(context: Context, mode: String) {
        val normalized = normalizeEncryptionMode(mode)
        context.networkSettingsDataStore.edit { it[KEY_ENCRYPTION_MODE] = normalized }
    }

    fun observeWebRtcEnabled(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_WEBRTC_ENABLED] ?: true }

    suspend fun setWebRtcEnabled(context: Context, enabled: Boolean) {
        context.networkSettingsDataStore.edit { it[KEY_WEBRTC_ENABLED] = enabled }
    }

    fun observeWebRtcSignalingUrl(context: Context): Flow<String> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { NetworkEndpointPolicy.normalizeWebRtcSignalingUrl(it[KEY_WEBRTC_SIGNALING_URL] ?: DEFAULT_WEBRTC_SIGNALING_URL) }

    suspend fun setWebRtcSignalingUrl(context: Context, url: String) {
        require(url.trim().isNotEmpty()) { "WebRTC signaling URL cannot be blank" }
        val normalized = NetworkEndpointPolicy.normalizeWebRtcSignalingUrl(url)
        context.networkSettingsDataStore.edit { it[KEY_WEBRTC_SIGNALING_URL] = normalized }
    }

    // STUN/TURN 列表（CSV 存储）
    fun observeStunServers(context: Context): Flow<List<String>> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { prefs ->
            NetworkEndpointPolicy.normalizeStunServers(parseCsv(prefs[KEY_STUN_SERVERS]))
        }

    suspend fun setStunServers(context: Context, servers: List<String>) {
        require(servers.any { it.isNotBlank() }) { "STUN server list cannot be blank" }
        val csv = NetworkEndpointPolicy.normalizeStunServers(servers).joinToString(",")
        context.networkSettingsDataStore.edit { it[KEY_STUN_SERVERS] = csv }
    }

    fun observeTurnServers(context: Context): Flow<List<String>> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { prefs ->
            NetworkEndpointPolicy.normalizeTurnServers(parseCsv(prefs[KEY_TURN_SERVERS]))
        }

    suspend fun setTurnServers(context: Context, servers: List<String>) {
        require(servers.any { it.isNotBlank() }) { "TURN server list cannot be blank" }
        val csv = NetworkEndpointPolicy.normalizeTurnServers(servers).joinToString(",")
        context.networkSettingsDataStore.edit { it[KEY_TURN_SERVERS] = csv }
    }

    // 证书固定 JSON（与 PinProvider 结构兼容）
    fun observeCertificatePinsJson(context: Context): Flow<String?> =
        context.networkSettingsDataStore.data
            .catch { rethrowPreferenceReadFailure(it) }
            .map { it[KEY_CERT_PINS_JSON] }

    suspend fun setCertificatePinsJson(context: Context, pinsJson: String) {
        context.networkSettingsDataStore.edit { it[KEY_CERT_PINS_JSON] = pinsJson }
    }

    private fun parseCsv(value: String?): List<String>? {
        val raw = value?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val list = raw.split(',').mapNotNull { s ->
            val v = s.trim()
            if (v.isEmpty()) null else v
        }
        return list.ifEmpty { null }
    }

    private fun readTlsStrictMode(value: Boolean?): Boolean {
        require(value != false) { "stored TLS strict mode is disabled" }
        return true
    }

    private fun readHandshakeEnabled(value: Boolean?): Boolean {
        require(value != false) { "stored transport handshake is disabled" }
        return true
    }

    private fun readEncryptionMode(value: String?): String =
        normalizeEncryptionMode(value ?: "AES_GCM")

    private fun normalizeEncryptionMode(mode: String): String {
        val normalized = mode.trim().uppercase()
        require(normalized == "AES_GCM") { "unsupported network encryption mode" }
        return normalized
    }

    private suspend fun kotlinx.coroutines.flow.FlowCollector<androidx.datastore.preferences.core.Preferences>.rethrowPreferenceReadFailure(
        error: Throwable
    ) {
        throw error
    }
}
