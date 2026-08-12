package com.skybridge.compass.core.p2p

import android.content.SharedPreferences
import com.skybridge.compass.shared.p2p.P2PCryptoCapabilities
import com.skybridge.compass.shared.p2p.P2PHandshakePolicy
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import com.skybridge.compass.shared.p2p.P2PSoa
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class InboundTcpPeerIdentityResolverTest {
    private val localDeviceId = "12345678-1234-1234-1234-1234567890ab"
    private val peerDeviceId = "87654321-4321-4321-4321-ba0987654321"
    private val peerAliasId = "mac-alias-1"
    private val peerIdentity = identity(ByteArray(32) { 0x11 })
    private val peerFingerprint = P2PHandshakeWire.computePeerSigningFingerprint(peerIdentity)
    private val json = Json { explicitNulls = false }

    @Test
    fun resolvesActiveTrustedPeerFromSignedMessageASoaAndCanonicalFingerprint() {
        val prefs = InMemorySharedPreferences()
        TrustedPeerStore(prefs).upsertCurrentPathAuthority(
            deviceId = peerDeviceId,
            protocolPublicKeyFingerprint = peerFingerprint,
            name = "Mac",
            protocolSigningAlgorithm = "Ed25519",
            aliasIds = listOf(peerAliasId)
        )
        val messageA = messageA(
            identity = peerIdentity,
            soa = soa(initiatorDeviceId = peerAliasId, targetDeviceId = localDeviceId)
        )

        val resolved = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(prefs),
            localDeviceId = localDeviceId
        ).resolve(messageA)

        assertEquals(peerDeviceId, resolved.peerId)
        assertEquals(peerFingerprint, resolved.peerSigningFingerprint)
    }

    @Test
    fun rejectsMessageAWithoutSoa() {
        val resolver = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(InMemorySharedPreferences()),
            localDeviceId = localDeviceId
        )

        val error = assertThrows(IllegalArgumentException::class.java) {
            resolver.resolve(messageA(identity = peerIdentity, soa = null))
        }

        assertEquals("Inbound TCP responder requires SOA identity extension", error.message)
    }

    @Test
    fun rejectsSoaTargetForDifferentDevice() {
        val prefs = InMemorySharedPreferences()
        TrustedPeerStore(prefs).upsertCurrentPathAuthority(
            deviceId = peerDeviceId,
            protocolPublicKeyFingerprint = peerFingerprint
        )
        val resolver = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(prefs),
            localDeviceId = localDeviceId
        )

        val error = assertThrows(IllegalArgumentException::class.java) {
            resolver.resolve(
                messageA(
                    identity = peerIdentity,
                    soa = soa(
                        initiatorDeviceId = peerDeviceId,
                        targetDeviceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    )
                )
            )
        }

        assertEquals("Inbound TCP SOA target does not match this device", error.message)
    }

    @Test
    fun rejectsFingerprintMismatchForMatchedSoaRecord() {
        val prefs = InMemorySharedPreferences()
        TrustedPeerStore(prefs).upsertCurrentPathAuthority(
            deviceId = peerDeviceId,
            protocolPublicKeyFingerprint = "ab".repeat(32)
        )
        val resolver = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(prefs),
            localDeviceId = localDeviceId
        )

        val error = assertThrows(IllegalArgumentException::class.java) {
            resolver.resolve(
                messageA(
                    identity = peerIdentity,
                    soa = soa(initiatorDeviceId = peerDeviceId, targetDeviceId = localDeviceId)
                )
            )
        }

        assertEquals("Inbound TCP peer signing fingerprint mismatch", error.message)
    }

    @Test
    fun rejectsNonActiveTrustedRecord() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = peerDeviceId,
                    protocolPublicKeyFingerprint = peerFingerprint,
                    lifecycleState = TrustedPeerLifecycleState.REVOKED
                )
            )
        )
        val resolver = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(prefs),
            localDeviceId = localDeviceId
        )

        val error = assertThrows(IllegalArgumentException::class.java) {
            resolver.resolve(
                messageA(
                    identity = peerIdentity,
                    soa = soa(initiatorDeviceId = peerDeviceId, targetDeviceId = localDeviceId)
                )
            )
        }

        assertEquals("Inbound TCP peer is not trusted for SOA identity", error.message)
    }

    @Test
    fun corruptTrustStoreFailsClosed() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()
        val resolver = InboundTcpPeerIdentityResolver(
            trustedPeerStore = TrustedPeerStore(prefs),
            localDeviceId = localDeviceId
        )

        assertThrows(TrustedPeerStoreCorruptionException::class.java) {
            resolver.resolve(
                messageA(
                    identity = peerIdentity,
                    soa = soa(initiatorDeviceId = peerDeviceId, targetDeviceId = localDeviceId)
                )
            )
        }
    }

    private fun messageA(
        identity: P2PIdentityPublicKeys.Keys,
        soa: P2PSoa.SoaExtension?
    ): P2PHandshakeWire.MessageA =
        P2PHandshakeWire.MessageA(
            supportedSuites = emptyList(),
            keyShares = emptyList(),
            clientNonce = ByteArray(32),
            capabilities = P2PCryptoCapabilities(
                supportedKEM = emptyList(),
                supportedSignature = emptyList(),
                supportedAuthProfiles = emptyList(),
                supportedAEAD = emptyList(),
                pqcAvailable = false,
                platformVersion = "test",
                providerTypeRaw = "test"
            ),
            policy = P2PHandshakePolicy.DEFAULT,
            identityPublicKeys = identity,
            extensionsRaw = soa?.encodeTlv() ?: ByteArray(0),
            signature = ByteArray(64)
        )

    private fun soa(initiatorDeviceId: String, targetDeviceId: String): P2PSoa.SoaExtension =
        P2PSoa.SoaExtension(
            version = P2PSoa.VERSION,
            initiatorPeerId = P2PSoa.canonicalPeerIdBytes(initiatorDeviceId),
            targetPeerId = P2PSoa.canonicalPeerIdBytes(targetDeviceId),
            attemptId = ByteArray(P2PSoa.ATTEMPT_ID_LEN) { 0x44 }
        )

    private fun identity(publicKey: ByteArray): P2PIdentityPublicKeys.Keys =
        P2PIdentityPublicKeys.Keys(
            protocolPublicKey = publicKey,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
        )

    private fun writeRecords(prefs: SharedPreferences, records: List<TrustedPeerRecord>) {
        prefs.edit()
            .putString(
                TrustedPeerStore.KEY_RECORDS_JSON,
                json.encodeToString(records)
            )
            .apply()
    }

    private class InMemorySharedPreferences : SharedPreferences {
        private val map = HashMap<String, Any?>()

        override fun getString(key: String?, defValue: String?): String? =
            (map[key] as? String) ?: defValue

        override fun edit(): SharedPreferences.Editor = Editor()

        override fun getAll(): MutableMap<String, *> = map.toMutableMap()
        override fun getStringSet(key: String?, defValues: MutableSet<String>?) = defValues
        override fun getInt(key: String?, defValue: Int) = (map[key] as? Int) ?: defValue
        override fun getLong(key: String?, defValue: Long) = (map[key] as? Long) ?: defValue
        override fun getFloat(key: String?, defValue: Float) = (map[key] as? Float) ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean) = (map[key] as? Boolean) ?: defValue
        override fun contains(key: String?) = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()

            override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }

            override fun putStringSet(key: String?, values: MutableSet<String>?) = this
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun remove(key: String?): SharedPreferences.Editor { if (key != null) removals.add(key); return this }
            override fun clear(): SharedPreferences.Editor { pending.clear(); removals.addAll(map.keys); return this }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                removals.forEach { map.remove(it) }
                map.putAll(pending)
            }
        }
    }
}
