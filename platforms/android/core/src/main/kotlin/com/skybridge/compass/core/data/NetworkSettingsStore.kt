package com.skybridge.compass.core.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.emptyPreferences
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
            .catch { emit(emptyPreferences()) }
            .map { prefs ->
            NetworkSettings(
                portRangeStart = prefs[KEY_PORT_START] ?: 8080,
                portRangeEnd = prefs[KEY_PORT_END] ?: 8090,
                discoveryTimeoutMs = prefs[KEY_DISCOVERY_TIMEOUT] ?: 30000L,
                maxReconnectAttempts = prefs[KEY_MAX_RECONNECT] ?: 3,
                tlsStrictMode = prefs[KEY_TLS_STRICT] ?: true,
                handshakeEnabled = prefs[KEY_HANDSHAKE_ENABLED] ?: true,
                encryptionMode = prefs[KEY_ENCRYPTION_MODE] ?: "AES_GCM",
                webrtcEnabled = prefs[KEY_WEBRTC_ENABLED] ?: true,
                webrtcSignalingUrl = (prefs[KEY_WEBRTC_SIGNALING_URL] ?: DEFAULT_WEBRTC_SIGNALING_URL).trim()
                    .ifBlank { DEFAULT_WEBRTC_SIGNALING_URL },
                stunServers = parseCsv(prefs[KEY_STUN_SERVERS]) ?: DEFAULT_STUN_SERVERS,
                turnServers = parseCsv(prefs[KEY_TURN_SERVERS]) ?: DEFAULT_TURN_SERVERS
            )
        }

    suspend fun setPortRange(context: Context, start: Int, end: Int) {
        val s = start.coerceAtLeast(1)
        val e = end.coerceAtLeast(s).coerceAtMost(65535)
        context.networkSettingsDataStore.edit { prefs ->
            prefs[KEY_PORT_START] = s
            prefs[KEY_PORT_END] = e
        }
    }

    suspend fun setDiscoveryTimeoutMs(context: Context, timeoutMs: Long) {
        val t = timeoutMs.coerceIn(250L, 120_000L)
        context.networkSettingsDataStore.edit { prefs ->
            prefs[KEY_DISCOVERY_TIMEOUT] = t
        }
    }

    suspend fun setMaxReconnectAttempts(context: Context, attempts: Int) {
        val a = attempts.coerceIn(0, 10)
        context.networkSettingsDataStore.edit { prefs ->
            prefs[KEY_MAX_RECONNECT] = a
        }
    }

    // TLS 严格模式
    fun observeTlsStrictMode(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { it[KEY_TLS_STRICT] ?: true }

    suspend fun setTlsStrictMode(context: Context, enabled: Boolean) {
        context.networkSettingsDataStore.edit { it[KEY_TLS_STRICT] = enabled }
    }

    // 握手开关
    fun observeHandshakeEnabled(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { it[KEY_HANDSHAKE_ENABLED] ?: true }

    suspend fun setHandshakeEnabled(context: Context, enabled: Boolean) {
        context.networkSettingsDataStore.edit { it[KEY_HANDSHAKE_ENABLED] = enabled }
    }

    // 加密模式（例如：AES_GCM、AES_CBC 等）
    fun observeEncryptionMode(context: Context): Flow<String> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { it[KEY_ENCRYPTION_MODE] ?: "AES_GCM" }

    suspend fun setEncryptionMode(context: Context, mode: String) {
        val normalized = mode.uppercase()
        context.networkSettingsDataStore.edit { it[KEY_ENCRYPTION_MODE] = normalized }
    }

    fun observeWebRtcEnabled(context: Context): Flow<Boolean> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { it[KEY_WEBRTC_ENABLED] ?: true }

    suspend fun setWebRtcEnabled(context: Context, enabled: Boolean) {
        context.networkSettingsDataStore.edit { it[KEY_WEBRTC_ENABLED] = enabled }
    }

    fun observeWebRtcSignalingUrl(context: Context): Flow<String> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { (it[KEY_WEBRTC_SIGNALING_URL] ?: DEFAULT_WEBRTC_SIGNALING_URL).trim().ifBlank { DEFAULT_WEBRTC_SIGNALING_URL } }

    suspend fun setWebRtcSignalingUrl(context: Context, url: String) {
        val normalized = url.trim().ifBlank { DEFAULT_WEBRTC_SIGNALING_URL }
        context.networkSettingsDataStore.edit { it[KEY_WEBRTC_SIGNALING_URL] = normalized }
    }

    // STUN/TURN 列表（CSV 存储）
    fun observeStunServers(context: Context): Flow<List<String>> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { prefs ->
            (prefs[KEY_STUN_SERVERS] ?: "").split(',').mapNotNull { s ->
                val v = s.trim()
                if (v.isEmpty()) null else v
            }
        }

    suspend fun setStunServers(context: Context, servers: List<String>) {
        val csv = servers.map { it.trim() }.filter { it.isNotEmpty() }.joinToString(",")
        context.networkSettingsDataStore.edit { it[KEY_STUN_SERVERS] = csv }
    }

    fun observeTurnServers(context: Context): Flow<List<String>> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
            .map { prefs ->
            (prefs[KEY_TURN_SERVERS] ?: "").split(',').mapNotNull { s ->
                val v = s.trim()
                if (v.isEmpty()) null else v
            }
        }

    suspend fun setTurnServers(context: Context, servers: List<String>) {
        val csv = servers.map { it.trim() }.filter { it.isNotEmpty() }.joinToString(",")
        context.networkSettingsDataStore.edit { it[KEY_TURN_SERVERS] = csv }
    }

    // 证书固定 JSON（与 PinProvider 结构兼容）
    fun observeCertificatePinsJson(context: Context): Flow<String?> =
        context.networkSettingsDataStore.data
            .catch { emit(emptyPreferences()) }
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
}
