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
import com.skybridge.compass.supabase.SupabaseConfigException
import com.skybridge.compass.supabase.SupabasePostgrestUrls
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.jan.supabase.auth.status.SessionStatus
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Cloud sync for settings (local DataStore remains source-of-truth).
 *
 * - Pull once when user becomes authenticated (best-effort).
 * - Push debounced on local changes (best-effort).
 *
 * Requires Supabase table + RLS:
 * - docs/supabase/user_settings.sql
 */
@Singleton
class CloudUserSettingsSyncManager internal constructor(
    private val authState: CloudSettingsAuthState,
    private val remoteStore: CloudSettingsRemoteStore,
    private val localStore: CloudSettingsLocalStore,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
) {
    private var job: Job? = null
    private val _syncStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val syncStatus: StateFlow<SyncStatus> = _syncStatus.asStateFlow()

    sealed interface SyncStatus {
        data object Idle : SyncStatus
        data object Running : SyncStatus
        data object Synced : SyncStatus
        data class Failed(val stage: String, val message: String) : SyncStatus
    }

    class CloudSettingsSyncException(
        val stage: String,
        detail: String,
        val retryable: Boolean = true
    ) : IllegalStateException("$stage: $detail")

    @Inject
    constructor(
        @ApplicationContext appContext: Context,
        authRepository: AuthRepository,
        httpClient: HttpClient,
        json: Json
    ) : this(
        appContext = appContext,
        authState = AuthRepositoryCloudSettingsAuthState(authRepository),
        httpClient = httpClient,
        json = json
    )

    private constructor(
        appContext: Context,
        authState: CloudSettingsAuthState,
        httpClient: HttpClient,
        json: Json
    ) : this(
        authState = authState,
        remoteStore = SupabaseCloudSettingsRemoteStore(
            configProvider = { SupabaseConfigStore.requireConfig(appContext) },
            authState = authState,
            httpClient = httpClient,
            json = json
        ),
        localStore = AndroidCloudSettingsLocalStore(appContext)
    )

    @Serializable
    data class AppSettingsDto(
        val darkMode: Boolean = true,
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
        val enforcePqcHandshake: Boolean = true,
        val allowClassicFallbackForCompatibility: Boolean = false,
        val pqcMinimumTier: String = "nativePQC",
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
            authState.authenticated
                .collect { authenticated ->
                    if (authenticated) {
                        startAuthedSync()
                    } else {
                        stopAuthedSync()
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

        val launched = scope.launch {
            var pullRetryJob: Job? = null
            try {
                _syncStatus.value = SyncStatus.Running
                val pullResult = runSyncStage("pull") {
                    pullAndApplyOnce()
                }
                if (!pullResult.succeeded && pullResult.retryable) {
                    pullRetryJob = launchPullRetryJob()
                }

                // Push local updates (debounced)
                @OptIn(FlowPreview::class)
                localStore.snapshots()
                    .debounce(900)
                    .collect { snap ->
                        val pushed = runSyncStage("push") {
                            pushSnapshot(snap)
                        }
                        if (pushed.succeeded) {
                            _syncStatus.value = SyncStatus.Synced
                        }
                    }
            } catch (t: Throwable) {
                if (t is CancellationException) throw t
                recordSyncFailure(t, "sync")
            } finally {
                pullRetryJob?.cancel()
            }
        }
        authedJob = launched
        launched.invokeOnCompletion {
            if (authedJob === launched) {
                authedJob = null
            }
        }
    }

    private suspend fun pullAndApplyOnce() {
        val snap = remoteStore.pull() ?: return
        val securityDefaults = SecuritySettings()
        try {
            CloudSettingsPullPolicy.validateIncomingSnapshot(snap, securityDefaults)
        } catch (violation: CloudSettingsPullPolicy.Violation) {
            throw CloudSettingsSyncException(
                stage = "pull",
                detail = violation.message ?: "cloud settings policy violation",
                retryable = false
            )
        }

        localStore.applySnapshotIfDefaults(snap, securityDefaults)
    }

    private suspend fun pushSnapshot(snapshot: SettingsSnapshot) {
        remoteStore.push(snapshot)
    }

    private data class SyncStageResult(
        val succeeded: Boolean,
        val retryable: Boolean
    )

    private suspend fun runSyncStage(stage: String, block: suspend () -> Unit): SyncStageResult =
        try {
            block()
            SyncStageResult(succeeded = true, retryable = false)
        } catch (t: Throwable) {
            if (t is CancellationException) throw t
            recordSyncFailure(t, stage)
            SyncStageResult(
                succeeded = false,
                retryable = (t as? CloudSettingsSyncException)?.retryable ?: true
            )
        }

    private fun launchPullRetryJob(): Job = scope.launch {
        for (attempt in 1..MAX_PULL_RETRY_ATTEMPTS) {
            delay(pullRetryDelayMillis(attempt))
            val result = runSyncStage("pull") {
                pullAndApplyOnce()
            }
            if (result.succeeded) {
                _syncStatus.value = SyncStatus.Synced
                return@launch
            }
            if (!result.retryable) {
                return@launch
            }
        }
    }

    private fun recordSyncFailure(t: Throwable, fallbackStage: String) {
        _syncStatus.value = when (t) {
            is CloudSettingsSyncException -> SyncStatus.Failed(t.stage, t.message ?: t.stage)
            else -> SyncStatus.Failed(fallbackStage, t.message ?: t.javaClass.simpleName)
        }
    }

    internal companion object {
        const val MAX_PULL_RETRY_ATTEMPTS = 3

        fun pullRetryDelayMillis(attempt: Int): Long =
            when (attempt) {
                1 -> 1_000L
                2 -> 5_000L
                else -> 30_000L
            }
    }
}

internal interface CloudSettingsAuthState {
    val authenticated: Flow<Boolean>
    fun currentAccessTokenOrNull(): String?
    fun currentUserIdOrNull(): String?
}

internal interface CloudSettingsRemoteStore {
    suspend fun pull(): CloudUserSettingsSyncManager.SettingsSnapshot?
    suspend fun push(snapshot: CloudUserSettingsSyncManager.SettingsSnapshot)
}

internal interface CloudSettingsLocalStore {
    fun snapshots(): Flow<CloudUserSettingsSyncManager.SettingsSnapshot>
    suspend fun applySnapshotIfDefaults(
        snapshot: CloudUserSettingsSyncManager.SettingsSnapshot,
        securityDefaults: SecuritySettings
    )
}

private class AuthRepositoryCloudSettingsAuthState(
    private val authRepository: AuthRepository
) : CloudSettingsAuthState {
    override val authenticated: Flow<Boolean> =
        authRepository.sessionStatus
            .map { it is SessionStatus.Authenticated }
            .distinctUntilChanged()

    override fun currentAccessTokenOrNull(): String? =
        authRepository.currentAccessTokenOrNull()

    override fun currentUserIdOrNull(): String? =
        authRepository.currentUserIdOrNull()
}

internal class SupabaseCloudSettingsRemoteStore(
    private val configProvider: () -> com.skybridge.compass.android.data.SupabaseConfig,
    private val authState: CloudSettingsAuthState,
    private val httpClient: HttpClient,
    private val json: Json
) : CloudSettingsRemoteStore {

    override suspend fun pull(): CloudUserSettingsSyncManager.SettingsSnapshot? {
        val (baseUrl, headersMap) = requireAuthHeaders("pull")
        val userId = requireUserId("pull")
        val url = SupabasePostgrestUrls.table(
            baseUrl = baseUrl,
            table = "user_settings",
            query = mapOf(
                "user_id" to "eq.$userId",
                "select" to "settings_json,updated_at,schema_version",
                "limit" to "1"
            )
        )

        val response = httpClient.get(url) {
            headers { headersMap.forEach { (k, v) -> append(k, v) } }
        }
        requireSuccessfulResponse(response, "pull")
        val bodyText = response.body<String>()

        val arr = runCatching { json.parseToJsonElement(bodyText).jsonArray }
            .getOrElse {
                throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                    "pull",
                    "invalid settings response JSON",
                    retryable = false
                )
            }
        val first = arr.firstOrNull()?.jsonObject ?: return null
        val settingsJson = first["settings_json"]
            ?: throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                "pull",
                "settings_json missing",
                retryable = false
            )
        val rowSchemaVersion = first["schema_version"]?.jsonPrimitive?.intOrNull

        val decoded = runCatching {
            json.decodeFromString(
                CloudUserSettingsSyncManager.SettingsSnapshot.serializer(),
                settingsJson.toString()
            )
        }.getOrElse {
            throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                "pull",
                "invalid settings snapshot JSON",
                retryable = false
            )
        }
        return rowSchemaVersion?.let { decoded.copy(schemaVersion = it) } ?: decoded
    }

    override suspend fun push(snapshot: CloudUserSettingsSyncManager.SettingsSnapshot) {
        val (baseUrl, headersMap) = requireAuthHeaders("push")
        val userId = requireUserId("push")
        val url = SupabasePostgrestUrls.table(
            baseUrl = baseUrl,
            table = "user_settings",
            query = mapOf("on_conflict" to "user_id")
        )

        val payload = buildJsonObject {
            put("user_id", userId)
            put("schema_version", snapshot.schemaVersion)
            put(
                "settings_json",
                json.parseToJsonElement(
                    json.encodeToString(
                        CloudUserSettingsSyncManager.SettingsSnapshot.serializer(),
                        snapshot
                    )
                )
            )
            put("updated_at", Instant.now().toString())
        }.toString()

        val response = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            headers {
                headersMap.forEach { (k, v) -> append(k, v) }
                append("Prefer", "resolution=merge-duplicates")
                append("Prefer", "return=minimal")
            }
            setBody(payload)
        }
        requireSuccessfulResponse(response, "push")
    }

    private fun requireAuthHeaders(stage: String): Pair<String, Map<String, String>> {
        val config = try {
            configProvider()
        } catch (error: SupabaseConfigException) {
            throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                stage,
                "Supabase config unavailable: ${error.message ?: error.javaClass.simpleName}",
                retryable = false
            )
        }
        val token = authState.currentAccessTokenOrNull()
            ?: throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                stage,
                "missing Supabase access token",
                retryable = false
            )
        return config.url to mapOf(
            HttpHeaders.Authorization to "Bearer $token",
            "apikey" to config.anonKey
        )
    }

    private fun requireUserId(stage: String): String =
        authState.currentUserIdOrNull()
            ?: throw CloudUserSettingsSyncManager.CloudSettingsSyncException(
                stage,
                "missing authenticated user id",
                retryable = false
            )

    private fun requireSuccessfulResponse(response: HttpResponse, stage: String) {
        if (!response.status.isSuccess()) {
            throw CloudUserSettingsSyncManager.CloudSettingsSyncException(stage, "HTTP ${response.status.value}")
        }
    }
}

