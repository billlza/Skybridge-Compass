package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Locks the exact-transport generation gates into the production LAN remote client. */
class MacRemoteControlGenerationWiringTest {

    @Test
    fun handshakeAndStreamConfigurationCommitOnlyForExactTransport() {
        val source = clientSource()
        val handshakeBody = sourceBlock(
            source = source,
            startMarker = "private fun startHandshake(context: ConnectionContext)",
            endMarker = "private fun remoteControlSoaExtensions"
        )
        assertTrue(handshakeBody.contains("runIfCurrentConnection(context)"))
        assertTrue(
            handshakeBody.indexOf("runIfCurrentConnection(context)") <
                handshakeBody.indexOf("handshakeClient = client")
        )

        val streamConfigBody = sourceBlock(
            source = source,
            startMarker = "private fun sendEncryptedStreamConfigurationIfNeeded(context: ConnectionContext)",
            endMarker = "private fun remoteControlSecurityIdentity"
        )
        assertTrue(streamConfigBody.contains("connectionGeneration != context.generation"))
        assertTrue(streamConfigBody.contains("activeTransport !== context.transport"))
        assertTrue(streamConfigBody.contains("secureLanSession"))
        assertFalse(source.contains("sendEncryptedStreamConfigurationIfNeeded(context.generation)"))
        assertFalse(source.contains("encryptedStreamConfigurationSent"))
    }

    @Test
    fun streamConfigurationRetriesReuseOneTransactionAndExactEncodedMessage() {
        val source = clientSource()
        val initialSendBody = sourceBlock(
            source = source,
            startMarker = "private fun sendInitialStreamConfigurationNow(",
            endMarker = "private fun sendEncryptedStreamConfigurationIfNeeded"
        )
        assertTrue(initialSendBody.contains("RemoteDesktopStreamConfigurationTransaction.fresh()"))
        assertTrue(initialSendBody.contains("streamConfigurationTransaction = transaction"))
        assertTrue(initialSendBody.contains("encodedMessage = RemoteControlWireCodec.encodeMessage(message)"))
        assertTrue(
            initialSendBody.indexOf("installStreamConfigurationOperation(operation)") <
                initialSendBody.indexOf("sendStreamConfigurationOperationNow(operation)")
        )

        val retryBody = sourceBlock(
            source = source,
            startMarker = "private fun scheduleStreamConfigurationAcknowledgementRetries(",
            endMarker = "private fun remoteControlSecurityIdentity"
        )
        assertTrue(retryBody.contains("sendStreamConfigurationOperationNow(operation)"))
        assertTrue(retryBody.contains("pendingStreamConfiguration === operation"))
        assertTrue(retryBody.contains("stream configuration acknowledgement missing after bounded retries"))
        assertFalse(retryBody.contains("RemoteDesktopStreamConfigurationTransaction.fresh()"))
        assertFalse(retryBody.contains("RemoteControlWireCodec.encodeMessage"))
    }

