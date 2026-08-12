package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class QPeriaptPlatformPolicyTest {

    @Test
    fun localAndroidGateAcceptsAndroid16AndRejectsNonAndroidLabels() {
        assertTrue(QPeriaptPlatformPolicy.isLocalAndroidSupported("Android 16 (API 36)"))
        assertTrue(QPeriaptPlatformPolicy.isLocalAndroidSupported("Android 17 (API 37)"))

        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("16"))
        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("15"))
        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("Android 15 (API 35)"))
        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("Android 16 (API 35)"))
        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("Android 15 (API 36)"))
        assertFalse(
            QPeriaptPlatformPolicy.isLocalAndroidSupported(
                QPeriaptPlatformPolicy.androidHandshakePlatformVersion(null, 36)
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isLocalAndroidSupported(
                QPeriaptPlatformPolicy.androidHandshakePlatformVersion(" ", 36)
            )
        )
        assertFalse(QPeriaptPlatformPolicy.isLocalAndroidSupported("macOS 26.0"))
    }

    @Test
    fun androidPlatformVersionUsesCanonicalMetadataShape() {
        assertEquals(
            "Android 16 (API 36)",
            QPeriaptPlatformPolicy.androidPlatformVersion("16", 36)
        )
        assertEquals(
            "Android unknown (API 36)",
            QPeriaptPlatformPolicy.androidPlatformVersion(null, 36)
        )
    }

    @Test
    fun appPeerGateAcceptsOnlyExplicitSupportedPlatforms() {
        assertTrue(QPeriaptPlatformPolicy.isAppPeerEligible("macOS", "macOS 26.0"))
        assertTrue(QPeriaptPlatformPolicy.isAppPeerEligible("iOS", "iOS 26.1"))
        assertTrue(QPeriaptPlatformPolicy.isAppPeerEligible("Android", "Android 16 (API 36)"))
        assertTrue(QPeriaptPlatformPolicy.isAppPeerEligible("android", "Android 17 (API 37)"))

        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("macOS", "macOS 25.9"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("iOS", "iOS 25.9"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("Android", "Android 15 (API 35)"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("Android", "Android 16 (API 35)"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("Android", "Android 15 (API 36)"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible("Windows", "Windows 26"))
        assertFalse(QPeriaptPlatformPolicy.isAppPeerEligible(null, "26.0"))
    }

    @Test
    fun handshakePeerGateRequiresExplicitPlatformAndQBetaProfile() {
        val eligible = capabilities(
            platformVersion = "macOS 26.0",
            authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE)
        )
        assertTrue(QPeriaptPlatformPolicy.isHandshakePeerEligible(eligible))

        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "macOS 26.0",
                    authProfiles = listOf("pqc")
                )
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "26.0",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE)
                )
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "Android 16 (API 36)",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                    pqcAvailable = false
                )
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "Android 16 (API 36)",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                    supportedKEM = listOf("x-wing")
                )
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "Android 16 (API 36)",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                    supportedSignature = listOf("ed25519")
                )
            )
        )
        assertFalse(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "Android 16 (API 36)",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                    providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_PQC
                )
            )
        )
        assertThrows(IllegalArgumentException::class.java) {
            QPeriaptPlatformPolicy.requireHandshakePeerEligible(
                capabilities = capabilities(
                    platformVersion = "iOS 25.9",
                    authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE)
                ),
                peerRole = "test"
            )
        }
    }

    @Test
    fun handshakePeerGateAcceptsAppleWireCapabilitySpelling() {
        assertTrue(
            QPeriaptPlatformPolicy.isHandshakePeerEligible(
                capabilities(
                    platformVersion = "macOS 27.0",
                    authProfiles = listOf("q-periapt-beta", "Hybrid", "PQC", "Classic"),
                    supportedKEM = listOf("Q-Periapt-ContextBound"),
                    supportedSignature = listOf("ML-DSA-65")
                )
            )
        )
    }

    @Test
    fun deterministicCapabilitiesDecodeRejectsMalformedBooleansAndTrailingBytes() {
        val encoded = capabilities(
            platformVersion = "Android 16 (API 36)",
            authProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE)
        ).deterministicEncode()
        val malformedBool = encoded.copyOf()
        malformedBool[capabilitiesPqcBoolOffset(encoded)] = 0x02

        assertThrows(IllegalArgumentException::class.java) {
            P2PCryptoCapabilities.deterministicDecode(malformedBool)
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PCryptoCapabilities.deterministicDecode(encoded + byteArrayOf(0x00))
        }
    }

    private fun capabilitiesPqcBoolOffset(encoded: ByteArray): Int {
        var offset = 0
        repeat(4) {
            val count = readU32LE(encoded, offset)
            offset += 4
            repeat(count) {
                val length = readU32LE(encoded, offset)
                offset += 4 + length
            }
        }
        return offset
    }

    private fun readU32LE(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)

    private fun capabilities(
        platformVersion: String,
        authProfiles: List<String>,
        supportedKEM: List<String> = listOf(P2PQPeriaptKem.KEM_CAPABILITY_NAME),
        supportedSignature: List<String> = listOf("ml-dsa-65"),
        pqcAvailable: Boolean = true,
        providerTypeRaw: String = P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT
    ): P2PCryptoCapabilities =
        P2PCryptoCapabilities(
            supportedKEM = supportedKEM,
            supportedSignature = supportedSignature,
            supportedAuthProfiles = authProfiles,
            supportedAEAD = listOf("aes256GCM"),
            pqcAvailable = pqcAvailable,
            platformVersion = platformVersion,
            providerTypeRaw = providerTypeRaw
        )
}
