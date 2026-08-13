package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.network.ListenPortAllocator
import com.skybridge.compass.core.network.ListenPortRangeExhaustedException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import android.util.Log
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TcpControlServer @Inject constructor(
    private val localIdentity: LocalP2PIdentity,
    private val peerKemStore: PeerKemKeyStore
) {
    @Volatile
    var handshakePolicyOverride: P2PHandshakePolicyOverride? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleLock = Any()
    private val cleanupLock = Any()
    private val socketOwners = TcpControlServerOwner<ServerSocket, Socket, TcpControlSession>()

    private val _incomingSessions = MutableSharedFlow<TcpControlSession>(extraBufferCapacity = 8)
    val incomingSessions: SharedFlow<TcpControlSession> = _incomingSessions
    private val terminalFailureState = MutableStateFlow<TcpControlServerFailure?>(null)
    val terminalFailure: StateFlow<TcpControlServerFailure?> = terminalFailureState.asStateFlow()

    /**
     * Start listening for Pro-release compatible TCP control sessions.
     *
     * @param port 0 = ephemeral
     * @return bound port
     */
    fun start(port: Int = 0): Int = startWith {
        ServerSocket(port).apply { reuseAddress = true }
    }

    /**
     * Start listening on a port taken from the user-configured listen range
     * (`RuntimeNetworkParameters.listenPortRange`, R7.4).
     *
     * Ports are tried in ascending order and the first bindable one wins. When **every** port in
     * the range is occupied this throws [ListenPortRangeExhaustedException] instead of silently
     * falling back to an ephemeral or hardcoded port — a silent fallback would recreate exactly the
     * "the setting looks applied but is not" defect this wiring removes.
     *
     * @return bound port, always inside [portRange]
     */
    fun start(portRange: IntRange): Int = startWith {
        ListenPortAllocator.bindWithin(portRange) { candidate ->
            ServerSocket(candidate).apply { reuseAddress = true }
        }
    }

    private fun startWith(openSocket: () -> ServerSocket): Int {
        val owner = synchronized(lifecycleLock) {
            socketOwners.currentListener()?.let { return it.resource.localPort }
            socketOwners.requireCleanupComplete()
            val socket = openSocket()
            terminalFailureState.value = null
            socketOwners.installListener(socket)
        }
        scope.launch {
            try {
                while (true) {
                    val acceptOwner = socketOwners.beginAcceptWhenAvailable(owner) ?: break
                    val client: Socket = try {
                        owner.resource.accept()
                    } catch (error: Exception) {
                        val listenerStillCurrent = synchronized(lifecycleLock) {
                            socketOwners.completeAcceptFailure(acceptOwner)
                        }
                        if (listenerStillCurrent) {
                            if (error is IOException) throw error
                            throw IOException("TCP control accept failed", error)
                        }
                        break
                    }
                    val acceptedOwner = synchronized(lifecycleLock) {
                        socketOwners.completeAcceptSuccess(acceptOwner, client)
                    }
                    if (acceptedOwner == null) {
                        break
                    }
                    if (!isCurrent(owner)) {
                        val cleaned = synchronized(cleanupLock) {
                            val cleanupTarget = synchronized(lifecycleLock) {
                                socketOwners.beginAcceptedCleanup(acceptedOwner)
                            }
                            cleanupTarget == null || closeAcceptedCleanupLocked(cleanupTarget)
                        }
                        if (!cleaned) return@launch
                        break
                    }

                    val session = try {
                        client.tcpNoDelay = true
                        client.keepAlive = true
                        TcpControlSession(
                            socket = client,
                            localIdentity = localIdentity,
                            peerKemStore = peerKemStore,
                            peerIdHint = null,
                            handshakePolicyOverride = handshakePolicyOverride,
                            role = TcpControlSession.Role.RESPONDER,
                            handshakeDeadlineMillis = HANDSHAKE_DEADLINE_MILLIS
                        )
                    } catch (error: Exception) {
                        val cleaned = synchronized(cleanupLock) {
                            val cleanupTarget = synchronized(lifecycleLock) {
                                socketOwners.beginAcceptedCleanup(acceptedOwner)
                            }
                            cleanupTarget == null || closeAcceptedCleanupLocked(cleanupTarget, error)
                        }
                        if (!cleaned) return@launch
                        Log.e(TAG, "Failed to initialize accepted TCP control session", error)
                        continue
                    }
                    val sessionOwner = synchronized(lifecycleLock) {
                        socketOwners.promoteAcceptedToSession(owner, acceptedOwner, session)
                    }
                    if (sessionOwner == null) {
                        break
                    }
                    session.setOnClosed {
                        synchronized(lifecycleLock) { socketOwners.retireSession(sessionOwner) }
                    }
                    val retained = synchronized(lifecycleLock) {
                        if (!socketOwners.isCurrent(owner)) {
                            false
                        } else {
                            session.start()
                            _incomingSessions.tryEmit(session)
                            true
                        }
                    }
                    if (!retained) {
                        break
                    }
                }
            } catch (error: IOException) {
                synchronized(cleanupLock) {
                    val cleanupTarget = synchronized(lifecycleLock) {
                        socketOwners.beginListenerFailureCleanup(owner)
                    }
                    if (cleanupTarget != null) {
                        val cleanupFailures = closeRetiredResources(cleanupTarget)
                        cleanupFailures.forEach(error::addSuppressed)
                        val published = synchronized(lifecycleLock) {
                            if (cleanupFailures.isEmpty()) {
                                check(socketOwners.completeCleanup(cleanupTarget)) {
                                    "TCP control server cleanup ownership changed unexpectedly"
                                }
                            }
                            if (!socketOwners.isCurrentTransition(cleanupTarget)) {
                                false
                            } else {
                                terminalFailureState.value = TcpControlServerFailure(
                                    generation = owner.generation,
                                    cause = error
                                )
                                true
                            }
                        }
                        if (published) Log.e(TAG, "TCP control accept loop stopped unexpectedly", error)
                    }
                }
            }
        }
        return checkNotNull(owner.resource.localPort.takeIf { it > 0 }) {
            "TCP control server did not expose a bound port"
        }
    }

    fun stop() = synchronized(cleanupLock) {
        val initialRetired = synchronized(lifecycleLock) {
            socketOwners.beginStopCleanup()
        }
        closeRetiredResources(initialRetired)
        val acceptsDrained = socketOwners.awaitAcceptsDrained(ACCEPT_DRAIN_TIMEOUT_MILLIS)
        val retired = synchronized(lifecycleLock) {
            socketOwners.beginStopCleanup()
        }
        val failures = closeRetiredResources(retired).toMutableList()
        if (!acceptsDrained) {
            failures += IOException("Timed out waiting for TCP accept ownership handoff")
        }
        if (failures.isNotEmpty()) {
            val error = IllegalStateException("Failed to close TCP control server resources")
            failures.forEach(error::addSuppressed)
            throw error
        }
        synchronized(lifecycleLock) {
            check(socketOwners.completeCleanup(retired)) {
                "TCP control server cleanup ownership changed unexpectedly"
            }
            if (socketOwners.isCurrentTransition(retired)) terminalFailureState.value = null
        }
    }

    private fun closeRetiredResources(
        retired: TcpControlServerOwner.RetiredOwner<ServerSocket, Socket, TcpControlSession>
    ): List<Exception> = buildList {
        retired.listeners.forEach { listener ->
            try {
                listener.resource.close()
            } catch (failure: Exception) {
                add(failure)
            }
        }
        retired.accepted.forEach { accepted ->
            try {
                accepted.resource.close()
            } catch (failure: Exception) {
                add(failure)
            }
        }
        retired.sessions.forEach { session ->
            try {
                session.resource.close()
            } catch (failure: Exception) {
                add(failure)
            }
        }
    }

    private fun closeAcceptedCleanupLocked(
        cleanupTarget: TcpControlServerOwner.RetiredOwner<ServerSocket, Socket, TcpControlSession>,
        primaryFailure: Exception? = null
    ): Boolean {
        val failures = closeRetiredResources(cleanupTarget)
        if (failures.isEmpty()) {
            synchronized(lifecycleLock) {
                check(socketOwners.completeCleanup(cleanupTarget)) {
                    "TCP accepted-client cleanup ownership changed unexpectedly"
                }
            }
            return true
        }

        val cleanupFailure = IOException("Failed to close accepted TCP control client")
        primaryFailure?.let(cleanupFailure::addSuppressed)
        failures.forEach(cleanupFailure::addSuppressed)
        val retiredListener = synchronized(lifecycleLock) {
            socketOwners.beginListenerFailureCleanup(
                socketOwners.currentListener()?.takeIf { it.generation == cleanupTarget.accepted.single().generation }
                    ?: return@synchronized null
            )
        }
        val retryFailures = retiredListener?.let(::closeRetiredResources).orEmpty()
        retryFailures.forEach(cleanupFailure::addSuppressed)
        synchronized(lifecycleLock) {
            if (retiredListener == null || !socketOwners.isCurrentTransition(retiredListener)) {
                return@synchronized
            } else {
                if (retryFailures.isEmpty()) {
                    check(socketOwners.completeCleanup(retiredListener)) {
                        "TCP failed-generation cleanup ownership changed unexpectedly"
                    }
                }
                terminalFailureState.value = TcpControlServerFailure(
                    generation = cleanupTarget.accepted.single().generation,
                    cause = cleanupFailure
                )
                Log.e(TAG, "TCP accepted-client cleanup failed", cleanupFailure)
            }
        }
        return false
    }

    private fun isCurrent(owner: TcpControlServerOwner.ListenerOwner<ServerSocket>): Boolean =
        synchronized(lifecycleLock) { socketOwners.isCurrent(owner) }

    internal val activeSessionCount: Int
        get() = synchronized(lifecycleLock) { socketOwners.sessionCount }

    internal val acceptedClientCount: Int
        get() = synchronized(lifecycleLock) { socketOwners.acceptedCount }

    private companion object {
        private const val TAG = "TcpControlServer"
        private const val ACCEPT_DRAIN_TIMEOUT_MILLIS = 5_000L
        private const val HANDSHAKE_DEADLINE_MILLIS = 30_000L
    }
}

data class TcpControlServerFailure(
    val generation: Long,
    val cause: IOException
)
