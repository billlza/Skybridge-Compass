package com.skybridge.compass.core.p2p

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
    fun start(port: Int = 0): Int {
        if (!running.compareAndSet(false, true)) {
            return serverSocket?.localPort ?: port
        }
        val ss = ServerSocket(port).apply {
            reuseAddress = true
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
