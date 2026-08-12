package com.skybridge.compass.shared.p2p

import java.security.MessageDigest

/**
 * Shared mirror of Apple `SessionKeys.deterministicSessionId(transcriptHash:)`.
 */
object P2PSessionIds {
    fun deterministicSessionId(transcriptHash: ByteArray): String {
        val input = "SkyBridge-SessionId-v1|".toByteArray(Charsets.UTF_8) + transcriptHash
        val digest = MessageDigest.getInstance("SHA-256").digest(input)
        val hex = StringBuilder(32)
        for (i in 0 until 16) {
            hex.append(HEX[(digest[i].toInt() ushr 4) and 0x0F])
            hex.append(HEX[digest[i].toInt() and 0x0F])
        }
        return "hs-$hex"
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
