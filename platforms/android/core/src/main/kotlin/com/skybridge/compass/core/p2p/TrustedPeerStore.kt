package com.skybridge.compass.core.p2p

import android.content.SharedPreferences
import androidx.core.content.edit
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
enum class TrustedPeerLifecycleState {
    ACTIVE,
    REVERIFICATION_REQUIRED,
    QUARANTINED,
    REVOKED
}

@Serializable
enum class TrustedPeerVerificationOrigin {
    AUTHENTICATED_PRODUCT_V1
}

@Serializable
data class TrustedPeerRecord(
    val deviceId: String,
    val name: String? = null,
    val protocolSigningAlgorithm: String? = null,
    val protocolPublicKeyFingerprint: String,
    val currentDeviceId: String = deviceId,
    val knownDeviceIds: List<String> = listOf(deviceId),
    val lifecycleState: TrustedPeerLifecycleState = TrustedPeerLifecycleState.ACTIVE,
    val verificationOrigin: TrustedPeerVerificationOrigin? = null
)

enum class TrustedPeerStoreIntegrityState {
    HEALTHY,
    CORRUPTED
}

/** Canonical identifier contract shared by formal LAN endpoint and trust-store boundaries. */
internal object TrustedPeerDeviceIdValidation {
    const val MAX_LENGTH = 256

    fun normalize(raw: String?): String? = raw?.trim()?.takeIf { value ->
        value.isNotEmpty() &&
            value.length <= MAX_LENGTH &&
            value.none { it.code < 0x20 || it.code == 0x7F || it == '=' }
    }

    fun isCanonical(raw: String): Boolean = normalize(raw) == raw
}

data class TrustedPeerStoreIntegrityStatus(
    val state: TrustedPeerStoreIntegrityState,
    val detail: String? = null
)

class TrustedPeerStoreCorruptionException(
    detail: String,
    cause: Throwable? = null
) : IllegalStateException("trusted peer store is corrupted: $detail", cause)

class TrustedPeerStorePersistenceException(
    detail: String,
    val conflict: PairingTrustConflict? = null,
    val rollbackConfirmed: Boolean = true,
    cause: Throwable? = null
) : IllegalStateException("trusted peer store rejected current-path authority: $detail", cause)

