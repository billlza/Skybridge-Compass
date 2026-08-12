package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class WebRtcRemoteControlConfigurationWiringTest {
    @Test
    fun webRtcConfigurationIsImmutableRetriedAndAckGatedBySecureOwner() {
        val source = viewModelSource()

        assertTrue(source.contains("transport.onSecurePacketData = packet@{ owner, bytes, packetType ->"))
        assertTrue(source.contains("transport.secureOperationOwner.collect { owner ->"))
        assertTrue(source.contains("onSecureOperationOwnerChanged(owner)"))
        assertTrue(source.contains("beginStreamConfigurationOperation(owner)"))
        assertTrue(source.contains("transport.currentSecureOperationOwner()"))
        assertTrue(source.contains("streamConfigurationTransaction = transaction"))
        assertTrue(source.contains("encodedMessage = RemoteControlWireCodec.encodeMessage(message)"))
        assertTrue(source.contains("operation.encodedMessage"))
        assertTrue(source.contains("pendingStreamConfiguration === operation"))
        assertTrue(source.contains("acknowledgedStreamConfiguration = pending"))
        assertTrue(source.contains("hasAcknowledgedStreamConfiguration(owner)"))
        assertTrue(source.contains("transport.isCurrentSecureOperationOwner(operation.owner)"))
        assertTrue(source.contains("WebRtcRemoteControlPacketAdmissionPolicy.decide("))
        assertTrue(source.contains("if (!transport.failSecureOperation(owner, reason)) return"))
        assertTrue(source.contains("onInboundScreenData(owner, screen)"))
        assertTrue(source.contains("commitIfCurrentAcknowledgedRemoteControlOwner(owner)"))
        assertTrue(source.contains("transport.runIfCurrentSecureOperationOwner(owner)"))
        assertFalse(source.contains("encryptedStreamConfigurationSent"))
        assertFalse(source.contains("transport.send(\n            json.encodeToString"))
    }

    @Test
    fun firstFrameInputAndWatchdogCannotBypassExactAcknowledgement() {
        val source = viewModelSource()
        val packetHandler = sourceBlock(
            source,
            startMarker = "private fun handleSecureRemoteControlPacket(",
            endMarker = "private fun handleStreamConfigurationAcknowledgement("
        )
        assertTrue(packetHandler.contains("if (!hasAcknowledgedStreamConfiguration(owner))"))
        assertTrue(packetHandler.contains("screen frame received before stream configuration acknowledgement"))

        val currentOwner = sourceBlock(
            source,
            startMarker = "private fun currentRemoteControlOwner()",
            endMarker = "fun hasSessionKeys()"
        )
        assertTrue(currentOwner.contains("owner.takeIf(::isCurrentAcknowledgedRemoteControlOwner)"))

        val acknowledgementHandler = sourceBlock(
            source,
            startMarker = "private fun handleStreamConfigurationAcknowledgement(",
            endMarker = "private fun RemoteDesktopStreamConfigurationAcknowledgement.matches("
        )
        assertTrue(acknowledgementHandler.contains("AcknowledgementHandling.DUPLICATE -> Unit"))
        assertTrue(acknowledgementHandler.contains("transport.runIfCurrentSecureOperationOwner(owner)"))
        assertTrue(acknowledgementHandler.contains("startWatchdog()"))
        assertTrue(acknowledgementHandler.contains("recordAcknowledgement("))
        assertFalse(acknowledgementHandler.contains("lastFrameAtMs = clockMs()"))
        assertFalse(acknowledgementHandler.contains("reconnectAttempts = 0"))

        val frameCommit = sourceBlock(
            source,
            startMarker = "private fun onInboundScreenData(",
            endMarker = "/**\n     * Surfaced"
        )
        assertTrue(frameCommit.contains("commitIfCurrentAcknowledgedRemoteControlOwner(owner)"))
        assertTrue(
            frameCommit.indexOf("commitIfCurrentAcknowledgedRemoteControlOwner(owner)") <
                frameCommit.indexOf("_frame.value = RemoteFrame(")
        )

        val clipboardCommit = sourceBlock(
            source,
            startMarker = "private fun handleInboundClipboard(",
            endMarker = "// endregion"
        )
        assertTrue(clipboardCommit.contains("commitIfCurrentAcknowledgedRemoteControlOwner(owner)"))
        assertTrue(
            clipboardCommit.indexOf("commitIfCurrentAcknowledgedRemoteControlOwner(owner)") <
                clipboardCommit.indexOf("manager.setPrimaryClip(")
        )
    }

    @Test
    fun webRtcInputSurfaceRequiresPolicySessionKeysAndExactStreamAcknowledgement() {
        val source = remoteControlScreenSource()
        val webRtcSurface = sourceBlock(
            source,
            startMarker = "private fun WebRtcRemoteControlContent(",
            endMarker = "@Composable\nprivate fun RemoteScreenSurface("
        )

        assertTrue(
            webRtcSurface.contains(
                "val remoteControlReady = streamConfigurationReady && viewModel.hasSessionKeys()"
            )
        )
        assertTrue(
            webRtcSurface.contains(
                "controlEnabled = securitySettings.allowRemoteControl && remoteControlReady"
            )
        )
        assertFalse(
            webRtcSurface.contains("controlEnabled = securitySettings.allowRemoteControl,")
        )
    }

    private fun viewModelSource(): String {
        val sourceFile = listOf(
            File("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt"),
            File("src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlViewModel.kt")
        ).firstOrNull(File::isFile)
            ?: error("RemoteControlViewModel source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }

    private fun remoteControlScreenSource(): String {
        val sourceFile = listOf(
            File("app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlScreen.kt"),
            File("src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol/RemoteControlScreen.kt")
        ).firstOrNull(File::isFile)
            ?: error("RemoteControlScreen source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }

    private fun sourceBlock(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        val end = source.indexOf(endMarker, startIndex = start + startMarker.length)
        require(start >= 0 && end > start) {
            "source block not found: start=$startMarker end=$endMarker"
        }
        return source.substring(start, end)
    }
}
