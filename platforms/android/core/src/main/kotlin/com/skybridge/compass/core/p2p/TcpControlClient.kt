package com.skybridge.compass.core.p2p

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.net.InetSocketAddress
import java.io.IOException
import java.net.Socket
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TcpControlClient @Inject constructor(
    private val localIdentity: LocalP2PIdentity,
    private val peerKemStore: PeerKemKeyStore
) {
    @Volatile
    var handshakePolicyOverride: P2PHandshakePolicyOverride? = null

    private val attemptPermits = Semaphore(MAX_UNDELIVERED_ATTEMPTS)
    private val cleanupOwners = TcpControlClientCleanupRegistry<TcpControlClientCleanupOwner>(
        maxOwners = MAX_UNDELIVERED_ATTEMPTS,
        closeOwner = TcpControlClientCleanupOwner::close
    )

    suspend fun connect(
        host: String,
        port: Int,
        peerDeviceIdHint: String? = null,
        timeoutMillis: Long = 30_000,
        onClosed: ((TcpControlSession) -> Unit)? = null
    ): TcpControlSession = attemptPermits.withPermit {
        cleanupOwners.retryBeforeNextConnect()

        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(host, port), 5_000)
        } catch (primaryFailure: Exception) {
            closeUnpublishedOwner(
                primaryFailure = primaryFailure,
                owner = TcpControlClientCleanupOwner.SocketOwner(socket)
            )
        }

        val session = try {
            TcpControlSession(
                socket = socket,
                localIdentity = localIdentity,
                peerKemStore = peerKemStore,
                peerIdHint = peerDeviceIdHint,
                handshakePolicyOverride = handshakePolicyOverride,
                role = TcpControlSession.Role.INITIATOR,
                handshakeDeadlineMillis = timeoutMillis
            )
        } catch (primaryFailure: Exception) {
            closeUnpublishedOwner(
                primaryFailure = primaryFailure,
                owner = TcpControlClientCleanupOwner.SocketOwner(socket)
            )
        }
        onClosed?.let(session::setOnClosed)

        // Wait for handshake established or failure.
        try {
            val terminalEvent = coroutineScope {
                val terminal = async(start = CoroutineStart.UNDISPATCHED) {
                    withTimeout(timeoutMillis) {
                        session.events.first { event ->
                            event is TcpControlEvent.HandshakeEstablished ||
                                event is TcpControlEvent.Failed ||
                                event is TcpControlEvent.Disconnected
                        }
                    }
                }
                session.start()
                terminal.await()
            }
            when (terminalEvent) {
                is TcpControlEvent.HandshakeEstablished -> Unit
                is TcpControlEvent.Failed -> throw TcpControlHandshakeException(terminalEvent.error)
                is TcpControlEvent.Disconnected -> throw TcpControlHandshakeException(
                    "TCP control session closed before authentication"
                )
                else -> error("Unexpected TCP handshake event")
            }
        } catch (primaryFailure: Exception) {
            closeUnpublishedOwner(
                primaryFailure = primaryFailure,
                owner = TcpControlClientCleanupOwner.SessionOwner(session)
            )
        }
        session
    }

    private suspend fun closeUnpublishedOwner(
        primaryFailure: Exception,
        owner: TcpControlClientCleanupOwner
    ): Nothing {
        val cleanupFailure = withContext(NonCancellable) {
            cleanupOwners.closeAfterFailure(owner)
        }
        cleanupFailure?.let(primaryFailure::addSuppressed)
        throw primaryFailure
    }

    private companion object {
        private const val MAX_UNDELIVERED_ATTEMPTS = 8
    }
}

class TcpControlHandshakeException internal constructor(message: String) : IOException(message)

internal sealed interface TcpControlClientCleanupOwner {
    fun close()

    class SocketOwner(private val socket: Socket) : TcpControlClientCleanupOwner {
        override fun close() = socket.close()
    }

    class SessionOwner(private val session: TcpControlSession) : TcpControlClientCleanupOwner {
        override fun close() = session.close()
    }
}

internal class TcpControlClientCleanupRegistry<T : Any>(
    private val maxOwners: Int,
    private val closeOwner: (T) -> Unit
) {
    private val lock = Mutex()
    private val pending = mutableListOf<T>()

    init {
        require(maxOwners > 0) { "TCP cleanup owner capacity must be positive" }
    }

    suspend fun retryBeforeNextConnect() = lock.withLock {
        if (pending.isEmpty()) return@withLock

        val failures = mutableListOf<Exception>()
        pending.toList().forEach { owner ->
            try {
                closeOwner(owner)
                pending.removeAll { it === owner }
            } catch (failure: Exception) {
                failures += failure
            }
        }
        if (failures.isNotEmpty()) {
            val error = IllegalStateException(
                "TCP client cleanup is incomplete; connection is refused until cleanup succeeds"
            )
            failures.forEach(error::addSuppressed)
            throw error
        }
    }

    suspend fun closeAfterFailure(owner: T): Exception? = lock.withLock {
        try {
            closeOwner(owner)
            null
        } catch (failure: Exception) {
            if (pending.none { it === owner }) {
                check(pending.size < maxOwners) {
                    "TCP client cleanup ownership exceeded its bounded attempt capacity"
                }
                pending += owner
            }
            failure
        }
    }

    internal suspend fun pendingCount(): Int = lock.withLock { pending.size }
}
