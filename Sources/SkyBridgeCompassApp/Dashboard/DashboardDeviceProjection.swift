import Foundation
import SkyBridgeCore
import SkyBridgeProtocolCore

/// A view of current discovery observations, not an identity or route store.
/// Keep the selected observation intact so presentation and connection use the
/// same protocol identity, address, platform metadata, and advertised endpoints.
enum DashboardDeviceProjection {
    static func project(
        currentPeers: [DiscoveredDevice],
        connectedUSBPeers: [DiscoveredDevice],
        supplementary: [DiscoveredDevice],
        compatibilityMode: Bool
    ) -> [DiscoveredDevice] {
        let peers = (currentPeers + connectedUSBPeers).filter {
            !$0.isLocalDevice && isSkyBridgePeer($0)
        }
        let auxiliary = compatibilityMode ? supplementary.filter {
            !$0.isLocalDevice && !$0.isSkyBridgePeer && !isSkyBridgePeer($0)
        } : []

        // Current discovery takes precedence over an additional USB observation.
        // Never retain a previous projection or borrow fields from a cached row.
        return (peers + auxiliary).reduce(into: []) { result, candidate in
            if !result.contains(where: { sameObservationOrAuthority($0, candidate) }) {
                result.append(candidate)
            }
        }
    }

    static func isSkyBridgePeer(_ device: DiscoveredDevice) -> Bool {
        device.services.contains { $0.hasPrefix("_skybridge") }
    }

    /// Presentation only. The caller supplies a current authenticated connection;
    /// an unrelated discovery record cannot borrow its connected state by name/IP.
    static func connectedTransport(for device: DiscoveredDevice, authenticatedPeerId: String,
        authenticatedFingerprint: String?, transport: P2PConnection.ControlTransport) -> P2PConnection.ControlTransport? {
        guard let selectedID = PeerIdentityFusionPolicy.normalizedStableDeviceId(device.deviceId),
              let ownerID = PeerIdentityFusionPolicy.normalizedStableDeviceId(authenticatedPeerId),
              selectedID == ownerID,
              let selectedPin = BonjourInteropProtocolContract.normalizedPubKeyFingerprint(device.pubKeyFP),
              let ownerPin = BonjourInteropProtocolContract.normalizedPubKeyFingerprint(authenticatedFingerprint),
              selectedPin == ownerPin else { return nil }
        return transport
    }

    static func filter(
        _ devices: [DiscoveredDevice],
        searchText: String,
        sortBySignalStrength: Bool
    ) -> [DiscoveredDevice] {
        let query = searchText.lowercased()
        let filtered = query.isEmpty ? devices : devices.filter { device in
            device.name.lowercased().contains(query)
                || device.ipv4?.lowercased().contains(query) == true
                || device.ipv6?.lowercased().contains(query) == true
                || device.services.contains { $0.lowercased().contains(query) }
        }
        guard sortBySignalStrength else { return filtered }
        return filtered.sorted { lhs, rhs in
            let left = lhs.signalStrength ?? 0
            let right = rhs.signalStrength ?? 0
            if left != right { return left > right }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private static func sameObservationOrAuthority(
        _ lhs: DiscoveredDevice,
        _ rhs: DiscoveredDevice
    ) -> Bool {
        let left = identityEvidence(lhs)
        let right = identityEvidence(rhs)
        guard !PeerIdentityFusionPolicy.identitiesContradict(left, right) else { return false }
        // Equal complete evidence also avoids bridging conflicting authorities
        // through a third observation that has only a device ID or fingerprint.
        // Partial observations stay distinct rather than filling missing identity.
        guard left == right else { return false }
        return lhs.id == rhs.id || left.hasProtocolIdentity
    }

    private static func identityEvidence(
        _ device: DiscoveredDevice
    ) -> PeerIdentityFusionPolicy.IdentityEvidence {
        .init(
            stableDeviceId: PeerIdentityFusionPolicy.normalizedStableDeviceId(device.deviceId),
            publicKeyFingerprint: BonjourInteropProtocolContract.normalizedPubKeyFingerprint(device.pubKeyFP)
        )
    }
}
