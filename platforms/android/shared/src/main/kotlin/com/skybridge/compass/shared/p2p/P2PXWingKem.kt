package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.coroutines.runBlocking
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.KeyAgreement

/**
 * X-Wing hybrid KEM helper (draft-connolly-cfrg-xwing-kem-09).
 *
 * Public key format: pk_M(ML-KEM-768 1184) || pk_X(X25519 32) = 1216 bytes
 * Ciphertext format: ct_M(ML-KEM-768 1088) || ct_X(X25519 32) = 1120 bytes
 * Private key storage format (local): sk_X(32) || sk_M(2400) = 2432 bytes
 *
 * Combiner:
 * SHA3-256(ss_M || ss_X || ct_X || pk_X || "X-Wing")
 */
object P2PXWingKem {
    // X-WingLabel from the current CFRG draft and Apple native implementation:
    // hex 5c2e2f2f5e5c == "\\.//^\\"
    private val X_WING_LABEL = byteArrayOf(
        0x5c,
        0x2e,
        0x2f,
        0x2f,
        0x5e,
        0x5c
    )

    const val X25519_PUBLIC_KEY_SIZE: Int = 32
    const val X25519_PRIVATE_KEY_SIZE: Int = 32
    const val X25519_CIPHERTEXT_SIZE: Int = 32

    const val MLKEM768_PUBLIC_KEY_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE
    const val MLKEM768_SECRET_KEY_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_SECRET_KEY_SIZE
    const val MLKEM768_CIPHERTEXT_SIZE: Int = AndroidPQCCryptoProvider.MLKEM768_CIPHERTEXT_SIZE

