package com.skybridge.compass.shared.p2p

import java.security.PrivateKey

/**
 * Stable protocol signing keys for the Pro-release compatible P2P handshake.
 *
 * - Classic suite uses Ed25519.
 * - PQC / hybrid suites use ML-DSA-65 (raw key bytes from AndroidPQCCryptoProvider / liboqs).
 */
data class P2PProtocolSigningKeys(
    val ed25519PrivateKey: PrivateKey,
    val ed25519PublicKeyRaw32: ByteArray,
    val mlDsa65PrivateKeyRaw: ByteArray? = null,
    val mlDsa65PublicKeyRaw: ByteArray? = null
)