    @Test
    fun exactAcknowledgementIsTheOnlyMediaAndControlAdmissionGate() {
        val source = clientSource()
        val acknowledgementBody = sourceBlock(
            source = source,
            startMarker = "private fun handleStreamConfigurationAcknowledgement(",
            endMarker = "private fun requireAcknowledgedStreamConfiguration"
        )
        assertTrue(acknowledgementBody.contains("connectionGeneration != context.generation"))
        assertTrue(acknowledgementBody.contains("activeTransport !== context.transport"))
        assertTrue(acknowledgementBody.contains("RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide"))
        assertTrue(acknowledgementBody.contains("pendingStreamConfiguration = null"))
        assertTrue(acknowledgementBody.contains("acknowledgedStreamConfiguration = acceptedOperation"))
        assertTrue(acknowledgementBody.contains("when (decision)"))
        assertTrue(
            acknowledgementBody.contains(
                "RemoteDesktopStreamConfigurationAcknowledgementDecision.IGNORE_DUPLICATE"
            )
        )
        assertTrue(acknowledgementBody.contains("duplicate exact stream configuration acknowledgement ignored"))
        assertTrue(acknowledgementBody.contains("RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_UNEXPECTED"))
        assertTrue(acknowledgementBody.contains("RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_CONFLICTING"))
        assertTrue(acknowledgementBody.contains("invalid stream configuration acknowledgement"))
        assertTrue(acknowledgementBody.contains("startWatchdogForStreaming(context)"))

        val screenBody = sourceBlock(
            source = source,
            startMarker = "private fun handleRemoteScreenMessage(",
            endMarker = "/**\n     * Surfaced by the viewer surface"
        )
        assertTrue(
            screenBody.indexOf("requireAcknowledgedStreamConfiguration(context)") <
                screenBody.indexOf("RemoteControlWireCodec.decodeScreenData(msg)")
        )

        val trustedContextBody = sourceBlock(
            source = source,
            startMarker = "private fun trustedOutboundContext()",
            endMarker = "private fun sendTrustedMessageNow("
        )
        assertTrue(trustedContextBody.contains("acknowledgedStreamConfiguration"))
        assertTrue(trustedContextBody.contains("configured.context.generation != connectionGeneration"))
        assertTrue(trustedContextBody.contains("configured.context.transport !== transport"))
        assertTrue(trustedContextBody.contains("configured.secureSession !== session"))

        assertEquals(1, source.countOccurrences("startWatchdogForStreaming(context)"))
    }

    @Test
    fun connectionResetRetiresPendingAndAcknowledgedConfigurationState() {
        val source = clientSource()
        val resetBody = sourceBlock(
            source = source,
            startMarker = "private fun resetConnectionState(",
            endMarker = "fun hasSecureChannel()"
        )
        assertTrue(resetBody.contains("streamConfigurationAckRetryJob?.cancel()"))
        assertTrue(resetBody.contains("pendingStreamConfiguration = null"))
        assertTrue(resetBody.contains("acknowledgedStreamConfiguration = null"))

        val failureBody = sourceBlock(
            source = source,
            startMarker = "private fun failConnection(",
            endMarker = "private fun closeTransport(transport: ConnectionTransport)"
        )
        assertTrue(failureBody.contains("streamConfigurationAckRetryJob?.cancel()"))
        assertTrue(failureBody.contains("pendingStreamConfiguration = null"))
        assertTrue(failureBody.contains("acknowledgedStreamConfiguration = null"))
    }

    @Test
    fun watchdogReconnectAndTerminalCleanupUseExactTransportDetachWithoutWriteLock() {
        val source = clientSource()
        val connectBody = sourceBlock(
            source = source,
            startMarker = "private fun connectInternal(",
            endMarker = "fun disconnect()"
        )
        assertTrue(connectBody.contains("forceReplaceExactWatchdogConnection("))
        assertEquals(
            4,
            connectBody.countOccurrences(
                "expectedInterruptionAtMs = expectedInterruptionAtMs"
            )
        )

        val cleanupBody = sourceBlock(
            source = source,
            startMarker = "private fun endSessionCleanup(expectedGeneration: Long, interruptionAtMs: Long)",
            endMarker = "// endregion"
        )

        assertTrue(cleanupBody.contains("forceInvalidateExactWatchdogConnection("))
        assertTrue(cleanupBody.contains("expectedGeneration = expectedGeneration"))
        assertTrue(cleanupBody.contains("expectedInterruptionAtMs = interruptionAtMs"))
        assertTrue(cleanupBody.contains("resetConnectionState("))
        assertTrue(cleanupBody.contains("generation = generation"))
        assertTrue(cleanupBody.contains("disconnectedViewerStatus = RemoteViewerStatus.SessionEnded"))
        assertFalse(cleanupBody.contains("invalidateConnection()"))
        assertFalse(cleanupBody.contains("invalidateConnectionIfCurrent("))

        val forceBody = sourceBlock(
            source = source,
            startMarker = "private fun forceInvalidateExactWatchdogConnection(",
            endMarker = "/** Must be called with [connectionLifecycleLock] held. */"
        )
        assertTrue(forceBody.contains("detachIfCurrentMacRemoteWatchdogOwner("))
        assertFalse(forceBody.contains("writeLock"))

        val failureBody = sourceBlock(
            source = source,
            startMarker = "private fun failConnection(",
            endMarker = "private fun closeTransport(transport: ConnectionTransport)"
        )
        assertTrue(failureBody.contains("forceInvalidateExactWatchdogConnection("))
    }

