package com.skybridge.compass.core.webrtc

import android.util.Log
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.header
import io.ktor.client.request.url
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.Proxy
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Minimal signaling client compatible with Pro release `WebSocketSignalingClient`:
 * - connect / send / onEnvelope
 */
class WebSocketSignalingClient(
    private val wsUrlString: String = SkyBridgeServerConfig.signalingWebSocketURL,
    private val additionalHeaders: Map<String, String> = emptyMap(),
    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
) {
    private val tag = "SB-SIGNAL-WS"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val httpClient = HttpClient(OkHttp) {
        install(WebSockets)
        if (shouldBypassProxyForUrl(wsUrlString)) {
            engine {
                config {
                    proxy(Proxy.NO_PROXY)
                }
            }
        }
    }

    private var session: io.ktor.client.plugins.websocket.DefaultClientWebSocketSession? = null
    private var receiveJob: Job? = null
    private var readyDeferred: CompletableDeferred<Unit>? = null
    private val pendingBusinessFrames = ArrayDeque<String>()
    @Volatile private var closed: Boolean = false
    @Volatile private var isBound: Boolean = false

    var onEnvelope: ((WebRtcSignalingEnvelope) -> Unit)? = null
    var onServerFrame: ((SignalingServerFrame) -> Unit)? = null
    var onError: ((Throwable) -> Unit)? = null

    fun connect() {
        check(!closed) { "signaling websocket client is closed" }
        if (session != null || receiveJob?.isActive == true) return
        val ready = CompletableDeferred<Unit>()
        readyDeferred = ready
        pendingBusinessFrames.clear()
        isBound = false
        Log.i(
            tag,
            "connect url=${redactedUrlString(wsUrlString)} headers=${redactedHeadersSummary(additionalHeaders)}"
        )
        receiveJob = scope.launch {
            try {
                val s = httpClient.webSocketSession {
                    url(wsUrlString)
                    additionalHeaders
                        .toSortedMap(String.CASE_INSENSITIVE_ORDER)
                        .forEach { (name, value) -> header(name, value) }
                }
                session = s
                Log.i(
                    tag,
                    "connected url=${redactedUrlString(wsUrlString)} headers=${redactedHeadersSummary(additionalHeaders)}"
                )
                if (!ready.isCompleted) {
                    ready.complete(Unit)
                }
                for (frame in s.incoming) {
                    val text = (frame as? Frame.Text)?.data?.decodeToString() ?: continue
                    Log.i(tag, "recv frame ${payloadSizeSummary(text)}")
                    when (val inbound = parseInboundText(text, json)) {
                        is InboundMessage.Envelope -> {
                            Log.i(
                                tag,
                                "recv env session=${redactIdentifierForLog(inbound.value.sessionId)} type=${inbound.value.type} from=${redactIdentifierForLog(inbound.value.from)} to=${inbound.value.to?.let(::redactIdentifierForLog) ?: "-"} auth=${if (inbound.value.authToken.isNullOrBlank()) "missing" else "present"}"
                            )
                            onEnvelope?.invoke(inbound.value)
                        }
                        is InboundMessage.ServerFrame -> {
                            Log.i(
                                tag,
                                "recv server-frame type=${inbound.value.type} session=${redactIdentifierForLog(inbound.value.sessionId)} error=${inbound.value.error?.let(::sanitizeTextForLog) ?: "-"} what=${inbound.value.what?.let(::sanitizeTextForLog) ?: "-"}"
                            )
                            if (inbound.value.type == "bound") {
                                isBound = true
                                flushPendingBusinessFrames()
                            }
                            onServerFrame?.invoke(inbound.value)
                        }
                        InboundMessage.Unknown -> {
                            Log.w(tag, "recv unknown ${payloadSizeSummary(text)}")
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                if (!ready.isCompleted) {
                    ready.completeExceptionally(cancelled)
                }
                throw cancelled
            } catch (throwable: Throwable) {
                Log.e(
                    tag,
                    "socket failure url=${redactedUrlString(wsUrlString)} headers=${redactedHeadersSummary(additionalHeaders)} error=${sanitizeTextForLog(throwable.message ?: throwable::class.java.simpleName)}"
                )
                if (!ready.isCompleted) {
                    ready.completeExceptionally(throwable)
                }
                onError?.invoke(throwable)
            } finally {
                pendingBusinessFrames.clear()
                isBound = false
                Log.i(
                    tag,
                    "disconnected url=${redactedUrlString(wsUrlString)} headers=${redactedHeadersSummary(additionalHeaders)}"
                )
                session = null
                if (receiveJob === this.coroutineContext[Job]) {
                    receiveJob = null
                }
                if (readyDeferred === ready) {
                    readyDeferred = null
                }
            }
        }
    }

    internal suspend fun close(): WebRtcResourceCloseReport {
        val report = WebRtcResourceCloseReport()
        closed = true
        val closingReceiveJob = receiveJob
        receiveJob = null
        closingReceiveJob?.cancel()
        val ready = readyDeferred
        readyDeferred = null
        if (ready != null && !ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("signaling websocket closed"))
        }
        val s = session
        session = null
        onEnvelope = null
        onServerFrame = null
        onError = null
        pendingBusinessFrames.clear()
        isBound = false
        Log.i(
            tag,
            "close requested url=${redactedUrlString(wsUrlString)} headers=${redactedHeadersSummary(additionalHeaders)}"
        )
        report.attemptSuspending("webSocketSession.close") { s?.close() }
        report.attempt("httpClient.close") { httpClient.close() }
        report.attempt("coroutineScope.cancel") { scope.cancel() }
        return report
    }

    suspend fun send(envelope: WebRtcSignalingEnvelope) {
        awaitReady()
        val s = session ?: throw IllegalStateException("signaling websocket not connected")
        val text = json.encodeToString(WebRtcSignalingEnvelope.serializer(), envelope)
        if (envelope.type != WebRtcSignalingEnvelope.MessageType.JOIN && !isBound) {
            check(pendingBusinessFrames.size < MAX_PENDING_BUSINESS_FRAMES) {
                "signaling pending frame queue full"
            }
            pendingBusinessFrames.addLast(text)
            Log.i(
                tag,
                "queue env-until-bound session=${redactIdentifierForLog(envelope.sessionId)} type=${envelope.type} size=${pendingBusinessFrames.size}"
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
                Log.w(tag, "drop queued frame due to decode failure ${payloadSizeSummary(raw)}")
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
            "${if (queued) "flush" else "send"} env session=${redactIdentifierForLog(envelope.sessionId)} type=${envelope.type} from=${redactIdentifierForLog(envelope.from)} to=${envelope.to?.let(::redactIdentifierForLog) ?: "-"} auth=${if (envelope.authToken.isNullOrBlank()) "missing" else "present"} ${payloadSizeSummary(text)}"
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
        private const val MAX_PENDING_BUSINESS_FRAMES = 128

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

        internal fun sanitizeTextForLog(text: String): String =
            truncateForLog(redactTokenLikeSegments(redactSensitiveJsonFields(text)))

        private fun redactSensitiveJsonFields(text: String): String =
            text.replace(
                Regex("(?i)\"(authToken|sessionId|sessionToken|token|secret|password|credential|apiKey|xApiKey|xSkyBridgeTurnAdmission|sdp|candidate|sdpMid)\"\\s*:\\s*\"[^\"]*\"")
            ) { match ->
                val fieldName = match.groupValues[1]
                "\"$fieldName\":\"<redacted>\""
            }

        private fun redactTokenLikeSegments(text: String): String =
            text
                .replace(Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/\\-=]+")) {
                    "Bearer <redacted>"
                }
                .replace(
                    Regex("(?i)\\b(X-API-Key|X-SkyBridge-Turn-Admission)\\s*:\\s*([^\\s]+)")
                ) { match ->
                    "${match.groupValues[1]}: <redacted>"
                }
                .replace(
                    Regex("(?i)\\b(authToken|sessionId|sessionToken|token|secret|password|credential|apiKey|x-api-key|x-skybridge-turn-admission|st|shard)=([^\\s&]+)")
                ) { match ->
                    "${match.groupValues[1]}=<redacted>"
                }

        internal fun payloadSizeSummary(text: String): String =
            "payloadBytes=${text.toByteArray(Charsets.UTF_8).size}"

        internal fun redactIdentifierForLog(value: String?): String =
            if (value.isNullOrBlank()) "-" else "<redacted>"

        private fun truncateForLog(text: String, maxChars: Int = 700): String =
            if (text.length <= maxChars) text else text.take(maxChars) + "...<truncated>"

        internal fun redactedUrlString(raw: String): String {
            val uri = URI(raw)
            val rawQuery = uri.rawQuery ?: return raw
            val redactedQueryItems = mutableListOf<String>()
            val existingKeys = linkedSetOf<String>()
            rawQuery.split("&")
                .filter { it.isNotBlank() }
                .forEach { rawPair ->
                    val rawName = rawPair.substringBefore("=", rawPair)
                    val name = URLDecoder.decode(rawName, Charsets.UTF_8.name())
                    if (!existingKeys.add(name)) return@forEach
                    if (shouldRedactQueryParameter(name)) {
                        redactedQueryItems += "$rawName=${encodeQueryComponent("<redacted>")}"
                    } else {
                        redactedQueryItems += rawPair
                    }
                }
            val base = raw.substringBefore("?")
            val fragment = uri.rawFragment?.let { "#$it" }.orEmpty()
            return "$base?${redactedQueryItems.joinToString("&")}$fragment"
        }

        private fun shouldRedactQueryParameter(name: String): Boolean {
            val normalized = name.lowercase()
            return normalized == "st" ||
                normalized == "shard" ||
                "token" in normalized ||
                "session" in normalized ||
                "secret" in normalized
        }

        private fun encodeQueryComponent(value: String): String =
            URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

        internal fun redactedHeadersSummary(headers: Map<String, String>): String =
            if (headers.isEmpty()) {
                "none"
            } else {
                headers.keys.sortedWith(String.CASE_INSENSITIVE_ORDER).joinToString(
                    prefix = "present[",
                    postfix = "]"
                )
            }

        internal fun shouldBypassProxyForUrl(raw: String): Boolean =
            runCatching {
                val uri = URI(raw.trim())
                val scheme = uri.scheme?.lowercase()
                val host = uri.host
                    ?.trim()
                    ?.trim('[', ']')
                    ?.lowercase()
                scheme in setOf("ws", "wss") &&
                    host in setOf("127.0.0.1", "localhost", "::1", "10.0.2.2")
            }.getOrDefault(false)
    }
}
