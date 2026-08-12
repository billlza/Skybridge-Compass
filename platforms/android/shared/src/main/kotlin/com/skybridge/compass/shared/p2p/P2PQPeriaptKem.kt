package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.coroutines.runBlocking
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.KeyAgreement

/**
 * Q-Periapt ContextBound KEM helper for Android.
 *
 * Wire layout matches the macOS/iOS provider:
 * - publicKey  = pk_pq(1184) || pk_trad(32)
 * - privateKey = sk_pq(2400) || sk_trad(32) || pk_pq(1184) || pk_trad(32)
 * - ciphertext = ct_pq(1088) || ct_trad(32)
 * - secret     = SHA3-256 ContextBound output (32 bytes)
 *
 * This intentionally stays in Kotlin/JNI over the existing Android ML-KEM and
 * X25519 primitives. It does not introduce the SkyBridge Rust core on Android.
 */
object P2PQPeriaptKem {
    const val PROFILE_CONTEXT_BOUND: Byte = 2
    const val POLICY_VERSION: Int = 1

    const val MLKEM768_PUBLIC_KEY_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE
    const val MLKEM768_SECRET_KEY_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_SECRET_KEY_SIZE
    const val MLKEM768_CIPHERTEXT_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_CIPHERTEXT_SIZE
    const val X25519_SIZE: Int = 32
    const val SHARED_SECRET_SIZE: Int = 32

    const val QPERIAPT_PUBLIC_KEY_SIZE: Int = MLKEM768_PUBLIC_KEY_SIZE + X25519_SIZE
    const val QPERIAPT_PRIVATE_KEY_SIZE: Int =
        MLKEM768_SECRET_KEY_SIZE + X25519_SIZE + MLKEM768_PUBLIC_KEY_SIZE + X25519_SIZE
    const val QPERIAPT_CIPHERTEXT_SIZE: Int = MLKEM768_CIPHERTEXT_SIZE + X25519_SIZE

    const val MIN_ANDROID_API: Int = 36
    const val MINIMUM_TIER_RAW: String = "qperiaptPQC"
    const val KEM_CAPABILITY_NAME: String = "q-periapt-context-bound"

    private val DOMAIN = "Q-PERIAPT-HYBRID-KEM/v1".toByteArray(Charsets.UTF_8)
    private val SUITE_ID = "ML-KEM-768+X25519".toByteArray(Charsets.UTF_8)
    private val DEFAULT_CONTEXT = "skybridge-qperiapt/v1".toByteArray(Charsets.UTF_8)

    private val X25519_PKCS8_PREFIX = byteArrayOf(
        0x30, 0x2e,
        0x02, 0x01, 0x00,
        0x30, 0x05,
        0x06, 0x03, 0x2b, 0x65, 0x6e,
        0x04, 0x22,
        0x04, 0x20
    )

    data class KeyPairMaterial(
        val publicKey: ByteArray,
        val privateKey: ByteArray
    )

    data class EncapResult(
        val ciphertext: ByteArray,
        val sharedSecret32: ByteArray
    )

    fun availabilityFailureReason(): String? {
        if (!AndroidPQCCryptoProvider.isAvailable()) return "mlkem_unavailable"
        runCatching { sha3Digest256() }
            .exceptionOrNull()
            ?.let { return "sha3_unavailable_${it.javaClass.simpleName}" }
        runCatching { P2PClassicHpkeX25519.generateX25519KeyPair() }
            .exceptionOrNull()
            ?.let { return "x25519_keygen_${it.javaClass.simpleName}" }
        runCatching { KeyAgreement.getInstance("X25519") }
            .exceptionOrNull()
            ?.let { return "x25519_key_agreement_${it.javaClass.simpleName}" }
        return null
    }

    fun isAvailable(): Boolean = availabilityFailureReason() == null

    fun generateKeyPair(pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider()): KeyPairMaterial {
        val mlKem = generateMLKEM768KeyPairRaw(pqcProvider)
        val x25519 = P2PClassicHpkeX25519.generateX25519KeyPair()
        val xSk = rawX25519PrivateKey32(x25519.private)
        val xPk = P2PClassicHpkeX25519.rawPublicKey32(x25519.public)

        val publicKey = ByteArray(QPERIAPT_PUBLIC_KEY_SIZE)
        System.arraycopy(mlKem.publicKey1184, 0, publicKey, 0, MLKEM768_PUBLIC_KEY_SIZE)
        System.arraycopy(xPk, 0, publicKey, MLKEM768_PUBLIC_KEY_SIZE, X25519_SIZE)

        val privateKey = ByteArray(QPERIAPT_PRIVATE_KEY_SIZE)
        var offset = 0
        System.arraycopy(mlKem.privateKey2400, 0, privateKey, offset, MLKEM768_SECRET_KEY_SIZE)
        offset += MLKEM768_SECRET_KEY_SIZE
        System.arraycopy(xSk, 0, privateKey, offset, X25519_SIZE)
        offset += X25519_SIZE
        System.arraycopy(mlKem.publicKey1184, 0, privateKey, offset, MLKEM768_PUBLIC_KEY_SIZE)
        offset += MLKEM768_PUBLIC_KEY_SIZE
        System.arraycopy(xPk, 0, privateKey, offset, X25519_SIZE)

        return KeyPairMaterial(publicKey = publicKey, privateKey = privateKey)
    }

