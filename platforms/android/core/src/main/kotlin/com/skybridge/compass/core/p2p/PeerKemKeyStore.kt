@file:Suppress("DEPRECATION")

package com.skybridge.compass.core.p2p

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

internal data class PeerKemKeyStoreRecord(
    val qPeriaptPublicKeyBase64: String?,
    val qPeriaptAllowed: Boolean,
    val qPeriaptPlatform: String?,
    val xWingPublicKeyBase64: String?,
    val mlKem768PublicKeyBase64: String?,
    val updatedAtMillis: Long? = null
)

internal data class PeerKemKeyStoreLoadResult(
    val keys: PeerKemKeyStore.PeerKemPublicKeys,
    val clearQPeriapt: Boolean
)

internal object PeerKemTrustOriginPolicy {
    const val AUTHENTICATED_PRODUCT_V1 = "authenticated_product_session_v1"
    const val SIGNED_LAN_KEM_REFRESH = "signed_lan_kem_refresh"

    fun isFormalAcceptanceEligible(storedOrigin: String?): Boolean =
        storedOrigin == AUTHENTICATED_PRODUCT_V1 || storedOrigin == SIGNED_LAN_KEM_REFRESH
}

internal data class SignedLanRefreshProvenance(
    val keyId: String,
    val generation: Long,
    val expiresAtMillis: Long,
    val protocolIdentityFingerprint: String,
    val signingFingerprint: String,
    val payloadHashHex: String,
    val kemPublicKeyHashHex: String,
    val signedSuiteWireIds: List<Int>,
    val responseDeviceId: String
)

internal sealed interface PeerKemTrustOrigin {
    data object AuthenticatedProductSessionV1 : PeerKemTrustOrigin
    data class SignedLanKemRefresh(val provenance: SignedLanRefreshProvenance) : PeerKemTrustOrigin
}

internal class PeerKemKeyStorePersistenceException(
    message: String,
    val rollbackConfirmed: Boolean,
    cause: Throwable? = null
) : IllegalStateException(message, cause)

internal class PeerKemKeyStoreCorruptionException(
    message: String,
    cause: Throwable? = null
) : IllegalStateException(message, cause)

internal object PeerKemKeyStoreRecords {
    /** Validate and materialize bootstrap keys without touching persistent trust state. */
    fun materialize(
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?
    ): PeerKemKeyStore.PeerKemPublicKeys = load(
        snapshot(
            kemPublicKeys = kemPublicKeys,
            platform = platform,
            osVersion = osVersion,
            updatedAtMillis = 0L
        )
    ).keys

    fun load(
        record: PeerKemKeyStoreRecord,
        strictBase64: Boolean = false
    ): PeerKemKeyStoreLoadResult {
        var clearQPeriapt = false
        val qPeriapt = if (record.qPeriaptAllowed) {
            val metadata = record.qPeriaptPlatform?.trim()?.takeIf { it.isNotEmpty() }
            val encodedKey = record.qPeriaptPublicKeyBase64?.trim()?.takeIf { it.isNotEmpty() }
            if (
                metadata == null ||
                    encodedKey == null ||
                    !QPeriaptPlatformPolicy.isAppPeerEligible(platform = null, osVersion = metadata)
            ) {
                clearQPeriapt = true
                null
            } else {
                decodeBase64(encodedKey, strict = strictBase64)
                    .also { PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND, it) }
            }
        } else {
            null
        }
        val xWing = record.xWingPublicKeyBase64
            ?.let { decodeBase64(it, strict = strictBase64) }
            ?.also { PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.X_WING, it) }
        val mlKem = record.mlKem768PublicKeyBase64
            ?.let { decodeBase64(it, strict = strictBase64) }
            ?.also { PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.MLKEM_768, it) }
        return PeerKemKeyStoreLoadResult(
            keys = PeerKemKeyStore.PeerKemPublicKeys(
                qPeriaptPublicKey = qPeriapt,
                xWingPublicKey = xWing,
                mlKem768PublicKey = mlKem
            ),
            clearQPeriapt = clearQPeriapt
        )
    }

    fun snapshot(
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?,
        updatedAtMillis: Long
    ): PeerKemKeyStoreRecord {
        var qPeriapt: ByteArray? = null
        var xWing: ByteArray? = null
        var mlKem: ByteArray? = null
        for (k in kemPublicKeys) {
            when (k.suiteWireId) {
                P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt() -> {
                    QPeriaptPlatformPolicy.requireAppPeerEligible(
                        platform = platform,
                        osVersion = osVersion
                    )
                    PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND, k.publicKey)
                    qPeriapt = k.publicKey
                }
                P2PCryptoSuite.X_WING.wireId.toInt() -> {
                    PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.X_WING, k.publicKey)
                    xWing = k.publicKey
                }
                P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                P2PCryptoSuite.MLKEM_768_FS_COMPAT.wireId.toInt() -> {
                    PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.MLKEM_768, k.publicKey)
                    mlKem = k.publicKey
                }
                else -> throw IllegalArgumentException("Unsupported peer KEM suite wireId=${k.suiteWireId}")
            }
        }
        val platformMetadata = listOfNotNull(platform, osVersion).joinToString(" ").take(128)
        return PeerKemKeyStoreRecord(
            qPeriaptPublicKeyBase64 = qPeriapt?.let(::encodeBase64),
            qPeriaptAllowed = qPeriapt != null,
            qPeriaptPlatform = qPeriapt?.let { platformMetadata },
            xWingPublicKeyBase64 = xWing?.let(::encodeBase64),
            mlKem768PublicKeyBase64 = mlKem?.let(::encodeBase64),
            updatedAtMillis = updatedAtMillis
        )
    }

    private fun decodeBase64(value: String, strict: Boolean): ByteArray =
        if (strict) Base64.getDecoder().decode(value) else Base64.getMimeDecoder().decode(value)

    private fun encodeBase64(value: ByteArray): String =
        Base64.getEncoder().encodeToString(value)
}

