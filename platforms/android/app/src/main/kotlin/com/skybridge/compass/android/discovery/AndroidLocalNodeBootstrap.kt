package com.skybridge.compass.android.discovery

import android.content.Context
import android.os.Build
import android.util.Log
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.core.p2p.TcpControlEvent
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.core.p2p.TcpControlSession
import com.skybridge.compass.discovery.data.datasources.BonjourLocalNetworkPermissionPolicy
import com.skybridge.compass.discovery.data.services.P2PLocalNodeService
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

@Singleton
class AndroidLocalNodeBootstrap @Inject constructor(
    @param:ApplicationContext private val appContext: Context,
    private val localNodeService: P2PLocalNodeService,
    private val tcpControlServer: TcpControlServer
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var observeJob: Job? = null
    private var incomingSessionsJob: Job? = null
    private val activeIncomingSessions: MutableMap<Int, TcpControlSession> = ConcurrentHashMap()
    private val incomingSessionJobs: MutableMap<Int, Job> = ConcurrentHashMap()

    /**
     * Starts the local Bonjour presence only after Android's local-network gate is satisfied.
     * Returning false is an expected first-run state, not a transient network failure to retry.
     */
    fun start(): Boolean {
        if (!BonjourLocalNetworkPermissionPolicy.isGranted(appContext, Build.VERSION.SDK_INT)) {
            Log.i(TAG, "Android Bonjour presence waiting for local-network permission")
            return false
        }
        if (observeJob?.isActive == true) return true
        Log.i(TAG, "Starting Android Bonjour presence bootstrap")
        collectIncomingSessions()
        observeJob = scope.launch {
            SecuritySettingsStore.observe(appContext)
                .map(AndroidLocalNodeBootstrapPolicy::advertisementSettings)
                .distinctUntilChanged()
                .collectLatest { settings ->
                    startLocalNode(settings)
                }
        }.also { job ->
            job.invokeOnCompletion { error ->
                if (error != null && error !is CancellationException) {
                    Log.e(TAG, "Android Bonjour presence monitor stopped unexpectedly", error)
                }
            }
        }
        return true
    }

    fun stop() {
        observeJob?.cancel()
        observeJob = null
        incomingSessionsJob?.cancel()
        incomingSessionsJob = null
        incomingSessionJobs.values.forEach { it.cancel() }
        incomingSessionJobs.clear()
        activeIncomingSessions.values.forEach { it.close() }
        activeIncomingSessions.clear()
        localNodeService.stop()
    }

    private suspend fun startLocalNode(settings: AndroidLocalNodeAdvertisementSettings) {
        var attempt = 1
        while (currentCoroutineContext().isActive) {
            try {
                Log.i(
                    TAG,
                    "Android Bonjour presence settings resolved showDeviceName=${settings.showDeviceName} " +
                        "verifiedCapabilities=${settings.verifiedCapabilities.size} attempt=$attempt"
                )
                val port = localNodeService.start(
                    showDeviceName = settings.showDeviceName,
                    verifiedCapabilities = settings.verifiedCapabilities
                )
                Log.i(TAG, "Android Bonjour presence active on _skybridge._tcp port=$port")
                return
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!BonjourLocalNetworkPermissionPolicy.isGranted(appContext, Build.VERSION.SDK_INT)) {
                    Log.w(TAG, "Android Bonjour presence stopped because local-network permission is unavailable")
                    return
                }
                Log.e(
                    TAG,
                    "Android Bonjour presence stopped after startup failure attempt=$attempt " +
                        "retryInMs=$START_RETRY_DELAY_MS",
                    error
                )
                delay(START_RETRY_DELAY_MS)
                attempt += 1
            }
        }
    }

    fun close() {
        stop()
        scope.cancel()
    }

    private fun collectIncomingSessions() {
        if (incomingSessionsJob?.isActive == true) return
        incomingSessionsJob = scope.launch {
            tcpControlServer.incomingSessions.collect { session ->
                val sessionId = System.identityHashCode(session)
                activeIncomingSessions[sessionId] = session
                incomingSessionJobs[sessionId] = scope.launch {
                    observeIncomingSession(sessionId = sessionId, session = session)
                }
            }
        }
    }

    private suspend fun observeIncomingSession(
        sessionId: Int,
        session: TcpControlSession
    ) {
        try {
            session.events
                .onEach { event -> logIncomingSessionEvent(sessionId = sessionId, event = event) }
                .takeWhile { event -> event !is TcpControlEvent.Disconnected }
                .collect()
        } finally {
            activeIncomingSessions.remove(sessionId)
            incomingSessionJobs.remove(sessionId)
        }
    }

    private fun logIncomingSessionEvent(sessionId: Int, event: TcpControlEvent) {
        when (event) {
            is TcpControlEvent.HandshakeEstablished -> Log.i(
                TAG,
                "Inbound TCP control session established id=$sessionId suite=0x${
                    event.negotiatedSuiteWireId.toString(radix = 16)
                } peerKnown=${event.peerId != null}"
            )
            is TcpControlEvent.AppMessageReceived -> Log.i(
                TAG,
                "Inbound TCP control app message id=$sessionId type=${event.message.javaClass.simpleName}"
            )
            is TcpControlEvent.RemoteDesktopFrameReceived -> Log.d(
                TAG,
                "Inbound TCP remote desktop frame id=$sessionId bytes=${event.payload.size}"
            )
            is TcpControlEvent.Failed -> Log.e(
                TAG,
                "Inbound TCP control session failed id=$sessionId error=${event.error}"
            )
            is TcpControlEvent.Disconnected -> Log.i(
                TAG,
                "Inbound TCP control session disconnected id=$sessionId"
            )
        }
    }

    private companion object {
        private const val TAG = "AndroidLocalNode"
        private const val START_RETRY_DELAY_MS = 30_000L
    }
}

