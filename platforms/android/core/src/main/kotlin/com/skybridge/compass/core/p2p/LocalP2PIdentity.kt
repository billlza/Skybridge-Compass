@file:Suppress("DEPRECATION")

package com.skybridge.compass.core.p2p

import android.content.Context
import android.os.Build
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.SkyBridgeKeyManager
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Local device identity for Pro-release compatible LAN discovery + handshake.
 *
 * - `deviceId`: stable UUID stored in encrypted prefs
 * - `pubKeyFP`: SHA-256(hex, lowercase) of uncompressed P-256 public key (0x04||X||Y)
 * - Protocol signing keys:
 *   - Ed25519 for classic suite signatures
 *   - ML-DSA-65 for PQC/hybrid suite signatures (when liboqs is available)
 * - KEM identity keys:
 *   - ML-KEM-768 identity key pair (public 1184, private 2400)
 *   - X-Wing identity key pair (public 1216, private 2432) when available
 */
@Singleton
class LocalP2PIdentity @Inject constructor(
    @param:ApplicationContext private val appContext: Context
) {
    private val storageContext by lazy { appContext.createDeviceProtectedStorageContext() }
    private val prefs by lazy { encryptedPrefs(storageContext) }
    private val keyManager by lazy { SkyBridgeKeyManager(storageContext) }
    @Volatile private var inMemoryEd25519PrivateKey: PrivateKey? = null
    @Volatile private var inMemoryEd25519PublicRaw32: ByteArray? = null

    fun deviceName(): String = Build.MODEL.ifBlank { "Android" }

    fun deviceId(): String {
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) return existing
        val created = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_DEVICE_ID, created).apply()
        return created
    }

    /**
     * Compute (or load) the discovery fingerprint `pubKeyFP`.
     *
     * Matches macOS/iOS Pro release: SHA-256 over P-256 public key rawRepresentation (X9.63).
     */
    fun pubKeyFingerprint(): String {
        val cached = prefs.getString(KEY_PUBKEY_FP, null)
        if (!cached.isNullOrBlank()) return cached

        val kp = keyManager.getDeviceIdentityKey() ?: keyManager.generateDeviceIdentityKey()
        val pub = kp.public as? ECPublicKey
            ?: return ""
        val raw = uncompressedP256Point(pub)
        val fp = sha256HexLower(raw)
        prefs.edit().putString(KEY_PUBKEY_FP, fp).apply()
        return fp
    }

    data class ProtocolSigningKeys(
        val ed25519PrivateKey: PrivateKey,
        val ed25519PublicRaw32: ByteArray,
        val mlDsa65PrivateKeyRaw: ByteArray?,
        val mlDsa65PublicKeyRaw: ByteArray?
    )

    fun getOrCreateProtocolSigningKeys(): ProtocolSigningKeys {
        val edPrivPkcs8B64 = prefs.getString(KEY_ED25519_PRIV_PKCS8_B64, null)
        val edPubB64 = prefs.getString(KEY_ED25519_PUB_RAW32_B64, null)
        val (edPriv, edPubRaw) = when {
            !edPrivPkcs8B64.isNullOrBlank() && !edPubB64.isNullOrBlank() -> {
                val privBytes = Base64.decode(edPrivPkcs8B64, Base64.NO_WRAP)
                val pubBytes = Base64.decode(edPubB64, Base64.NO_WRAP)
                val priv = P2PHandshakeWire.decodeEd25519PrivateKey(privBytes)
                priv to pubBytes
            }

            inMemoryEd25519PrivateKey != null && inMemoryEd25519PublicRaw32 != null -> {
                requireNotNull(inMemoryEd25519PrivateKey) to requireNotNull(inMemoryEd25519PublicRaw32)
            }

            else -> {
            val (priv, pubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
                val privBytes = priv.encoded
                if (privBytes != null) {
                    prefs.edit()
                        .putString(KEY_ED25519_PRIV_PKCS8_B64, Base64.encodeToString(privBytes, Base64.NO_WRAP))
                        .putString(KEY_ED25519_PUB_RAW32_B64, Base64.encodeToString(pubRaw32, Base64.NO_WRAP))
                        .apply()
                } else {
                    inMemoryEd25519PrivateKey = priv
                    inMemoryEd25519PublicRaw32 = pubRaw32
                }
                priv to pubRaw32
            }
        }

        val (mlPriv, mlPub) = if (smokeClassicOnly()) {
            null to null
        } else {
            val mlPrivB64 = prefs.getString(KEY_MLDSA65_PRIV_RAW_B64, null)
            val mlPubB64 = prefs.getString(KEY_MLDSA65_PUB_RAW_B64, null)
            if (!mlPrivB64.isNullOrBlank() && !mlPubB64.isNullOrBlank()) {
                Base64.decode(mlPrivB64, Base64.NO_WRAP) to Base64.decode(mlPubB64, Base64.NO_WRAP)
            } else if (AndroidPQCCryptoProvider.isAvailable()) {
                val provider = AndroidPQCCryptoProvider()
                val kp = kotlinx.coroutines.runBlocking { provider.generateKeyPair(KeyUsage.SIGNING) }
                val privRaw = kp.privateKey.bytes
                val pubRaw = kp.publicKey.bytes
                prefs.edit()
                    .putString(KEY_MLDSA65_PRIV_RAW_B64, Base64.encodeToString(privRaw, Base64.NO_WRAP))
                    .putString(KEY_MLDSA65_PUB_RAW_B64, Base64.encodeToString(pubRaw, Base64.NO_WRAP))
                    .apply()
                privRaw to pubRaw
            } else {
                null to null
            }
        }

        return ProtocolSigningKeys(
            ed25519PrivateKey = edPriv,
            ed25519PublicRaw32 = edPubRaw,
            mlDsa65PrivateKeyRaw = mlPriv,
            mlDsa65PublicKeyRaw = mlPub
        )
    }

    data class KemIdentityKeys(
        val mlKem768PublicKey: ByteArray?,
        val mlKem768PrivateKey: ByteArray?,
        val xWingPublicKey: ByteArray?,
        val xWingPrivateKey: ByteArray?
    )

    fun getOrCreateKemIdentityKeys(): KemIdentityKeys {
        if (smokeClassicOnly()) {
            return KemIdentityKeys(
                mlKem768PublicKey = null,
                mlKem768PrivateKey = null,
                xWingPublicKey = null,
                xWingPrivateKey = null
            )
        }
        val mlKem = getOrCreateKemKeyPair(alias = ALIAS_KEM_MLKEM768, suite = CryptoSuite.ML_KEM_768_ML_DSA_65) {
            val provider = AndroidPQCCryptoProvider()
            kotlinx.coroutines.runBlocking { provider.generateKeyPair(KeyUsage.KEY_EXCHANGE) }
        }

        val xWing = if (P2PXWingKem.isAvailable()) {
            getOrCreateKemKeyPair(alias = ALIAS_KEM_XWING, suite = CryptoSuite.X_WING_ML_DSA) {
                val provider = AndroidPQCCryptoProvider()
                val material = P2PXWingKem.generateKeyPair(provider)
                KeyPair(
                    publicKey = KeyMaterial(CryptoSuite.X_WING_ML_DSA, KeyUsage.KEY_EXCHANGE, material.publicKey),
                    privateKey = KeyMaterial(CryptoSuite.X_WING_ML_DSA, KeyUsage.KEY_EXCHANGE, material.privateKey)
                )
            }
        } else {
            null
        }

        return KemIdentityKeys(
            mlKem768PublicKey = mlKem?.publicKey?.bytes,
            mlKem768PrivateKey = mlKem?.privateKey?.bytes,
            xWingPublicKey = xWing?.publicKey?.bytes,
            xWingPrivateKey = xWing?.privateKey?.bytes
        )
    }

    fun discoveryCryptoSuitesCsv(): String {
        if (smokeClassicOnly()) {
            return "1001"
        }
        val kem = getOrCreateKemIdentityKeys()
        return buildList {
            when (Build.VERSION.SDK_INT) {
                in Int.MIN_VALUE..33 -> {
                    add("1001")
                }

                in 34..35 -> {
                    if (kem.mlKem768PublicKey != null) add("0101")
                    add("1001")
                }

                else -> {
                    if (kem.xWingPublicKey != null) add("0001")
                    if (kem.mlKem768PublicKey != null) add("0101")
                    add("1001")
                }
            }
        }.joinToString(",")
    }

    private fun getOrCreateKemKeyPair(
        alias: String,
        suite: CryptoSuite,
        generator: () -> KeyPair
    ): KeyPair? {
        return try {
            keyManager.retrievePQCKeyPair(alias) ?: run {
                val kp = generator()
                keyManager.storePQCKeyPair(kp, alias)
                kp
            }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Build the local `pairingIdentityExchange` payload for macOS/iOS bootstrap.
     */
    fun buildPairingIdentityExchange(nowSwiftSeconds: Double, platform: String = "android"): AppMessage.PairingIdentityExchangePayload {
        val kem = getOrCreateKemIdentityKeys()
        val keys = ArrayList<AppMessage.KemPublicKeyInfo>(2)
        // Crypto policy by Android version (per project requirement):
        // - Android 13–15 (API 33–35): liboqs PQC only (no X-Wing key)
        // - Android 16+ (API 36+): X-Wing + PQC
        val allowPqc = Build.VERSION.SDK_INT >= 33
        val allowXWing = Build.VERSION.SDK_INT >= 36

        if (allowPqc && allowXWing && kem.xWingPublicKey != null) {
            keys += AppMessage.KemPublicKeyInfo(
                suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                publicKey = kem.xWingPublicKey
            )
        }
        if (allowPqc && kem.mlKem768PublicKey != null) {
            keys += AppMessage.KemPublicKeyInfo(
                suiteWireId = P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                publicKey = kem.mlKem768PublicKey
            )
        }
        return AppMessage.PairingIdentityExchangePayload(
            deviceId = deviceId(),
            kemPublicKeys = keys,
            deviceName = deviceName(),
            modelName = Build.MODEL,
            platform = platform,
            osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            chip = null,
            remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats(),
            sentAt = nowSwiftSeconds
        )
    }

    fun handshakeClient(peerKem: P2PHandshakeClient.PeerKemPublicKeys, policy: P2PHandshakePolicyOverride? = null): P2PHandshakeClient {
        val effectivePolicy = policy ?: defaultHandshakePolicyOverride()
        val effectiveProviderType = P2PHandshakeWire.compatibleProviderTypeRawForTier(effectivePolicy.minimumTierRaw)
        return P2PHandshakeClient(
            platformVersion = Build.VERSION.RELEASE,
            providerTypeRaw = effectivePolicy.providerTypeRaw.ifBlank { effectiveProviderType },
        )
    }

    fun defaultHandshakePolicyOverride(): P2PHandshakePolicyOverride = when {
        Build.VERSION.SDK_INT >= 36 -> capabilityAwareHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = false,
            minimumTierRaw = "nativePQC"
        )
        Build.VERSION.SDK_INT >= 33 -> capabilityAwareHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = true,
            minimumTierRaw = "liboqsPQC"
        )
        else -> capabilityAwareHandshakePolicyOverride(
            requirePqc = false,
            allowClassicFallback = true,
            minimumTierRaw = "classic"
        )
    }

    fun trustStore(): P2PHandshakeWire.TrustStore = PrefsTrustStore(prefs)

    fun trustedPeerStore(): TrustedPeerStore = TrustedPeerStore(prefs)

    fun fallbackCooldownStore(): P2PHandshakeWire.FallbackCooldownStore = PrefsFallbackCooldownStore(prefs)

    companion object {
        private const val PREFS_NAME = "skybridge_p2p_identity"

        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_PUBKEY_FP = "pub_key_fp"

        private const val KEY_ED25519_PRIV_PKCS8_B64 = "ed25519_priv_pkcs8_b64"
        private const val KEY_ED25519_PUB_RAW32_B64 = "ed25519_pub_raw32_b64"

        private const val KEY_MLDSA65_PRIV_RAW_B64 = "mldsa65_priv_raw_b64"
        private const val KEY_MLDSA65_PUB_RAW_B64 = "mldsa65_pub_raw_b64"

        private const val ALIAS_KEM_MLKEM768 = "p2p_kem_identity_mlkem768"
        private const val ALIAS_KEM_XWING = "p2p_kem_identity_xwing"

        private fun encryptedPrefs(context: Context) =
            if (System.getProperty("skybridge.smoke.classicOnly") == "1") {
                context.getSharedPreferences("${PREFS_NAME}_smoke", Context.MODE_PRIVATE)
            } else {
                EncryptedSharedPreferences.create(
                    context,
                    PREFS_NAME,
                    MasterKey.Builder(context)
                        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                        .build(),
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            }

        private fun sha256HexLower(data: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(data)
            val sb = StringBuilder(digest.size * 2)
            for (b in digest) {
                sb.append(String.format("%02x", b))
            }
            return sb.toString()
        }

        private fun uncompressedP256Point(pub: ECPublicKey): ByteArray {
            val x = pub.w.affineX
            val y = pub.w.affineY
            val xBytes = bigIntToFixed(x, 32)
            val yBytes = bigIntToFixed(y, 32)
            val out = ByteArray(1 + 32 + 32)
            out[0] = 0x04
            System.arraycopy(xBytes, 0, out, 1, 32)
            System.arraycopy(yBytes, 0, out, 33, 32)
            return out
        }

        private fun bigIntToFixed(v: BigInteger, len: Int): ByteArray {
            val raw = v.toByteArray()
            // BigInteger.toByteArray is signed; may include leading 0x00.
            val stripped = if (raw.size > 1 && raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
            if (stripped.size == len) return stripped
            val out = ByteArray(len)
            if (stripped.size > len) {
                // Truncate from left (shouldn't happen for P-256).
                System.arraycopy(stripped, stripped.size - len, out, 0, len)
            } else {
                System.arraycopy(stripped, 0, out, len - stripped.size, stripped.size)
            }
            return out
        }
    }

    private fun smokeClassicOnly(): Boolean =
        System.getProperty("skybridge.smoke.classicOnly") == "1"
}

/**
 * Persistent trust store compatible with [P2PHandshakeWire.TrustStore].
 */
internal class PrefsTrustStore(
    private val prefs: android.content.SharedPreferences
) : P2PHandshakeWire.TrustStore {
    override fun loadPeerSigningFingerprint(peerId: String): String? =
        prefs.getString("trust_fp_${peerId.sha256Key()}", null)
            ?: TrustedPeerStore(prefs)
                .findByKnownDeviceId(peerId)
                ?.protocolPublicKeyFingerprint

    override fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String) {
        val normalizedFingerprint = peerSigningFingerprint.trim().lowercase()
        prefs.edit().putString("trust_fp_${peerId.sha256Key()}", normalizedFingerprint).apply()
        TrustedPeerStore(prefs).upsertCurrentPathAuthority(
            deviceId = peerId,
            protocolPublicKeyFingerprint = normalizedFingerprint,
            aliasIds = listOf(peerId)
        )
    }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

/**
 * Persistent fallback cooldown store compatible with [P2PHandshakeWire.FallbackCooldownStore].
 */
internal class PrefsFallbackCooldownStore(
    private val prefs: android.content.SharedPreferences
) : P2PHandshakeWire.FallbackCooldownStore {
    override fun loadLastClassicFallbackAtMillis(peerId: String): Long? {
        val v = prefs.getLong("fallback_${peerId.sha256Key()}", Long.MIN_VALUE)
        return if (v == Long.MIN_VALUE) null else v
    }

    override fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long) {
        prefs.edit().putLong("fallback_${peerId.sha256Key()}", unixTimeMillis).apply()
    }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

/**
 * Optional policy override used by transport-layer bootstrap strategies.
 */
data class P2PHandshakePolicyOverride(
    val requirePqc: Boolean,
    val allowClassicFallback: Boolean,
    val minimumTierRaw: String,
    val requireSecureEnclavePoP: Boolean = false,
    val providerTypeRaw: String = "Android"
)

fun P2PHandshakePolicyOverride.forTrustedClassicBootstrap(enabled: Boolean): P2PHandshakePolicyOverride =
    if (!enabled) {
        this
    } else {
        P2PHandshakePolicyOverride(
            requirePqc = false,
            allowClassicFallback = false,
            minimumTierRaw = "classic",
            requireSecureEnclavePoP = false,
            providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
        )
    }

fun bestAvailablePqcMinimumTierRaw(): String? = when {
    P2PXWingKem.isAvailable() -> "nativePQC"
    AndroidPQCCryptoProvider.isAvailable() -> "liboqsPQC"
    else -> null
}

fun resolveRequestedHandshakeMinimumTierRaw(
    requestedMinimumTierRaw: String,
    requirePqc: Boolean
): String {
    val normalizedRequestedTier = when (requestedMinimumTierRaw.trim()) {
        "nativePQC", "x-wing", "xwing", "strictXWing" -> "nativePQC"
        "liboqsPQC", "pqc", "mlkem", "ml-kem" -> "liboqsPQC"
        else -> "classic"
    }
    return when (normalizedRequestedTier) {
        "nativePQC" -> when {
            P2PXWingKem.isAvailable() -> "nativePQC"
            AndroidPQCCryptoProvider.isAvailable() -> "liboqsPQC"
            requirePqc -> "nativePQC"
            else -> "classic"
        }

        "liboqsPQC" -> when {
            AndroidPQCCryptoProvider.isAvailable() -> "liboqsPQC"
            requirePqc -> "liboqsPQC"
            else -> "classic"
        }

        else -> if (requirePqc) {
            bestAvailablePqcMinimumTierRaw() ?: "classic"
        } else {
            "classic"
        }
    }
}

fun capabilityAwareHandshakePolicyOverride(
    requirePqc: Boolean,
    allowClassicFallback: Boolean,
    minimumTierRaw: String,
    requireSecureEnclavePoP: Boolean = false
): P2PHandshakePolicyOverride {
    val resolvedMinimumTierRaw = resolveRequestedHandshakeMinimumTierRaw(
        requestedMinimumTierRaw = minimumTierRaw,
        requirePqc = requirePqc
    )
    return P2PHandshakePolicyOverride(
        requirePqc = requirePqc,
        allowClassicFallback = allowClassicFallback,
        minimumTierRaw = resolvedMinimumTierRaw,
        requireSecureEnclavePoP = requireSecureEnclavePoP,
        providerTypeRaw = P2PHandshakeWire.compatibleProviderTypeRawForTier(resolvedMinimumTierRaw)
    )
}

fun P2PHandshakePolicyOverride.toWirePolicy(): P2PHandshakePolicy =
    P2PHandshakePolicy(
        requirePqc = requirePqc,
        allowClassicFallback = allowClassicFallback,
        minimumTierRaw = minimumTierRaw,
        requireSecureEnclavePoP = requireSecureEnclavePoP
    )

fun P2PHandshakeWire.TrustStore.isPeerPinned(peerId: String): Boolean =
    loadPeerSigningFingerprint(peerId)?.isNotBlank() == true

fun P2PHandshakeClient.PeerKemPublicKeys.isMissingPqcMaterial(): Boolean =
    xWingPublicKey == null && mlKem768PublicKey == null
