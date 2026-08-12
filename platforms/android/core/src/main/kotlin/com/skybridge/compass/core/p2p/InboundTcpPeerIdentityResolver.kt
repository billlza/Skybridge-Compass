package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PSoa

internal data class InboundTcpPeerIdentity(
    val peerId: String,
    val peerSigningFingerprint: String,
    val soaExtension: P2PSoa.SoaExtension,
    val remoteSoaPeerId: ByteArray
)

internal class InboundTcpPeerIdentityResolver(
    private val trustedPeerStore: TrustedPeerStore,
    private val localDeviceId: String
) {
    fun resolve(messageA: P2PHandshakeWire.MessageA): InboundTcpPeerIdentity {
        val soa = P2PSoa.decodeFromExtensions(messageA.extensionsRaw)
            ?: throw IllegalArgumentException("Inbound TCP responder requires SOA identity extension")
        val localPeerId = P2PSoa.canonicalPeerIdBytes(localDeviceId)
        require(soa.targetPeerId.contentEquals(localPeerId)) {
            "Inbound TCP SOA target does not match this device"
        }

        val observedFingerprint = P2PHandshakeWire.computePeerSigningFingerprint(messageA.identityPublicKeys)
        val matches = trustedPeerStore.loadAll()
            .asSequence()
            .filter { it.lifecycleState == TrustedPeerLifecycleState.ACTIVE }
            .filter { record -> record.matchesSoaPeerId(soa.initiatorPeerId) }
            .toList()

        require(matches.isNotEmpty()) { "Inbound TCP peer is not trusted for SOA identity" }
        require(matches.size == 1) { "Inbound TCP SOA identity resolved to multiple trusted peers" }

        val record = matches.single()
        require(record.protocolPublicKeyFingerprint.equals(observedFingerprint, ignoreCase = true)) {
            "Inbound TCP peer signing fingerprint mismatch"
        }

        return InboundTcpPeerIdentity(
            peerId = record.currentDeviceId.ifBlank { record.deviceId },
            peerSigningFingerprint = observedFingerprint,
            soaExtension = soa,
            remoteSoaPeerId = soa.initiatorPeerId.copyOf()
        )
    }

    private fun TrustedPeerRecord.matchesSoaPeerId(remoteSoaPeerId: ByteArray): Boolean =
        buildSet {
            add(deviceId)
            add(currentDeviceId)
            knownDeviceIds.forEach(::add)
        }.any { candidate ->
            P2PSoa.canonicalPeerIdBytes(candidate).contentEquals(remoteSoaPeerId)
        }
}
