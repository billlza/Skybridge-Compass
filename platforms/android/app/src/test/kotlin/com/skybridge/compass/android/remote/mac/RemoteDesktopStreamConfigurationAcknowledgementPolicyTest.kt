package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class RemoteDesktopStreamConfigurationAcknowledgementPolicyTest {

    private val transaction = RemoteDesktopStreamConfigurationTransaction(
        UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
    )
    private val expectation = RemoteDesktopStreamConfigurationAcknowledgementExpectation(
        transaction = transaction,
        streamRefreshToken = 42uL,
        audioEndpointPresent = true,
        screenFrameTransport = "sbc2"
    )
    private val exactAcknowledgement = RemoteDesktopStreamConfigurationAcknowledgement(
        acceptedAt = 1_000.0,
        transaction = transaction,
        streamRefreshToken = 42uL,
        audioEndpointPresent = true,
        screenFrameTransport = "sbc2"
    )

    @Test
    fun exactAcknowledgement_isAcceptedOnlyWhileAwaiting() {
        assertEquals(
            RemoteDesktopStreamConfigurationAcknowledgementDecision.ACCEPT,
            RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                acknowledgement = exactAcknowledgement,
                awaiting = expectation,
                acknowledged = null
            )
        )
        assertEquals(
            RemoteDesktopStreamConfigurationAcknowledgementDecision.IGNORE_DUPLICATE,
            RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                acknowledgement = exactAcknowledgement,
                awaiting = null,
                acknowledged = expectation
            )
        )
    }

    @Test
    fun acknowledgementWithoutCurrentOperation_isRejected() {
        assertEquals(
            RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_UNEXPECTED,
            RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                acknowledgement = exactAcknowledgement,
                awaiting = null,
                acknowledged = null
            )
        )
    }

    @Test
    fun everyCorrelatedField_mustMatchExactly() {
        val conflictingAcknowledgements = listOf(
            exactAcknowledgement.copy(
                transaction = RemoteDesktopStreamConfigurationTransaction(UUID.randomUUID())
            ),
            exactAcknowledgement.copy(streamRefreshToken = 43uL),
            exactAcknowledgement.copy(audioEndpointPresent = false),
            exactAcknowledgement.copy(screenFrameTransport = "legacy")
        )

        conflictingAcknowledgements.forEach { acknowledgement ->
            assertEquals(
                RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_CONFLICTING,
                RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                    acknowledgement = acknowledgement,
                    awaiting = expectation,
                    acknowledged = null
                )
            )
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidTrackerState_isRejected() {
        RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
            acknowledgement = exactAcknowledgement,
            awaiting = expectation,
            acknowledged = expectation
        )
    }
}
