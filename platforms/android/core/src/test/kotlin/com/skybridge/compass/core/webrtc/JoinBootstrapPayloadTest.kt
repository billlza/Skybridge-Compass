package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.util.Base64
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class JoinBootstrapPayloadTest {

    @Test
    fun convertsPairingKemKeysToJoinPayloadWithPlatformMetadata() {
        val xWingKey = sizedKey(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)
        val mlKemKey = sizedKey(AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE)
        val binding = ProtocolIdentityBinding(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = ByteArray(32) { 0x22 }
        )

        val payload = JoinBootstrapPayload.fromPairingIdentity(
            payload = AppMessage.PairingIdentityExchangePayload(
                deviceId = "android-device",
                kemPublicKeys = listOf(
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                        publicKey = xWingKey
                    ),
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                        publicKey = mlKemKey
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)",
                sentAt = 1.0
            ),
            authority = binding
        )

        val keys = checkNotNull(payload?.kemPublicKeys)
        assertEquals(ProtocolSigningAlgorithm.ED25519, payload.protocolSigningAlgorithm)
        assertEquals(binding.protocolPublicKeyFingerprint, payload.protocolPublicKeyFingerprint)
        assertArrayEquals(binding.protocolPublicKeyBytes, Base64.getDecoder().decode(payload.protocolPublicKeyBytes))
        assertEquals("Android", payload.platform)
        assertEquals("Android 16 (API 36)", payload.osVersion)
        assertEquals(P2PCryptoSuite.X_WING.wireId.toInt(), keys[0].suiteWireId)
        assertArrayEquals(xWingKey, Base64.getDecoder().decode(keys[0].publicKey))
        assertEquals(P2PCryptoSuite.MLKEM_768.wireId.toInt(), keys[1].suiteWireId)
        assertArrayEquals(mlKemKey, Base64.getDecoder().decode(keys[1].publicKey))
    }

    @Test
    fun joinBootstrapDoesNotLeakBusinessIdentityMetadata() {
        val xWingKey = sizedKey(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)

        val payload = JoinBootstrapPayload.fromPairingIdentity(
            payload = AppMessage.PairingIdentityExchangePayload(
                deviceId = "android-device",
                kemPublicKeys = listOf(
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                        publicKey = xWingKey
                    )
                ),
                platform = "Android",
                osVersion = "Android 16 (API 36)",
                sentAt = 1.0,
                accountDisplayName = "Bill",
                nebulaId = "NEBULA-2026-ABCDEF123456",
                capabilities = listOf("remoteControl")
            )
        )

        val encoded = Json.encodeToString(checkNotNull(payload))

        assertEquals("Android", payload.platform)
        assertEquals("Android 16 (API 36)", payload.osVersion)
        assertFalse(encoded.contains("accountDisplayName"))
        assertFalse(encoded.contains("nebulaId"))
        assertFalse(encoded.contains("capabilities"))
        assertFalse(encoded.contains("NEBULA-2026-ABCDEF123456"))
        assertFalse(encoded.contains("Bill"))
    }

    @Test
    fun returnsNullWhenPairingPayloadHasNoKemKeys() {
        val payload = JoinBootstrapPayload.fromPairingIdentity(
            AppMessage.PairingIdentityExchangePayload(
                deviceId = "android-device",
                kemPublicKeys = emptyList(),
                platform = "Android",
                osVersion = "Android 16 (API 36)",
                sentAt = 1.0
            )
        )

        assertNull(payload)
    }

    @Test
    fun rejectsEmptyJoinBootstrapPublicKey() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapPayload.fromPairingIdentity(
                AppMessage.PairingIdentityExchangePayload(
                    deviceId = "android-device",
                    kemPublicKeys = listOf(
                        AppMessage.KemPublicKeyInfo(
                            suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                            publicKey = ByteArray(0)
                        )
                    ),
                    platform = "Android",
                    osVersion = "Android 16 (API 36)",
                    sentAt = 1.0
                )
            )
        }
    }

    @Test
    fun rejectsInvalidJoinBootstrapPublicKeyLength() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapPayload.fromPairingIdentity(
                AppMessage.PairingIdentityExchangePayload(
                    deviceId = "android-device",
                    kemPublicKeys = listOf(
                        AppMessage.KemPublicKeyInfo(
                            suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                            publicKey = sizedKey(P2PXWingKem.XWING_PUBLIC_KEY_SIZE - 1)
                        )
                    ),
                    platform = "Android",
                    osVersion = "Android 16 (API 36)",
                    sentAt = 1.0
                )
            )
        }
    }

    private fun sizedKey(size: Int): ByteArray =
        ByteArray(size) { index -> (index and 0x7f).toByte() }
}
