package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class WebRtcSessionLifecycleContractTest {

    @Test
    fun managerStateStringDoesNotExposeConnectionCode() {
        val code = "ABCD2345"
        val rendered = listOf(
            SkyBridgeWebRtcConnectionManager.State.Waiting(code),
            SkyBridgeWebRtcConnectionManager.State.Connecting(code),
            SkyBridgeWebRtcConnectionManager.State.Connected(code),
            SkyBridgeWebRtcConnectionManager.State.Established(code),
            SkyBridgeWebRtcConnectionManager.State.Failed(code, "boom")
        ).joinToString(separator = "\n") { it.toString() }

        assertFalse(rendered, rendered.contains(code))
        assertTrue(rendered, rendered.contains("<redacted:8>"))
    }

    @Test
    fun remoteDescriptionsArrivingBeforePeerConnectionStartAreQueued() {
        val source = File(repositoryRoot(), "core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebRtcSession.kt")
            .readText()

        assertTrue(source.contains("private var pendingRemoteOfferSdp: String? = null"))
        assertTrue(source.contains("private var pendingRemoteAnswerSdp: String? = null"))
        assertTrue(source.contains("pendingRemoteOfferSdp = sdp"))
        assertTrue(source.contains("pendingRemoteAnswerSdp = sdp"))
        assertFalse(
            "Remote description calls must use the checked PeerConnection reference, not pc?.setRemoteDescription which silently no-ops before start.",
            source.contains("pc?.setRemoteDescription")
        )

        val pcAssignment = source.indexOf("pc = createdPeerConnection ?: run")
        val drain = source.indexOf("drainPendingRemoteDescriptions()")
        val offererBranch = source.indexOf("if (role == Role.OFFERER)")

        assertTrue("PeerConnection assignment must be present", pcAssignment >= 0)
        assertTrue("Pending descriptions must drain after PeerConnection assignment", drain > pcAssignment)
        assertTrue("Pending descriptions must drain before offerer branch creates local offers", offererBranch > drain)
    }

    @Test
    fun joinBootstrapIsSentBeforePeerConnectionStart() {
        val source = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
        ).readText()

        val offerer = functionBody(source, "startOffererSession")
        val answerer = functionBody(source, "startAnswererSession")

        assertJoinBeforePeerConnectionStart("offerer", offerer)
        assertJoinBeforePeerConnectionStart("answerer", answerer)
    }

    @Test
    fun bothDataChannelObserversAdmitChunksBeforeCopyingAndReportProtocolViolations() {
        val sessionSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebRtcSession.kt"
        ).readText()
        val managerSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
        ).readText()

        assertTrue(sessionSource.contains("attachDataChannel(dc, remote = true)"))
        assertTrue(sessionSource.contains("attachDataChannel(createdDataChannel, remote = false)"))
        assertEquals(
            "Both local and remote channels must share one observer implementation.",
            1,
            sessionSource.windowed("deliverDataChannelMessage(buffer)".length)
                .count { it == "deliverDataChannelMessage(buffer)" }
        )
        assertTrue(sessionSource.contains("WebRtcDataChannelFraming.copyAdmittedChunk(buffer.data)"))
        assertTrue(sessionSource.contains("if (!buffer.binary)"))
        assertFalse(sessionSource.contains("ByteArray(buffer.data.remaining())"))
        assertTrue(managerSource.contains("s.onProtocolViolation = { reason ->"))
        assertTrue(managerSource.contains("failSecureTransport(owner, \"datachannel protocol violation: \$reason\")"))
    }

    @Test
    fun nativeAndSignalingCleanupAreReportedInsteadOfSilentlySwallowed() {
        val sessionSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebRtcSession.kt"
        ).readText()
        val signalingSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebSocketSignalingClient.kt"
        ).readText()
        val dataChannelLifecycleSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebRtcDataChannelLifecycle.kt"
        ).readText()
        val managerSource = File(
            repositoryRoot(),
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
        ).readText()

        assertTrue(sessionSource.contains("internal fun close(): WebRtcResourceCloseReport"))
        assertTrue(dataChannelLifecycleSource.contains("WebRtcDataChannelAdmission.evaluate("))
        val closeBody = sessionSource.substring(sessionSource.indexOf("internal fun close():"))
        assertTrue(closeBody.contains("dataChannelLifecycle.closeAndDetach()"))
        assertTrue(closeBody.contains("closingAttachment?.channel?.unregisterObserver()"))
        assertTrue(
            closeBody.indexOf("closingAttachment?.channel?.unregisterObserver()") <
                closeBody.indexOf("closingAttachment?.channel?.close()")
        )
        assertTrue(sessionSource.contains("dataChannelLifecycle.withExactAttached(attachment)"))
        assertFalse(sessionSource.contains("if (dc.state() == DataChannel.State.OPEN)"))
        assertTrue(signalingSource.contains("internal suspend fun close(): WebRtcResourceCloseReport"))
        assertFalse(sessionSource.contains("runCatching { dataChannel?.close() }"))
        assertFalse(signalingSource.contains("runCatching { s?.close() }"))
        assertFalse(managerSource.contains("runCatching { session?.close() }"))
        assertFalse(managerSource.contains("runCatching { closingSignaling.close() }"))
        assertTrue(managerSource.contains("throw cleanup.asException(\"WebRTC connection reset\")"))
    }

    private fun assertJoinBeforePeerConnectionStart(label: String, body: String) {
        val ensureSignaling = body.indexOf("ensureSignalingConfigured(net, owner)")
        val buildJoin = body.indexOf("val joinPayload = buildJoinBootstrapPayload()")
        val sendJoin = body.indexOf("sendSignalingEnvelope(")
        val startPeerConnection = body.indexOf("prepareSession(owner = owner, net = net")

        assertTrue("$label must bind signaling before emitting JOIN", ensureSignaling >= 0)
        assertTrue("$label must build JOIN before PeerConnection start", buildJoin in 0 until startPeerConnection)
        assertTrue("$label must send JOIN before PeerConnection start", sendJoin in 0 until startPeerConnection)
    }

    private fun functionBody(source: String, name: String): String {
        val signature = "private suspend fun $name"
        val start = source.indexOf(signature)
        assertTrue("Missing function $name", start >= 0)
        val nextFunction = source.indexOf("\n    private ", start + signature.length)
        assertTrue("Missing next function after $name", nextFunction > start)
        return source.substring(start, nextFunction)
    }

    private fun repositoryRoot(): File {
        var current = File(".").canonicalFile
        while (!File(current, "settings.gradle.kts").isFile) {
            current = requireNotNull(current.parentFile) {
                "Could not locate repository root from ${File(".").canonicalPath}"
            }
        }
        return current
    }
}