    @Test
    fun outboundInputUsesGenerationBoundFifoAndFinalExactOwnerCommit() {
        val source = clientSource()
        val sendBody = sourceBlock(
            source = source,
            startMarker = "private fun sendMessage(msg: RemoteMessage)",
            endMarker = "private fun readLoop"
        )
        assertTrue(sendBody.contains("val outboundContext = trustedOutboundContext() ?: return"))
        assertTrue(sendBody.contains("trustedInputQueue.enqueueAll("))
        assertTrue(sendBody.contains("MacRemoteQueuedInput.from(outboundContext.generation"))
        assertFalse(sendBody.contains("currentConnectionGeneration()"))

        val trustedSendBody = sourceBlock(
            source = source,
            startMarker = "private fun sendTrustedMessageNow(",
            endMarker = "/** Final generation/transport/session proof"
        )
        assertTrue(trustedSendBody.contains("activeTransport !== context.transport"))
        assertTrue(trustedSendBody.contains("secureLanSession !== context.secureSession"))
        assertTrue(trustedSendBody.contains("isTrustedOutboundContextCurrent(context, os)"))
        assertTrue(trustedSendBody.contains("runIfCurrentMacRemoteInputCommit("))
        assertTrue(trustedSendBody.contains("pressedInputState.record(input)"))
    }

    @Test
    fun trustedFrameEvidenceUsesOneAtomicExactOwnerSnapshot() {
        val evidenceBody = sourceBlock(
            source = clientSource(),
            startMarker = "internal fun currentTrustedFrameEvidence()",
            endMarker = "private fun logHandshake("
        )

        assertTrue(evidenceBody.contains("synchronized(connectionLifecycleLock)"))
        assertTrue(evidenceBody.contains("latestFrameGeneration"))
        assertTrue(evidenceBody.contains("secureConnectionGeneration"))
        assertTrue(evidenceBody.contains("acknowledged.context.generation"))
        assertTrue(evidenceBody.contains("acknowledged.context.transport === transport"))
        assertTrue(evidenceBody.contains("acknowledged.secureSession === secureSession"))
        assertTrue(
            evidenceBody.contains("MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner")
        )

        val screenBody = sourceBlock(
            source = clientSource(),
            startMarker = "private fun handleRemoteScreenMessage(",
            endMarker = "/**\n     * Surfaced by the viewer surface"
        )
        assertTrue(screenBody.contains("latestFrameGeneration = context.generation"))
    }

    @Test
    fun reconnectPreflightRunsBeforeReplacingCurrentTransport() {
        val source = clientSource()
        val connectBody = sourceBlock(
            source = source,
            startMarker = "private fun connectInternal(",
            endMarker = "fun disconnect()"
        )
        val preflight = connectBody.indexOf("val stablePeerId = try")
        val generationBranch = connectBody.indexOf("val generation = if")
        val normalInvalidate = connectBody.indexOf(
            "invalidateConnectionForExplicitConnect()",
            generationBranch
        )
        val watchdogInvalidate = connectBody.indexOf(
            "forceReplaceExactWatchdogConnection(",
            generationBranch
        )
        val ownerRegistration = connectBody.indexOf("registerConnectionOwner(context, job)")
        val reconnectWatchdog = connectBody.indexOf("startWatchdog(context.generation)")
        require(
            preflight >= 0 &&
                generationBranch >= 0 &&
                normalInvalidate >= 0 &&
                watchdogInvalidate >= 0 &&
                ownerRegistration >= 0 &&
                reconnectWatchdog >= 0
        )
        assertTrue(
            "identity/trust preflight must precede normal replacement",
            preflight < normalInvalidate
        )
        assertTrue(
            "identity/trust preflight must precede watchdog replacement",
            preflight < watchdogInvalidate
        )
        assertTrue(
            "both replacement branches must complete before owner registration",
            normalInvalidate < ownerRegistration && watchdogInvalidate < ownerRegistration
        )
        assertTrue("watchdog must only be installed after exact owner registration", ownerRegistration < reconnectWatchdog)
    }

