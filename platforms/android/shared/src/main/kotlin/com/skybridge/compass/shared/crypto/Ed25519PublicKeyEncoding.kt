package com.skybridge.compass.shared.crypto

/** RFC 8410 SubjectPublicKeyInfo wrapper for a raw 32-byte Ed25519 public key. */
internal object Ed25519PublicKeyEncoding {
    private val subjectPublicKeyInfoPrefix = byteArrayOf(
        0x30, 0x2a,
        0x30, 0x05,
        0x06, 0x03, 0x2b, 0x65, 0x70,
        0x03, 0x21, 0x00
    )

    fun toRfc8410SubjectPublicKeyInfo(rawPublicKey: ByteArray): ByteArray {
        require(rawPublicKey.size == RAW_PUBLIC_KEY_BYTES) {
            "Ed25519 public key must be $RAW_PUBLIC_KEY_BYTES bytes"
        }
        return subjectPublicKeyInfoPrefix + rawPublicKey
    }

    private const val RAW_PUBLIC_KEY_BYTES = 32
}
