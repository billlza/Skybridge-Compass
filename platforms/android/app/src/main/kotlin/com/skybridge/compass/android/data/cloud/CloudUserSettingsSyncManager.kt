package com.skybridge.compass.android.data.cloud

import android.content.Context
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.data.SupabaseConfigStore
import com.skybridge.compass.auth.AuthRepository
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.webrtc.SkyBridgeServerConfig
import io.github.jan.supabase.auth.status.SessionStatus
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.time.Instant

/**
 * Cloud sync for settings (local DataStore remains source-of-truth).
 *
 * - Pull once when user becomes authenticated (best-effort).
 * - Push debounced on local changes (best-effort).
 *
 * Requires Supabase table + RLS:
 * - docs/supabase/user_settings.sql
 */
class CloudUserSettingsSyncManager(
    private val appContext: Context,
    private val authRepository: AuthRepository,
    private val httpClient: HttpClient,
    private val json: Json
) {
    private val scope = CoroutineScope(Dispatchers.Default)
    private var job: Job? = null

    @Serializable
    data class AppSettingsDto(
        val darkMode: Boolean = false,
        val autoConnect: Boolean = true,
        val notificationsEnabled: Boolean = true,
        val rememberLogin: Boolean = false,
        val appLanguage: String = "system",
        val useDynamicColor: Boolean = false,
        val hapticFeedback: Boolean = true,
        val keepScreenOn: Boolean = false,
        val showBatteryOptimizationWarning: Boolean = true
    ) {
        companion object {
            fun from(src: AppSettings) = AppSettingsDto(
                darkMode = src.darkMode,
                autoConnect = src.autoConnect,
                notificationsEnabled = src.notificationsEnabled,
                rememberLogin = src.rememberLogin,
                appLanguage = src.appLanguage,
                useDynamicColor = src.useDynamicColor,
                hapticFeedback = src.hapticFeedback,
                keepScreenOn = src.keepScreenOn,
                showBatteryOptimizationWarning = src.showBatteryOptimizationWarning
            )
        }
    }

    @Serializable
    data class NetworkSettingsDto(
        val portRangeStart: Int = 8080,
        val portRangeEnd: Int = 8090,
        val discoveryTimeoutMs: Long = 30000L,
        val maxReconnectAttempts: Int = 3,
        val tlsStrictMode: Boolean = true,
        val handshakeEnabled: Boolean = true,
        val encryptionMode: String = "AES_GCM",

        // Cross-network WebRTC (Pro release defaults)
        val webrtcEnabled: Boolean = true,
        val webrtcSignalingUrl: String = SkyBridgeServerConfig.signalingWebSocketURL,
        val stunServers: List<String> = SkyBridgeServerConfig.defaultStunServers,
        val turnServers: List<String> = SkyBridgeServerConfig.defaultTurnServers
    ) {
        companion object {
            fun from(src: NetworkSettings) = NetworkSettingsDto(
                portRangeStart = src.portRangeStart,
                portRangeEnd = src.portRangeEnd,
                discoveryTimeoutMs = src.discoveryTimeoutMs,
                maxReconnectAttempts = src.maxReconnectAttempts,
                tlsStrictMode = src.tlsStrictMode,
                handshakeEnabled = src.handshakeEnabled,
                encryptionMode = src.encryptionMode,
                webrtcEnabled = src.webrtcEnabled,
                webrtcSignalingUrl = src.webrtcSignalingUrl,
                stunServers = src.stunServers,
                turnServers = src.turnServers
            )
        }
    }

    @Serializable
    data class SecuritySettingsDto(
        val requirePairing: Boolean = true,
        val autoTrustKnownDevices: Boolean = false,
        val pairingTimeoutSec: Int = 30,

        val encryptionEnabled: Boolean = true,
        val encryptionAlgorithm: String = "AES-256-GCM",
        val pqcEnabled: Boolean = true,
        val enforcePqcHandshake: Boolean = false,
        val allowClassicFallbackForCompatibility: Boolean = true,
        val pqcMinimumTier: String = "classic",
        val requireSecureEnclavePoP: Boolean = false,

        val allowScreenMirroring: Boolean = true,
        val allowFileTransfer: Boolean = true,
        val autoAcceptTrustedDevices: Boolean = false,
        val confirmOverwriteOnInbound: Boolean = true,
        val allowRemoteControl: Boolean = false,
        val remoteControlRequireConfirmation: Boolean = true,
        val allowClipboardSync: Boolean = true,

        val collectAnalytics: Boolean = false,
        val shareUsageData: Boolean = false,
        val showDeviceName: Boolean = true
    ) {
        companion object {
            fun from(src: SecuritySettings) = SecuritySettingsDto(
                requirePairing = src.requirePairing,
                autoTrustKnownDevices = src.autoTrustKnownDevices,
                pairingTimeoutSec = src.pairingTimeoutSec,
                encryptionEnabled = src.encryptionEnabled,
                encryptionAlgorithm = src.encryptionAlgorithm,
                pqcEnabled = src.pqcEnabled,
                enforcePqcHandshake = src.enforcePqcHandshake,
                allowClassicFallbackForCompatibility = src.allowClassicFallbackForCompatibility,
                pqcMinimumTier = src.pqcMinimumTier,
                requireSecureEnclavePoP = src.requireSecureEnclavePoP,
                allowScreenMirroring = src.allowScreenMirroring,
                allowFileTransfer = src.allowFileTransfer,
                autoAcceptTrustedDevices = src.autoAcceptTrustedDevices,
                confirmOverwriteOnInbound = src.confirmOverwriteOnInbound,
                allowRemoteControl = src.allowRemoteControl,
                remoteControlRequireConfirmation = src.remoteControlRequireConfirmation,
                allowClipboardSync = src.allowClipboardSync,
                collectAnalytics = src.collectAnalytics,
                shareUsageData = src.shareUsageData,
                showDeviceName = src.showDeviceName
            )
        }
    }

    @Serializable
    data class SettingsSnapshot(
        val schemaVersion: Int = 2,
        val app: AppSettingsDto = AppSettingsDto(),
        val network: NetworkSettingsDto = NetworkSettingsDto(),
        val security: SecuritySettingsDto = SecuritySettingsDto()
    )

    fun start() {
        if (job != null) return

        job = scope.launch {
            authRepository.sessionStatus
                .collect { status ->
                    when (status) {
                        is SessionStatus.Authenticated -> startAuthedSync()
                        else -> stopAuthedSync()
                    }
                }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        stopAuthedSync()
    }

    private var authedJob: Job? = null

    private fun stopAuthedSync() {
        authedJob?.cancel()
        authedJob = null
    }

    private fun startAuthedSync() {
        if (authedJob != null) return

        authedJob = scope.launch {
            // Pull once at auth (best-effort)
            runCatching { pullAndApplyOnce() }

            // Push local updates (debounced)
            @OptIn(FlowPreview::class)
            combine(
                AppSettingsStore.observe(appContext),
                NetworkSettingsStore.observe(appContext),
                SecuritySettingsStore.observe(appContext)
            ) { app, net, sec ->
                SettingsSnapshot(
                    app = AppSettingsDto.from(app),
                    network = NetworkSettingsDto.from(net),
                    security = SecuritySettingsDto.from(sec)
                )
            }
                .debounce(900)
                .collect { snap ->
                    runCatching { pushSnapshot(snap) }
                }
        }
    }

    private fun currentAuthHeaders(): Pair<String, Map<String, String>>? {
        val config = runCatching { SupabaseConfigStore.requireConfig(appContext) }.getOrNull() ?: return null
        val token = authRepository.currentAccessTokenOrNull() ?: return null
        return config.url to mapOf(
            HttpHeaders.Authorization to "Bearer $token",
            "apikey" to config.anonKey
        )
    }

    private suspend fun pullAndApplyOnce() {
        val (baseUrl, headersMap) = currentAuthHeaders() ?: return
        val userId = authRepository.currentUserIdOrNull() ?: return
        val url = "$baseUrl/rest/v1/user_settings?user_id=eq.$userId&select=settings_json,updated_at,schema_version&limit=1"

        val bodyText = httpClient.get(url) {
            headers { headersMap.forEach { (k, v) -> append(k, v) } }
        }.body<String>()

        // Supabase returns JSON array.
        val arr = runCatching { json.parseToJsonElement(bodyText).jsonArray }.getOrNull() ?: return
        val first = arr.firstOrNull()?.jsonObject ?: return
        val settingsJson = first["settings_json"] ?: return

        val snap = runCatching { json.decodeFromString(SettingsSnapshot.serializer(), settingsJson.toString()) }.getOrNull()
            ?: return
        val legacySchema = snap.schemaVersion < 2
        val securityDefaults = SecuritySettings()

        // Apply to local stores (best-effort). Local remains source-of-truth; we only set if local looks default-ish.
        // AppSettings
        AppSettingsStore.setDarkMode(appContext, snap.app.darkMode)
        AppSettingsStore.setAutoConnect(appContext, snap.app.autoConnect)
        AppSettingsStore.setNotifications(appContext, snap.app.notificationsEnabled)
        AppSettingsStore.setRememberLogin(appContext, snap.app.rememberLogin)
        AppSettingsStore.setAppLanguage(appContext, snap.app.appLanguage)
        AppSettingsStore.setUseDynamicColor(appContext, snap.app.useDynamicColor)
        AppSettingsStore.setHapticFeedback(appContext, snap.app.hapticFeedback)
        AppSettingsStore.setKeepScreenOn(appContext, snap.app.keepScreenOn)
        AppSettingsStore.setBatteryOptimizationWarning(appContext, snap.app.showBatteryOptimizationWarning)

        // Network settings
        NetworkSettingsStore.setPortRange(appContext, snap.network.portRangeStart, snap.network.portRangeEnd)
        NetworkSettingsStore.setDiscoveryTimeoutMs(appContext, snap.network.discoveryTimeoutMs)
        NetworkSettingsStore.setMaxReconnectAttempts(appContext, snap.network.maxReconnectAttempts)
        NetworkSettingsStore.setWebRtcEnabled(appContext, snap.network.webrtcEnabled)
        NetworkSettingsStore.setWebRtcSignalingUrl(appContext, snap.network.webrtcSignalingUrl)
        NetworkSettingsStore.setStunServers(appContext, snap.network.stunServers)
        NetworkSettingsStore.setTurnServers(appContext, snap.network.turnServers)

        // Security settings
        SecuritySettingsStore.setRequirePairing(appContext, snap.security.requirePairing)
        SecuritySettingsStore.setAutoTrustKnownDevices(appContext, snap.security.autoTrustKnownDevices)
        SecuritySettingsStore.setPairingTimeoutSec(appContext, snap.security.pairingTimeoutSec)
        SecuritySettingsStore.setEncryptionEnabled(appContext, snap.security.encryptionEnabled)
        SecuritySettingsStore.setEncryptionAlgorithm(appContext, snap.security.encryptionAlgorithm)
        SecuritySettingsStore.setPqcEnabled(appContext, snap.security.pqcEnabled)
        SecuritySettingsStore.setEnforcePqcHandshake(
            appContext,
            if (legacySchema) securityDefaults.enforcePqcHandshake else snap.security.enforcePqcHandshake
        )
        SecuritySettingsStore.setAllowClassicFallbackForCompatibility(
            appContext,
            if (legacySchema) securityDefaults.allowClassicFallbackForCompatibility
            else snap.security.allowClassicFallbackForCompatibility
        )
        SecuritySettingsStore.setPqcMinimumTier(
            appContext,
            if (legacySchema) securityDefaults.pqcMinimumTier else snap.security.pqcMinimumTier
        )
        SecuritySettingsStore.setRequireSecureEnclavePoP(
            appContext,
            if (legacySchema) securityDefaults.requireSecureEnclavePoP else snap.security.requireSecureEnclavePoP
        )
        SecuritySettingsStore.setAllowScreenMirroring(appContext, snap.security.allowScreenMirroring)
        SecuritySettingsStore.setAllowFileTransfer(appContext, snap.security.allowFileTransfer)
        SecuritySettingsStore.setAllowRemoteControl(appContext, snap.security.allowRemoteControl)
        SecuritySettingsStore.setAutoAcceptTrustedDevices(appContext, snap.security.autoAcceptTrustedDevices)
        SecuritySettingsStore.setConfirmOverwriteOnInbound(appContext, snap.security.confirmOverwriteOnInbound)
        SecuritySettingsStore.setRemoteControlRequireConfirmation(appContext, snap.security.remoteControlRequireConfirmation)
        SecuritySettingsStore.setAllowClipboardSync(appContext, snap.security.allowClipboardSync)
        SecuritySettingsStore.setCollectAnalytics(appContext, snap.security.collectAnalytics)
        SecuritySettingsStore.setShareUsageData(appContext, snap.security.shareUsageData)
        SecuritySettingsStore.setShowDeviceName(appContext, snap.security.showDeviceName)
    }

    private suspend fun pushSnapshot(snapshot: SettingsSnapshot) {
        val (baseUrl, headersMap) = currentAuthHeaders() ?: return
        val userId = authRepository.currentUserIdOrNull() ?: return
        val url = "$baseUrl/rest/v1/user_settings?on_conflict=user_id"

        val payload = buildJsonObject {
            put("user_id", userId)
            put("schema_version", snapshot.schemaVersion)
            // Store as real jsonb, not a JSON string.
            put("settings_json", json.parseToJsonElement(json.encodeToString(SettingsSnapshot.serializer(), snapshot)))
            put("updated_at", Instant.now().toString())
        }.toString()

        httpClient.post(url) {
            contentType(ContentType.Application.Json)
            headers {
                headersMap.forEach { (k, v) -> append(k, v) }
                append("Prefer", "resolution=merge-duplicates")
                append("Prefer", "return=minimal")
            }
            setBody(payload)
        }
    }

    companion object
}