class TrustedPeerStore(
    private val prefs: SharedPreferences
) {
    internal data class ExistingAuthorityReadOnlyAdmission(
        val exactAuthority: TrustedPeerRecord?,
        val conflict: PairingTrustConflict?
    )
    private data class StoreSnapshot(
        val recordsJson: String?,
        val corruptionFlagPresent: Boolean,
        val corrupted: Boolean,
        val corruptionDetail: String?
    )

    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun loadAll(): List<TrustedPeerRecord> = synchronized(PROCESS_LOCK) {
        loadAllLocked()
    }

    private fun loadAllLocked(updateIntegrityMarkers: Boolean = true): List<TrustedPeerRecord> {
        val raw = readPersistenceStateLocked("read trusted-peer records") {
            prefs.getString(KEY_RECORDS_JSON, null)
        }
        if (raw == null) {
            if (updateIntegrityMarkers) markHealthyLocked()
            return emptyList()
        }
        val records = try {
            json.decodeFromString<List<TrustedPeerRecord>>(raw).also {
                validateRecords(it)
            }
        } catch (e: TrustedPeerStoreCorruptionException) {
            throw e
        } catch (t: Exception) {
            val detail = "invalid trusted-peer record set (${t.javaClass.simpleName})"
            if (!updateIntegrityMarkers) {
                throw TrustedPeerStoreCorruptionException(detail, t)
            }
            try {
                markCorruptedLocked(detail)
            } catch (persistenceFailure: TrustedPeerStorePersistenceException) {
                throw TrustedPeerStoreCorruptionException(
                    "$detail (integrity marker persistence failed; " +
                        "rollbackConfirmed=${persistenceFailure.rollbackConfirmed})",
                    persistenceFailure
                )
            }
            throw TrustedPeerStoreCorruptionException(detail, t)
        }
        if (updateIntegrityMarkers) markHealthyLocked()
        return records
    }

    fun integrityStatus(): TrustedPeerStoreIntegrityStatus = synchronized(PROCESS_LOCK) {
        val corrupted = prefs.getBoolean(KEY_CORRUPTED, false)
        return if (corrupted) {
            TrustedPeerStoreIntegrityStatus(
                state = TrustedPeerStoreIntegrityState.CORRUPTED,
                detail = prefs.getString(KEY_CORRUPTION_DETAIL, null)
            )
        } else {
            TrustedPeerStoreIntegrityStatus(TrustedPeerStoreIntegrityState.HEALTHY)
        }
    }

    fun findByKnownDeviceId(deviceId: String): TrustedPeerRecord? {
        return findRecordByKnownDeviceIdIncludingInactive(deviceId)
            ?.takeIf { it.lifecycleState == TrustedPeerLifecycleState.ACTIVE }
    }

    /**
     * Resolve a canonical record without applying its lifecycle state filter.
     *
     * Callers that consult a legacy trust representation must use this result to distinguish
     * "there is no canonical record yet" from "the canonical identity is blocked". Falling back to
     * legacy data for the latter would resurrect revoked or quarantined peers.
     */
    internal fun findRecordByKnownDeviceIdIncludingInactive(deviceId: String): TrustedPeerRecord? {
        val normalized = normalizeDeviceId(deviceId) ?: return null
        return synchronized(PROCESS_LOCK) {
            loadAllLocked().firstOrNull { record ->
                record.deviceId == normalized ||
                    record.currentDeviceId == normalized ||
                    record.knownDeviceIds.contains(normalized)
            }
        }
    }

    /**
     * Read one canonical authority without changing integrity markers or filtering lifecycle.
     *
     * Formal bootstrap callers need to distinguish a truly absent identity from an explicitly
     * revoked/quarantined one, while an existing corruption marker must remain fail-closed. The
     * marker check and record lookup intentionally share [PROCESS_LOCK] so a concurrent trust
     * mutation cannot change the classification between two reads.
     */
    internal fun findRecordByKnownDeviceIdIncludingInactiveReadOnly(
        deviceId: String
    ): TrustedPeerRecord? = synchronized(PROCESS_LOCK) {
        if (prefs.getBoolean(KEY_CORRUPTED, false)) {
            val detail = prefs.getString(KEY_CORRUPTION_DETAIL, null)
                ?: "existing corruption marker"
            throw TrustedPeerStoreCorruptionException(detail)
        }
        val normalized = normalizeDeviceId(deviceId) ?: return@synchronized null
        loadAllLocked(updateIntegrityMarkers = false).firstOrNull { record ->
            record.deviceId == normalized ||
                record.currentDeviceId == normalized ||
                record.knownDeviceIds.contains(normalized)
        }
    }

    internal fun findVerifiedRecordByKnownDeviceIdReadOnly(
        deviceId: String
    ): TrustedPeerRecord? = synchronized(PROCESS_LOCK) {
        if (prefs.getBoolean(KEY_CORRUPTED, false)) {
            val detail = prefs.getString(KEY_CORRUPTION_DETAIL, null)
                ?: "existing corruption marker"
            throw TrustedPeerStoreCorruptionException(detail)
        }
        val normalized = normalizeDeviceId(deviceId) ?: return@synchronized null
        loadAllLocked(updateIntegrityMarkers = false).firstOrNull { record ->
            val hasProductProvenance =
                record.verificationOrigin == TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1
            record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                hasProductProvenance &&
                (
                    record.deviceId == normalized ||
                        record.currentDeviceId == normalized ||
                        record.knownDeviceIds.contains(normalized)
                )
        }
    }

    /**
     * Resolve every identifier to one exact, active, product-authenticated authority without
     * repairing integrity markers or otherwise mutating persistence.
     *
     * This is the durable postcondition used before KEM material may be written. Returning a
     * record for only one alias would let a mixed or stale alias set escape the authority check.
     */
    internal fun findExactVerifiedAuthorityReadOnly(
        deviceIds: Collection<String>,
        protocolPublicKeyFingerprint: String
    ): TrustedPeerRecord? {
        val normalizedDeviceIds = deviceIds.map { normalizeDeviceId(it) ?: return null }.distinct()
        if (normalizedDeviceIds.isEmpty()) return null
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint) ?: return null
        return synchronized(PROCESS_LOCK) {
            if (prefs.getBoolean(KEY_CORRUPTED, false)) {
                val detail = prefs.getString(KEY_CORRUPTION_DETAIL, null)
                    ?: "existing corruption marker"
                throw TrustedPeerStoreCorruptionException(detail)
            }
            val records = loadAllLocked(updateIntegrityMarkers = false)
            val resolved = normalizedDeviceIds.map { deviceId ->
                records.firstOrNull { record -> record.resolves(deviceId) }
                    ?: return@synchronized null
            }
            val canonical = resolved.first()
            canonical.takeIf { record ->
                resolved.all { it === canonical || it == canonical } &&
                    record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                    record.verificationOrigin == TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1 &&
                    record.protocolPublicKeyFingerprint == normalizedFingerprint
            }
        }
    }

    /**
     * Atomically classify all aliases and resolve one exact existing product authority without
     * repairing or clearing integrity markers. A pre-existing marker is authoritative corruption
     * even when the record JSON remains parseable.
     */
    internal fun evaluateExactExistingAuthorityReadOnly(
        deviceIds: Collection<String>,
        protocolPublicKeyFingerprint: String
    ): ExistingAuthorityReadOnlyAdmission = synchronized(PROCESS_LOCK) {
        if (prefs.getBoolean(KEY_CORRUPTED, false)) {
            return@synchronized ExistingAuthorityReadOnlyAdmission(
                exactAuthority = null,
                conflict = PairingTrustConflict.TRUST_STORE_CORRUPTED
            )
        }
        val normalizedDeviceIds = buildList {
            for (rawDeviceId in deviceIds) {
                val normalized = normalizeDeviceId(rawDeviceId)
                    ?: return@synchronized ExistingAuthorityReadOnlyAdmission(
                        null,
                        PairingTrustConflict.IDENTITY_CONFLICT
                    )
                add(normalized)
            }
        }.distinct()
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint)
            ?: return@synchronized ExistingAuthorityReadOnlyAdmission(
                null,
                PairingTrustConflict.IDENTITY_CONFLICT
            )
        if (normalizedDeviceIds.isEmpty()) {
            return@synchronized ExistingAuthorityReadOnlyAdmission(
                null,
                PairingTrustConflict.IDENTITY_CONFLICT
            )
        }
        val records = try {
            loadAllLocked(updateIntegrityMarkers = false)
        } catch (_: TrustedPeerStoreCorruptionException) {
            return@synchronized ExistingAuthorityReadOnlyAdmission(
                null,
                PairingTrustConflict.TRUST_STORE_CORRUPTED
            )
        }
        val conflict = normalizedDeviceIds.asSequence()
            .mapNotNull { deviceId ->
                evaluateCurrentPathBinding(records, deviceId, normalizedFingerprint)
            }
            .firstOrNull()
        if (conflict != null) {
            return@synchronized ExistingAuthorityReadOnlyAdmission(null, conflict)
        }
        val resolved = normalizedDeviceIds.map { deviceId ->
            records.firstOrNull { record -> record.resolves(deviceId) }
                ?: return@synchronized ExistingAuthorityReadOnlyAdmission(null, null)
        }
        val canonical = resolved.first()
        val exact = canonical.takeIf { record ->
            resolved.all { it == canonical } &&
                record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                record.verificationOrigin == TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1 &&
                record.protocolPublicKeyFingerprint == normalizedFingerprint
        }
        ExistingAuthorityReadOnlyAdmission(exact, null)
    }

    fun currentPathTrustRecord(fingerprint: String): TrustedPeerRecord? {
        val normalized = normalizeFingerprint(fingerprint) ?: return null
        return synchronized(PROCESS_LOCK) {
            loadAllLocked().firstOrNull { record ->
                record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                    record.protocolPublicKeyFingerprint == normalized
            }
        }
    }

    fun evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ): PairingTrustConflict? {
        val normalizedDeviceId = normalizeDeviceId(deviceId) ?: return null
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint) ?: return null
        return synchronized(PROCESS_LOCK) {
            val records = try {
                loadAllLocked()
            } catch (_: TrustedPeerStoreCorruptionException) {
                return@synchronized PairingTrustConflict.TRUST_STORE_CORRUPTED
            }

            evaluateCurrentPathBinding(records, normalizedDeviceId, normalizedFingerprint)
        }
    }

    fun upsertCurrentPathAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        name: String? = null,
        protocolSigningAlgorithm: String? = null,
        aliasIds: Collection<String> = emptyList()
    ): TrustedPeerRecord? {
        val normalizedDeviceId = normalizeDeviceId(deviceId) ?: return null
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint) ?: return null
        val normalizedAliases = normalizeAliasIds(normalizedDeviceId, aliasIds) ?: return null
        return synchronized(PROCESS_LOCK) {
            val records = loadAllLocked().toMutableList()
            if (evaluateAliasBindings(records, normalizedAliases, normalizedFingerprint) != null) {
                return@synchronized null
            }
            val merged = mergeCurrentPathAuthority(
                records = records,
                normalizedDeviceId = normalizedDeviceId,
                normalizedFingerprint = normalizedFingerprint,
                name = name,
                protocolSigningAlgorithm = protocolSigningAlgorithm,
                normalizedAliases = normalizedAliases,
                verificationOrigin = null
            ) ?: return@synchronized null
            if (merged.lifecycleState != TrustedPeerLifecycleState.ACTIVE) {
                // Preserve the observable blocked record without rewriting or reactivating it.
                return@synchronized merged
            }
            saveAllLocked(records)
            merged
        }
    }

    fun upsertVerifiedCurrentPathAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        name: String? = null,
        protocolSigningAlgorithm: String? = null,
        aliasIds: Collection<String> = emptyList()
    ): TrustedPeerRecord = upsertVerifiedCurrentPathAuthority(
        deviceId = deviceId,
        protocolPublicKeyFingerprint = protocolPublicKeyFingerprint,
        name = name,
        protocolSigningAlgorithm = protocolSigningAlgorithm,
        aliasIds = aliasIds,
        allowExplicitDeviceIdMigration = false
    )

    /**
     * Persist an authority after an explicit TRUST_ALWAYS decision for this authenticated
     * handshake attempt. Unlike the general verified upsert, this narrowly permits adding a new
     * identifier to an existing record with the same observed fingerprint. Cross-owner aliases,
     * rotated fingerprints, and inactive records remain conflicts.
     */
    internal fun upsertExplicitlyApprovedCurrentPathAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        name: String? = null,
        protocolSigningAlgorithm: String? = null,
        aliasIds: Collection<String> = emptyList()
    ): TrustedPeerRecord = upsertVerifiedCurrentPathAuthority(
        deviceId = deviceId,
        protocolPublicKeyFingerprint = protocolPublicKeyFingerprint,
        name = name,
        protocolSigningAlgorithm = protocolSigningAlgorithm,
        aliasIds = aliasIds,
        allowExplicitDeviceIdMigration = true
    )

    private fun upsertVerifiedCurrentPathAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        name: String?,
        protocolSigningAlgorithm: String?,
        aliasIds: Collection<String>,
        allowExplicitDeviceIdMigration: Boolean
    ): TrustedPeerRecord {
        val normalizedDeviceId = normalizeDeviceId(deviceId)
            ?: throw TrustedPeerStorePersistenceException("invalid device id")
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint)
            ?: throw TrustedPeerStorePersistenceException("invalid protocol fingerprint")
        val normalizedAliases = normalizeAliasIds(normalizedDeviceId, aliasIds)
            ?: throw TrustedPeerStorePersistenceException("invalid alias device id")
        return synchronized(PROCESS_LOCK) {
            val records = loadAllLocked().toMutableList()
            evaluateCurrentPathBinding(records, normalizedDeviceId, normalizedFingerprint)?.let { conflict ->
                if (!(allowExplicitDeviceIdMigration &&
                        conflict == PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED)
                ) {
                    throw TrustedPeerStorePersistenceException(
                        detail = "current-path binding conflict: $conflict",
                        conflict = conflict
                    )
                }
            }
            evaluateAliasBindings(records, normalizedAliases, normalizedFingerprint)?.let { conflict ->
                throw TrustedPeerStorePersistenceException(
                    detail = "alias binding conflict: $conflict",
                    conflict = conflict
                )
            }

            val record = mergeCurrentPathAuthority(
                records = records,
                normalizedDeviceId = normalizedDeviceId,
                normalizedFingerprint = normalizedFingerprint,
                name = name,
                protocolSigningAlgorithm = protocolSigningAlgorithm,
                normalizedAliases = normalizedAliases,
                verificationOrigin = TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1
            ) ?: throw TrustedPeerStorePersistenceException("upsert returned no record")

            if (record.lifecycleState != TrustedPeerLifecycleState.ACTIVE) {
                throw TrustedPeerStorePersistenceException("record is not active: ${record.lifecycleState}")
            }
            if (record.protocolPublicKeyFingerprint != normalizedFingerprint) {
                throw TrustedPeerStorePersistenceException("stored fingerprint differs from verified fingerprint")
            }
            val matchesDevice = record.deviceId == normalizedDeviceId ||
                record.currentDeviceId == normalizedDeviceId ||
                record.knownDeviceIds.contains(normalizedDeviceId)
            if (!matchesDevice) {
                throw TrustedPeerStorePersistenceException("stored record does not resolve the verified device id")
            }

            saveAllLocked(records)
            record
        }
    }

    fun corruptionConflictOrNull(): PairingTrustConflict? =
        try {
            loadAll()
            null
        } catch (_: TrustedPeerStoreCorruptionException) {
            PairingTrustConflict.TRUST_STORE_CORRUPTED
        }

    private fun lifecycleConflict(state: TrustedPeerLifecycleState): PairingTrustConflict? =
        when (state) {
            TrustedPeerLifecycleState.ACTIVE -> null
            TrustedPeerLifecycleState.REVERIFICATION_REQUIRED,
            TrustedPeerLifecycleState.QUARANTINED -> PairingTrustConflict.QUARANTINED_IDENTITY
            TrustedPeerLifecycleState.REVOKED -> PairingTrustConflict.REVOKED_IDENTITY
        }

    private fun mergeCurrentPathAuthority(
        records: MutableList<TrustedPeerRecord>,
        normalizedDeviceId: String,
        normalizedFingerprint: String,
        name: String?,
        protocolSigningAlgorithm: String?,
        normalizedAliases: List<String>,
        verificationOrigin: TrustedPeerVerificationOrigin?
    ): TrustedPeerRecord? {
        val fingerprintIndex = records.indexOfFirst {
            it.protocolPublicKeyFingerprint == normalizedFingerprint
        }
        val deviceIndex = records.indexOfFirst {
            it.deviceId == normalizedDeviceId ||
                it.currentDeviceId == normalizedDeviceId ||
                it.knownDeviceIds.contains(normalizedDeviceId)
        }

        if (deviceIndex >= 0 && fingerprintIndex >= 0 && deviceIndex != fingerprintIndex) {
            return records[deviceIndex]
        }

        val targetIndex = fingerprintIndex.takeIf { it >= 0 } ?: deviceIndex
        val merged = if (targetIndex >= 0) {
            val existing = records[targetIndex]
            if (existing.lifecycleState != TrustedPeerLifecycleState.ACTIVE) {
                return existing
            }
            if (existing.protocolPublicKeyFingerprint != normalizedFingerprint) {
                return existing
            }
            existing.copy(
                deviceId = normalizedDeviceId,
                name = normalizeName(name) ?: existing.name,
                protocolSigningAlgorithm = normalizeAlgorithm(protocolSigningAlgorithm) ?: existing.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = normalizedFingerprint,
                currentDeviceId = normalizedDeviceId,
                knownDeviceIds = (existing.knownDeviceIds + normalizedAliases).distinct(),
                verificationOrigin = verificationOrigin ?: existing.verificationOrigin
            )
        } else {
            TrustedPeerRecord(
                deviceId = normalizedDeviceId,
                name = normalizeName(name),
                protocolSigningAlgorithm = normalizeAlgorithm(protocolSigningAlgorithm),
                protocolPublicKeyFingerprint = normalizedFingerprint,
                currentDeviceId = normalizedDeviceId,
                knownDeviceIds = normalizedAliases,
                verificationOrigin = verificationOrigin
            )
        }

        if (targetIndex >= 0) {
            records[targetIndex] = merged
        } else {
            records += merged
        }
        return merged
    }

    private fun saveAllLocked(records: List<TrustedPeerRecord>) {
        try {
            validateRecords(records)
        } catch (error: IllegalArgumentException) {
            throw TrustedPeerStorePersistenceException(
                "refusing invalid trusted-peer record set (${error.message ?: "validation failed"})"
            )
        }
        val previous = captureSnapshotLocked("commit trusted-peer records")
        val encoded = json.encodeToString(records)
        val expected = StoreSnapshot(
            recordsJson = encoded,
            corruptionFlagPresent = false,
            corrupted = false,
            corruptionDetail = null
        )
        commitMutationLocked(
            previous = previous,
            expected = expected,
            expectedRecords = records,
            operation = "commit trusted-peer records"
        ) { editor ->
            editor.putString(KEY_RECORDS_JSON, encoded)
                .remove(KEY_CORRUPTED)
                .remove(KEY_CORRUPTION_DETAIL)
        }
    }

    private fun markHealthyLocked() {
        val previous = captureSnapshotLocked("clear trusted-peer integrity marker")
        if (!previous.corruptionFlagPresent && previous.corruptionDetail == null) return
        commitMutationLocked(
            previous = previous,
            expected = previous.copy(
                corruptionFlagPresent = false,
                corrupted = false,
                corruptionDetail = null
            ),
            operation = "clear trusted-peer integrity marker"
        ) { editor ->
            editor.remove(KEY_CORRUPTED)
                .remove(KEY_CORRUPTION_DETAIL)
        }
    }

    private fun markCorruptedLocked(detail: String) {
        val previous = captureSnapshotLocked("persist trusted-peer corruption marker")
        val storedDetail = detail.take(MAX_CORRUPTION_DETAIL_LENGTH)
        commitMutationLocked(
            previous = previous,
            expected = previous.copy(
                corruptionFlagPresent = true,
                corrupted = true,
                corruptionDetail = storedDetail
            ),
            operation = "persist trusted-peer corruption marker"
        ) { editor ->
            editor.putBoolean(KEY_CORRUPTED, true)
                .putString(KEY_CORRUPTION_DETAIL, storedDetail)
        }
    }

    private fun snapshotLocked(): StoreSnapshot = StoreSnapshot(
        recordsJson = prefs.getString(KEY_RECORDS_JSON, null),
        corruptionFlagPresent = prefs.contains(KEY_CORRUPTED),
        corrupted = prefs.getBoolean(KEY_CORRUPTED, false),
        corruptionDetail = prefs.getString(KEY_CORRUPTION_DETAIL, null)
    )

    private fun captureSnapshotLocked(operation: String): StoreSnapshot =
        readPersistenceStateLocked("snapshot trusted-peer state before $operation") {
            snapshotLocked()
        }

    private inline fun <T> readPersistenceStateLocked(
        operation: String,
        read: () -> T
    ): T = try {
        read()
    } catch (error: CancellationException) {
        throw error
    } catch (error: RuntimeException) {
        throw TrustedPeerStorePersistenceException(
            detail = "failed to $operation",
            rollbackConfirmed = false,
            cause = error
        )
    }

    private fun restoreSnapshotLocked(snapshot: StoreSnapshot): Boolean {
        try {
            prefs.edit(commit = true) {
                writeSnapshot(this, snapshot)
            }
        } catch (_: RuntimeException) {
            // A SharedPreferences implementation may throw after a partial write. Confirmation is
            // based solely on the strict post-read below, never on the return value or exception.
        }
        return snapshotMatchesLocked(snapshot, expectedRecords = null)
    }

    private fun writeSnapshot(editor: SharedPreferences.Editor, snapshot: StoreSnapshot) {
        if (snapshot.recordsJson == null) {
            editor.remove(KEY_RECORDS_JSON)
        } else {
            editor.putString(KEY_RECORDS_JSON, snapshot.recordsJson)
        }
        if (snapshot.corruptionFlagPresent) {
            editor.putBoolean(KEY_CORRUPTED, snapshot.corrupted)
        } else {
            editor.remove(KEY_CORRUPTED)
        }
        if (snapshot.corruptionDetail == null) {
            editor.remove(KEY_CORRUPTION_DETAIL)
        } else {
            editor.putString(KEY_CORRUPTION_DETAIL, snapshot.corruptionDetail)
        }
    }

    private inline fun commitMutationLocked(
        previous: StoreSnapshot,
        expected: StoreSnapshot,
        expectedRecords: List<TrustedPeerRecord>? = null,
        operation: String,
        mutate: (SharedPreferences.Editor) -> Unit
    ) {
        var commitFailure: RuntimeException? = null
        val committed = try {
            val editor = prefs.edit()
            mutate(editor)
            if (editor.commit()) true else false
        } catch (error: RuntimeException) {
            commitFailure = error
            false
        }
        if (committed && snapshotMatchesLocked(expected, expectedRecords)) return

        val rollbackConfirmed = restoreSnapshotLocked(previous)
        val detail = if (rollbackConfirmed) {
            "$operation did not durably persist the exact expected state; previous snapshot restored"
        } else {
            "$operation did not durably persist the exact expected state and snapshot rollback could not be confirmed"
        }
        throw TrustedPeerStorePersistenceException(
            detail = detail,
            rollbackConfirmed = rollbackConfirmed,
            cause = commitFailure
        )
    }

    private fun snapshotMatchesLocked(
        expected: StoreSnapshot,
        expectedRecords: List<TrustedPeerRecord>?
    ): Boolean = try {
        val actual = snapshotLocked()
        if (actual != expected) return false
        if (expectedRecords == null) return true
        val raw = actual.recordsJson ?: return false
        val decoded = json.decodeFromString<List<TrustedPeerRecord>>(raw)
        validateRecords(decoded)
        decoded == expectedRecords && json.encodeToString(decoded) == raw
    } catch (_: RuntimeException) {
        false
    }

    private fun evaluateCurrentPathBinding(
        records: List<TrustedPeerRecord>,
        normalizedDeviceId: String,
        normalizedFingerprint: String
    ): PairingTrustConflict? {
        val byDevice = records.firstOrNull { record ->
            record.deviceId == normalizedDeviceId ||
                record.currentDeviceId == normalizedDeviceId ||
                record.knownDeviceIds.contains(normalizedDeviceId)
        }
        if (byDevice != null) {
            lifecycleConflict(byDevice.lifecycleState)?.let { return it }
            if (byDevice.protocolPublicKeyFingerprint != normalizedFingerprint) {
                return PairingTrustConflict.IDENTITY_CONFLICT
            }
        }

        val byFingerprint = records.firstOrNull {
            it.protocolPublicKeyFingerprint == normalizedFingerprint
        }
        if (byFingerprint != null) {
            lifecycleConflict(byFingerprint.lifecycleState)?.let { return it }
            val matchesDevice = byFingerprint.deviceId == normalizedDeviceId ||
                byFingerprint.currentDeviceId == normalizedDeviceId ||
                byFingerprint.knownDeviceIds.contains(normalizedDeviceId)
            if (!matchesDevice) {
                return PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED
            }
        }
        return null
    }

    private fun TrustedPeerRecord.resolves(normalizedDeviceId: String): Boolean =
        deviceId == normalizedDeviceId ||
            currentDeviceId == normalizedDeviceId ||
            knownDeviceIds.contains(normalizedDeviceId)

    private fun evaluateAliasBindings(
        records: List<TrustedPeerRecord>,
        normalizedAliases: List<String>,
        normalizedFingerprint: String
    ): PairingTrustConflict? {
        normalizedAliases.forEach { alias ->
            val owner = records.firstOrNull { record ->
                record.deviceId == alias ||
                    record.currentDeviceId == alias ||
                    record.knownDeviceIds.contains(alias)
            } ?: return@forEach
            if (owner.protocolPublicKeyFingerprint != normalizedFingerprint) {
                return PairingTrustConflict.IDENTITY_CONFLICT
            }
        }
        return null
    }

    private fun normalizeAliasIds(
        normalizedDeviceId: String,
        aliasIds: Collection<String>
    ): List<String>? {
        val aliases = ArrayList<String>(aliasIds.size + 1)
        aliases += normalizedDeviceId
        aliasIds.forEach { alias ->
            aliases += normalizeDeviceId(alias) ?: return null
        }
        return aliases.distinct()
    }

    private fun validateRecords(records: List<TrustedPeerRecord>) {
        val identifierOwners = HashMap<String, Int>()
        val fingerprintOwners = HashMap<String, Int>()
        records.forEachIndexed { index, record ->
            require(normalizeDeviceId(record.deviceId) == record.deviceId) { "invalid device id" }
            require(normalizeDeviceId(record.currentDeviceId) == record.currentDeviceId) { "invalid current device id" }
            require(record.knownDeviceIds.isNotEmpty()) { "known device ids are empty" }
            require(record.knownDeviceIds.distinct().size == record.knownDeviceIds.size) {
                "known device ids contain duplicates"
            }
            record.knownDeviceIds.forEach { knownId ->
                require(normalizeDeviceId(knownId) == knownId) { "invalid known device id" }
                val previous = identifierOwners.put(knownId, index)
                require(previous == null || previous == index) { "device id resolves to multiple records" }
            }
            listOf(record.deviceId, record.currentDeviceId).forEach { id ->
                val previous = identifierOwners.put(id, index)
                require(previous == null || previous == index) { "device id resolves to multiple records" }
            }
            require(normalizeFingerprint(record.protocolPublicKeyFingerprint) == record.protocolPublicKeyFingerprint) {
                "invalid protocol fingerprint"
            }
            val previousFingerprint = fingerprintOwners.put(record.protocolPublicKeyFingerprint, index)
            require(previousFingerprint == null || previousFingerprint == index) {
                "protocol fingerprint resolves to multiple records"
            }
            require(record.name == null || normalizeName(record.name) == record.name) { "invalid peer name" }
            require(record.protocolSigningAlgorithm == null ||
                normalizeAlgorithm(record.protocolSigningAlgorithm) == record.protocolSigningAlgorithm
            ) { "invalid protocol signing algorithm" }
        }
    }

    private fun normalizeDeviceId(raw: String?): String? =
        TrustedPeerDeviceIdValidation.normalize(raw)

    private fun normalizeFingerprint(raw: String?): String? =
        raw?.trim()?.lowercase()?.takeIf { candidate ->
            candidate.length == 64 && candidate.all { it in '0'..'9' || it in 'a'..'f' }
        }

    private fun normalizeName(raw: String?): String? =
        raw?.trim()?.takeIf { value ->
            value.isNotEmpty() &&
                value.length <= MAX_NAME_LENGTH &&
                value.none { it.code < 0x20 || it.code == 0x7F }
        }

    private fun normalizeAlgorithm(raw: String?): String? =
        raw?.trim()?.takeIf { value ->
            value.isNotEmpty() &&
                value.length <= MAX_ALGORITHM_LENGTH &&
                value.none { it.code < 0x20 || it.code == 0x7F || it == '=' }
        }

    companion object {
        // Multiple LocalP2PIdentity/EncryptedSharedPreferences wrappers can target the same backing
        // file. A process-wide lock keeps evaluate + merge + commit atomic across those wrappers.
        private val PROCESS_LOCK = Any()
        internal const val KEY_RECORDS_JSON = "trusted_peer_records_v1"
        internal const val KEY_CORRUPTED = "trusted_peer_records_corrupted_v1"
        internal const val KEY_CORRUPTION_DETAIL = "trusted_peer_records_corruption_detail_v1"
        private const val MAX_CORRUPTION_DETAIL_LENGTH = 240
        private const val MAX_NAME_LENGTH = 256
        private const val MAX_ALGORITHM_LENGTH = 64
    }
}
