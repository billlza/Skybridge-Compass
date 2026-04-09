package com.skybridge.compass.shared.p2p

import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Security
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Implements enough of RFC 9180 HPKE base mode for Pro release classic provider interop:
 * - KEM: DHKEM(X25519, HKDF-SHA256)
 * - KDF: HKDF-SHA256
 * - AEAD: ChaCha20-Poly1305
 *
 * This is used for opening the MessageB encryptedPayload and exporting the session root secret:
 * `SkyBridge-KEMDEM-SessionRoot-v1|` + suiteWireIdLE + info
 */
object P2PClassicHpkeX25519 {
    // HPKE IDs (RFC 9180)
    private const val KEM_ID: Int = 0x0020
    private const val KDF_ID: Int = 0x0001
    private const val AEAD_ID: Int = 0x0003

    private val SUITE_ID: ByteArray = buildSuiteId()
    private val KEM_SUITE_ID: ByteArray = buildKemSuiteId()

    private val X25519_SPKI_PREFIX = byteArrayOf(
        0x30, 0x2a,
        0x30, 0x05,
        0x06, 0x03, 0x2b, 0x65, 0x6e,
        0x03, 0x21, 0x00
    )

    private const val EXPORTER_CONTEXT_PREFIX = "SkyBridge-KEMDEM-SessionRoot-v1|"

    data class OpenResult(
        val plaintext: ByteArray,
        val exportedSecret32: ByteArray
    )

    data class SealResult(
        val sealedBox: P2PHPKESealedBox,
        val exportedSecret32: ByteArray
    )

    data class EncapResult(
        val encapsulatedKey32: ByteArray,
        val sharedSecret32: ByteArray
    )

    fun generateX25519KeyPair(): KeyPair {
        val discoveredProviders = Security.getProviders("KeyPairGenerator.X25519").orEmpty()
        val softwareProviders = buildList {
            discoveredProviders
                .filterNot { provider ->
                    provider.name.contains("AndroidKeyStore", ignoreCase = true)
                }
                .forEach(::add)

            listOf("Conscrypt", "AndroidOpenSSL", "BC").forEach { name ->
                Security.getProvider(name)?.let { provider ->
                    if (none { it.name == provider.name } &&
                        !provider.name.contains("AndroidKeyStore", ignoreCase = true)
                    ) {
                        add(provider)
                    }
                }
            }

            val bundledBc = runCatching { BouncyCastleProvider() }.getOrNull()
            if (bundledBc != null && !providerAlreadyIncluded(this, bundledBc)) {
                add(bundledBc)
            }
        }
        return softwareProviders.asSequence()
            .mapNotNull { provider ->
                runCatching {
                    KeyPairGenerator.getInstance("X25519", provider).generateKeyPair()
                }.getOrNull()
            }
            .firstOrNull()
            ?: run {
                val generator = KeyPairGenerator.getInstance("X25519")
                require(!generator.provider.name.contains("AndroidKeyStore", ignoreCase = true)) {
                    "No exportable X25519 software provider available"
                }
                generator.generateKeyPair()
            }
    }

    fun rawPublicKey32(publicKey: PublicKey): ByteArray {
        val enc = publicKey.encoded
        require(enc.size >= 32) { "X25519 public key encoding too short" }
        return enc.copyOfRange(enc.size - 32, enc.size)
    }

    fun publicKeyFromRaw32(raw: ByteArray): PublicKey {
        require(raw.size == 32) { "X25519 raw public key must be 32 bytes" }
        val spki = ByteArray(X25519_SPKI_PREFIX.size + 32)
        System.arraycopy(X25519_SPKI_PREFIX, 0, spki, 0, X25519_SPKI_PREFIX.size)
        System.arraycopy(raw, 0, spki, X25519_SPKI_PREFIX.size, 32)
        val kf = KeyFactory.getInstance("X25519")
        return kf.generatePublic(X509EncodedKeySpec(spki))
    }

    /**
     * Lightweight X25519 KEM-compatible encapsulation used by latest P2P v1 handshake:
     * - ciphertext = ephemeral X25519 public key (32 bytes)
     * - sharedSecret = DH(ephemeralPrivate, receiverPublic)
     */
    fun encapsulateSharedSecret(receiverPublicKeyRaw32: ByteArray): EncapResult {
        require(receiverPublicKeyRaw32.size == 32) { "receiverPublicKeyRaw32 must be 32 bytes" }
        val epk = generateX25519KeyPair()
        val encapsulated = rawPublicKey32(epk.public)
        val receiverPub = publicKeyFromRaw32(receiverPublicKeyRaw32)
        val sharedSecret = x25519Dh(epk.private, receiverPub)
        return EncapResult(encapsulatedKey32 = encapsulated, sharedSecret32 = sharedSecret)
    }

