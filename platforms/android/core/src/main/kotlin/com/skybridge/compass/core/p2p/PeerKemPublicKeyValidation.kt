package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.P2PXWingKem

internal object PeerKemPublicKeyValidation {
    fun validateWirePublicKey(suiteWireId: Int, publicKey: ByteArray): P2PCryptoSuite {
        val suite = suiteForWireId(suiteWireId)
        validatePublicKey(suite, publicKey)
        return suite
    }

    fun validatePublicKey(suite: P2PCryptoSuite, publicKey: ByteArray) {
        val expectedLength = when (suite) {
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE
            P2PCryptoSuite.X_WING -> P2PXWingKem.XWING_PUBLIC_KEY_SIZE
            P2PCryptoSuite.MLKEM_768,
            P2PCryptoSuite.MLKEM_768_FS_COMPAT -> AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE
            P2PCryptoSuite.X25519,
            P2PCryptoSuite.P256 -> error("Classic suite does not carry stored peer KEM key: ${suite.name}")
        }
        require(publicKey.size == expectedLength) {
            "Invalid peer KEM public key length for ${suite.name}: ${publicKey.size}, expected $expectedLength"
        }
    }

    private fun suiteForWireId(suiteWireId: Int): P2PCryptoSuite {
        require(suiteWireId in 0..0xFFFF) {
            "Unsupported peer KEM suite wireId=$suiteWireId"
        }
        return P2PCryptoSuite.fromWireId(suiteWireId.toUShort())
            ?: throw IllegalArgumentException("Unsupported peer KEM suite wireId=$suiteWireId")
    }
}
