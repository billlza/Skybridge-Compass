package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRemoteTrustedSessionPolicyTest {

    @Test
    fun existingTrustedSecureStateAllowsRemoteControl() {
        val state = secureState(MacRemoteControlClient.TrustState.TRUSTED_EXISTING)

        assertTrue(MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(state))
        assertSame(
            MacRemoteControlClient.TrustState.TRUSTED_EXISTING,
            MacRemoteTrustedSessionPolicy.requireTrustedRemoteControlTrust(
                peerId = "mac-1",
                trustState = MacRemoteControlClient.TrustState.TRUSTED_EXISTING
            )
        )
    }

    @Test
    fun newlyTrustedSecureStateAllowsRemoteControl() {
        val state = secureState(MacRemoteControlClient.TrustState.TRUSTED_NEW)

        assertTrue(MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(state))
    }

    @Test
    fun untrustedEphemeralSecureStateDoesNotAllowRemoteControl() {
        val state = secureState(MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL)

        assertFalse(MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(state))
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteTrustedSessionPolicy.requireTrustedRemoteControlTrust(
                peerId = "mac-1",
                trustState = MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL
            )
        }
    }

    @Test
    fun nonSecureStatesDoNotAllowRemoteControl() {
        assertFalse(
            MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(
                MacRemoteControlClient.SecurityState.Negotiating(peerId = "mac-1", pinned = false)
            )
        )
        assertFalse(
            MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(
                MacRemoteControlClient.SecurityState.Plaintext(peerId = "mac-1", reason = "legacy")
            )
        )
        assertFalse(
            MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(
                MacRemoteControlClient.SecurityState.Failed(peerId = "mac-1", reason = "failed")
            )
        )
        assertFalse(
            MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(
                MacRemoteControlClient.SecurityState.Disconnected
            )
        )
    }

    private fun secureState(
        trustState: MacRemoteControlClient.TrustState
    ): MacRemoteControlClient.SecurityState.Secure =
        MacRemoteControlClient.SecurityState.Secure(
            peerId = "mac-1",
            fingerprint = "00",
            suite = "Q_PERIAPT_CONTEXT_BOUND",
            trustState = trustState
        )
}
