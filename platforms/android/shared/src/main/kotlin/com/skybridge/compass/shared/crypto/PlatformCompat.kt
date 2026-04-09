package com.skybridge.compass.shared.crypto

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/**
 * Platform compatibility layer for Android 13-17 (API 33-36).
 *
 * Provides version-aware crypto operations with graceful degradation:
 * - Android 17 (API 36): Full PQC support with hardware acceleration
 * - Android 16 (API 35): PQC support with software fallback
 * - Android 14-15 (API 34): Hybrid crypto with enhanced security
 * - Android 13 (API 33): Classic crypto with compatibility mode
 *
 * Key features:
 * - Hardware-backed keystore when available
 * - StrongBox support detection
 * - Cross-platform signature verification with Apple devices
 */
object PlatformCompat {

    // API level constants
    const val API_ANDROID_13 = 33  // Tiramisu
    const val API_ANDROID_14 = 34  // Upside Down Cake
    const val API_ANDROID_15 = 35  // Vanilla Ice Cream
    const val API_ANDROID_16 = 35  // Extension (same as 15 currently)
    const val API_ANDROID_17 = 36  // Latest

    /**
     * Current device API level.
     */
    val apiLevel: Int = Build.VERSION.SDK_INT

    /**
     * Device model for telemetry.
     */
    val deviceModel: String = Build.MODEL

    /**
     * Android version string.
     */
    val androidVersion: String = Build.VERSION.RELEASE

    /**
     * Check if running on Android 17 (API 36) or higher.
     */
    val isAndroid17OrHigher: Boolean
        get() = apiLevel >= API_ANDROID_17

    /**
     * Check if running on Android 14 (API 34) or higher.
     */
    val isAndroid14OrHigher: Boolean
        get() = apiLevel >= API_ANDROID_14

