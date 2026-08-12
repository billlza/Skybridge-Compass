package com.skybridge.compass.core.p2p

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PairingTrustManagerTest {

    @Test
    fun requestDecisionDeclinesWhenNoApprovalProviderIsRegistered() = runBlocking {
        val previousProvider = PairingTrustManager.approvalProvider
        PairingTrustManager.approvalProvider = null
        try {
            val decision = PairingTrustManager.requestDecision(
                PairingTrustRequest(
                    peerId = "peer-a",
                    declaredDeviceId = "peer-a"
                )
            )

            assertEquals(PairingTrustDecision.DECLINE, decision)
        } finally {
            PairingTrustManager.approvalProvider = previousProvider
        }
    }
}