    fun encapsulate(
        recipientPublicKey: ByteArray,
        pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider(),
        context: ByteArray = DEFAULT_CONTEXT
    ): EncapResult {
        require(recipientPublicKey.size == QPERIAPT_PUBLIC_KEY_SIZE) {
            "Invalid Q-Periapt public key length: ${recipientPublicKey.size}"
        }
        require(context.isNotEmpty()) { "Q-Periapt ContextBound context must be non-empty" }

        val pkPq = recipientPublicKey.copyOfRange(0, MLKEM768_PUBLIC_KEY_SIZE)
        val pkTrad = recipientPublicKey.copyOfRange(MLKEM768_PUBLIC_KEY_SIZE, QPERIAPT_PUBLIC_KEY_SIZE)

        val (ctPq, ssPq) = pqcProvider.encapsulate(pkPq)
        val x = P2PClassicHpkeX25519.encapsulateSharedSecret(pkTrad)
        requireContributoryX25519(x.sharedSecret32)

        val ciphertext = ByteArray(QPERIAPT_CIPHERTEXT_SIZE)
        System.arraycopy(ctPq, 0, ciphertext, 0, MLKEM768_CIPHERTEXT_SIZE)
        System.arraycopy(x.encapsulatedKey32, 0, ciphertext, MLKEM768_CIPHERTEXT_SIZE, X25519_SIZE)

        val secret = combineContextBound(
            suiteId = SUITE_ID,
            policyVersion = POLICY_VERSION,
            ssPq = ssPq,
            ssTrad = x.sharedSecret32,
            ctPq = ctPq,
            pkPq = pkPq,
            ctTrad = x.encapsulatedKey32,
            pkTrad = pkTrad,
            context = context
        )
        return EncapResult(ciphertext = ciphertext, sharedSecret32 = secret)
    }

    fun decapsulate(
        ciphertext: ByteArray,
        privateKey: ByteArray,
        pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider(),
        context: ByteArray = DEFAULT_CONTEXT
    ): ByteArray {
        require(ciphertext.size == QPERIAPT_CIPHERTEXT_SIZE) {
            "Invalid Q-Periapt ciphertext length: ${ciphertext.size}"
        }
        require(privateKey.size == QPERIAPT_PRIVATE_KEY_SIZE) {
            "Invalid Q-Periapt private key length: ${privateKey.size}"
        }
        require(context.isNotEmpty()) { "Q-Periapt ContextBound context must be non-empty" }

        var offset = 0
        val skPq = privateKey.copyOfRange(offset, offset + MLKEM768_SECRET_KEY_SIZE)
        offset += MLKEM768_SECRET_KEY_SIZE
        val skTrad = privateKey.copyOfRange(offset, offset + X25519_SIZE)
        offset += X25519_SIZE
        val pkPq = privateKey.copyOfRange(offset, offset + MLKEM768_PUBLIC_KEY_SIZE)
        offset += MLKEM768_PUBLIC_KEY_SIZE
        val pkTrad = privateKey.copyOfRange(offset, offset + X25519_SIZE)

        val ctPq = ciphertext.copyOfRange(0, MLKEM768_CIPHERTEXT_SIZE)
        val ctTrad = ciphertext.copyOfRange(MLKEM768_CIPHERTEXT_SIZE, QPERIAPT_CIPHERTEXT_SIZE)

        val derivedPkTrad = publicKeyFromPrivateRaw32(privateKeyFromRaw32(skTrad))
        require(derivedPkTrad.contentEquals(pkTrad)) {
            "Q-Periapt private key is corrupt: X25519 public key does not match private key"
        }

        val ssPq = pqcProvider.decapsulate(ctPq, skPq)
        val ssTrad = x25519Dh(privateKeyFromRaw32(skTrad), P2PClassicHpkeX25519.publicKeyFromRaw32(ctTrad))
        requireContributoryX25519(ssTrad)

        return combineContextBound(
            suiteId = SUITE_ID,
            policyVersion = POLICY_VERSION,
            ssPq = ssPq,
            ssTrad = ssTrad,
            ctPq = ctPq,
            pkPq = pkPq,
            ctTrad = ctTrad,
            pkTrad = pkTrad,
            context = context
        )
    }

    internal fun combineContextBound(
        suiteId: ByteArray,
        policyVersion: Int,
        ssPq: ByteArray,
        ssTrad: ByteArray,
        ctPq: ByteArray,
        pkPq: ByteArray,
        ctTrad: ByteArray,
        pkTrad: ByteArray,
        context: ByteArray
    ): ByteArray {
        require(context.isNotEmpty()) { "Q-Periapt ContextBound context must be non-empty" }
        val digest = sha3Digest256()
        absorbLengthPrefixed(digest, DOMAIN)
        absorbLengthPrefixed(digest, suiteId)
        absorbLengthPrefixed(
            digest,
            ByteBuffer.allocate(Int.SIZE_BYTES)
                .order(ByteOrder.BIG_ENDIAN)
                .putInt(policyVersion)
                .array()
        )
        absorbLengthPrefixed(digest, ssPq)
        absorbLengthPrefixed(digest, ssTrad)
        absorbLengthPrefixed(digest, ctPq)
        absorbLengthPrefixed(digest, pkPq)
        absorbLengthPrefixed(digest, ctTrad)
        absorbLengthPrefixed(digest, pkTrad)
        absorbLengthPrefixed(digest, context)
        return digest.digest()
    }

