package com.skybridge.compass.shared.p2p

/**
 * Pro release P2P handshake suites (wireId is UInt16 LE on wire).
 */
enum class P2PCryptoSuite(val wireId: UShort, val isPqc: Boolean) {
    X_WING(0x0001u, true),      // X25519(32) + ML-KEM-768(1088) ciphertext in keyShare
    MLKEM_768(0x0101u, true),   // ML-KEM-768
    MLKEM_768_FS_COMPAT(0x0102u, true), // compatibility parse path (non-negotiable by default)
    X25519(0x1001u, false),
    P256(0x1002u, false);

    companion object {
        fun fromWireId(wireId: UShort): P2PCryptoSuite? = entries.firstOrNull { it.wireId == wireId }

        fun isNegotiable(suite: P2PCryptoSuite): Boolean = suite != MLKEM_768_FS_COMPAT
    }
}

