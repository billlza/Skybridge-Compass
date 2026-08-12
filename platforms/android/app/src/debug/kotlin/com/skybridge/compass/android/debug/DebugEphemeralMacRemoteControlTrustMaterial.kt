package com.skybridge.compass.android.debug

import com.skybridge.compass.android.remote.mac.MacRemoteControlTrustContext
import com.skybridge.compass.android.remote.mac.MacRemoteControlTrustMode
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.PeerKemPublicKeySource
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.util.Locale

/**
 * Activity-scoped remote trust material for diagnostic LAN smoke runs.
 *
 * Nothing in this class has an Android storage dependency. Dropping the activity and its client
 * drops every injected KEM key, observed signing fingerprint, and fallback timestamp.
 */
internal class DebugEphemeralMacRemoteControlTrustMaterial {
    private val lock = Any()
    private val peerKemKeys = LinkedHashMap<String, PeerKemKeyStore.PeerKemPublicKeys>()
    private val peerSigningFingerprints = LinkedHashMap<String, String>()
    private val fallbackTimestamps = LinkedHashMap<String, Long>()

    val clientTrustContext = MacRemoteControlTrustContext(
        peerKemPublicKeys = PeerKemPublicKeySource(::loadPeerKemKeys),
        peerSigningFingerprints = object : P2PHandshakeWire.TrustStore {
            override fun loadPeerSigningFingerprint(peerId: String): String? = synchronized(lock) {
                peerSigningFingerprints[validatedPeerId(peerId)]
            }

            override fun savePeerSigningFingerprint(
                peerId: String,
                peerSigningFingerprint: String
            ) {
                val normalizedFingerprint = peerSigningFingerprint
                    .trim()
                    .lowercase(Locale.ROOT)
                    .takeIf(String::isNotEmpty)
                    ?: throw IllegalArgumentException("peer signing fingerprint is required")
                synchronized(lock) {
                    peerSigningFingerprints[validatedPeerId(peerId)] = normalizedFingerprint
                }
            }
        },
        fallbackCooldowns = object : P2PHandshakeWire.FallbackCooldownStore {
            override fun loadLastClassicFallbackAtMillis(peerId: String): Long? = synchronized(lock) {
                fallbackTimestamps[validatedPeerId(peerId)]
            }

            override fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long) {
                require(unixTimeMillis >= 0L) { "classic fallback timestamp must be non-negative" }
                synchronized(lock) {
                    fallbackTimestamps[validatedPeerId(peerId)] = unixTimeMillis
                }
            }
        },
        mode = MacRemoteControlTrustMode.EPHEMERAL_DIAGNOSTIC
    )

    fun seedPeerKemKeys(
        peerId: String,
        mlKem768PublicKey: ByteArray?,
        xWingPublicKey: ByteArray?
    ) {
        require(mlKem768PublicKey != null || xWingPublicKey != null) {
            "at least one diagnostic peer KEM public key is required"
        }
        mlKem768PublicKey?.let {
            require(it.size == AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE) {
                "invalid diagnostic ML-KEM-768 public key length"
            }
        }
        xWingPublicKey?.let {
            require(it.size == P2PXWingKem.XWING_PUBLIC_KEY_SIZE) {
                "invalid diagnostic X-Wing public key length"
            }
        }
        synchronized(lock) {
            peerKemKeys[validatedPeerId(peerId)] = PeerKemKeyStore.PeerKemPublicKeys(
                mlKem768PublicKey = mlKem768PublicKey?.copyOf(),
                xWingPublicKey = xWingPublicKey?.copyOf()
            )
        }
    }

    private fun loadPeerKemKeys(peerId: String): PeerKemKeyStore.PeerKemPublicKeys =
        synchronized(lock) {
            peerKemKeys[validatedPeerId(peerId)]?.deepCopy()
                ?: PeerKemKeyStore.PeerKemPublicKeys()
        }

    private fun PeerKemKeyStore.PeerKemPublicKeys.deepCopy(): PeerKemKeyStore.PeerKemPublicKeys =
        PeerKemKeyStore.PeerKemPublicKeys(
            qPeriaptPublicKey = qPeriaptPublicKey?.copyOf(),
            xWingPublicKey = xWingPublicKey?.copyOf(),
            mlKem768PublicKey = mlKem768PublicKey?.copyOf()
        )

    private fun validatedPeerId(peerId: String): String =
        peerId.trim().takeIf(String::isNotEmpty)
            ?: throw IllegalArgumentException("peer id is required")
}