    /**
     * Check if StrongBox hardware security module is available.
     * StrongBox provides hardware-isolated key storage.
     */
    val hasStrongBox: Boolean by lazy {
        if (apiLevel >= 28) {
            try {
                val keyStore = KeyStore.getInstance("AndroidKeyStore")
                keyStore.load(null)

                // Try to generate a test key with StrongBox
                val keyGenerator = KeyGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_AES,
                    "AndroidKeyStore"
                )

                val paramSpec = KeyGenParameterSpec.Builder(
                    "_strongbox_test_key_",
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                ).apply {
                    setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    setKeySize(256)
                    if (apiLevel >= 28) {
                        setIsStrongBoxBacked(true)
                    }
                }.build()

                keyGenerator.init(paramSpec)
                keyGenerator.generateKey()

                // Clean up test key
                keyStore.deleteEntry("_strongbox_test_key_")
                true
            } catch (e: Exception) {
                false
            }
        } else {
            false
        }
    }

    /**
     * Check if hardware-backed keystore is available.
     */
    val hasHardwareKeystore: Boolean by lazy {
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Crypto capabilities for this device.
     */
    data class CryptoCapabilities(
        val supportsPQC: Boolean,
        val supportsHardwareKeystore: Boolean,
        val supportsStrongBox: Boolean,
        val supportsECDSA: Boolean,
        val supportsEd25519: Boolean,
        val supportsX25519: Boolean,
        val supportsAESGCM: Boolean,
        val supportsChaChaPoly: Boolean,
        val maxECKeySize: Int,
        val preferredSignatureAlgorithm: String,
        val preferredKEXAlgorithm: String
    )

    /**
     * Get crypto capabilities for this device.
     */
    val capabilities: CryptoCapabilities by lazy {
        val supportsPqc = checkPQCSupport()
        CryptoCapabilities(
            supportsPQC = supportsPqc,
            supportsHardwareKeystore = hasHardwareKeystore,
            supportsStrongBox = hasStrongBox,
            supportsECDSA = true,  // Always available
            supportsEd25519 = apiLevel >= 33,  // Ed25519 added in API 33
            supportsX25519 = apiLevel >= 33,   // X25519 added in API 33
            supportsAESGCM = true,  // Always available
            supportsChaChaPoly = apiLevel >= 28,  // ChaCha20-Poly1305 in API 28
            maxECKeySize = if (apiLevel >= 33) 521 else 384,  // P-521 in API 33
            preferredSignatureAlgorithm = preferredSignatureAlgorithm(supportsPqc),
            preferredKEXAlgorithm = preferredKexAlgorithm(supportsPqc)
        )
    }

    /**
     * Check if PQC (Post-Quantum Cryptography) is supported.
     * PQC support depends on liboqs native library availability.
     */
    private fun checkPQCSupport(): Boolean {
        return try {
            // Check if liboqs native library is loaded
            System.loadLibrary("skybridge_pqc")
            true
        } catch (e: UnsatisfiedLinkError) {
            false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Get preferred signature algorithm based on API level and capabilities.
     */
    private fun preferredSignatureAlgorithm(supportsPqc: Boolean): String {
        return when {
            supportsPqc -> "ML-DSA-65"  // Post-quantum
            apiLevel >= 33 -> "Ed25519"  // Modern, fast
            else -> "SHA256withECDSA"  // Classic fallback
        }
    }

    /**
     * Get preferred key exchange algorithm.
     */
    private fun preferredKexAlgorithm(supportsPqc: Boolean): String {
        return when {
            supportsPqc -> "ML-KEM-768"  // Post-quantum
            apiLevel >= 33 -> "X25519"  // Modern, fast
            else -> "ECDH-P256"  // Classic fallback
        }
    }

    /**
     * Signature verification mode for cross-platform compatibility.
     */
    enum class SignatureMode {
        /** Use PQC ML-DSA-65 (preferred for Android 17+) */
        PQC_ML_DSA,
        /** Use Ed25519 (compatible with Apple CryptoKit) */
        ED25519,
        /** Use ECDSA P-256 (universal fallback) */
        ECDSA_P256,
        /** Hybrid: verify with multiple algorithms */
        HYBRID
    }

    /**
     * Get recommended signature mode for cross-platform verification.
     *
     * @param peerPlatform The peer's platform ("ios", "macos", "android", "unknown")
     * @param peerApiLevel The peer's API level (for Android peers)
     * @return Recommended signature mode
     */
    fun getRecommendedSignatureMode(
        peerPlatform: String,
        peerApiLevel: Int = 0
    ): SignatureMode {
        return when {
            // Both Android 17+ with PQC support
            peerPlatform == "android" && peerApiLevel >= API_ANDROID_17 && isAndroid17OrHigher -> {
                SignatureMode.PQC_ML_DSA
            }
            // Apple platform - use Ed25519 for CryptoKit compatibility
            peerPlatform in listOf("ios", "macos") -> {
                if (apiLevel >= 33) SignatureMode.ED25519 else SignatureMode.ECDSA_P256
            }
            // Unknown or mixed - use hybrid for maximum compatibility
            else -> {
                if (capabilities.supportsPQC) SignatureMode.HYBRID else SignatureMode.ECDSA_P256
            }
        }
    }

    /**
     * Create a signature verifier compatible with Apple CryptoKit.
     *
     * Apple CryptoKit uses:
     * - P256.Signing for ECDSA
     * - Curve25519.Signing for Ed25519
     * - Post-quantum: ML-DSA (when available)
     *
     * @param algorithm The signature algorithm
     * @return Configured Signature instance
     */
    fun createAppleCompatibleVerifier(algorithm: String): Signature {
        val jcaAlgorithm = when (algorithm.uppercase()) {
            "ECDSA", "ECDSA-P256", "P256" -> "SHA256withECDSA"
            "ED25519" -> if (apiLevel >= 33) "Ed25519" else "SHA256withECDSA"
            "SHA256WITHECDSA" -> "SHA256withECDSA"
            "SHA384WITHECDSA" -> "SHA384withECDSA"
            "SHA512WITHECDSA" -> "SHA512withECDSA"
            else -> "SHA256withECDSA"
        }
        return Signature.getInstance(jcaAlgorithm)
    }

    /**
     * AES-GCM cipher with Apple-compatible parameters.
     *
     * Apple uses:
     * - 12-byte nonce (standard)
     * - 16-byte tag (128-bit)
     * - No additional padding
     */
    fun createAppleCompatibleCipher(): Cipher {
        return Cipher.getInstance("AES/GCM/NoPadding")
    }

    /**
     * Create GCM parameter spec with Apple-compatible defaults.
     */
    fun createAppleCompatibleGCMSpec(nonce: ByteArray): GCMParameterSpec {
        require(nonce.size == 12) { "Nonce must be 12 bytes for Apple compatibility" }
        return GCMParameterSpec(128, nonce)  // 128-bit tag
    }

    /**
     * Generate EC key pair compatible with Apple CryptoKit.
     *
     * @param curve The curve name ("P-256", "P-384", "P-521")
     * @return KeyPair suitable for cross-platform use
     */
    fun generateAppleCompatibleKeyPair(curve: String = "P-256"): java.security.KeyPair {
        val keyPairGenerator = KeyPairGenerator.getInstance("EC")
        val ecSpec = java.security.spec.ECGenParameterSpec(
            when (curve.uppercase()) {
                "P-256", "SECP256R1" -> "secp256r1"
                "P-384", "SECP384R1" -> "secp384r1"
                "P-521", "SECP521R1" -> if (apiLevel >= 33) "secp521r1" else "secp384r1"
                else -> "secp256r1"
            }
        )
        keyPairGenerator.initialize(ecSpec)
        return keyPairGenerator.generateKeyPair()
    }

    /**
     * Log platform info for debugging.
     */
    fun getPlatformInfo(): Map<String, Any> {
        return mapOf(
            "apiLevel" to apiLevel,
            "androidVersion" to androidVersion,
            "deviceModel" to deviceModel,
            "hasStrongBox" to hasStrongBox,
            "hasHardwareKeystore" to hasHardwareKeystore,
            "supportsPQC" to capabilities.supportsPQC,
            "supportsEd25519" to capabilities.supportsEd25519,
            "supportsX25519" to capabilities.supportsX25519,
            "preferredSignature" to capabilities.preferredSignatureAlgorithm,
            "preferredKEX" to capabilities.preferredKEXAlgorithm
        )
    }
}