    /**
     * Lightweight X25519 KEM-compatible decapsulation used by latest P2P v1 handshake:
     * - sharedSecret = DH(receiverPrivate, ephemeralPublic)
     */
    fun decapsulateSharedSecret(
        encapsulatedKeyRaw32: ByteArray,
        receiverPrivateKey: PrivateKey
    ): ByteArray {
        require(encapsulatedKeyRaw32.size == 32) { "encapsulatedKeyRaw32 must be 32 bytes" }
        val ephemeralPub = publicKeyFromRaw32(encapsulatedKeyRaw32)
        return x25519Dh(receiverPrivateKey, ephemeralPub)
    }

    fun openAndExport(
        sealedBox: P2PHPKESealedBox,
        receiverPrivateKey: PrivateKey,
        receiverPublicKeyRaw32: ByteArray,
        info: ByteArray,
        suiteWireId: UShort
    ): OpenResult {
        // Pro release uses HPKE version 2 when nonce/tag are empty.
        require(sealedBox.version == 2) { "Unsupported sealedBox version: ${sealedBox.version}" }
        require(sealedBox.nonce.isEmpty() && sealedBox.tag.isEmpty()) { "Expected HPKE v2 (nonce/tag empty)" }
        require(sealedBox.encapsulatedKey.size == 32) { "Expected X25519 enc size 32" }

        val encPub = publicKeyFromRaw32(sealedBox.encapsulatedKey)
        require(receiverPublicKeyRaw32.size == 32) { "receiverPublicKeyRaw32 must be 32 bytes" }
        val dh = x25519Dh(receiverPrivateKey, encPub)

        // DHKEM kem_context = enc || pkR
        val kemContext = concat(sealedBox.encapsulatedKey, receiverPublicKeyRaw32)

        val sharedSecret = dhkemExtractAndExpand(dh, kemContext)
        val keySchedule = keySchedule(sharedSecret, info)

        val pt = aeadOpen(keySchedule.key, keySchedule.baseNonce, info, sealedBox.ciphertext)

        val exporterContext = buildExporterContext(suiteWireId, info)
        val exported = exportSecret(keySchedule.exporterSecret, exporterContext, 32)

        return OpenResult(plaintext = pt, exportedSecret32 = exported)
    }

    /**
     * Seal (encrypt) a handshake payload to the receiver's X25519 public key, producing HPKESealedBox v2
     * compatible with Pro release (nonce/tag are empty; ciphertext contains ct||tag).
     */
    fun sealAndExport(
        plaintext: ByteArray,
        receiverPublicKeyRaw32: ByteArray,
        info: ByteArray,
        suiteWireId: UShort
    ): SealResult {
        require(receiverPublicKeyRaw32.size == 32) { "receiverPublicKeyRaw32 must be 32 bytes" }

        val epk = generateX25519KeyPair()
        val encRaw32 = rawPublicKey32(epk.public)
        val receiverPub = publicKeyFromRaw32(receiverPublicKeyRaw32)

        val dh = x25519Dh(epk.private, receiverPub)
        // DHKEM kem_context = enc || pkR
        val kemContext = concat(encRaw32, receiverPublicKeyRaw32)

        val sharedSecret = dhkemExtractAndExpand(dh, kemContext)
        val keySchedule = keySchedule(sharedSecret, info)

        val ctWithTag = aeadSeal(keySchedule.key, keySchedule.baseNonce, info, plaintext)

        val exporterContext = buildExporterContext(suiteWireId, info)
        val exported = exportSecret(keySchedule.exporterSecret, exporterContext, 32)

        val sealed = P2PHPKESealedBox(
            version = 2,
            suiteWireId = suiteWireId,
            encapsulatedKey = encRaw32,
            nonce = ByteArray(0),
            ciphertext = ctWithTag,
            tag = ByteArray(0)
        )
        return SealResult(sealedBox = sealed, exportedSecret32 = exported)
    }

    private data class KeyScheduleOut(
        val key: ByteArray,
        val baseNonce: ByteArray,
        val exporterSecret: ByteArray
    )

    private fun buildExporterContext(suiteWireId: UShort, info: ByteArray): ByteArray {
        val suiteIdLe = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(suiteWireId.toShort()).array()
        return concat(EXPORTER_CONTEXT_PREFIX.toByteArray(Charsets.UTF_8), suiteIdLe, info)
    }

    private fun x25519Dh(priv: PrivateKey, pub: PublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("X25519")
        ka.init(priv)
        ka.doPhase(pub, true)
        return ka.generateSecret()
    }

