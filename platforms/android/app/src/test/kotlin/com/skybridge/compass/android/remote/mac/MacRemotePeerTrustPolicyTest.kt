package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class MacRemotePeerTrustPolicyTest {

    @Test
    fun unauthenticatedDiscoveryFingerprintDoesNotPersistWhenTofuIsDisabled() {
        val evaluation = MacRemotePeerTrustPolicy.evaluate(
            peerId = "mac-1",
            observedFingerprint = "aa11",
            advertisedFingerprint = "AA11",
            advertisedFingerprintTrustSource = MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY,
            pinnedFingerprint = null,
            allowTrustOnFirstUse = false
        )

        assertEquals(MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL, evaluation.trustState)
        assertNull(evaluation.fingerprintToPersist)
    }

    @Test
    fun trustedConfigurationFingerprintPersistsEvenWhenTofuIsDisabled() {
        val evaluation = MacRemotePeerTrustPolicy.evaluate(
            peerId = "mac-1",
            observedFingerprint = "aa11",
            advertisedFingerprint = "AA11",
            advertisedFingerprintTrustSource = MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION,
            pinnedFingerprint = null,
            allowTrustOnFirstUse = false
        )

        assertEquals(MacRemoteControlClient.TrustState.TRUSTED_NEW, evaluation.trustState)
        assertEquals("aa11", evaluation.fingerprintToPersist)
    }

    @Test
    fun tofuPersistsWhenExplicitlyEnabled() {
        val evaluation = MacRemotePeerTrustPolicy.evaluate(
            peerId = "mac-1",
            observedFingerprint = "aa11",
            advertisedFingerprint = null,
            advertisedFingerprintTrustSource = MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY,
            pinnedFingerprint = null,
            allowTrustOnFirstUse = true
        )

        assertEquals(MacRemoteControlClient.TrustState.TRUSTED_NEW, evaluation.trustState)
        assertEquals("aa11", evaluation.fingerprintToPersist)
    }

    @Test
    fun pinnedFingerprintMismatchFailsClosed() {
        assertThrows(IllegalStateException::class.java) {
            MacRemotePeerTrustPolicy.evaluate(
                peerId = "mac-1",
                observedFingerprint = "aa11",
                advertisedFingerprint = null,
                advertisedFingerprintTrustSource = MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY,
                pinnedFingerprint = "bb22",
                allowTrustOnFirstUse = true
            )
        }
    }

    @Test
    fun advertisedFingerprintMismatchFailsClosed() {
        assertThrows(IllegalStateException::class.java) {
            MacRemotePeerTrustPolicy.evaluate(
                peerId = "mac-1",
                observedFingerprint = "aa11",
                advertisedFingerprint = "bb22",
                advertisedFingerprintTrustSource = MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY,
                pinnedFingerprint = null,
                allowTrustOnFirstUse = false
            )
        }
    }
}