internal data class AndroidLocalNodeAdvertisementSettings(
    val showDeviceName: Boolean,
    val verifiedCapabilities: Set<DeviceCapability>
)

/**
 * Runtime precondition for a single advertised capability: a capability is only truthfully
 * advertised when the user has granted the corresponding access permission AND the local
 * subsystem that backs it is actually ready. Both facts must hold at advertisement time.
 */
internal data class CapabilityPrecondition(
    val permissionGranted: Boolean,
    val serviceReady: Boolean
) {
    val isSatisfied: Boolean get() = permissionGranted && serviceReady
}

/**
 * Snapshot of every capability's runtime precondition at advertisement time. Capabilities absent
 * from the map are treated as unsatisfied.
 */
internal data class CapabilityRuntimeState(
    val preconditions: Map<DeviceCapability, CapabilityPrecondition>
)

/**
 * Resolves the set of capabilities that may be advertised. A capability appears in the result
 * if and only if its runtime precondition (permission granted + service ready) holds. When at
 * least one precondition holds the result is non-empty; when none hold the result is empty.
 */
internal fun interface VerifiedCapabilityResolver {
    fun resolve(now: CapabilityRuntimeState): Set<DeviceCapability>
}

internal object DefaultVerifiedCapabilityResolver : VerifiedCapabilityResolver {
    override fun resolve(now: CapabilityRuntimeState): Set<DeviceCapability> =
        now.preconditions
            .asSequence()
            .filter { (_, precondition) -> precondition.isSatisfied }
            .map { (capability, _) -> capability }
            .toCollection(LinkedHashSet())
}

internal object AndroidLocalNodeBootstrapPolicy {
    private val resolver: VerifiedCapabilityResolver = DefaultVerifiedCapabilityResolver

    fun advertisementSettings(settings: SecuritySettings): AndroidLocalNodeAdvertisementSettings =
        AndroidLocalNodeAdvertisementSettings(
            showDeviceName = settings.showDeviceName,
            verifiedCapabilities = resolver.resolve(capabilityRuntimeState(settings))
        )

    /**
     * Maps the persisted access toggles to per-capability runtime preconditions.
     *
     * - Permission is the user's access consent from [SecuritySettings].
     * - Service readiness reflects whether the Android-side subsystem that backs the capability is
     *   actually reachable today. File transfer and clipboard sync are delivered and reachable from
     *   the LAN control endpoint, so they are service-ready. Screen sharing (host capture) and
     *   remote control (accessibility injection) host capabilities are not yet delivered, so they
     *   are never advertised regardless of the access toggle.
     */
    internal fun capabilityRuntimeState(settings: SecuritySettings): CapabilityRuntimeState =
        CapabilityRuntimeState(
            preconditions = linkedMapOf(
                DeviceCapability.FILE_TRANSFER to CapabilityPrecondition(
                    permissionGranted = settings.allowFileTransfer,
                    serviceReady = true
                ),
                DeviceCapability.CLIPBOARD_SYNC to CapabilityPrecondition(
                    permissionGranted = settings.allowClipboardSync,
                    serviceReady = true
                ),
                DeviceCapability.SCREEN_SHARING to CapabilityPrecondition(
                    permissionGranted = settings.allowScreenMirroring,
                    serviceReady = false
                ),
                DeviceCapability.REMOTE_CONTROL to CapabilityPrecondition(
                    permissionGranted = settings.allowRemoteControl,
                    serviceReady = false
                )
            )
        )
}
