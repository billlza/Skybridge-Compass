package com.skybridge.compass.core.webrtc

import android.net.Uri
import android.util.Log
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Minimal signaling client compatible with Pro release `WebSocketSignalingClient`:
 * - connect / send / onEnvelope
 */
class WebSocketSignalingClient(
    private val wsUrlString: String = SkyBridgeServerConfig.signalingWebSocketURL,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
) {
    private val tag = "SB-SIGNAL-WS"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val httpClient = HttpClient(OkHttp) { install(WebSockets) }

    private var session: io.ktor.client.plugins.websocket.DefaultClientWebSocketSession? = null
    private var receiveJob: Job? = null
    private var readyDeferred: CompletableDeferred<Unit>? = null
    private val pendingBusinessFrames = ArrayDeque<String>()
    @Volatile private var isBound: Boolean = false

    var onEnvelope: ((WebRtcSignalingEnvelope) -> Unit)? = null
    var onServerFrame: ((SignalingServerFrame) -> Unit)? = null
    var onError: ((Throwable) -> Unit)? = null

    fun connect() {
        if (session != null || receiveJob?.isActive == true) return
        val ready = CompletableDeferred<Unit>()
        readyDeferred = ready
        pendingBusinessFrames.clear()
        isBound = false
        Log.i(tag, "connect url=${redactedUrlString(wsUrlString)}")
        receiveJob = scope.launch {
            try {
                val s = httpClient.webSocketSession(wsUrlString)
                session = s
                Log.i(tag, "connected url=${redactedUrlString(wsUrlString)}")
                if (!ready.isCompleted) {
                    ready.complete(Unit)
                }
                for (frame in s.incoming) {
                    val text = (frame as? Frame.Text)?.data?.decodeToString() ?: continue
                    Log.i(tag, "recv raw=${truncateForLog(text)}")
                    when (val inbound = parseInboundText(text, json)) {
                        is InboundMessage.Envelope -> {
                            Log.i(
                                tag,
                                "recv env session=${inbound.value.sessionId} type=${inbound.value.type} from=${inbound.value.from} to=${inbound.value.to ?: "-"} auth=${if (inbound.value.authToken.isNullOrBlank()) "missing" else "present"}"
                            )
                            onEnvelope?.invoke(inbound.value)
                        }
                        is InboundMessage.ServerFrame -> {
                            Log.i(
                                tag,
                                "recv server-frame type=${inbound.value.type} session=${inbound.value.sessionId ?: "-"} error=${inbound.value.error ?: "-"} what=${inbound.value.what ?: "-"}"
                            )
                            if (inbound.value.type == "bound") {
                                isBound = true
                                flushPendingBusinessFrames()
                            }
                            onServerFrame?.invoke(inbound.value)
                        }
                        InboundMessage.Unknown -> {
                            Log.w(tag, "recv unknown=${truncateForLog(text)}")
                        }
                    }
                }
            } catch (throwable: Throwable) {
                Log.e(tag, "socket failure url=${redactedUrlString(wsUrlString)} error=${throwable.message}", throwable)
                if (!ready.isCompleted) {
                    ready.completeExceptionally(throwable)
                }
                onError?.invoke(throwable)
            } finally {
                pendingBusinessFrames.clear()
                isBound = false
                Log.i(tag, "disconnected url=${redactedUrlString(wsUrlString)}")
                session = null
                if (readyDeferred === ready) {
                    readyDeferred = null
                }
            }
        }
    }

    suspend fun close() {
        receiveJob?.cancel()
        val ready = readyDeferred
        readyDeferred = null
        if (ready != null && !ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("signaling websocket closed"))
        }
        val s = session
        session = null
        Log.i(tag, "close requested url=${redactedUrlString(wsUrlString)}")
        runCatching { s?.close() }
    }

    suspend fun send(envelope: WebRtcSignalingEnvelope) {
        val s = try {
            awaitReady()
            session ?: throw IllegalStateException("signaling websocket not connected")
        } catch (throwable: Throwable) {
            onError?.invoke(throwable)
            return
        }
        val text = json.encodeToString(WebRtcSignalingEnvelope.serializer(), envelope)
        if (envelope.type != WebRtcSignalingEnvelope.MessageType.JOIN && !isBound) {
            pendingBusinessFrames.addLast(text)
            Log.i(
                tag,
                "queue env-until-bound session=${envelope.sessionId} type=${envelope.type} size=${pendingBusinessFrames.size}"
            )
            return
        }
        sendRawText(s, envelope, text)
    }

    private suspend fun flushPendingBusinessFrames() {
        val activeSession = session ?: return
        val flushed = ArrayList<Pair<WebRtcSignalingEnvelope, String>>(pendingBusinessFrames.size)
        while (pendingBusinessFrames.isNotEmpty()) {
            val raw = pendingBusinessFrames.removeFirst()
            val envelope = runCatching {
                json.decodeFromString(WebRtcSignalingEnvelope.serializer(), raw)
            }.getOrNull()
            if (envelope == null) {
                Log.w(tag, "drop queued frame due to decode failure raw=${truncateForLog(raw)}")
                continue
            }
            flushed += envelope to raw
        }

        flushed
            .sortedWith(
                compareBy<Pair<WebRtcSignalingEnvelope, String>> { queuedPriority(it.first) }
                    .thenBy { it.first.sentAt }
            )
            .forEach { (envelope, raw) ->
                sendRawText(activeSession, envelope, raw, queued = true)
            }
    }

    private fun queuedPriority(envelope: WebRtcSignalingEnvelope): Int =
        when (envelope.type) {
            WebRtcSignalingEnvelope.MessageType.OFFER -> 0
            WebRtcSignalingEnvelope.MessageType.ANSWER -> 1
            WebRtcSignalingEnvelope.MessageType.ICE_CANDIDATE -> 2
            WebRtcSignalingEnvelope.MessageType.LEAVE -> 3
            WebRtcSignalingEnvelope.MessageType.JOIN -> 4
        }

    private suspend fun sendRawText(
        activeSession: io.ktor.client.plugins.websocket.DefaultClientWebSocketSession,
        envelope: WebRtcSignalingEnvelope,
        text: String,
        queued: Boolean = false
    ) {
        Log.i(
            tag,
            "${if (queued) "flush" else "send"} env session=${envelope.sessionId} type=${envelope.type} from=${envelope.from} to=${envelope.to ?: "-"} auth=${if (envelope.authToken.isNullOrBlank()) "missing" else "present"} raw=${truncateForLog(redactAuthToken(text))}"
        )
        activeSession.send(Frame.Text(text))
    }

    private suspend fun awaitReady(timeoutMillis: Long = 5_000L) {
        if (session != null) return
        connect()
        val ready = readyDeferred ?: return
        withTimeout(timeoutMillis) {
            ready.await()
        }
    }

    sealed interface InboundMessage {
        data class Envelope(val value: WebRtcSignalingEnvelope) : InboundMessage
        data class ServerFrame(val value: SignalingServerFrame) : InboundMessage
        data object Unknown : InboundMessage
    }

    @Serializable
    data class SignalingServerFrame(
        val type: String,
        val error: String? = null,
        val sessionId: String? = null,
        val what: String? = null
    ) {
        val isError: Boolean
            get() = type == "error" && !error.isNullOrBlank()
    }

    companion object {
        fun parseInboundText(
            text: String,
            json: Json = Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            }
        ): InboundMessage {
            val envelope = runCatching {
                json.decodeFromString(WebRtcSignalingEnvelope.serializer(), text)
            }.getOrNull()
            if (envelope != null) {
                return InboundMessage.Envelope(envelope)
            }
            val serverFrame = runCatching {
                json.decodeFromString(SignalingServerFrame.serializer(), text)
            }.getOrNull()
            if (serverFrame != null) {
                return InboundMessage.ServerFrame(serverFrame)
            }
            return InboundMessage.Unknown
        }

        private fun redactAuthToken(text: String): String =
            text.replace(Regex("\"authToken\"\\s*:\\s*\"[^\"]*\""), "\"authToken\":\"<redacted>\"")

        private fun truncateForLog(text: String, maxChars: Int = 700): String =
            if (text.length <= maxChars) text else text.take(maxChars) + "...<truncated>"

        private fun redactedUrlString(raw: String): String {
            val uri = Uri.parse(raw)
            val builder = uri.buildUpon().clearQuery()
            val existingKeys = linkedSetOf<String>()
            for (name in uri.queryParameterNames) {
                if (!existingKeys.add(name)) continue
                val values = uri.getQueryParameters(name)
                if (name == "st") {
                    builder.appendQueryParameter(name, "<redacted>")
                } else {
                    values.forEach { value -> builder.appendQueryParameter(name, value) }
                }
            }
            return builder.build().toString()
        }
    }
}