    const val XWING_PUBLIC_KEY_SIZE: Int = MLKEM768_PUBLIC_KEY_SIZE + X25519_PUBLIC_KEY_SIZE
    const val XWING_PRIVATE_KEY_SIZE: Int = X25519_PRIVATE_KEY_SIZE + MLKEM768_SECRET_KEY_SIZE
    const val XWING_CIPHERTEXT_SIZE: Int = MLKEM768_CIPHERTEXT_SIZE + X25519_CIPHERTEXT_SIZE

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
        if (runCatching { sha3Digest256() }.isFailure) return "sha3_unavailable"
        runCatching { P2PClassicHpkeX25519.generateX25519KeyPair() }
            .exceptionOrNull()
            ?.let { return "x25519_keygen_${it.javaClass.simpleName}" }
        runCatching { KeyAgreement.getInstance("X25519") }
            .exceptionOrNull()
            ?.let { return "x25519_key_agreement_${it.javaClass.simpleName}" }
        return null
    }

    fun isAvailable(): Boolean {
        if (!AndroidPQCCryptoProvider.isAvailable()) return false
        return availabilityFailureReason() == null
    }

    fun generateKeyPair(pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider()): KeyPairMaterial {
        val x25519 = P2PClassicHpkeX25519.generateX25519KeyPair()
        val xSk = rawX25519PrivateKey32(x25519.private)
        val xPk = P2PClassicHpkeX25519.rawPublicKey32(x25519.public)

        val kemKeys = generateMLKEM768KeyPairRaw(pqcProvider)
        val mlPk = kemKeys.publicKey1184
        val mlSk = kemKeys.privateKey2400

        val publicKey = ByteArray(XWING_PUBLIC_KEY_SIZE)
        System.arraycopy(mlPk, 0, publicKey, 0, MLKEM768_PUBLIC_KEY_SIZE)
        System.arraycopy(xPk, 0, publicKey, MLKEM768_PUBLIC_KEY_SIZE, X25519_PUBLIC_KEY_SIZE)

        val privateKey = ByteArray(XWING_PRIVATE_KEY_SIZE)
        System.arraycopy(xSk, 0, privateKey, 0, X25519_PRIVATE_KEY_SIZE)
        System.arraycopy(mlSk, 0, privateKey, X25519_PRIVATE_KEY_SIZE, MLKEM768_SECRET_KEY_SIZE)

        return KeyPairMaterial(publicKey = publicKey, privateKey = privateKey)
    }

    fun encapsulate(
        recipientPublicKey: ByteArray,
        pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider()
    ): EncapResult {
        require(recipientPublicKey.size == XWING_PUBLIC_KEY_SIZE) {
            "Invalid X-Wing public key length: ${recipientPublicKey.size}"
        }

        // Public key format (draft-09): pk_M || pk_X
        val mlPk = recipientPublicKey.copyOfRange(0, MLKEM768_PUBLIC_KEY_SIZE)
        val xPk = recipientPublicKey.copyOfRange(MLKEM768_PUBLIC_KEY_SIZE, XWING_PUBLIC_KEY_SIZE)

        val (ctM, ssM) = pqcProvider.encapsulate(mlPk)
        val x = P2PClassicHpkeX25519.encapsulateSharedSecret(xPk)
        val ctX = x.encapsulatedKey32
        val ssX = x.sharedSecret32

        val combinedCt = ByteArray(XWING_CIPHERTEXT_SIZE)
        System.arraycopy(ctM, 0, combinedCt, 0, MLKEM768_CIPHERTEXT_SIZE)
        System.arraycopy(ctX, 0, combinedCt, MLKEM768_CIPHERTEXT_SIZE, X25519_CIPHERTEXT_SIZE)

        val shared = combineSecrets(mlKemSs32 = ssM, x25519Ss32 = ssX, ctX32 = ctX, pkX32 = xPk)
        return EncapResult(ciphertext = combinedCt, sharedSecret32 = shared)
    }

    fun decapsulate(
        ciphertext: ByteArray,
        privateKey: ByteArray,
        pqcProvider: AndroidPQCCryptoProvider = AndroidPQCCryptoProvider()
    ): ByteArray {
        require(ciphertext.size == XWING_CIPHERTEXT_SIZE) {
            "Invalid X-Wing ciphertext length: ${ciphertext.size}"
        }
        require(privateKey.size == XWING_PRIVATE_KEY_SIZE) {
            "Invalid X-Wing private key length: ${privateKey.size}"
        }

        val xSk = privateKey.copyOfRange(0, X25519_PRIVATE_KEY_SIZE)
        val mlSk = privateKey.copyOfRange(X25519_PRIVATE_KEY_SIZE, XWING_PRIVATE_KEY_SIZE)

        val ctM = ciphertext.copyOfRange(0, MLKEM768_CIPHERTEXT_SIZE)
        val ctX = ciphertext.copyOfRange(MLKEM768_CIPHERTEXT_SIZE, XWING_CIPHERTEXT_SIZE)

        val ssM = pqcProvider.decapsulate(ctM, mlSk)

        val xPriv = privateKeyFromRaw32(xSk)
        val ephemeralPub = P2PClassicHpkeX25519.publicKeyFromRaw32(ctX)
        val ssX = x25519Dh(xPriv, ephemeralPub)

        val pkX = publicKeyFromPrivateRaw32(xPriv)
        return combineSecrets(mlKemSs32 = ssM, x25519Ss32 = ssX, ctX32 = ctX, pkX32 = pkX)
    }

    private fun combineSecrets(
        mlKemSs32: ByteArray,
        x25519Ss32: ByteArray,
        ctX32: ByteArray,
        pkX32: ByteArray
    ): ByteArray {
        require(mlKemSs32.size == 32) { "mlKemSs32 must be 32 bytes" }
        require(x25519Ss32.size == 32) { "x25519Ss32 must be 32 bytes" }
        require(ctX32.size == 32) { "ctX32 must be 32 bytes" }
        require(pkX32.size == 32) { "pkX32 must be 32 bytes" }

        val md = sha3Digest256()
        md.update(mlKemSs32)
        md.update(x25519Ss32)
        md.update(ctX32)
        md.update(pkX32)
        md.update(X_WING_LABEL)
        return md.digest()
    }

    private val X25519_PKCS8_PREFIX = byteArrayOf(
        0x30, 0x2e,
        0x02, 0x01, 0x00,
        0x30, 0x05,
        0x06, 0x03, 0x2b, 0x65, 0x6e,
        0x04, 0x22,
        0x04, 0x20
    )

    private fun privateKeyFromRaw32(raw: ByteArray): PrivateKey {
        require(raw.size == 32) { "X25519 raw private key must be 32 bytes" }
        val pkcs8 = ByteArray(X25519_PKCS8_PREFIX.size + 32)
        System.arraycopy(X25519_PKCS8_PREFIX, 0, pkcs8, 0, X25519_PKCS8_PREFIX.size)
        System.arraycopy(raw, 0, pkcs8, X25519_PKCS8_PREFIX.size, 32)
        val kf = KeyFactory.getInstance("X25519")
        return kf.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
    }

    private fun x25519Dh(priv: PrivateKey, pub: java.security.PublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("X25519")
        ka.init(priv)
        ka.doPhase(pub, true)
        return ka.generateSecret()
    }

    private fun publicKeyFromPrivateRaw32(priv: PrivateKey): ByteArray {
        // pk = DH(priv, basepoint)
        val basepoint = ByteArray(32)
        basepoint[0] = 9
        val basePub = P2PClassicHpkeX25519.publicKeyFromRaw32(basepoint)
        val pk = x25519Dh(priv, basePub)
        require(pk.size == 32) { "Derived X25519 public key must be 32 bytes" }
        return pk
    }

    private fun sha3Digest256(): MessageDigest {
        runCatching { MessageDigest.getInstance("SHA3-256") }.getOrNull()?.let { return it }

        val bundledBc = runCatching { BouncyCastleProvider() }.getOrNull()
        if (bundledBc != null) {
            runCatching { MessageDigest.getInstance("SHA3-256", bundledBc) }.getOrNull()?.let { return it }
        }

        throw IllegalStateException("SHA3-256 provider unavailable")
    }

    private fun rawX25519PrivateKey32(privateKey: PrivateKey): ByteArray {
        val enc = privateKey.encoded
        require(enc.size >= 32) { "X25519 private key encoding too short" }
        return enc.copyOfRange(enc.size - 32, enc.size)
    }

    data class MlKemKeyPairRaw(
        val publicKey1184: ByteArray,
        val privateKey2400: ByteArray
    )

    private fun generateMLKEM768KeyPairRaw(provider: AndroidPQCCryptoProvider): MlKemKeyPairRaw {
        val keyPair = runBlocking { provider.generateKeyPair(KeyUsage.KEY_EXCHANGE) }
        val pub = keyPair.publicKey.bytes
        val priv = keyPair.privateKey.bytes
        require(pub.size == MLKEM768_PUBLIC_KEY_SIZE) { "Invalid ML-KEM public key length: ${pub.size}" }
        require(priv.size == MLKEM768_SECRET_KEY_SIZE) { "Invalid ML-KEM private key length: ${priv.size}" }
        return MlKemKeyPairRaw(publicKey1184 = pub, privateKey2400 = priv)
    }
}
