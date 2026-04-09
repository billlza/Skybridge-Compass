package com.skybridge.compass.android.webrtc

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.http.Url
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * Android counterpart of Pro release `WebSocketSignalingClient` (minimal connect/send/onEnvelope).
 *
 * NOTE: This is only the signaling transport. Creating the actual WebRTC PeerConnection/DataChannel
 * requires adding a WebRTC SDK dependency and is tracked as part of file transfer interop.
 */
class WebSocketSignalingClient(
    private val wsUrl: Url = Url("wss://api.nebula-technologies.net/ws"),
    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val httpClient = HttpClient {
        install(WebSockets)
    }

    @Volatile
    private var session: DefaultClientWebSocketSession? = null

    var onEnvelope: ((WebRtcSignalingEnvelope) -> Unit)? = null

    fun connect() {
        if (session != null) return
        scope.launch {
            val s = httpClient.webSocketSession(wsUrl.toString())
            session = s
            readLoop(s)
        }
    }

    suspend fun close() {
        val s = session
        session = null
        withContext(Dispatchers.IO) {
            try { s?.close() } catch (_: Throwable) {}
        }
    }

    suspend fun send(envelope: WebRtcSignalingEnvelope) {
        val s = session ?: return
        val text = json.encodeToString(WebRtcSignalingEnvelope.serializer(), envelope)
        s.send(Frame.Text(text))
    }

    private suspend fun readLoop(s: DefaultClientWebSocketSession) {
        try {
            for (frame in s.incoming) {
                val text = (frame as? Frame.Text)?.data?.decodeToString() ?: continue
                runCatching {
                    json.decodeFromString(WebRtcSignalingEnvelope.serializer(), text)
                }.onSuccess { env ->
                    onEnvelope?.invoke(env)
                }
            }
        } catch (_: Throwable) {
            // connection closed
        } finally {
            session = null
        }
    }
}


