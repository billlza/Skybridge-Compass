package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.network.ListenPortAllocator
import com.skybridge.compass.core.network.ListenPortRangeExhaustedException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
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
    private val running = AtomicBoolean(false)

    private var serverSocket: ServerSocket? = null

    private val _incomingSessions = MutableSharedFlow<TcpControlSession>(extraBufferCapacity = 8)
    val incomingSessions: SharedFlow<TcpControlSession> = _incomingSessions

    /**
     * Start listening for Pro-release compatible TCP control sessions.
     *
     * @param port 0 = ephemeral
     * @return bound port
     */
    fun start(port: Int = 0): Int = startWith(fallbackPort = port) {
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
    fun start(portRange: IntRange): Int = startWith(fallbackPort = portRange.first) {
        ListenPortAllocator.bindWithin(portRange) { candidate ->
            ServerSocket(candidate).apply { reuseAddress = true }
        }
    }

    private fun startWith(fallbackPort: Int, openSocket: () -> ServerSocket): Int {
        if (!running.compareAndSet(false, true)) {
            return serverSocket?.localPort ?: fallbackPort
        }
        val ss = try {
            openSocket()
        } catch (failure: Throwable) {
            running.set(false)
            serverSocket = null
            throw failure
        }
        serverSocket = ss
        scope.launch {
            while (running.get()) {
                val client: Socket = try {
                    ss.accept()
                } catch (_: Throwable) {
                    break
                }
                client.tcpNoDelay = true
                client.keepAlive = true

                val session = TcpControlSession(
                    socket = client,
                    localIdentity = localIdentity,
                    peerKemStore = peerKemStore,
                    peerIdHint = null,
                    handshakePolicyOverride = handshakePolicyOverride,
                    role = TcpControlSession.Role.RESPONDER
                )
                session.start()
                _incomingSessions.tryEmit(session)
            }
        }
        return ss.localPort
    }

    fun stop() {
        running.set(false)
        runCatching { serverSocket?.close() }
        serverSocket = null
    }
}
