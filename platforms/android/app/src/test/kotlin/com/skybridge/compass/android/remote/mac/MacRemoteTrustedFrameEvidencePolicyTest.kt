package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRemoteTrustedFrameEvidencePolicyTest {
    @Test
    fun watchdogReconnectCannotReuseRetainedFrameFromPreviousGeneration() {
        val generationA = exactSnapshot(generation = 41L)
        assertTrue(MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(generationA))

        val generationBWithRetainedFrame = exactSnapshot(generation = 42L).copy(
            frameGeneration = 41L
        )
        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                generationBWithRetainedFrame
            )
        )

        val generationBWithNewFrame = generationBWithRetainedFrame.copy(
            frameGeneration = 42L
        )
        assertTrue(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(generationBWithNewFrame)
        )
    }

    @Test
    fun acknowledgementMustOwnCurrentTransportAndSecureSession() {
        val exact = exactSnapshot(generation = 7L)

        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(acknowledgementGeneration = 6L)
            )
        )
        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(acknowledgementOwnsTransport = false)
            )
        )
        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(acknowledgementOwnsSecureSession = false)
            )
        )
    }

    @Test
    fun secureAndFrameOwnersMustBothBeCurrentAndTrusted() {
        val exact = exactSnapshot(generation = 99L)

        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(secureGeneration = 98L)
            )
        )
        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(transportGeneration = 98L)
            )
        )
        assertFalse(
            MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(
                exact.copy(trustedSecurityState = false)
            )
        )
    }

    private fun exactSnapshot(generation: Long): MacRemoteTrustedFrameOwnershipSnapshot =
        MacRemoteTrustedFrameOwnershipSnapshot(
            currentGeneration = generation,
            transportGeneration = generation,
            secureGeneration = generation,
            frameGeneration = generation,
            acknowledgementGeneration = generation,
            trustedSecurityState = true,
            acknowledgementOwnsTransport = true,
            acknowledgementOwnsSecureSession = true
        )
}
