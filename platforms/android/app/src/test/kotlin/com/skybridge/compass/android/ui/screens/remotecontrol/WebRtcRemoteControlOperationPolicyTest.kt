package com.skybridge.compass.android.ui.screens.remotecontrol

import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import org.junit.Assert.assertEquals
import org.junit.Test

class WebRtcRemoteControlOperationPolicyTest {
    @Test
    fun staleOwnerCallbackIsIgnoredWithoutFailingReplacement() {
        val replacementOwner = fakeOwner()
        val staleOwner = fakeOwner()

        assertEquals(
            WebRtcRemoteControlPacketAdmissionPolicy.Decision.IGNORE_STALE_OWNER,
            WebRtcRemoteControlPacketAdmissionPolicy.decide(
                expectedOwner = replacementOwner,
                callbackOwner = staleOwner,
                callbackOwnerIsCurrent = false
            )
        )
    }

    @Test
    fun revokedCapabilityIsIgnoredUntilTheAuthoritativeOwnerFlowCatchesUp() {
        val owner = fakeOwner()

        assertEquals(
            WebRtcRemoteControlPacketAdmissionPolicy.Decision.IGNORE_STALE_OWNER,
            WebRtcRemoteControlPacketAdmissionPolicy.decide(
                expectedOwner = owner,
                callbackOwner = owner,
                callbackOwnerIsCurrent = false
            )
        )
        assertEquals(
            WebRtcRemoteControlPacketAdmissionPolicy.Decision.HANDLE,
            WebRtcRemoteControlPacketAdmissionPolicy.decide(
                expectedOwner = owner,
                callbackOwner = owner,
                callbackOwnerIsCurrent = true
            )
        )
    }

    @Test
    fun reconnectAcknowledgementPreservesOriginalNoFrameWindowAndBudgetBaseline() {
        val firstAcknowledgementAt =
            WebRtcRemoteControlWatchdogBaselinePolicy.recordAcknowledgement(
                existingAcknowledgedAtMs = null,
                acceptedAtMs = 1_000L
            )
        val reconnectAcknowledgementAt =
            WebRtcRemoteControlWatchdogBaselinePolicy.recordAcknowledgement(
                existingAcknowledgedAtMs = firstAcknowledgementAt,
                acceptedAtMs = 9_000L
            )

        assertEquals(1_000L, reconnectAcknowledgementAt)
        assertEquals(
            1_000L,
            WebRtcRemoteControlWatchdogBaselinePolicy.baseline(
                lastAdmittedFrameAtMs = 0L,
                acknowledgedAtMs = reconnectAcknowledgementAt
            )
        )
        assertEquals(
            4_000L,
            WebRtcRemoteControlWatchdogBaselinePolicy.baseline(
                lastAdmittedFrameAtMs = 4_000L,
                acknowledgedAtMs = reconnectAcknowledgementAt
            )
        )
    }

    private fun fakeOwner(): WebRtcSecureOperationOwner =
        object : WebRtcSecureOperationOwner {}
}
