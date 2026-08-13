package com.skybridge.compass.android.discovery

import android.content.Context
import android.os.Build
import android.util.Log
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsSource
import com.skybridge.compass.core.p2p.TcpControlEvent
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.core.p2p.TcpControlSession
import com.skybridge.compass.discovery.data.datasources.BonjourLocalNetworkPermissionPolicy
import com.skybridge.compass.discovery.data.services.P2PLocalNodeService
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Singleton
class AndroidLocalNodeBootstrap internal constructor(
    private val localNodeService: P2PLocalNodeService,
    private val tcpControlServer: TcpControlServer,
    dispatcher: CoroutineDispatcher,
    private val observeSecuritySettings: () -> kotlinx.coroutines.flow.Flow<SecuritySettings>,
    private val permissionGranted: () -> Boolean,
    private val lifecycleHooks: AndroidLocalNodeLifecycleHooks = AndroidLocalNodeLifecycleHooks(),
    private val logInfo: (String) -> Unit = { },
    private val logWarning: (String) -> Unit = { },
    private val logError: (String, Throwable) -> Unit = { _, _ -> }
) {
    @Inject
    constructor(
        @ApplicationContext appContext: Context,
        localNodeService: P2PLocalNodeService,
        tcpControlServer: TcpControlServer,
        securitySettingsSource: SecuritySettingsSource
    ) : this(
        localNodeService = localNodeService,
        tcpControlServer = tcpControlServer,
        dispatcher = Dispatchers.IO,
        observeSecuritySettings = securitySettingsSource::observe,
        permissionGranted = {
            BonjourLocalNetworkPermissionPolicy.isGranted(appContext, Build.VERSION.SDK_INT)
        },
        logInfo = { message -> Log.i(TAG, message) },
        logWarning = { message -> Log.w(TAG, message) },
        logError = { message, error -> Log.e(TAG, message, error) }
    )

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val lifecycleCommands = Channel<LifecycleCommand>(capacity = LIFECYCLE_COMMAND_CAPACITY)
    private val nextSessionId = AtomicLong(0)
    private val requestLock = Any()
    private var requestGeneration = 0L
    private var desiredRunning = false
    private var closed = false
    private var lifecycleJob: Job? = null
    private var lifecycleGeneration = 0L
    private var cleanupRequired = false
    private val lifecycleCoordinator = scope.launch {
        for (command in lifecycleCommands) {
            when (command) {
                is LifecycleCommand.Start -> {
                    handleStartCommand(command.generation)
                }
                is LifecycleCommand.Stop -> completeLifecycleCommand(command.completion) {
                    lifecycleHooks.afterStopCommandClaimed()
                    stopRuntime()
                }
                is LifecycleCommand.Close -> {
                    val closedCleanly = completeLifecycleCommand(command.completion) {
                        lifecycleHooks.afterStopCommandClaimed()
                        stopRuntime()
                    }
                    if (closedCleanly) {
                        lifecycleCommands.close()
                        return@launch
                    }
                }
                is LifecycleCommand.RuntimeEnded -> {
                    if (lifecycleJob === command.job) {
                        lifecycleJob = null
                        val ownerGeneration = lifecycleGeneration
                        synchronized(requestLock) {
                            if (requestGeneration == ownerGeneration) desiredRunning = false
                        }
                        try {
                            cleanupRuntimeIfNeeded()
                        } catch (cleanupError: Exception) {
                            command.error.addSuppressed(cleanupError)
                            synchronized(requestLock) {
                                if (requestGeneration == ownerGeneration) desiredRunning = false
                            }
                            logError(
                                "Android Bonjour presence terminated with cleanup failure",
                                command.error
                            )
                        }
                        val restartGeneration = synchronized(requestLock) {
                            requestGeneration.takeIf {
                                !closed && desiredRunning && it != ownerGeneration
                            }
                        }
                        if (restartGeneration != null) {
                            handleStartCommand(restartGeneration)
                        }
                    }
                }
            }
        }
    }

    /**
     * Starts the local Bonjour presence only after Android's local-network gate is satisfied.
     * Returning false is an expected first-run state, not a transient network failure to retry.
     */
    fun start(): Boolean {
        if (!permissionGranted()) {
            logInfo("Android Bonjour presence waiting for local-network permission")
            return false
        }
        synchronized(requestLock) {
            check(!closed) { "Android Bonjour presence bootstrap is closed" }
            val previousGeneration = requestGeneration
            val previousDesiredRunning = desiredRunning
            desiredRunning = true
            val command = LifecycleCommand.Start(++requestGeneration)
            if (lifecycleCommands.trySend(command).isFailure) {
                requestGeneration = previousGeneration
                desiredRunning = previousDesiredRunning
                error("Android Bonjour presence command queue is full or closed")
            }
        }
        logInfo("Starting Android Bonjour presence bootstrap")
        return true
    }

    suspend fun stop() {
        val completion = CompletableDeferred<Unit>()
        synchronized(requestLock) {
            check(!closed) { "Android Bonjour presence bootstrap is closed" }
            val previousGeneration = requestGeneration
            val previousDesiredRunning = desiredRunning
            desiredRunning = false
            requestGeneration += 1
            val command = LifecycleCommand.Stop(completion)
            if (lifecycleCommands.trySend(command).isFailure) {
                requestGeneration = previousGeneration
                desiredRunning = previousDesiredRunning
                error("Android Bonjour presence command queue is full or closed")
            }
        }
        completion.await()
    }

    private suspend fun startRuntimeIfNeeded(generation: Long) {
        val existing = lifecycleJob
        if (existing?.isActive == true) {
            return
        }
        if (existing != null || cleanupRequired) stopRuntime()
        if (!isCurrentStartRequest(generation)) return
        cleanupRequired = true
        lifecycleGeneration = generation
        var runtimeError: Throwable? = null
        lifecycleJob = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                coroutineScope {
                    launch(start = CoroutineStart.UNDISPATCHED) { collectIncomingSessions() }
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        tcpControlServer.terminalFailure
                            .filterNotNull()
                            .collect { failure ->
                                throw IllegalStateException(
                                    "Android Bonjour presence lost its TCP listener",
                                    failure.cause
                                )
                            }
                    }
                    observeSecuritySettings()
                        .map(AndroidLocalNodeBootstrapPolicy::advertisementSettings)
                        .distinctUntilChanged()
                        .collectLatest { settings -> startLocalNode(settings) }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                runtimeError = error
            }
        }.also { job ->
            job.invokeOnCompletion { completionError ->
                val error = runtimeError ?: completionError
                    ?: IllegalStateException("Android Bonjour presence runtime ended unexpectedly")
                if (error !is CancellationException) {
                    logError("Android Bonjour presence monitor stopped unexpectedly", error)
                }
                postRuntimeEnded(LifecycleCommand.RuntimeEnded(job, error))
            }
        }
    }

    private suspend fun handleStartCommand(generation: Long) {
        if (!isCurrentStartRequest(generation)) return
        try {
            startRuntimeIfNeeded(generation)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            synchronized(requestLock) {
                if (requestGeneration == generation) desiredRunning = false
            }
            logError("Android Bonjour presence failed to start", error)
        }
    }

    private fun postRuntimeEnded(command: LifecycleCommand.RuntimeEnded) {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                lifecycleCommands.send(command)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!synchronized(requestLock) { closed }) {
                    logError("Android Bonjour presence coordinator rejected runtime completion", error)
                }
            }
        }
    }

    private fun isCurrentStartRequest(generation: Long): Boolean = synchronized(requestLock) {
        !closed && desiredRunning && requestGeneration == generation
    }

    private suspend fun stopRuntime() {
        val job = lifecycleJob
        lifecycleJob = null
        job?.cancelAndJoin()
        cleanupRuntimeIfNeeded()
    }

    private suspend fun cleanupRuntimeIfNeeded() {
        if (cleanupRequired) {
            localNodeService.stop()
            lifecycleHooks.afterRuntimeStopped()
            cleanupRequired = false
        }
    }

    private suspend fun completeLifecycleCommand(
        completion: CompletableDeferred<Unit>,
        operation: suspend () -> Unit
    ): Boolean {
        try {
            operation()
            completion.complete(Unit)
            return true
        } catch (error: Exception) {
            completion.completeExceptionally(error)
            return false
        }
    }

    private suspend fun startLocalNode(settings: AndroidLocalNodeAdvertisementSettings) {
        var attempt = 1
        while (currentCoroutineContext().isActive) {
            try {
                logInfo(
                    "Android Bonjour presence settings resolved showDeviceName=${settings.showDeviceName} " +
                        "verifiedCapabilities=${settings.verifiedCapabilities.size} attempt=$attempt"
                )
                val port = localNodeService.start(
                    showDeviceName = settings.showDeviceName,
                    verifiedCapabilities = settings.verifiedCapabilities
                )
                logInfo("Android Bonjour presence active on _skybridge._tcp port=$port")
                return
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!permissionGranted()) {
                    logWarning("Android Bonjour presence stopped because local-network permission is unavailable")
                    return
                }
                logError(
                    "Android Bonjour presence stopped after startup failure attempt=$attempt " +
                        "retryInMs=$START_RETRY_DELAY_MS",
                    error
                )
                delay(START_RETRY_DELAY_MS)
                attempt += 1
            }
        }
    }

    suspend fun close() {
        val completion = CompletableDeferred<Unit>()
        synchronized(requestLock) {
            check(!closed) { "Android Bonjour presence bootstrap is closed" }
            val previousGeneration = requestGeneration
            val previousDesiredRunning = desiredRunning
            closed = true
            desiredRunning = false
            requestGeneration += 1
            val command = LifecycleCommand.Close(completion)
            if (lifecycleCommands.trySend(command).isFailure) {
                closed = false
                requestGeneration = previousGeneration
                desiredRunning = previousDesiredRunning
                error("Android Bonjour presence command queue is full or closed")
            }
        }
        withContext(NonCancellable) {
            var completed = false
            try {
                completion.await()
                lifecycleCoordinator.join()
                completed = true
            } finally {
                if (!completed) {
                    synchronized(requestLock) { closed = false }
                } else {
                    scope.cancel()
                }
            }
        }
    }

    private suspend fun collectIncomingSessions(): Nothing = coroutineScope {
        tcpControlServer.incomingSessions.collect { session ->
            val sessionId = nextSessionId.incrementAndGet()
            launch(start = CoroutineStart.UNDISPATCHED) {
                observeIncomingSession(sessionId = sessionId, session = session)
            }
        }
    }

    private suspend fun observeIncomingSession(
        sessionId: Long,
        session: TcpControlSession
    ) {
        try {
            session.events
                .onEach { event -> logIncomingSessionEvent(sessionId = sessionId, event = event) }
                .takeWhile { event ->
                    event !is TcpControlEvent.Failed && event !is TcpControlEvent.Disconnected
                }
                .collect { }
        } finally { session.close() }
    }

    private fun logIncomingSessionEvent(sessionId: Long, event: TcpControlEvent) {
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

    private sealed interface LifecycleCommand {
        data class Start(val generation: Long) : LifecycleCommand
        data class Stop(val completion: CompletableDeferred<Unit>) : LifecycleCommand
        data class Close(val completion: CompletableDeferred<Unit>) : LifecycleCommand
        data class RuntimeEnded(
            val job: Job,
            val error: Throwable
        ) : LifecycleCommand
    }

    private companion object {
        private const val TAG = "AndroidLocalNode"
        private const val START_RETRY_DELAY_MS = 30_000L
        private const val LIFECYCLE_COMMAND_CAPACITY = 64
    }
}

internal class AndroidLocalNodeLifecycleHooks(
    val afterStopCommandClaimed: suspend () -> Unit = { },
    val afterRuntimeStopped: suspend () -> Unit = { }
)

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