    private fun dhkemExtractAndExpand(dh: ByteArray, kemContext: ByteArray): ByteArray {
        val eaePrk = labeledExtract(KEM_SUITE_ID, salt = ByteArray(0), label = "eae_prk", ikm = dh)
        return labeledExpand(KEM_SUITE_ID, eaePrk, label = "shared_secret", info = kemContext, outLen = 32)
    }

    private fun keySchedule(sharedSecret: ByteArray, info: ByteArray): KeyScheduleOut {
        val pskIdHash = labeledExtract(SUITE_ID, salt = ByteArray(0), label = "psk_id_hash", ikm = ByteArray(0))
        val infoHash = labeledExtract(SUITE_ID, salt = ByteArray(0), label = "info_hash", ikm = info)
        val ksContext = concat(byteArrayOf(0x00), pskIdHash, infoHash)

        val secret = labeledExtract(SUITE_ID, salt = sharedSecret, label = "secret", ikm = ByteArray(0))
        val key = labeledExpand(SUITE_ID, secret, label = "key", info = ksContext, outLen = 32)
        val baseNonce = labeledExpand(SUITE_ID, secret, label = "base_nonce", info = ksContext, outLen = 12)
        val exporterSecret = labeledExpand(SUITE_ID, secret, label = "exp", info = ksContext, outLen = 32)
        return KeyScheduleOut(key, baseNonce, exporterSecret)
    }

    private fun exportSecret(exporterSecret: ByteArray, exporterContext: ByteArray, outLen: Int): ByteArray =
        labeledExpand(SUITE_ID, exporterSecret, label = "sec", info = exporterContext, outLen = outLen)

    private fun aeadOpen(key: ByteArray, nonce: ByteArray, aad: ByteArray, ciphertextWithTag: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        val sk = SecretKeySpec(key, "ChaCha20")
        cipher.init(Cipher.DECRYPT_MODE, sk, IvParameterSpec(nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextWithTag)
    }

    private fun aeadSeal(key: ByteArray, nonce: ByteArray, aad: ByteArray, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        val sk = SecretKeySpec(key, "ChaCha20")
        cipher.init(Cipher.ENCRYPT_MODE, sk, IvParameterSpec(nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext) // returns ct||tag
    }

    // HKDF / labeled helpers (RFC 9180)
    private fun labeledExtract(suiteId: ByteArray, salt: ByteArray, label: String, ikm: ByteArray): ByteArray {
        val labeledIkm = concat("HPKE-v1".toByteArray(Charsets.UTF_8), suiteId, label.toByteArray(Charsets.UTF_8), ikm)
        return hkdfExtract(salt, labeledIkm)
    }

    private fun labeledExpand(suiteId: ByteArray, prk: ByteArray, label: String, info: ByteArray, outLen: Int): ByteArray {
        val lenBytes = ByteBuffer.allocate(2).order(ByteOrder.BIG_ENDIAN).putShort(outLen.toShort()).array()
        val labeledInfo = concat(lenBytes, "HPKE-v1".toByteArray(Charsets.UTF_8), suiteId, label.toByteArray(Charsets.UTF_8), info)
        return hkdfExpand(prk, labeledInfo, outLen)
    }

    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val s = if (salt.isEmpty()) ByteArray(32) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(s, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, outLen: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        var t = ByteArray(0)
        var okm = ByteArray(0)
        var counter: Byte = 1
        while (okm.size < outLen) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(counter)
            t = mac.doFinal()
            okm = concat(okm, t)
            counter = (counter + 1).toByte()
        }
        return okm.copyOfRange(0, outLen)
    }

    private fun buildSuiteId(): ByteArray {
        val bb = ByteBuffer.allocate(4 + 2 + 2 + 2).order(ByteOrder.BIG_ENDIAN)
        bb.put("HPKE".toByteArray(Charsets.UTF_8))
        bb.putShort(KEM_ID.toShort())
        bb.putShort(KDF_ID.toShort())
        bb.putShort(AEAD_ID.toShort())
        return bb.array()
    }

    private fun buildKemSuiteId(): ByteArray {
        val bb = ByteBuffer.allocate(3 + 2).order(ByteOrder.BIG_ENDIAN)
        bb.put("KEM".toByteArray(Charsets.UTF_8))
        bb.putShort(KEM_ID.toShort())
        return bb.array()
    }

    private fun concat(vararg parts: ByteArray): ByteArray {
        val total = parts.sumOf { it.size }
        val out = ByteArray(total)
        var off = 0
        for (p in parts) {
            System.arraycopy(p, 0, out, off, p.size)
            off += p.size
        }
        return out
    }

    private fun providerAlreadyIncluded(
        providers: List<java.security.Provider>,
        candidate: java.security.Provider
    ): Boolean = providers.any { existing ->
        existing.name == candidate.name &&
            existing::class.java.name == candidate::class.java.name
    }
}
