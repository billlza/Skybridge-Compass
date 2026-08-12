package com.skybridge.compass.shared.crypto

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Manages cryptographic key storage for SkyBridge.
 * 
 * Classic keys (P-256/Ed25519) are stored in Android Keystore with TEE/StrongBox backing.
 * PQC keys are encrypted with AES-256-GCM using a wrapping key from Android Keystore
 * and stored in SharedPreferences.
 * 
 * @param context Android application context
 */
class SkyBridgeKeyManager(private val context: Context) {
    
    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val DEVICE_IDENTITY_ALIAS = "skybridge_device_identity"
        private const val PQC_WRAPPING_KEY_ALIAS = "skybridge_pqc_wrapping_key"
        private const val PREFS_NAME = "skybridge_pqc_keys"
        
        // Key suffixes for SharedPreferences
        private const val SUFFIX_PUBLIC = "_pub"
        private const val SUFFIX_PRIVATE_ENC = "_priv_enc"
        private const val SUFFIX_IV = "_iv"
        private const val SUFFIX_SUITE = "_suite"
        private const val SUFFIX_USAGE = "_usage"
        
        // AES-GCM parameters
        private const val GCM_TAG_LENGTH = 128
        private const val GCM_IV_LENGTH = 12

        internal fun requireExistingSecretKeyEntry(keyStore: KeyStore, alias: String): SecretKey {
            val aliasPresent = keyStore.containsAlias(alias)
            val entry = if (aliasPresent) keyStore.getEntry(alias, null) else null
            return requireExistingSecretKeyEntry(alias, aliasPresent, entry)
        }