private class AndroidCloudSettingsLocalStore(
    private val appContext: Context
) : CloudSettingsLocalStore {

    override fun snapshots(): Flow<CloudUserSettingsSyncManager.SettingsSnapshot> =
        combine(
            AppSettingsStore.observe(appContext),
            NetworkSettingsStore.observe(appContext),
            SecuritySettingsStore.observe(appContext)
        ) { app, net, sec ->
            CloudUserSettingsSyncManager.SettingsSnapshot(
                app = CloudUserSettingsSyncManager.AppSettingsDto.from(app),
                network = CloudUserSettingsSyncManager.NetworkSettingsDto.from(net),
                security = CloudUserSettingsSyncManager.SecuritySettingsDto.from(sec)
            )
        }

    override suspend fun applySnapshotIfDefaults(
        snapshot: CloudUserSettingsSyncManager.SettingsSnapshot,
        securityDefaults: SecuritySettings
    ) {
        val legacySchema = snapshot.schemaVersion < 2

        // Apply cloud state only while the local group is still at defaults. Without local
        // per-setting timestamps, this avoids stale cloud rows overwriting explicit local changes.
        if (AppSettingsStore.observe(appContext).first() == AppSettings()) {
            AppSettingsStore.setDarkMode(appContext, snapshot.app.darkMode)
            AppSettingsStore.setAutoConnect(appContext, snapshot.app.autoConnect)
            AppSettingsStore.setNotifications(appContext, snapshot.app.notificationsEnabled)
            AppSettingsStore.setRememberLogin(appContext, snapshot.app.rememberLogin)
            AppSettingsStore.setAppLanguage(appContext, snapshot.app.appLanguage)
            AppSettingsStore.setUseDynamicColor(appContext, snapshot.app.useDynamicColor)
            AppSettingsStore.setHapticFeedback(appContext, snapshot.app.hapticFeedback)
            AppSettingsStore.setKeepScreenOn(appContext, snapshot.app.keepScreenOn)
            AppSettingsStore.setBatteryOptimizationWarning(appContext, snapshot.app.showBatteryOptimizationWarning)
        }

        if (NetworkSettingsStore.observe(appContext).first() == NetworkSettings()) {
            // R7.8：这三项已改为「先校验后写入」。云端快照里越界的历史值会被**拒绝**而不再被静默
            // 钳制，此时本地保留默认值，避免把非法端口/窗口/次数当成用户设置落盘。
            NetworkSettingsStore.setPortRange(appContext, snapshot.network.portRangeStart, snapshot.network.portRangeEnd)
            NetworkSettingsStore.setDiscoveryTimeoutMs(appContext, snapshot.network.discoveryTimeoutMs)
            NetworkSettingsStore.setMaxReconnectAttempts(appContext, snapshot.network.maxReconnectAttempts)
            NetworkSettingsStore.setTlsStrictMode(appContext, snapshot.network.tlsStrictMode)
            NetworkSettingsStore.setHandshakeEnabled(appContext, snapshot.network.handshakeEnabled)
            NetworkSettingsStore.setEncryptionMode(appContext, snapshot.network.encryptionMode)
            NetworkSettingsStore.setWebRtcEnabled(appContext, snapshot.network.webrtcEnabled)
            NetworkSettingsStore.setWebRtcSignalingUrl(appContext, snapshot.network.webrtcSignalingUrl)
            NetworkSettingsStore.setStunServers(appContext, snapshot.network.stunServers)
            NetworkSettingsStore.setTurnServers(appContext, snapshot.network.turnServers)
        }

        if (SecuritySettingsStore.observe(appContext).first() == SecuritySettings()) {
            SecuritySettingsStore.setRequirePairing(appContext, snapshot.security.requirePairing)
            SecuritySettingsStore.setAutoTrustKnownDevices(appContext, snapshot.security.autoTrustKnownDevices)
            SecuritySettingsStore.setPairingTimeoutSec(appContext, snapshot.security.pairingTimeoutSec)
            SecuritySettingsStore.setEncryptionEnabled(appContext, snapshot.security.encryptionEnabled)
            SecuritySettingsStore.setEncryptionAlgorithm(appContext, snapshot.security.encryptionAlgorithm)
            SecuritySettingsStore.setPqcEnabled(appContext, snapshot.security.pqcEnabled)
            SecuritySettingsStore.setEnforcePqcHandshake(
                appContext,
                if (legacySchema) securityDefaults.enforcePqcHandshake
                else snapshot.security.enforcePqcHandshake
            )
            SecuritySettingsStore.setAllowClassicFallbackForCompatibility(
                appContext,
                if (legacySchema) securityDefaults.allowClassicFallbackForCompatibility
                else snapshot.security.allowClassicFallbackForCompatibility
            )
            SecuritySettingsStore.setPqcMinimumTier(
                appContext,
                if (legacySchema) securityDefaults.pqcMinimumTier else snapshot.security.pqcMinimumTier
            )
            SecuritySettingsStore.setRequireSecureEnclavePoP(
                appContext,
                if (legacySchema) securityDefaults.requireSecureEnclavePoP
                else snapshot.security.requireSecureEnclavePoP
            )
            SecuritySettingsStore.setAllowScreenMirroring(appContext, snapshot.security.allowScreenMirroring)
            SecuritySettingsStore.setAllowFileTransfer(appContext, snapshot.security.allowFileTransfer)
            SecuritySettingsStore.setAllowRemoteControl(appContext, snapshot.security.allowRemoteControl)
            SecuritySettingsStore.setAutoAcceptTrustedDevices(appContext, snapshot.security.autoAcceptTrustedDevices)
            SecuritySettingsStore.setConfirmOverwriteOnInbound(appContext, snapshot.security.confirmOverwriteOnInbound)
            SecuritySettingsStore.setRemoteControlRequireConfirmation(
                appContext,
                snapshot.security.remoteControlRequireConfirmation
            )
            SecuritySettingsStore.setAllowClipboardSync(appContext, snapshot.security.allowClipboardSync)
            SecuritySettingsStore.setCollectAnalytics(appContext, snapshot.security.collectAnalytics)
            SecuritySettingsStore.setShareUsageData(appContext, snapshot.security.shareUsageData)
            SecuritySettingsStore.setShowDeviceName(appContext, snapshot.security.showDeviceName)
        }
    }
}
