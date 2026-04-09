package com.skybridge.compass.core.p2p

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import java.net.InetSocketAddress
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

    suspend fun connect(
        host: String,
        port: Int,
        peerDeviceIdHint: String? = null,
        timeoutMillis: Long = 30_000
    ): TcpControlSession {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.keepAlive = true
        socket.connect(InetSocketAddress(host, port), 5_000)

        val session = TcpControlSession(
            socket = socket,
            localIdentity = localIdentity,
            peerKemStore = peerKemStore,
            peerIdHint = peerDeviceIdHint,
            handshakePolicyOverride = handshakePolicyOverride,
            role = TcpControlSession.Role.INITIATOR
        )
        session.start()

        // Wait for handshake established or failure.
        try {
            withTimeout(timeoutMillis) {
                session.events.filterIsInstance<TcpControlEvent.HandshakeEstablished>().first()
            }
        } catch (t: Throwable) {
            session.close()
            throw t
        }
        return session
    }
}
