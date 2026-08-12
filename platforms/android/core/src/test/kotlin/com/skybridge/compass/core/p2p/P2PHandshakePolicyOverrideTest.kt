package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PHandshakePolicyOverrideTest {

    @Test
    fun trustedClassicBootstrapDowngradesStrictPolicyToClassicWireContract() {
        val strictPolicy = P2PHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = false,
            minimumTierRaw = "nativePQC",
            requireSecureEnclavePoP = true,
            providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_PQC
        )

        val effective = strictPolicy.forTrustedClassicBootstrap(enabled = true)

        assertNotSame(strictPolicy, effective)
        assertFalse(effective.requirePqc)
        assertFalse(effective.allowClassicFallback)
        assertEquals("classic", effective.minimumTierRaw)
        assertFalse(effective.requireSecureEnclavePoP)
        assertEquals(P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC, effective.providerTypeRaw)
    }

    @Test
    fun trustedClassicBootstrapLeavesOriginalPolicyWhenDisabled() {
        val strictPolicy = P2PHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = false,
            minimumTierRaw = "nativePQC",
            requireSecureEnclavePoP = false,
            providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_PQC
        )

        val effective = strictPolicy.forTrustedClassicBootstrap(enabled = false)

        assertSame(strictPolicy, effective)
        assertTrue(effective.requirePqc)
        assertEquals("nativePQC", effective.minimumTierRaw)
    }

    @Test
    fun trustedClassicBootstrapDoesNotDowngradeExplicitQPeriaptPolicy() {
        val qPolicy = P2PHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = false,
            minimumTierRaw = P2PQPeriaptKem.MINIMUM_TIER_RAW,
            requireSecureEnclavePoP = false,
            providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT
        )

        val effective = qPolicy.forTrustedClassicBootstrap(enabled = true)

        assertSame(qPolicy, effective)
        assertTrue(effective.requirePqc)
        assertEquals(P2PQPeriaptKem.MINIMUM_TIER_RAW, effective.minimumTierRaw)
        assertEquals(P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT, effective.providerTypeRaw)
    }
}
