package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinBootstrapKemAdmissionTest {

    @Test
    fun admitsQPeriaptWhenJoinPlatformIsExplicitlyEligible() {
        val admitted = JoinBootstrapKemAdmission.admit(
            keys = listOf(
                key(
                    suite = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
                    bytes = sizedKey(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE)
                )
            ),
            platform = "macOS",
            osVersion = "macOS 26.0"
        )

        assertFalse(admitted.rejectedQPeriapt)
        assertEquals(
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt(),
            admitted.acceptedKeys.single().suiteWireId
        )
    }

    @Test
    fun rejectsOnlyQPeriaptWhenJoinPlatformIsAmbiguous() {
        val admitted = JoinBootstrapKemAdmission.admit(
            keys = listOf(
                key(
                    suite = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
                    bytes = sizedKey(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE)
                ),
                key(
                    suite = P2PCryptoSuite.X_WING,
                    bytes = sizedKey(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)
                )
            ),
            platform = null,
            osVersion = "26.0"
        )

        assertTrue(admitted.rejectedQPeriapt)
        assertEquals(1, admitted.acceptedKeys.size)
        assertEquals(P2PCryptoSuite.X_WING.wireId.toInt(), admitted.acceptedKeys.single().suiteWireId)
    }

    @Test
    fun rejectedQPeriaptDoesNotRequireParsingItsPublicKey() {
        val admitted = JoinBootstrapKemAdmission.admit(
            keys = listOf(
                WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
                    suiteWireId = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt(),
                    publicKey = "not base64!"
                ),
                key(
                    suite = P2PCryptoSuite.X_WING,
                    bytes = sizedKey(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)
                )
            ),
            platform = null,
            osVersion = "26.0"
        )

        assertTrue(admitted.rejectedQPeriapt)
        assertEquals(1, admitted.acceptedKeys.size)
        assertEquals(P2PCryptoSuite.X_WING.wireId.toInt(), admitted.acceptedKeys.single().suiteWireId)
    }

    @Test
    fun rejectsQPeriaptWhenJoinPlatformIsTooOld() {
        val admitted = JoinBootstrapKemAdmission.admit(
            keys = listOf(
                key(
                    suite = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
                    bytes = sizedKey(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE)
                )
            ),
            platform = "Android",
            osVersion = "Android 16 (API 35)"
        )

        assertTrue(admitted.rejectedQPeriapt)
        assertTrue(admitted.acceptedKeys.isEmpty())
    }

    @Test
    fun blankJoinBootstrapPublicKeyFailsExplicitly() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapKemAdmission.admit(
                keys = listOf(
                    WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
                        suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                        publicKey = " "
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)"
            )
        }
    }

    @Test
    fun invalidJoinBootstrapPublicKeyLengthFailsAtAdmissionBoundary() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapKemAdmission.admit(
                keys = listOf(
                    key(
                        suite = P2PCryptoSuite.MLKEM_768,
                        bytes = sizedKey(AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE - 1)
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)"
            )
        }
    }

    @Test
    fun invalidJoinBootstrapBase64FailsWithSuiteContext() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapKemAdmission.admit(
                keys = listOf(
                    WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
                        suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                        publicKey = "not base64!"
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)"
            )
        }

        assertTrue(checkNotNull(error.message).contains("suite=${P2PCryptoSuite.X_WING.wireId.toInt()}"))
    }

    @Test
    fun unsupportedJoinBootstrapSuiteFailsAtAdmissionBoundary() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapKemAdmission.admit(
                keys = listOf(
                    WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
                        suiteWireId = 0x7777,
                        publicKey = Base64.getEncoder().encodeToString(byteArrayOf(1))
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)"
            )
        }
    }

    private fun key(
        suite: P2PCryptoSuite,
        bytes: ByteArray
    ): WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey =
        WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
            suiteWireId = suite.wireId.toInt(),
            publicKey = Base64.getEncoder().encodeToString(bytes)
        )

    private fun sizedKey(size: Int): ByteArray =
        ByteArray(size) { index -> (index and 0x7f).toByte() }
}
