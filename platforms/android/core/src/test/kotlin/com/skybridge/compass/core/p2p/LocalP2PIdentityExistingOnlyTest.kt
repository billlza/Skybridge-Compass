package com.skybridge.compass.core.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class LocalP2PIdentityExistingOnlyTest {
    @Test
    fun existingP256KeyCannotReplaceMissingCachedFingerprint() {
        val keyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }
        assertThrows(IllegalStateException::class.java) {
            LocalP2PIdentity.requireMatchingExistingP256Fingerprint(
                cachedFingerprint = null,
                keyPair = keyPair
            )
        }
    }

    @Test
    fun cachedFingerprintCannotReplaceMissingP256Key() {
        assertThrows(IllegalStateException::class.java) {
            LocalP2PIdentity.requireMatchingExistingP256Fingerprint(
                cachedFingerprint = "0".repeat(64),
                keyPair = null
            )
        }
    }

    @Test
    fun cachedFingerprintMustMatchExistingP256Key() {
        val keyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }
        val expected = fingerprint(keyPair.public as ECPublicKey)

        assertThrows(IllegalStateException::class.java) {
            LocalP2PIdentity.requireMatchingExistingP256Fingerprint(
                cachedFingerprint = "0".repeat(64),
                keyPair = keyPair
            )
        }
        assertEquals(
            expected,
            LocalP2PIdentity.requireMatchingExistingP256Fingerprint(
                cachedFingerprint = expected,
                keyPair = keyPair
            )
        )
    }

    private fun fingerprint(publicKey: ECPublicKey): String {
        val point = byteArrayOf(0x04) +
            fixedWidth(publicKey.w.affineX, 32) +
            fixedWidth(publicKey.w.affineY, 32)
        return MessageDigest.getInstance("SHA-256")
            .digest(point)
            .joinToString(separator = "") { "%02x".format(it) }
    }

    private fun fixedWidth(value: BigInteger, size: Int): ByteArray {
        val signed = value.toByteArray()
        val unsigned = if (signed.size > 1 && signed.first() == 0.toByte()) {
            signed.copyOfRange(1, signed.size)
        } else {
            signed
        }
        return ByteArray(size).also { output ->
            unsigned.copyInto(
                destination = output,
                destinationOffset = size - unsigned.size,
                startIndex = 0,
                endIndex = unsigned.size
            )
        }
    }
}
