package com.skybridge.compass.core.p2p

import android.content.SharedPreferences
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
data class TrustedPeerRecord(
    val deviceId: String,
    val name: String? = null,
    val protocolSigningAlgorithm: String? = null,
    val protocolPublicKeyFingerprint: String,
    val currentDeviceId: String = deviceId,
    val knownDeviceIds: List<String> = listOf(deviceId),
    val lifecycleState: TrustedPeerLifecycleState = TrustedPeerLifecycleState.ACTIVE
)

class TrustedPeerStore(
    private val prefs: SharedPreferences
) {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun loadAll(): List<TrustedPeerRecord> {
        val raw = prefs.getString(KEY_RECORDS_JSON, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString<List<TrustedPeerRecord>>(raw)
        }.getOrDefault(emptyList())
    }

    fun findByKnownDeviceId(deviceId: String): TrustedPeerRecord? {
        val normalized = normalizeDeviceId(deviceId) ?: return null
        return loadAll().firstOrNull { record ->
            record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                (record.deviceId == normalized ||
                    record.currentDeviceId == normalized ||
                    record.knownDeviceIds.contains(normalized))
        }
    }

    fun currentPathTrustRecord(fingerprint: String): TrustedPeerRecord? {
        val normalized = normalizeFingerprint(fingerprint) ?: return null
        return loadAll().firstOrNull { record ->
            record.lifecycleState == TrustedPeerLifecycleState.ACTIVE &&
                record.protocolPublicKeyFingerprint == normalized
        }
    }

    fun evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ): PairingTrustConflict? {
        val normalizedDeviceId = normalizeDeviceId(deviceId) ?: return null
        val normalizedFingerprint = normalizeFingerprint(protocolPublicKeyFingerprint) ?: return null

        val byFingerprint = loadAll().firstOrNull {
            it.protocolPublicKeyFingerprint == normalizedFingerprint
        }
        if (byFingerprint != null) {
            when (byFingerprint.lifecycleState) {
                TrustedPeerLifecycleState.ACTIVE -> {
                    val matchesDevice = byFingerprint.deviceId == normalizedDeviceId ||
                        byFingerprint.currentDeviceId == normalizedDeviceId ||
                        byFingerprint.knownDeviceIds.contains(normalizedDeviceId)
                    if (!matchesDevice) {
                        return PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED
                    }
                }

                TrustedPeerLifecycleState.REVERIFICATION_REQUIRED,
                TrustedPeerLifecycleState.QUARANTINED -> return PairingTrustConflict.QUARANTINED_IDENTITY

                TrustedPeerLifecycleState.REVOKED -> return PairingTrustConflict.REVOKED_IDENTITY
            }
        }

        val byDevice = findByKnownDeviceId(normalizedDeviceId)
        if (byDevice != null &&
            byDevice.protocolPublicKeyFingerprint != normalizedFingerprint
        ) {
            return when (byDevice.lifecycleState) {
                TrustedPeerLifecycleState.ACTIVE -> PairingTrustConflict.IDENTITY_CONFLICT
                TrustedPeerLifecycleState.REVERIFICATION_REQUIRED,
                TrustedPeerLifecycleState.QUARANTINED -> PairingTrustConflict.QUARANTINED_IDENTITY
                TrustedPeerLifecycleState.REVOKED -> PairingTrustConflict.REVOKED_IDENTITY
            }
        }

        return null
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
        val normalizedAliases = buildList {
            add(normalizedDeviceId)
            aliasIds.forEach { alias ->
                normalizeDeviceId(alias)?.let { add(it) }
            }
        }.distinct()

        val records = loadAll().toMutableList()
        val fingerprintIndex = records.indexOfFirst {
            it.protocolPublicKeyFingerprint == normalizedFingerprint
        }
        val deviceIndex = records.indexOfFirst {
            it.deviceId == normalizedDeviceId ||
                it.currentDeviceId == normalizedDeviceId ||
                normalizedAliases.any(it.knownDeviceIds::contains)
        }

        if (deviceIndex >= 0 && fingerprintIndex >= 0 && deviceIndex != fingerprintIndex) {
            return records[deviceIndex]
        }

        val targetIndex = fingerprintIndex.takeIf { it >= 0 } ?: deviceIndex
        val merged = if (targetIndex >= 0) {
            val existing = records[targetIndex]
            if (existing.protocolPublicKeyFingerprint != normalizedFingerprint) {
                return existing
            }
            existing.copy(
                deviceId = normalizedDeviceId,
                name = normalizeName(name) ?: existing.name,
                protocolSigningAlgorithm = protocolSigningAlgorithm?.ifBlank { null } ?: existing.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = normalizedFingerprint,
                currentDeviceId = normalizedDeviceId,
                knownDeviceIds = (existing.knownDeviceIds + normalizedAliases).distinct(),
                lifecycleState = TrustedPeerLifecycleState.ACTIVE
            )
        } else {
            TrustedPeerRecord(
                deviceId = normalizedDeviceId,
                name = normalizeName(name),
                protocolSigningAlgorithm = protocolSigningAlgorithm?.ifBlank { null },
                protocolPublicKeyFingerprint = normalizedFingerprint,
                currentDeviceId = normalizedDeviceId,
                knownDeviceIds = normalizedAliases
            )
        }

        if (targetIndex >= 0) {
            records[targetIndex] = merged
        } else {
            records += merged
        }
        saveAll(records)
        return merged
    }

    private fun saveAll(records: List<TrustedPeerRecord>) {
        prefs.edit()
            .putString(KEY_RECORDS_JSON, json.encodeToString(records))
            .apply()
    }

    private fun normalizeDeviceId(raw: String?): String? =
        raw?.trim()?.takeIf { it.isNotEmpty() }

    private fun normalizeFingerprint(raw: String?): String? =
        raw?.trim()?.lowercase()?.takeIf { candidate ->
            candidate.length == 64 && candidate.all { it in '0'..'9' || it in 'a'..'f' }
        }

    private fun normalizeName(raw: String?): String? =
        raw?.trim()?.takeIf { it.isNotEmpty() }

    companion object {
        private const val KEY_RECORDS_JSON = "trusted_peer_records_v1"
    }
}
