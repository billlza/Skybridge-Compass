package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import java.security.KeyPairGenerator
import java.security.spec.NamedParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CurrentPathProtocolAuthorityTest {
    @Test
    fun strictQPeriaptAuthorityUsesMlDsa65ProtocolIdentity() {
        val mlDsaPublic = ByteArray(AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE) {
            (it and 0x7f).toByte()
        }
        val signingKeys = signingKeys(mlDsaPublicKeyRaw = mlDsaPublic)

        val binding = CurrentPathProtocolAuthority.bindingFor(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            policy = policy(minimumTierRaw = P2PQPeriaptKem.MINIMUM_TIER_RAW),
            signingKeys = signingKeys
        )

        assertEquals(ProtocolSigningAlgorithm.ML_DSA_65, binding.protocolSigningAlgorithm)
        assertArrayEquals(mlDsaPublic, binding.protocolPublicKeyBytes)
        assertEquals(
            ProtocolIdentityBinding.computeFingerprint(
                ProtocolSigningAlgorithm.ML_DSA_65,
                mlDsaPublic
            ),
            binding.protocolPublicKeyFingerprint
        )
    }

    @Test
    fun classicAuthorityUsesEd25519ProtocolIdentity() {
        val ed25519Public = ByteArray(32) { (0x40 + it).toByte() }
        val signingKeys = signingKeys(ed25519PublicRaw32 = ed25519Public)

        val binding = CurrentPathProtocolAuthority.bindingFor(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            policy = policy(minimumTierRaw = "classic"),
            signingKeys = signingKeys
        )

        assertEquals(ProtocolSigningAlgorithm.ED25519, binding.protocolSigningAlgorithm)
        assertArrayEquals(ed25519Public, binding.protocolPublicKeyBytes)
    }

    @Test
    fun pqcAuthorityFailsClosedWhenMlDsa65KeyIsUnavailable() {
        val signingKeys = signingKeys(mlDsaPublicKeyRaw = null)

        assertThrows(IllegalArgumentException::class.java) {
            CurrentPathProtocolAuthority.bindingFor(
                deviceId = "12345678-1234-1234-1234-1234567890ab",
                policy = policy(minimumTierRaw = "nativePQC"),
                signingKeys = signingKeys
            )
        }
    }

    private fun policy(minimumTierRaw: String): P2PHandshakePolicyOverride =
        P2PHandshakePolicyOverride(
            requirePqc = minimumTierRaw != "classic",
            allowClassicFallback = false,
            minimumTierRaw = minimumTierRaw,
            providerTypeRaw = "Android"
        )

    private fun signingKeys(
        ed25519PublicRaw32: ByteArray = ByteArray(32) { it.toByte() },
        mlDsaPublicKeyRaw: ByteArray? = ByteArray(AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE)
    ): LocalP2PIdentity.ProtocolSigningKeys {
        val keyPair = KeyPairGenerator.getInstance("Ed25519")
            .apply { initialize(NamedParameterSpec.ED25519) }
            .generateKeyPair()
        return LocalP2PIdentity.ProtocolSigningKeys(
            ed25519PrivateKey = keyPair.private,
            ed25519PublicRaw32 = ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = mlDsaPublicKeyRaw?.let { ByteArray(32) },
            mlDsa65PublicKeyRaw = mlDsaPublicKeyRaw
        )
    }
}