fun interface PeerKemPublicKeySource {
    fun load(peerId: String): PeerKemKeyStore.PeerKemPublicKeys
}

@Singleton
class PeerKemKeyStore internal constructor(
    private val prefsProvider: () -> SharedPreferences,
    private val trustedPeerStoreProvider: () -> TrustedPeerStore,
    private val currentTimeMillis: () -> Long
) : PeerKemPublicKeySource {
    @Inject
    constructor(
        @ApplicationContext appContext: Context
    ) : this(
        prefsProvider = { createEncryptedPreferences(appContext.applicationContext) },
        trustedPeerStoreProvider = {
            LocalP2PIdentity(appContext.applicationContext).trustedPeerStore()
        },
        currentTimeMillis = System::currentTimeMillis
    )

    data class PeerKemPublicKeys(
        val qPeriaptPublicKey: ByteArray? = null,
        val xWingPublicKey: ByteArray? = null,
        val mlKem768PublicKey: ByteArray? = null
    )

    private val prefs by lazy(prefsProvider)
    private val trustedPeerStore by lazy(trustedPeerStoreProvider)

    override fun load(peerId: String): PeerKemPublicKeys =
        load(peerId = peerId, removeIneligibleQPeriapt = true)

    /**
     * Read-only acceptance view that excludes records predating authenticated product provenance.
     * Legacy records are left untouched and remain available to normal product compatibility paths;
     * they simply cannot prove that a formal run avoided historical diagnostic injection.
     */
    fun loadVerifiedReadOnly(peerId: String): PeerKemPublicKeys {
        require(peerId.isNotBlank()) { "peerId is required to load verified peer KEM keys" }
        return synchronized(PROCESS_LOCK) {
            val trustedPeer = trustedPeerStore.findVerifiedRecordByKnownDeviceIdReadOnly(peerId)
                ?: return@synchronized PeerKemPublicKeys()
            val h = peerId.sha256Key()
            val origin = readTypedOrigin(
                hashedPeerId = h,
                peerId = peerId,
                trustedPeer = trustedPeer,
                nowMillis = currentTimeMillis()
            ) ?: return@synchronized PeerKemPublicKeys()
            when (origin) {
                PeerKemTrustOrigin.AuthenticatedProductSessionV1 ->
                    loadFormalKeys(peerId)
                is PeerKemTrustOrigin.SignedLanKemRefresh -> {
                    val loaded = loadFormalKeys(peerId)
                    validateSignedRefreshMaterial(
                        keys = loaded,
                        provenance = origin.provenance,
                        trustedPeer = trustedPeer
                    )
                    loaded
                }
            }
        }
    }

    private fun load(
        peerId: String,
        removeIneligibleQPeriapt: Boolean,
        strictBase64: Boolean = false
    ): PeerKemPublicKeys = synchronized(PROCESS_LOCK) {
        require(peerId.isNotBlank()) { "peerId is required to load peer KEM keys" }
        val h = peerId.sha256Key()
        val result = PeerKemKeyStoreRecords.load(
            PeerKemKeyStoreRecord(
                qPeriaptPublicKeyBase64 = prefs.getString("qperiapt_$h", null),
                qPeriaptAllowed = prefs.getBoolean("qperiapt_allowed_$h", false),
                qPeriaptPlatform = prefs.getString("qperiapt_platform_$h", null),
                xWingPublicKeyBase64 = prefs.getString("xwing_$h", null),
                mlKem768PublicKeyBase64 = prefs.getString("mlkem768_$h", null),
                updatedAtMillis = if (prefs.contains("updated_at_$h")) prefs.getLong("updated_at_$h", 0L) else null
            ),
            strictBase64 = strictBase64
        )
        if (result.clearQPeriapt && removeIneligibleQPeriapt) {
            clearQPeriapt(peerId)
        }
        result.keys
    }

    /**
     * Persist KEM material admitted by an authenticated or explicitly approved product protocol
     * path. Diagnostic callers must use an in-memory [PeerKemPublicKeySource] instead.
     */
    internal fun save(
        peerId: String,
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?,
        verifiedProtocolFingerprint: String
    ) = saveForAliases(
        peerIds = listOf(peerId),
        kemPublicKeys = kemPublicKeys,
        platform = platform,
        osVersion = osVersion,
        verifiedProtocolFingerprint = verifiedProtocolFingerprint
    )

    internal fun saveForAliases(
        peerIds: Collection<String>,
        kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
        platform: String?,
        osVersion: String?,
        verifiedProtocolFingerprint: String
    ) = synchronized(PROCESS_LOCK) {
        val normalizedPeerIds = normalizePeerIdsForPersistence(
            peerIds = peerIds,
            operation = "authenticated product-session KEM persistence"
        )
        val authorityFingerprint = normalizeFingerprint(verifiedProtocolFingerprint)
            ?: throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session protocol fingerprint is invalid",
                rollbackConfirmed = true
            )
        requireActiveAuthorityForEveryPeer(normalizedPeerIds, authorityFingerprint)
        val snapshot = try {
            PeerKemKeyStoreRecords.snapshot(
                kemPublicKeys = kemPublicKeys,
                platform = platform,
                osVersion = osVersion,
                updatedAtMillis = currentTimeMillis()
            )
        } catch (e: IllegalArgumentException) {
            throw PeerKemKeyStorePersistenceException(
                message = "authenticated product-session KEM key material is invalid",
                rollbackConfirmed = true,
                cause = e
            )
        }
        val expected = normalizedPeerIds.flatMap { peerId ->
            expectedSessionRecord(
                hashedPeerId = peerId.sha256Key(),
                record = snapshot,
                authorityFingerprint = authorityFingerprint
            ).entries
        }.associate { it.toPair() }
        commitMutation(
            expected = expected,
            operation = "commit authenticated product-session KEM keys"
        ) { editor ->
            normalizedPeerIds.forEach { peerId ->
                writeSessionRecord(
                    editor = editor,
                    hashedPeerId = peerId.sha256Key(),
                    record = snapshot,
                    authorityFingerprint = authorityFingerprint
                )
            }
        }
    }

    internal fun maximumSignedRefreshGeneration(peerIds: Collection<String>): Long? =
        synchronized(PROCESS_LOCK) {
            peerIds.mapNotNull(::normalizePeerId)
                .distinct()
                .mapNotNull { peerId ->
                    val h = peerId.sha256Key()
                    if (prefs.getString("trust_origin_$h", null) !=
                        PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH
                    ) {
                        null
                    } else if (!prefs.contains("skr_generation_$h")) {
                        throw PeerKemKeyStoreCorruptionException(
                            "signed LAN KEM refresh generation is missing for peer=$peerId"
                        )
                    } else {
                        try {
                            prefs.getLong("skr_generation_$h", -1L).takeIf { it >= 0L }
                                ?: throw PeerKemKeyStoreCorruptionException(
                                    "signed LAN KEM refresh generation is invalid for peer=$peerId"
                                )
                        } catch (e: ClassCastException) {
                            throw PeerKemKeyStoreCorruptionException(
                                "signed LAN KEM refresh generation has the wrong type for peer=$peerId",
                                e
                            )
                        }
                    }
                }
                .maxOrNull()
        }

    /**
     * Persist a fully verified SKR-1 response for every signed identifier as one durable transaction.
     * All signature, request binding, key-length, expiry, and generation checks happen before entry.
     */
    internal fun saveSignedLanRefresh(
        peerIds: Collection<String>,
        refresh: VerifiedSignedLanKemRefresh
    ) = synchronized(PROCESS_LOCK) {
        val normalizedPeerIds = normalizePeerIdsForPersistence(
            peerIds = peerIds + refresh.allDeviceIds,
            operation = "signed LAN KEM refresh"
        )
        val normalizedFingerprint = normalizeFingerprint(refresh.protocolIdentityFingerprint)
            ?: throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh fingerprint is invalid",
                rollbackConfirmed = true
            )
        validateRefreshBeforeWrite(refresh, normalizedFingerprint)
        requireActiveAuthorityForEveryPeer(normalizedPeerIds, normalizedFingerprint)

        val maximumGeneration = maximumSignedRefreshGeneration(normalizedPeerIds)
        if (maximumGeneration != null && refresh.generation < maximumGeneration) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh generation rollback current=$maximumGeneration incoming=${refresh.generation}",
                rollbackConfirmed = true
            )
        }
        val snapshotRecord = try {
            PeerKemKeyStoreRecords.snapshot(
                kemPublicKeys = refresh.kemPublicKeys,
                platform = null,
                osVersion = null,
                updatedAtMillis = currentTimeMillis()
            )
        } catch (e: IllegalArgumentException) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh key material is invalid",
                rollbackConfirmed = true,
                cause = e
            )
        }
        val expected = normalizedPeerIds.flatMap { peerId ->
            expectedSignedRefreshRecord(
                hashedPeerId = peerId.sha256Key(),
                record = snapshotRecord,
                refresh = refresh,
                normalizedFingerprint = normalizedFingerprint
            ).entries
        }.associate { it.toPair() }
        commitMutation(expected = expected, operation = "commit signed LAN KEM refresh") { editor ->
            normalizedPeerIds.forEach { peerId ->
                writeSignedRefreshRecord(
                    editor = editor,
                    hashedPeerId = peerId.sha256Key(),
                    record = snapshotRecord,
                    refresh = refresh,
                    normalizedFingerprint = normalizedFingerprint
                )
            }
        }
    }

    internal fun clearQPeriapt(peerId: String) = synchronized(PROCESS_LOCK) {
        require(peerId.isNotBlank()) { "peerId is required to clear Q-Periapt KEM key" }
        val h = peerId.sha256Key()
        val expected = mapOf<String, Any?>(
            "qperiapt_$h" to null,
            "qperiapt_allowed_$h" to null,
            "qperiapt_platform_$h" to null
        )
        commitMutation(expected = expected, operation = "clear ineligible Q-Periapt KEM key") { editor ->
            editor.remove("qperiapt_$h")
                .remove("qperiapt_allowed_$h")
                .remove("qperiapt_platform_$h")
        }
    }

    private fun readTypedOrigin(
        hashedPeerId: String,
        peerId: String,
        trustedPeer: TrustedPeerRecord,
        nowMillis: Long
    ): PeerKemTrustOrigin? {
        val rawOrigin = readOptionalString("trust_origin_$hashedPeerId", peerId) ?: return null
        return when (rawOrigin) {
            PeerKemTrustOriginPolicy.AUTHENTICATED_PRODUCT_V1 -> {
                val storedFingerprint = readOptionalString(
                    "session_protocol_fingerprint_$hashedPeerId",
                    peerId
                ) ?: return null
                val normalizedStoredFingerprint = normalizeFingerprint(storedFingerprint)
                    ?: corrupt(peerId, "product-session KEM authority fingerprint is invalid")
                val activePin = normalizeFingerprint(trustedPeer.protocolPublicKeyFingerprint)
                    ?: corrupt(peerId, "active PIB pin is invalid")
                if (normalizedStoredFingerprint != activePin) {
                    corrupt(peerId, "product-session KEM authority does not match the active PIB pin")
                }
                PeerKemTrustOrigin.AuthenticatedProductSessionV1
            }
            PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH -> {
                val provenance = SignedLanRefreshProvenance(
                    keyId = readRequiredString("skr_key_id_$hashedPeerId", peerId),
                    generation = readRequiredLong("skr_generation_$hashedPeerId", peerId),
                    expiresAtMillis = readRequiredLong("skr_expires_at_$hashedPeerId", peerId),
                    protocolIdentityFingerprint = readRequiredString(
                        "skr_protocol_fingerprint_$hashedPeerId",
                        peerId
                    ),
                    signingFingerprint = readRequiredString(
                        "skr_signing_fingerprint_$hashedPeerId",
                        peerId
                    ),
                    payloadHashHex = readRequiredString("skr_payload_hash_$hashedPeerId", peerId),
                    kemPublicKeyHashHex = readRequiredString(
                        "skr_kem_public_key_hash_$hashedPeerId",
                        peerId
                    ),
                    signedSuiteWireIds = parseSuiteWireIds(
                        readRequiredString("skr_suite_wire_ids_$hashedPeerId", peerId),
                        peerId
                    ),
                    responseDeviceId = readRequiredString(
                        "skr_response_device_id_$hashedPeerId",
                        peerId
                    )
                )
                val isCurrent = validateSignedRefreshProvenance(
                    peerId = peerId,
                    provenance = provenance,
                    trustedPeer = trustedPeer,
                    nowMillis = nowMillis
                )
                if (!isCurrent) return null
                PeerKemTrustOrigin.SignedLanKemRefresh(provenance)
            }
            else -> null
        }
    }

    private fun validateSignedRefreshProvenance(
        peerId: String,
        provenance: SignedLanRefreshProvenance,
        trustedPeer: TrustedPeerRecord,
        nowMillis: Long
    ): Boolean {
        val pin = normalizeFingerprint(trustedPeer.protocolPublicKeyFingerprint)
            ?: corrupt(peerId, "active PIB pin is invalid")
        val protocolFingerprint = normalizeFingerprint(provenance.protocolIdentityFingerprint)
            ?: corrupt(peerId, "SKR protocol fingerprint is invalid")
        val signingFingerprint = normalizeFingerprint(provenance.signingFingerprint)
            ?: corrupt(peerId, "SKR signing fingerprint is invalid")
        if (protocolFingerprint != pin || signingFingerprint != pin ||
            protocolFingerprint != signingFingerprint
        ) {
            corrupt(peerId, "SKR fingerprints do not match the active PIB pin")
        }
        if (normalizePeerId(provenance.keyId) == null) corrupt(peerId, "SKR key id is invalid")
        if (provenance.generation < 0L) corrupt(peerId, "SKR generation is invalid")
        val isCurrent = provenance.expiresAtMillis > nowMillis
        if (normalizeFingerprint(provenance.payloadHashHex) == null) {
            corrupt(peerId, "SKR payload hash is invalid")
        }
        if (normalizeFingerprint(provenance.kemPublicKeyHashHex) == null) {
            corrupt(peerId, "SKR KEM public-key hash is invalid")
        }
        val responseDeviceId = normalizePeerId(provenance.responseDeviceId)
            ?: corrupt(peerId, "SKR response device id is invalid")
        val trustedIds = (trustedPeer.knownDeviceIds + trustedPeer.deviceId + trustedPeer.currentDeviceId).toSet()
        if (responseDeviceId !in trustedIds) {
            corrupt(peerId, "SKR response device id is not bound to the active PIB authority")
        }
        if (!isCanonicalSignedLanSuiteSubset(provenance.signedSuiteWireIds)) {
            corrupt(peerId, "SKR signed suite list is invalid")
        }
        val maximumGeneration = (trustedIds + peerId).mapNotNull { candidate ->
            val h = candidate.sha256Key()
            if (readOptionalString("trust_origin_$h", candidate) !=
                PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH
            ) {
                null
            } else {
                readRequiredLong("skr_generation_$h", candidate)
            }
        }.maxOrNull()
        if (maximumGeneration != null && provenance.generation < maximumGeneration) {
            corrupt(peerId, "SKR generation is stale relative to another trusted alias")
        }
        return isCurrent
    }

    private fun validateSignedRefreshMaterial(
        keys: PeerKemPublicKeys,
        provenance: SignedLanRefreshProvenance,
        trustedPeer: TrustedPeerRecord
    ) {
        val actualSuiteIds = buildList {
            if (keys.qPeriaptPublicKey != null) add(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt())
            if (keys.xWingPublicKey != null) add(P2PCryptoSuite.X_WING.wireId.toInt())
            if (keys.mlKem768PublicKey != null) add(P2PCryptoSuite.MLKEM_768.wireId.toInt())
        }.sorted()
        if (actualSuiteIds != provenance.signedSuiteWireIds) {
            throw PeerKemKeyStoreCorruptionException(
                "signed LAN KEM refresh material does not match signed suite metadata for peer=${trustedPeer.deviceId}"
            )
        }
        val actualKemPublicKeyHash = SkrCanonical.kemPublicKeyHashHex(
            buildList {
                keys.xWingPublicKey?.let {
                    add(SkrBootstrapWire.KemPublicKeyInfo(P2PCryptoSuite.X_WING.wireId.toInt(), it))
                }
                keys.mlKem768PublicKey?.let {
                    add(SkrBootstrapWire.KemPublicKeyInfo(P2PCryptoSuite.MLKEM_768.wireId.toInt(), it))
                }
            }
        )
        val expectedHash = provenance.kemPublicKeyHashHex
            .lowercase(Locale.ROOT)
            .toByteArray(Charsets.US_ASCII)
        val actualHash = actualKemPublicKeyHash.toByteArray(Charsets.US_ASCII)
        if (!MessageDigest.isEqual(expectedHash, actualHash)) {
            throw PeerKemKeyStoreCorruptionException(
                "signed LAN KEM refresh material does not match signed key hash for peer=${trustedPeer.deviceId}"
            )
        }
    }

    private fun validateRefreshBeforeWrite(
        refresh: VerifiedSignedLanKemRefresh,
        normalizedFingerprint: String
    ) {
        if (refresh.generation < 0L || refresh.expiresAtMillis <= currentTimeMillis()) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh is expired or has an invalid generation",
                rollbackConfirmed = true
            )
        }
        if (normalizePeerId(refresh.keyId) == null ||
            normalizePeerId(refresh.responseDeviceId) == null ||
            normalizeFingerprint(refresh.payloadHashHex) == null ||
            normalizeFingerprint(refresh.kemPublicKeyHashHex) == null
        ) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh provenance is invalid",
                rollbackConfirmed = true
            )
        }
        if (refresh.protocolIdentityFingerprint != normalizedFingerprint ||
            !isCanonicalSignedLanSuiteSubset(refresh.signedSuiteWireIds)
        ) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh metadata is inconsistent",
                rollbackConfirmed = true
            )
        }
        val keySuiteIds = refresh.kemPublicKeys.map(AppMessage.KemPublicKeyInfo::suiteWireId).sorted()
        if (keySuiteIds != refresh.signedSuiteWireIds) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh key material does not match suite metadata",
                rollbackConfirmed = true
            )
        }
        val actualKemHash = SkrCanonical.kemPublicKeyHashHex(
            refresh.kemPublicKeys.map {
                SkrBootstrapWire.KemPublicKeyInfo(
                    suiteWireId = it.suiteWireId,
                    publicKey = it.publicKey
                )
            }
        )
        if (!MessageDigest.isEqual(
                actualKemHash.toByteArray(Charsets.US_ASCII),
                refresh.kemPublicKeyHashHex.lowercase(Locale.ROOT).toByteArray(Charsets.US_ASCII)
            )
        ) {
            throw PeerKemKeyStorePersistenceException(
                message = "signed LAN KEM refresh key material does not match signed key hash",
                rollbackConfirmed = true
            )
        }
    }

    private fun writeSignedRefreshRecord(
        editor: SharedPreferences.Editor,
        hashedPeerId: String,
        record: PeerKemKeyStoreRecord,
        refresh: VerifiedSignedLanKemRefresh,
        normalizedFingerprint: String
    ) {
        editor.remove("qperiapt_$hashedPeerId")
            .remove("qperiapt_allowed_$hashedPeerId")
            .remove("qperiapt_platform_$hashedPeerId")
        if (record.xWingPublicKeyBase64 == null) {
            editor.remove("xwing_$hashedPeerId")
        } else {
            editor.putString("xwing_$hashedPeerId", record.xWingPublicKeyBase64)
        }
        if (record.mlKem768PublicKeyBase64 == null) {
            editor.remove("mlkem768_$hashedPeerId")
        } else {
            editor.putString("mlkem768_$hashedPeerId", record.mlKem768PublicKeyBase64)
        }
        editor.putLong("updated_at_$hashedPeerId", checkNotNull(record.updatedAtMillis))
            .putString("trust_origin_$hashedPeerId", PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH)
            .remove("session_protocol_fingerprint_$hashedPeerId")
            .putString("skr_key_id_$hashedPeerId", refresh.keyId)
            .putLong("skr_generation_$hashedPeerId", refresh.generation)
            .putLong("skr_expires_at_$hashedPeerId", refresh.expiresAtMillis)
            .putString("skr_protocol_fingerprint_$hashedPeerId", normalizedFingerprint)
            .putString("skr_signing_fingerprint_$hashedPeerId", normalizedFingerprint)
            .putString("skr_payload_hash_$hashedPeerId", refresh.payloadHashHex)
            .putString("skr_kem_public_key_hash_$hashedPeerId", refresh.kemPublicKeyHashHex)
            .putString(
                "skr_suite_wire_ids_$hashedPeerId",
                refresh.signedSuiteWireIds.joinToString(",")
            )
            .putString("skr_response_device_id_$hashedPeerId", refresh.responseDeviceId)
    }

    private fun writeSessionRecord(
        editor: SharedPreferences.Editor,
        hashedPeerId: String,
        record: PeerKemKeyStoreRecord,
        authorityFingerprint: String
    ) {
        if (record.qPeriaptPublicKeyBase64 != null) {
            editor.putString("qperiapt_$hashedPeerId", record.qPeriaptPublicKeyBase64)
                .putBoolean("qperiapt_allowed_$hashedPeerId", record.qPeriaptAllowed)
                .putString("qperiapt_platform_$hashedPeerId", record.qPeriaptPlatform)
        } else {
            editor.remove("qperiapt_$hashedPeerId")
                .remove("qperiapt_allowed_$hashedPeerId")
                .remove("qperiapt_platform_$hashedPeerId")
        }
        if (record.xWingPublicKeyBase64 != null) {
            editor.putString("xwing_$hashedPeerId", record.xWingPublicKeyBase64)
        } else {
            editor.remove("xwing_$hashedPeerId")
        }
        if (record.mlKem768PublicKeyBase64 != null) {
            editor.putString("mlkem768_$hashedPeerId", record.mlKem768PublicKeyBase64)
        } else {
            editor.remove("mlkem768_$hashedPeerId")
        }
        editor.putLong("updated_at_$hashedPeerId", checkNotNull(record.updatedAtMillis))
            .putString("trust_origin_$hashedPeerId", PeerKemTrustOriginPolicy.AUTHENTICATED_PRODUCT_V1)
            .putString("session_protocol_fingerprint_$hashedPeerId", authorityFingerprint)
        removeSignedRefreshMetadata(editor = editor, hashedPeerId = hashedPeerId)
    }

    private fun expectedSessionRecord(
        hashedPeerId: String,
        record: PeerKemKeyStoreRecord,
        authorityFingerprint: String
    ): Map<String, Any?> = buildMap {
        put("qperiapt_$hashedPeerId", record.qPeriaptPublicKeyBase64)
        put("qperiapt_allowed_$hashedPeerId", record.qPeriaptAllowed.takeIf { record.qPeriaptPublicKeyBase64 != null })
        put("qperiapt_platform_$hashedPeerId", record.qPeriaptPlatform)
        put("xwing_$hashedPeerId", record.xWingPublicKeyBase64)
        put("mlkem768_$hashedPeerId", record.mlKem768PublicKeyBase64)
        put("updated_at_$hashedPeerId", checkNotNull(record.updatedAtMillis))
        put("trust_origin_$hashedPeerId", PeerKemTrustOriginPolicy.AUTHENTICATED_PRODUCT_V1)
        put("session_protocol_fingerprint_$hashedPeerId", authorityFingerprint)
        signedRefreshMetadataKeys(hashedPeerId).forEach { put(it, null) }
    }

    private fun expectedSignedRefreshRecord(
        hashedPeerId: String,
        record: PeerKemKeyStoreRecord,
        refresh: VerifiedSignedLanKemRefresh,
        normalizedFingerprint: String
    ): Map<String, Any?> = mapOf(
        "qperiapt_$hashedPeerId" to null,
        "qperiapt_allowed_$hashedPeerId" to null,
        "qperiapt_platform_$hashedPeerId" to null,
        "xwing_$hashedPeerId" to record.xWingPublicKeyBase64,
        "mlkem768_$hashedPeerId" to record.mlKem768PublicKeyBase64,
        "updated_at_$hashedPeerId" to checkNotNull(record.updatedAtMillis),
        "trust_origin_$hashedPeerId" to PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH,
        "session_protocol_fingerprint_$hashedPeerId" to null,
        "skr_key_id_$hashedPeerId" to refresh.keyId,
        "skr_generation_$hashedPeerId" to refresh.generation,
        "skr_expires_at_$hashedPeerId" to refresh.expiresAtMillis,
        "skr_protocol_fingerprint_$hashedPeerId" to normalizedFingerprint,
        "skr_signing_fingerprint_$hashedPeerId" to normalizedFingerprint,
        "skr_payload_hash_$hashedPeerId" to refresh.payloadHashHex,
        "skr_kem_public_key_hash_$hashedPeerId" to refresh.kemPublicKeyHashHex,
        "skr_suite_wire_ids_$hashedPeerId" to refresh.signedSuiteWireIds.joinToString(","),
        "skr_response_device_id_$hashedPeerId" to refresh.responseDeviceId
    )

    private fun removeSignedRefreshMetadata(
        editor: SharedPreferences.Editor,
        hashedPeerId: String
    ) {
        signedRefreshMetadataKeys(hashedPeerId).forEach(editor::remove)
    }

    private fun signedRefreshMetadataKeys(hashedPeerId: String): List<String> = listOf(
        "skr_key_id_$hashedPeerId",
        "skr_generation_$hashedPeerId",
        "skr_expires_at_$hashedPeerId",
        "skr_protocol_fingerprint_$hashedPeerId",
        "skr_signing_fingerprint_$hashedPeerId",
        "skr_payload_hash_$hashedPeerId",
        "skr_kem_public_key_hash_$hashedPeerId",
        "skr_suite_wire_ids_$hashedPeerId",
        "skr_response_device_id_$hashedPeerId"
    )

    private inline fun commitMutation(
        expected: Map<String, Any?>,
        operation: String,
        mutate: (SharedPreferences.Editor) -> Unit
    ) {
        val previous = try {
            snapshotPreferences(expected.keys)
        } catch (snapshotFailure: RuntimeException) {
            throw PeerKemKeyStorePersistenceException(
                message = "failed to snapshot peer KEM state before $operation",
                rollbackConfirmed = true,
                cause = snapshotFailure
            )
        }
        val committed = try {
            val editor = prefs.edit()
            mutate(editor)
            if (editor.commit()) true else false
        } catch (commitFailure: RuntimeException) {
            val rollbackConfirmed = restoreSnapshot(previous)
            throw PeerKemKeyStorePersistenceException(
                message = persistenceFailureMessage(operation, rollbackConfirmed),
                rollbackConfirmed = rollbackConfirmed,
                cause = commitFailure
            )
        }
        val rereadMatches = committed && preferencesMatch(expected)
        if (!rereadMatches) {
            val rollbackConfirmed = restoreSnapshot(previous)
            val failureKind = if (committed) "durable re-read mismatch after" else "failed to"
            throw PeerKemKeyStorePersistenceException(
                message = persistenceFailureMessage("$failureKind $operation", rollbackConfirmed),
                rollbackConfirmed = rollbackConfirmed
            )
        }
    }

    private fun preferencesMatch(expected: Map<String, Any?>): Boolean = try {
        val current = prefs.all
        expected.all { (key, value) ->
            if (value == null) key !in current else current[key] == value
        }
    } catch (_: RuntimeException) {
        false
    }

    private data class PreferenceSnapshotValue(val present: Boolean, val value: Any?)

    private fun snapshotPreferences(keys: Set<String>): Map<String, PreferenceSnapshotValue> {
        val values = prefs.all
        return keys.associateWith { key ->
            PreferenceSnapshotValue(present = key in values, value = values[key])
        }
    }

    private fun restoreSnapshot(snapshot: Map<String, PreferenceSnapshotValue>): Boolean {
        return try {
            val editor = prefs.edit()
            for ((key, captured) in snapshot) {
                if (!captured.present) {
                    editor.remove(key)
                } else {
                    when (val value = captured.value) {
                        is String -> editor.putString(key, value)
                        is Long -> editor.putLong(key, value)
                        is Int -> editor.putInt(key, value)
                        is Boolean -> editor.putBoolean(key, value)
                        is Float -> editor.putFloat(key, value)
                        is Set<*> -> {
                            if (value.any { it !is String }) return false
                            editor.putStringSet(key, value.filterIsInstance<String>().toSet())
                        }
                        else -> return false
                    }
                }
            }
            if (!editor.commit()) return false
            val current = prefs.all
            snapshot.all { (key, captured) ->
                if (!captured.present) key !in current else current[key] == captured.value
            }
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun readOptionalString(key: String, peerId: String): String? = try {
        prefs.getString(key, null)
    } catch (e: ClassCastException) {
        throw PeerKemKeyStoreCorruptionException(
            "peer KEM provenance has the wrong type for peer=$peerId key=$key",
            e
        )
    }

    private fun readRequiredString(key: String, peerId: String): String =
        readOptionalString(key, peerId)?.takeIf(String::isNotBlank)
            ?: corrupt(peerId, "required SKR provenance is missing key=$key")

    private fun readRequiredLong(key: String, peerId: String): Long = try {
        if (!prefs.contains(key)) corrupt(peerId, "required SKR provenance is missing key=$key")
        prefs.getLong(key, -1L)
    } catch (e: ClassCastException) {
        throw PeerKemKeyStoreCorruptionException(
            "peer KEM provenance has the wrong type for peer=$peerId key=$key",
            e
        )
    }

    private fun loadFormalKeys(peerId: String): PeerKemPublicKeys = try {
        load(peerId = peerId, removeIneligibleQPeriapt = false, strictBase64 = true)
    } catch (e: PeerKemKeyStoreCorruptionException) {
        throw e
    } catch (e: RuntimeException) {
        throw PeerKemKeyStoreCorruptionException(
            "formal peer KEM material is malformed for peer=$peerId",
            e
        )
    }

    private fun parseSuiteWireIds(raw: String, peerId: String): List<Int> = raw.split(',').map { token ->
        token.toIntOrNull()?.takeIf { it in 0..0xffff }
            ?: corrupt(peerId, "SKR suite metadata is invalid")
    }

    private fun normalizePeerIdsForPersistence(
        peerIds: Collection<String>,
        operation: String
    ): List<String> {
        if (peerIds.isEmpty()) {
            throw PeerKemKeyStorePersistenceException(
                message = "$operation has no peer identifier",
                rollbackConfirmed = true
            )
        }
        val normalized = peerIds.map { raw ->
            normalizePeerId(raw) ?: throw PeerKemKeyStorePersistenceException(
                message = "$operation contains an invalid peer identifier",
                rollbackConfirmed = true
            )
        }.distinct()
        if (normalized.isEmpty()) {
            throw PeerKemKeyStorePersistenceException(
                message = "$operation has no valid peer identifier",
                rollbackConfirmed = true
            )
        }
        return normalized
    }

    private fun requireActiveAuthorityForEveryPeer(
        peerIds: Collection<String>,
        authorityFingerprint: String
    ) {
        peerIds.forEach { peerId ->
            val trustedPeer = try {
                trustedPeerStore.findVerifiedRecordByKnownDeviceIdReadOnly(peerId)
            } catch (e: TrustedPeerStoreCorruptionException) {
                throw PeerKemKeyStorePersistenceException(
                    message = "active authenticated PIB authority is corrupted",
                    rollbackConfirmed = true,
                    cause = e
                )
            } ?: throw PeerKemKeyStorePersistenceException(
                message = "peer is not an active authenticated PIB authority",
                rollbackConfirmed = true
            )
            val activeFingerprint = normalizeFingerprint(trustedPeer.protocolPublicKeyFingerprint)
                ?: throw PeerKemKeyStorePersistenceException(
                    message = "active authenticated PIB authority fingerprint is invalid",
                    rollbackConfirmed = true
                )
            if (activeFingerprint != authorityFingerprint) {
                throw PeerKemKeyStorePersistenceException(
                    message = "peer pin changed before KEM persistence",
                    rollbackConfirmed = true
                )
            }
        }
    }

    private fun normalizePeerId(raw: String?): String? = raw?.trim()?.takeIf { value ->
        value.isNotEmpty() && value.length <= 256 &&
            value.none { it.code < 0x20 || it.code == 0x7f || it == '=' }
    }

    private fun normalizeFingerprint(raw: String?): String? =
        raw?.trim()?.lowercase(Locale.ROOT)?.takeIf { value ->
            value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        }

    private fun isCanonicalSignedLanSuiteSubset(suiteWireIds: List<Int>): Boolean =
        suiteWireIds.isNotEmpty() &&
            suiteWireIds == suiteWireIds.distinct().sorted() &&
            suiteWireIds.all(ALLOWED_SIGNED_LAN_SUITE_WIRE_IDS::contains)

    private fun corrupt(peerId: String, detail: String): Nothing =
        throw PeerKemKeyStoreCorruptionException("$detail for peer=$peerId")

    private fun persistenceFailureMessage(operation: String, rollbackConfirmed: Boolean): String =
        if (rollbackConfirmed) {
            "failed to $operation; previous snapshot restored"
        } else {
            "failed to $operation and confirm snapshot rollback"
        }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    companion object {
        private val PROCESS_LOCK = Any()
        private val ALLOWED_SIGNED_LAN_SUITE_WIRE_IDS = setOf(
            P2PCryptoSuite.X_WING.wireId.toInt(),
            P2PCryptoSuite.MLKEM_768.wireId.toInt()
        )
        private const val PREFS_NAME = "skybridge_peer_kem_keys"

        private fun createEncryptedPreferences(appContext: Context): SharedPreferences =
            EncryptedSharedPreferences.create(
                appContext,
                PREFS_NAME,
                MasterKey.Builder(appContext).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
    }
}
