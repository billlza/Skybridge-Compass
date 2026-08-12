@file:Suppress("DEPRECATION")

package com.skybridge.compass.core.p2p

import android.content.Context
import android.os.Build
import android.util.Base64
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.SkyBridgeKeyManager
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.account.NebulaId
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import com.skybridge.compass.shared.platform.AndroidPlatformMetadata
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.nio.file.Files
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
class LocalP2PIdentity(
    @param:ApplicationContext private val appContext: Context,
    private val storageMode: StorageMode = StorageMode.ENCRYPTED
) {
    @Inject
    constructor(
        @ApplicationContext appContext: Context
    ) : this(
        appContext = appContext,
        storageMode = StorageMode.ENCRYPTED
    )

    enum class StorageMode {
        ENCRYPTED,
        ENCRYPTED_EXISTING_ONLY,
        ISOLATED_PLAINTEXT_TEST
    }

    private val storageContext by lazy { appContext.createDeviceProtectedStorageContext() }
    private val prefs by lazy { prefs(storageContext, storageMode) }
    private val keyManager by lazy { SkyBridgeKeyManager(storageContext) }
    @Volatile private var inMemoryEd25519PrivateKey: PrivateKey? = null
    @Volatile private var inMemoryEd25519PublicRaw32: ByteArray? = null

    fun deviceName(): String = Build.MODEL.ifBlank { "Android" }

    /**
     * Resolve the device name to PUBLISH in Bonjour/NSD discovery, honoring the privacy
     * `showDeviceName` toggle (Settings → Privacy). When ON we advertise the real [deviceName]; when
     * OFF we advertise a generic, non-identifying name so the device stays discoverable/connectable
     * without exposing the owner's model name in discovery results.
     *
     * The toggle value is owned by the app-module SecuritySettingsStore and passed in by the caller
     * (the LAN remote-control host), so core stays free of an app-module dependency.
     */
    fun publishedDeviceName(showDeviceName: Boolean): String =
        if (showDeviceName) deviceName() else ANONYMIZED_DEVICE_NAME

    fun deviceId(): String {
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) return existing
        check(storageMode != StorageMode.ENCRYPTED_EXISTING_ONLY) {
            "Existing-only identity is missing the device identifier"
        }
        val created = UUID.randomUUID().toString()
        prefs.edit {
            putString(KEY_DEVICE_ID, created)
        }
        return created
    }

    /**
     * Compute (or load) the discovery fingerprint `pubKeyFP`.
     *
     * Matches macOS/iOS Pro release: SHA-256 over P-256 public key rawRepresentation (X9.63).
     */
    fun pubKeyFingerprint(): String {
        val cached = prefs.getString(KEY_PUBKEY_FP, null)
        if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
            return requireMatchingExistingP256Fingerprint(
                cachedFingerprint = cached,
                keyPair = keyManager.getDeviceIdentityKey()
            )
        }
        if (!cached.isNullOrBlank()) return cached

        val kp = keyManager.getDeviceIdentityKey() ?: run {
            keyManager.generateDeviceIdentityKey()
        }
        val pub = kp.public as? ECPublicKey
            ?: return ""
        val raw = uncompressedP256Point(pub)
        val fp = sha256HexLower(raw)
        if (storageMode != StorageMode.ENCRYPTED_EXISTING_ONLY) {
            prefs.edit {
                putString(KEY_PUBKEY_FP, fp)
            }
        }
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

            storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY ->
                error("Existing-only identity is missing Ed25519 signing keys")

            else -> {
                val (priv, pubRaw32) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
                val privBytes = priv.encoded
                if (privBytes != null) {
                    prefs.edit {
                        putString(KEY_ED25519_PRIV_PKCS8_B64, Base64.encodeToString(privBytes, Base64.NO_WRAP))
                        putString(KEY_ED25519_PUB_RAW32_B64, Base64.encodeToString(pubRaw32, Base64.NO_WRAP))
                    }
                } else {
                    inMemoryEd25519PrivateKey = priv
                    inMemoryEd25519PublicRaw32 = pubRaw32
                }
                priv to pubRaw32
            }
        }

        val (mlPriv, mlPub) = if (storageMode == StorageMode.ISOLATED_PLAINTEXT_TEST) {
            null to null
        } else {
            val mlPrivB64 = prefs.getString(KEY_MLDSA65_PRIV_RAW_B64, null)
            val mlPubB64 = prefs.getString(KEY_MLDSA65_PUB_RAW_B64, null)
            if (!mlPrivB64.isNullOrBlank() && !mlPubB64.isNullOrBlank()) {
                Base64.decode(mlPrivB64, Base64.NO_WRAP) to Base64.decode(mlPubB64, Base64.NO_WRAP)
            } else if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
                error("Existing-only identity is missing ML-DSA-65 signing keys")
            } else if (AndroidPQCCryptoProvider.isAvailable()) {
                val provider = AndroidPQCCryptoProvider()
                val kp = kotlinx.coroutines.runBlocking { provider.generateKeyPair(KeyUsage.SIGNING) }
                val privRaw = kp.privateKey.bytes
                val pubRaw = kp.publicKey.bytes
                prefs.edit {
                    putString(KEY_MLDSA65_PRIV_RAW_B64, Base64.encodeToString(privRaw, Base64.NO_WRAP))
                    putString(KEY_MLDSA65_PUB_RAW_B64, Base64.encodeToString(pubRaw, Base64.NO_WRAP))
                }
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
        val qPeriaptPublicKey: ByteArray?,
        val qPeriaptPrivateKey: ByteArray?,
        val mlKem768PublicKey: ByteArray?,
        val mlKem768PrivateKey: ByteArray?,
        val xWingPublicKey: ByteArray?,
        val xWingPrivateKey: ByteArray?
    )

    fun getOrCreateKemIdentityKeys(allowQPeriapt: Boolean = false): KemIdentityKeys {
        if (storageMode == StorageMode.ISOLATED_PLAINTEXT_TEST) {
            return KemIdentityKeys(
                qPeriaptPublicKey = null,
                qPeriaptPrivateKey = null,
                mlKem768PublicKey = null,
                mlKem768PrivateKey = null,
                xWingPublicKey = null,
                xWingPrivateKey = null
            )
        }
        val qPeriapt = if (allowQPeriapt) {
            QPeriaptPlatformPolicy.requireLocalAndroidSupported(
                QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                    release = Build.VERSION.RELEASE,
                    sdkInt = Build.VERSION.SDK_INT
                )
            )
            P2PQPeriaptKem.availabilityFailureReason()?.let { reason ->
                throw IllegalStateException("Q-Periapt unavailable: $reason")
            }
            getOrCreateKemKeyPair(
                alias = ALIAS_KEM_QPERIAPT,
                suite = CryptoSuite.Q_PERIAPT_CONTEXT_BOUND
            ) {
                val provider = AndroidPQCCryptoProvider()
                P2PQPeriaptKem.asKeyPair(P2PQPeriaptKem.generateKeyPair(provider))
            }
        } else {
            null
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
            qPeriaptPublicKey = qPeriapt?.publicKey?.bytes,
            qPeriaptPrivateKey = qPeriapt?.privateKey?.bytes,
            mlKem768PublicKey = mlKem?.publicKey?.bytes,
            mlKem768PrivateKey = mlKem?.privateKey?.bytes,
            xWingPublicKey = xWing?.publicKey?.bytes,
            xWingPrivateKey = xWing?.privateKey?.bytes
        )
    }

    fun discoveryCryptoSuitesCsv(
        allowQPeriapt: Boolean = false,
        allowClassic: Boolean = false
    ): String {
        if (storageMode == StorageMode.ISOLATED_PLAINTEXT_TEST) {
            return "1001"
        }
        val kem = getOrCreateKemIdentityKeys(allowQPeriapt = allowQPeriapt)
        return buildList {
            if (allowQPeriapt && kem.qPeriaptPublicKey != null) add("0011")
            if (kem.xWingPublicKey != null) add("0001")
            if (kem.mlKem768PublicKey != null) add("0101")
            if (allowClassic) add("1001")
        }.joinToString(",")
    }

    private fun getOrCreateKemKeyPair(
        alias: String,
        suite: CryptoSuite,
        generator: () -> KeyPair
    ): KeyPair? {
        return try {
            val existing = if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
                keyManager.retrieveExistingPQCKeyPair(alias)
            } else {
                keyManager.retrievePQCKeyPair(alias)
            }
            existing?.also { validateKemKeyPair(alias, suite, it) } ?: run {
                check(storageMode != StorageMode.ENCRYPTED_EXISTING_ONLY) {
                    "Existing-only identity is missing KEM keypair for $alias"
                }
                val kp = generator()
                validateKemKeyPair(alias, suite, kp)
                keyManager.storePQCKeyPair(kp, alias)
                kp
            }
        } catch (t: Throwable) {
            throw IllegalStateException("Failed to load or create KEM keypair for $alias", t)
        }
    }

    private fun validateKemKeyPair(alias: String, suite: CryptoSuite, keyPair: KeyPair) {
        val (expectedPublicSize, expectedPrivateSize) = when (suite) {
            CryptoSuite.Q_PERIAPT_CONTEXT_BOUND ->
                P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE to P2PQPeriaptKem.QPERIAPT_PRIVATE_KEY_SIZE
            CryptoSuite.X_WING_ML_DSA ->
                P2PXWingKem.XWING_PUBLIC_KEY_SIZE to P2PXWingKem.XWING_PRIVATE_KEY_SIZE
            CryptoSuite.ML_KEM_768_ML_DSA_65 ->
                AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE to AndroidPQCCryptoProvider.MLKEM768_SECRET_KEY_SIZE
            else -> error("Unsupported KEM suite for $alias: ${suite.rawValue}")
        }
        require(keyPair.publicKey.bytes.size == expectedPublicSize) {
            "Invalid public key length for $alias: ${keyPair.publicKey.bytes.size}"
        }
        require(keyPair.privateKey.bytes.size == expectedPrivateSize) {
            "Invalid private key length for $alias: ${keyPair.privateKey.bytes.size}"
        }
    }

    /**
     * Build the local `pairingIdentityExchange` payload for macOS/iOS bootstrap.
     */
    fun buildPairingIdentityExchange(
        nowSwiftSeconds: Double,
        platform: String = "android",
        allowQPeriapt: Boolean = false,
        accountDisplayName: String? = null,
        nebulaId: String? = null
    ): AppMessage.PairingIdentityExchangePayload {
        val kem = getOrCreateKemIdentityKeys(allowQPeriapt = allowQPeriapt)
        val keys = ArrayList<AppMessage.KemPublicKeyInfo>(3)

        if (allowQPeriapt && kem.qPeriaptPublicKey != null) {
            keys += AppMessage.KemPublicKeyInfo(
                suiteWireId = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt(),
                publicKey = kem.qPeriaptPublicKey
            )
        }
        if (kem.xWingPublicKey != null) {
            keys += AppMessage.KemPublicKeyInfo(
                suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                publicKey = kem.xWingPublicKey
            )
        }
        if (kem.mlKem768PublicKey != null) {
            keys += AppMessage.KemPublicKeyInfo(
                suiteWireId = P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                publicKey = kem.mlKem768PublicKey
            )
        }
        val normalizedNebulaId = NebulaId.parseOrNull(nebulaId)?.value
        val normalizedDisplayName = if (normalizedNebulaId != null) {
            accountDisplayName?.trim()?.takeIf { it.isNotEmpty() }
        } else {
            null
        }
        return AppMessage.PairingIdentityExchangePayload(
            deviceId = deviceId(),
            kemPublicKeys = keys,
            deviceName = deviceName(),
            modelName = Build.MODEL,
            platform = platform,
            osVersion = AndroidPlatformMetadata.versionString(Build.VERSION.RELEASE, Build.VERSION.SDK_INT),
            chip = null,
            remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats(),
            capabilities = androidBusinessCapabilities(),
            sentAt = nowSwiftSeconds,
            accountDisplayName = normalizedDisplayName,
            nebulaId = normalizedNebulaId
        )
    }

    private fun androidBusinessCapabilities(): List<String> =
        listOf(
            "webrtcMedia",
            "remoteControl",
            "clipboard",
            "fileTransfer"
        )

    fun handshakeClient(peerKem: P2PHandshakeClient.PeerKemPublicKeys, policy: P2PHandshakePolicyOverride? = null): P2PHandshakeClient {
        val effectivePolicy = policy ?: defaultHandshakePolicyOverride()
        val effectiveProviderType = P2PHandshakeWire.compatibleProviderTypeRawForTier(effectivePolicy.minimumTierRaw)
        return P2PHandshakeClient(
            platformVersion = QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                release = Build.VERSION.RELEASE,
                sdkInt = Build.VERSION.SDK_INT
            ),
            providerTypeRaw = effectivePolicy.providerTypeRaw.ifBlank { effectiveProviderType },
        )
    }

    fun defaultHandshakePolicyOverride(): P2PHandshakePolicyOverride =
        capabilityAwareHandshakePolicyOverride(
            requirePqc = true,
            allowClassicFallback = false,
            minimumTierRaw = "nativePQC"
        )

    fun trustStore(): P2PHandshakeWire.TrustStore =
        if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
            FormalAcceptancePrefsTrustStore(prefs)
        } else {
            PrefsTrustStore(prefs)
        }

    fun formalAcceptanceTrustStore(): P2PHandshakeWire.TrustStore =
        FormalAcceptancePrefsTrustStore(prefs)

    fun trustedPeerStore(): TrustedPeerStore = TrustedPeerStore(prefs)

    fun fallbackCooldownStore(): P2PHandshakeWire.FallbackCooldownStore =
        if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
            FormalAcceptanceFallbackCooldownStore(prefs)
        } else {
            PrefsFallbackCooldownStore(prefs)
        }

    companion object {
        private const val PREFS_NAME = "skybridge_p2p_identity"

        /** Generic, non-identifying name advertised when the privacy `showDeviceName` toggle is OFF. */
        const val ANONYMIZED_DEVICE_NAME = "SkyBridge Device"

        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_PUBKEY_FP = "pub_key_fp"

        private const val KEY_ED25519_PRIV_PKCS8_B64 = "ed25519_priv_pkcs8_b64"
        private const val KEY_ED25519_PUB_RAW32_B64 = "ed25519_pub_raw32_b64"

        private const val KEY_MLDSA65_PRIV_RAW_B64 = "mldsa65_priv_raw_b64"
        private const val KEY_MLDSA65_PUB_RAW_B64 = "mldsa65_pub_raw_b64"

        private const val ALIAS_KEM_MLKEM768 = "p2p_kem_identity_mlkem768"
        private const val ALIAS_KEM_XWING = "p2p_kem_identity_xwing"
        private const val ALIAS_KEM_QPERIAPT = "p2p_kem_identity_qperiapt"

        private fun prefs(context: Context, storageMode: StorageMode) =
            if (storageMode == StorageMode.ISOLATED_PLAINTEXT_TEST) {
                context.getSharedPreferences("${PREFS_NAME}_smoke", Context.MODE_PRIVATE)
            } else {
                if (storageMode == StorageMode.ENCRYPTED_EXISTING_ONLY) {
                    val preferencesDirectory = java.io.File(context.dataDir, "shared_prefs")
                    val preferencesFile = java.io.File(preferencesDirectory, "$PREFS_NAME.xml")
                    check(
                        preferencesFile.canonicalFile.parentFile == preferencesDirectory.canonicalFile &&
                            preferencesFile.isFile &&
                            !Files.isSymbolicLink(preferencesFile.toPath()) &&
                            preferencesFile.length() > 0L
                    ) {
                        "Existing-only identity encrypted preferences are missing"
                    }
                    val rawPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    check(
                        rawPreferences.contains(ENCRYPTED_PREFS_KEY_KEYSET) &&
                            rawPreferences.contains(ENCRYPTED_PREFS_VALUE_KEYSET)
                    ) {
                        "Existing-only identity encrypted preference keysets are missing"
                    }
                    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    check(keyStore.containsAlias(MasterKey.DEFAULT_MASTER_KEY_ALIAS)) {
                        "Existing-only identity is missing the encrypted-preferences master key"
                    }
                }
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

        private const val ENCRYPTED_PREFS_KEY_KEYSET =
            "__androidx_security_crypto_encrypted_prefs_key_keyset__"
        private const val ENCRYPTED_PREFS_VALUE_KEYSET =
            "__androidx_security_crypto_encrypted_prefs_value_keyset__"

        internal fun requireMatchingExistingP256Fingerprint(
            cachedFingerprint: String?,
            keyPair: java.security.KeyPair?
        ): String {
            check(!cachedFingerprint.isNullOrBlank()) {
                "Existing-only identity is missing the cached P-256 discovery fingerprint"
            }
            val existing = keyPair
                ?: error("Existing-only identity is missing the P-256 discovery key")
            val publicKey = existing.public as? ECPublicKey
                ?: error("Existing-only identity P-256 discovery key has an invalid public key type")
            val computed = sha256HexLower(uncompressedP256Point(publicKey))
            check(cachedFingerprint == computed) {
                "Existing-only identity cached P-256 fingerprint does not match the existing key"
            }
            return computed
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

}

/**
 * Persistent trust store compatible with [P2PHandshakeWire.TrustStore].
 */
internal class PrefsTrustStore(
    private val prefs: android.content.SharedPreferences
) : P2PHandshakeWire.TrustStore {
    override fun loadPeerSigningFingerprint(peerId: String): String? {
        val canonical = TrustedPeerStore(prefs)
            .findRecordByKnownDeviceIdIncludingInactive(peerId)
        return when {
            canonical == null ->
                // Legacy pins are consulted only for peers that have never had a canonical record.
                // This is a one-way compatibility read; a blocked canonical identity must win.
                prefs.getString("trust_fp_${peerId.sha256Key()}", null)

            canonical.lifecycleState == TrustedPeerLifecycleState.ACTIVE ->
                canonical.protocolPublicKeyFingerprint

            else ->
                // REVERIFICATION_REQUIRED, QUARANTINED and REVOKED are authoritative deny states.
                null
        }
    }

    override fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String) {
        val normalizedFingerprint = peerSigningFingerprint.trim().lowercase()
        val stored = TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
            deviceId = peerId,
            protocolPublicKeyFingerprint = normalizedFingerprint,
            aliasIds = listOf(peerId)
        )
        check(stored.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
            stored.protocolPublicKeyFingerprint == normalizedFingerprint
        ) {
            "Cannot persist peer signing fingerprint while canonical trust record is blocked"
        }
        prefs.edit {
            putString("trust_fp_${peerId.sha256Key()}", normalizedFingerprint)
        }
    }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

/**
 * Non-mutating trust view for formal acceptance probes.
 *
 * Legacy records without authenticated product provenance are intentionally invisible. Writes fail
 * closed, and record parsing does not repair integrity markers or migrate stored data.
 */
internal class FormalAcceptancePrefsTrustStore(
    private val prefs: android.content.SharedPreferences
) : P2PHandshakeWire.TrustStore {
    override fun loadPeerSigningFingerprint(peerId: String): String? =
        TrustedPeerStore(prefs)
            .findVerifiedRecordByKnownDeviceIdReadOnly(peerId)
            ?.protocolPublicKeyFingerprint

    override fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String) {
        error("formal acceptance trust store is read-only")
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
        prefs.edit {
            putLong("fallback_${peerId.sha256Key()}", unixTimeMillis)
        }
    }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

internal class FormalAcceptanceFallbackCooldownStore(
    private val prefs: android.content.SharedPreferences
) : P2PHandshakeWire.FallbackCooldownStore {
    override fun loadLastClassicFallbackAtMillis(peerId: String): Long? {
        val value = prefs.getLong("fallback_${peerId.sha256Key()}", Long.MIN_VALUE)
        return if (value == Long.MIN_VALUE) null else value
    }

    override fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long) {
        error("formal acceptance fallback cooldown store is read-only")
    }

    private fun String.sha256Key(): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
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
    if (!enabled || minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW) {
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
        P2PQPeriaptKem.MINIMUM_TIER_RAW, "q-periapt", "qperiapt" -> P2PQPeriaptKem.MINIMUM_TIER_RAW
        "nativePQC", "x-wing", "xwing", "strictXWing" -> "nativePQC"
        "liboqsPQC", "pqc", "mlkem", "ml-kem" -> "liboqsPQC"
        "classic" -> "classic"
        else -> throw IllegalArgumentException("Unsupported handshake minimum tier: $requestedMinimumTierRaw")
    }
    return when (normalizedRequestedTier) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW -> P2PQPeriaptKem.MINIMUM_TIER_RAW
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
            bestAvailablePqcMinimumTierRaw()
                ?: throw IllegalStateException("PQC is required but no PQC provider is available")
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
    qPeriaptPublicKey == null && xWingPublicKey == null && mlKem768PublicKey == null
