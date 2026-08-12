package com.skybridge.compass.android.security

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HandshakePolicyMappingTest {
    @Test
    fun rejectsDisabledPqcBeforeRuntimePolicyMapping() {
        assertThrows(IllegalArgumentException::class.java) {
            SecuritySettings(pqcEnabled = false).toHandshakePolicyOverride()
        }
    }

    @Test
    fun mapsExplicitQPeriaptWithoutWeakFallback() {
        val policy = SecuritySettings(
            pqcMinimumTier = P2PQPeriaptKem.MINIMUM_TIER_RAW,
            enforcePqcHandshake = true,
            allowClassicFallbackForCompatibility = false
        ).toHandshakePolicyOverride()

        assertTrue(policy.requirePqc)
        assertFalse(policy.allowClassicFallback)
        assertEquals(P2PQPeriaptKem.MINIMUM_TIER_RAW, policy.minimumTierRaw)
    }

    @Test
    fun explicitQPeriaptSuppressesCompatibilityFallback() {
        val policy = SecuritySettings(
            pqcMinimumTier = P2PQPeriaptKem.MINIMUM_TIER_RAW,
            enforcePqcHandshake = true,
            allowClassicFallbackForCompatibility = true
        ).toHandshakePolicyOverride()

        assertTrue(policy.requirePqc)
        assertFalse(policy.allowClassicFallback)
        assertEquals(P2PQPeriaptKem.MINIMUM_TIER_RAW, policy.minimumTierRaw)
    }
}