    fun asKeyPair(material: KeyPairMaterial): KeyPair {
        require(material.publicKey.size == QPERIAPT_PUBLIC_KEY_SIZE) {
            "Invalid Q-Periapt public key length: ${material.publicKey.size}"
        }
        require(material.privateKey.size == QPERIAPT_PRIVATE_KEY_SIZE) {
            "Invalid Q-Periapt private key length: ${material.privateKey.size}"
        }
        return KeyPair(
            publicKey = KeyMaterial(CryptoSuite.Q_PERIAPT_CONTEXT_BOUND, KeyUsage.KEY_EXCHANGE, material.publicKey),
            privateKey = KeyMaterial(CryptoSuite.Q_PERIAPT_CONTEXT_BOUND, KeyUsage.KEY_EXCHANGE, material.privateKey)
        )
    }

    private fun absorbLengthPrefixed(digest: MessageDigest, field: ByteArray) {
        digest.update(
            ByteBuffer.allocate(Long.SIZE_BYTES)
                .order(ByteOrder.BIG_ENDIAN)
                .putLong(field.size.toLong())
                .array()
        )
        digest.update(field)
    }

    private fun requireContributoryX25519(sharedSecret32: ByteArray) {
        require(sharedSecret32.size == X25519_SIZE) { "X25519 shared secret must be 32 bytes" }
        require(sharedSecret32.any { it != 0.toByte() }) {
            "Invalid X25519 public key share: non-contributory all-zero shared secret"
        }
    }

    private fun sha3Digest256(): MessageDigest {
        runCatching { MessageDigest.getInstance("SHA3-256") }.getOrNull()?.let { return it }

        val bundledBc = runCatching { BouncyCastleProvider() }.getOrNull()
        if (bundledBc != null) {
            runCatching { MessageDigest.getInstance("SHA3-256", bundledBc) }.getOrNull()?.let { return it }
        }

        throw IllegalStateException("SHA3-256 provider unavailable")
    }

    private fun privateKeyFromRaw32(raw: ByteArray): PrivateKey {
        require(raw.size == X25519_SIZE) { "X25519 raw private key must be 32 bytes" }
        val pkcs8 = ByteArray(X25519_PKCS8_PREFIX.size + X25519_SIZE)
        System.arraycopy(X25519_PKCS8_PREFIX, 0, pkcs8, 0, X25519_PKCS8_PREFIX.size)
        System.arraycopy(raw, 0, pkcs8, X25519_PKCS8_PREFIX.size, X25519_SIZE)
        val keyFactory = KeyFactory.getInstance("X25519")
        return keyFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
    }

    private fun x25519Dh(priv: PrivateKey, pub: java.security.PublicKey): ByteArray {
        val keyAgreement = KeyAgreement.getInstance("X25519")
        keyAgreement.init(priv)
        keyAgreement.doPhase(pub, true)
        return keyAgreement.generateSecret()
    }

    private fun publicKeyFromPrivateRaw32(priv: PrivateKey): ByteArray {
        val basepoint = ByteArray(X25519_SIZE)
        basepoint[0] = 9
        val basePub = P2PClassicHpkeX25519.publicKeyFromRaw32(basepoint)
        val publicKey = x25519Dh(priv, basePub)
        require(publicKey.size == X25519_SIZE) { "Derived X25519 public key must be 32 bytes" }
        return publicKey
    }

    private fun rawX25519PrivateKey32(privateKey: PrivateKey): ByteArray {
        val encoded = privateKey.encoded
        require(encoded.size >= X25519_SIZE) { "X25519 private key encoding too short" }
        return encoded.copyOfRange(encoded.size - X25519_SIZE, encoded.size)
    }

    private data class MlKemKeyPairRaw(
        val publicKey1184: ByteArray,
        val privateKey2400: ByteArray
    )

    private fun generateMLKEM768KeyPairRaw(provider: AndroidPQCCryptoProvider): MlKemKeyPairRaw {
        val keyPair = runBlocking { provider.generateKeyPair(KeyUsage.KEY_EXCHANGE) }
        val publicKey = keyPair.publicKey.bytes
        val privateKey = keyPair.privateKey.bytes
        require(publicKey.size == MLKEM768_PUBLIC_KEY_SIZE) {
            "Invalid ML-KEM public key length: ${publicKey.size}"
        }
        require(privateKey.size == MLKEM768_SECRET_KEY_SIZE) {
            "Invalid ML-KEM private key length: ${privateKey.size}"
        }
        return MlKemKeyPairRaw(publicKey1184 = publicKey, privateKey2400 = privateKey)
    }
}