    @Test
    fun watchdogReconnectPreflightFailureCannotRemainReconnecting() {
        assertEquals(
            RemoteViewerStatus.SessionEnded,
            MacRemoteViewerFailurePolicy.terminalStatus(
                currentStatus = RemoteViewerStatus.Reconnecting,
                interruptedAtMs = 5_000L,
                watchdogReconnecting = true
            )
        )
        assertEquals(
            RemoteViewerStatus.Idle,
            MacRemoteViewerFailurePolicy.terminalStatus(
                currentStatus = RemoteViewerStatus.Idle,
                interruptedAtMs = null,
                watchdogReconnecting = false
            )
        )

        val failBody = sourceBlock(
            source = clientSource(),
            startMarker = "private fun failConnection(",
            endMarker = "private fun closeTransport(transport: ConnectionTransport)"
        )
        assertTrue(failBody.contains("MacRemoteViewerFailurePolicy.terminalStatus("))
        assertTrue(failBody.contains("_viewerStatus.value = terminalViewerStatus"))
        assertTrue(failBody.contains("reconnectInFlight = false"))
        assertTrue(failBody.contains("_state.value = State.Failed(reason)"))
        assertTrue(failBody.contains("_securityState.value = SecurityState.Failed"))
        assertFalse(failBody.contains("if (reconnectInFlight)"))
    }

    @Test
    fun explicitDisconnectIntentBlocksWatchdogReplacementAndOwnerRegistration() {
        val source = clientSource()
        val connectBody = sourceBlock(
            source = source,
            startMarker = "private fun connectInternal(",
            endMarker = "fun disconnect()"
        )
        assertTrue(connectBody.contains("invalidateConnectionForExplicitConnect()"))
        assertTrue(connectBody.contains("forceReplaceExactWatchdogConnection("))

        val disconnectBody = sourceBlock(
            source = source,
            startMarker = "fun disconnect()",
            endMarker = "private fun invalidateConnectionForExplicitConnect()"
        )
        assertTrue(
            disconnectBody.indexOf("userDisconnectRequested = true") <
                disconnectBody.indexOf("val outboundContext = trustedOutboundContext()")
        )
        assertTrue(disconnectBody.contains("if (isInputDrainOwnerCurrent(owner)) return"))
        assertTrue(disconnectBody.contains("watchdogJob.also { watchdogJob = null }"))
        assertTrue(disconnectBody.contains("watchdogToCancel?.cancel()"))
        assertTrue(disconnectBody.contains("forceInvalidateUserDisconnectIntent()"))

        val registrationBody = sourceBlock(
            source = source,
            startMarker = "private fun registerConnectionOwner(",
            endMarker = "private fun clearConnectionJob("
        )
        assertTrue(registrationBody.contains("!userDisconnectRequested"))

        val reconnectBody = sourceBlock(
            source = source,
            startMarker = "private fun reconnectNow(",
            endMarker = "/**\n     * End the session"
        )
        assertTrue(reconnectBody.contains("userDisconnectRequested ||"))
    }

    private fun sourceBlock(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        val end = source.indexOf(endMarker, start)
        require(start >= 0 && end > start) {
            "source block not found: $startMarker -> $endMarker"
        }
        return source.substring(start, end)
    }

    private fun String.countOccurrences(value: String): Int {
        require(value.isNotEmpty())
        var count = 0
        var searchFrom = 0
        while (true) {
            val index = indexOf(value, searchFrom)
            if (index < 0) return count
            count += 1
            searchFrom = index + value.length
        }
    }

    private fun clientSource(): String {
        val sourceFile = listOf(
            File("app/src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlClient.kt"),
            File("src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlClient.kt")
        ).firstOrNull { it.isFile }
            ?: error("MacRemoteControlClient source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }
}
