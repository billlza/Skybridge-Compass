package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider

/** Dispatches protocol-identity verification only after the wire algorithm has been parsed. */
internal class ProtocolIdentitySignatureVerifier(
    private val verifyEd25519: (ByteArray, ByteArray, ByteArray) -> Boolean =
        Ed25519SoftwareVerifier::verify,
    private val verifyMlDsa65: suspend (ByteArray, ByteArray, ByteArray) -> Boolean =
        { data, signature, publicKey ->
            AndroidPQCCryptoProvider().verify(data, signature, publicKey)
        }
) {
    suspend fun verify(
        algorithm: ProtocolSigningAlgorithm,
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean = when (algorithm) {
        ProtocolSigningAlgorithm.ED25519 -> verifyEd25519(data, signature, publicKey)
        ProtocolSigningAlgorithm.ML_DSA_65 -> {
            require(publicKey.size == AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE) {
                "ML-DSA-65 public key must be ${AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE} bytes"
            }
            require(signature.size == AndroidPQCCryptoProvider.MLDSA65_SIGNATURE_SIZE) {
                "ML-DSA-65 signature must be ${AndroidPQCCryptoProvider.MLDSA65_SIGNATURE_SIZE} bytes"
            }
            verifyMlDsa65(data, signature, publicKey)
        }
    }
}