        internal fun requireExistingSecretKeyEntry(
            alias: String,
            aliasPresent: Boolean,
            entry: KeyStore.Entry?
        ): SecretKey {
            if (!aliasPresent) {
                throw KeyStorageException(
                    alias = alias,
                    message = "Existing PQC wrapping key is missing"
                )
            }
            if (entry is KeyStore.SecretKeyEntry) {
                return entry.secretKey
            }
            throw KeyStorageException(
                alias = alias,
                message = "Existing PQC wrapping key has the wrong entry type"
            )
        }
    }
    
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { 
        load(null) 
    }
    
    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    
    /**
     * Generates a device identity key pair using secp256r1 (P-256) curve.
     * 
     * The key is stored in Android Keystore with TEE/StrongBox backing when available.
     * On Android P+ (API 28+), StrongBox is preferred if available.
     * 
     * @return The generated key pair from Android Keystore
     * @throws KeyStorageException if key generation fails
     * 
     * _Requirements: 7.1, 7.3, 7.4_
     */
    fun generateDeviceIdentityKey(): java.security.KeyPair {
        try {
            // Check if key already exists
            if (keyStore.containsAlias(DEVICE_IDENTITY_ALIAS)) {
                val entry = keyStore.getEntry(DEVICE_IDENTITY_ALIAS, null)
                if (entry is KeyStore.PrivateKeyEntry) {
                    return java.security.KeyPair(entry.certificate.publicKey, entry.privateKey)
                }
            }
            
            val preferStrongBox = PlatformCompat.hasStrongBox
            return runCatching {
                generateDeviceIdentityKey(preferStrongBox = preferStrongBox)
            }.recoverCatching { error ->
                if (!preferStrongBox) throw error
                generateDeviceIdentityKey(preferStrongBox = false)
            }.getOrThrow()
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = DEVICE_IDENTITY_ALIAS,
                message = "Failed to generate device identity key: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Retrieves the existing device identity key pair.
     * 
     * @return The device identity key pair, or null if not generated yet
     * @throws KeyStorageException if retrieval fails
     */
    fun getDeviceIdentityKey(): java.security.KeyPair? {
        try {
            if (!keyStore.containsAlias(DEVICE_IDENTITY_ALIAS)) {
                return null
            }
            
            val entry = keyStore.getEntry(DEVICE_IDENTITY_ALIAS, null)
            if (entry is KeyStore.PrivateKeyEntry) {
                return java.security.KeyPair(entry.certificate.publicKey, entry.privateKey)
            }
            return null
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = DEVICE_IDENTITY_ALIAS,
                message = "Failed to retrieve device identity key: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Checks if a device identity key exists.
     * 
     * @return true if the device identity key exists
     */
    fun hasDeviceIdentityKey(): Boolean {
        return try {
            keyStore.containsAlias(DEVICE_IDENTITY_ALIAS)
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * Deletes the device identity key.
     * 
     * @throws KeyStorageException if deletion fails
     */
    fun deleteDeviceIdentityKey() {
        try {
            if (keyStore.containsAlias(DEVICE_IDENTITY_ALIAS)) {
                keyStore.deleteEntry(DEVICE_IDENTITY_ALIAS)
            }
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = DEVICE_IDENTITY_ALIAS,
                message = "Failed to delete device identity key: ${e.message}",
                cause = e
            )
        }
    }

    
    /**
     * Gets or creates the AES-256-GCM wrapping key for PQC key encryption.
     * 
     * The wrapping key is stored in Android Keystore with TEE backing.
     * 
     * @return The AES-256 wrapping key
     * @throws KeyStorageException if key creation fails
     * 
     * _Requirements: 7.2_
     */
    private fun getOrCreateWrappingKey(): SecretKey {
        try {
            // Check if wrapping key already exists
            if (keyStore.containsAlias(PQC_WRAPPING_KEY_ALIAS)) {
                val entry = keyStore.getEntry(PQC_WRAPPING_KEY_ALIAS, null)
                if (entry is KeyStore.SecretKeyEntry) {
                    return entry.secretKey
                }
            }
            
            val preferStrongBox = PlatformCompat.hasStrongBox
            return runCatching {
                generateWrappingKey(preferStrongBox = preferStrongBox)
            }.recoverCatching { error ->
                if (!preferStrongBox) throw error
                generateWrappingKey(preferStrongBox = false)
            }.getOrThrow()
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = PQC_WRAPPING_KEY_ALIAS,
                message = "Failed to get or create wrapping key: ${e.message}",
                cause = e
            )
        }
    }

    private fun getExistingWrappingKey(): SecretKey {
        try {
            return requireExistingSecretKeyEntry(keyStore, PQC_WRAPPING_KEY_ALIAS)
        } catch (e: KeyStorageException) {
            throw e
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = PQC_WRAPPING_KEY_ALIAS,
                message = "Failed to retrieve existing PQC wrapping key: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Stores a PQC key pair encrypted with AES-256-GCM.
     * 
     * The private key is encrypted using a wrapping key from Android Keystore.
     * Both keys are stored in SharedPreferences with Base64 encoding.
     * 
     * @param keyPair The PQC key pair to store
     * @param alias Unique identifier for this key pair
     * @throws KeyStorageException if storage fails
     * 
     * _Requirements: 7.2, 7.5_
     */
    fun storePQCKeyPair(keyPair: KeyPair, alias: String) {
        try {
            val wrappingKey = getOrCreateWrappingKey()
            
            // Encrypt private key with AES-GCM
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
            
            val encryptedPrivate = cipher.doFinal(keyPair.privateKey.bytes)
            val iv = cipher.iv
            
            // Store all components in SharedPreferences
            prefs.edit().apply {
                putString(
                    alias + SUFFIX_PUBLIC, 
                    Base64.encodeToString(keyPair.publicKey.bytes, Base64.NO_WRAP)
                )
                putString(
                    alias + SUFFIX_PRIVATE_ENC, 
                    Base64.encodeToString(encryptedPrivate, Base64.NO_WRAP)
                )
                putString(
                    alias + SUFFIX_IV, 
                    Base64.encodeToString(iv, Base64.NO_WRAP)
                )
                putInt(alias + SUFFIX_SUITE, keyPair.suite.wireId.toInt())
                putString(alias + SUFFIX_USAGE, keyPair.usage.name)
                apply()
            }
        } catch (e: KeyStorageException) {
            throw e
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = alias,
                message = "Failed to store PQC key pair: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Retrieves a PQC key pair from encrypted storage.
     * 
     * @param alias The unique identifier for the key pair
     * @return The decrypted key pair, or null if not found
     * @throws KeyStorageException if retrieval or decryption fails
     * 
     * _Requirements: 7.2, 7.5_
     */
    fun retrievePQCKeyPair(alias: String): KeyPair? {
        return retrievePQCKeyPair(alias, allowWrappingKeyCreation = true)
    }

    /**
     * Retrieves an existing PQC key pair without creating any Android Keystore material.
     *
     * This is the only retrieval API permitted in formal read-only diagnostics. If encrypted
     * key records exist but their wrapping key is absent or invalid, retrieval fails closed.
     */
    fun retrieveExistingPQCKeyPair(alias: String): KeyPair? {
        return retrievePQCKeyPair(alias, allowWrappingKeyCreation = false)
    }

    private fun retrievePQCKeyPair(alias: String, allowWrappingKeyCreation: Boolean): KeyPair? {
        try {
            // Check if key exists
            val publicKeyB64 = prefs.getString(alias + SUFFIX_PUBLIC, null) ?: return null
            val encryptedPrivateB64 = prefs.getString(alias + SUFFIX_PRIVATE_ENC, null) ?: return null
            val ivB64 = prefs.getString(alias + SUFFIX_IV, null) ?: return null
            val suiteWireId = prefs.getInt(alias + SUFFIX_SUITE, -1)
            val usageName = prefs.getString(alias + SUFFIX_USAGE, null) ?: return null
            
            if (suiteWireId == -1) return null
            
            // Decode Base64
            val publicKeyBytes = Base64.decode(publicKeyB64, Base64.NO_WRAP)
            val encryptedPrivate = Base64.decode(encryptedPrivateB64, Base64.NO_WRAP)
            val iv = Base64.decode(ivB64, Base64.NO_WRAP)
            
            // Get wrapping key and decrypt private key
            val wrappingKey = if (allowWrappingKeyCreation) {
                getOrCreateWrappingKey()
            } else {
                getExistingWrappingKey()
            }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey, GCMParameterSpec(GCM_TAG_LENGTH, iv))
            
            val privateKeyBytes = cipher.doFinal(encryptedPrivate)
            
            // Reconstruct key pair
            val suite = CryptoSuite.fromWireId(suiteWireId.toUShort())
                ?: throw KeyStorageException(alias, "Unknown suite wireId: $suiteWireId")
            val usage = KeyUsage.valueOf(usageName)
            
            return KeyPair(
                publicKey = KeyMaterial(suite, usage, publicKeyBytes),
                privateKey = KeyMaterial(suite, usage, privateKeyBytes)
            )
        } catch (e: KeyStorageException) {
            throw e
        } catch (e: Exception) {
            throw KeyStorageException(
                alias = alias,
                message = "Failed to retrieve PQC key pair: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Checks if a PQC key pair exists for the given alias.
     * 
     * @param alias The unique identifier for the key pair
     * @return true if the key pair exists
     */
    fun hasPQCKeyPair(alias: String): Boolean {
        return prefs.contains(alias + SUFFIX_PUBLIC) &&
               prefs.contains(alias + SUFFIX_PRIVATE_ENC) &&
               prefs.contains(alias + SUFFIX_IV)
    }
    
    /**
     * Deletes a PQC key pair from storage.
     * 
     * @param alias The unique identifier for the key pair
     */
    fun deletePQCKeyPair(alias: String) {
        prefs.edit().apply {
            remove(alias + SUFFIX_PUBLIC)
            remove(alias + SUFFIX_PRIVATE_ENC)
            remove(alias + SUFFIX_IV)
            remove(alias + SUFFIX_SUITE)
            remove(alias + SUFFIX_USAGE)
            apply()
        }
    }
    
    /**
     * Lists all stored PQC key pair aliases.
     * 
     * @return List of aliases for stored PQC key pairs
     */
    fun listPQCKeyAliases(): List<String> {
        return prefs.all.keys
            .filter { it.endsWith(SUFFIX_PUBLIC) }
            .map { it.removeSuffix(SUFFIX_PUBLIC) }
    }
    
    /**
     * Clears all stored PQC keys and the wrapping key.
     * Use with caution - this is irreversible.
     */
    fun clearAllKeys() {
        // Clear SharedPreferences
        prefs.edit().clear().apply()
        
        // Delete wrapping key from Keystore
        try {
            if (keyStore.containsAlias(PQC_WRAPPING_KEY_ALIAS)) {
                keyStore.deleteEntry(PQC_WRAPPING_KEY_ALIAS)
            }
        } catch (e: Exception) {
            // Ignore errors during cleanup
        }
        
        // Delete device identity key
        try {
            if (keyStore.containsAlias(DEVICE_IDENTITY_ALIAS)) {
                keyStore.deleteEntry(DEVICE_IDENTITY_ALIAS)
            }
        } catch (e: Exception) {
            // Ignore errors during cleanup
        }
    }

    private fun generateDeviceIdentityKey(preferStrongBox: Boolean): java.security.KeyPair {
        val specBuilder = KeyGenParameterSpec.Builder(
            DEVICE_IDENTITY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        ).apply {
            setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
            setUserAuthenticationRequired(false)

            if (preferStrongBox) {
                setIsStrongBoxBacked(true)
            }
        }

        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            ANDROID_KEYSTORE
        )
        keyPairGenerator.initialize(specBuilder.build())
        return keyPairGenerator.generateKeyPair()
    }

    private fun generateWrappingKey(preferStrongBox: Boolean): SecretKey {
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE
        )

        val specBuilder = KeyGenParameterSpec.Builder(
            PQC_WRAPPING_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        ).apply {
            setKeySize(256)
            setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            setUserAuthenticationRequired(false)

            if (preferStrongBox) {
                setIsStrongBoxBacked(true)
            }
        }

        keyGenerator.init(specBuilder.build())
        return keyGenerator.generateKey()
    }
}
