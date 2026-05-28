import CryptoKit
import Foundation

struct LANRemoteControlCurrentPathAuthority: Sendable {
    let deviceId: String
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyFingerprints: Set<String>
}

struct LANRemoteControlHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: LANRemoteControlCurrentPathAuthority

    func trustedFingerprint(for deviceId: String) async -> String? {
        guard deviceId == expectedRemoteAuthority.deviceId else { return nil }
        return expectedRemoteAuthority.protocolPublicKeyFingerprint
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        guard await trustedFingerprint(for: deviceId) != nil else { return [] }
        return expectedRemoteAuthority.protocolPublicKeyFingerprints
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        await KEMTrustStore.shared.kemPublicKeys(for: deviceId)
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        _ = deviceId
        return nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return true
    }
}

enum RemoteDesktopLANHandshakeTrust {
    static func resolveTrustedLANPeerIdentifier(
        for device: DiscoveredDevice,
        trustedDevices: [TrustedDeviceStore.TrustedDevice]
    ) throws -> String {
        switch LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: device.id,
            trustedDevices: trustedDevices
        ) {
        case .resolved(_, let canonicalPeerId):
            return PeerIdentityAliasResolver.persistentDeviceId(from: canonicalPeerId) ?? canonicalPeerId
        case .missing:
            throw RemoteDesktopError.connectionFailed("远控目标未建立受信任身份")
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteDesktopError.connectionFailed("远控目标匹配到多条受信任身份记录: \(summary)")
        }
    }

    static func resolveTrustedRemoteAuthority(
        for device: DiscoveredDevice,
        trustedPeerId: String,
        trustedDevices: [TrustedDeviceStore.TrustedDevice]
    ) async throws -> LANRemoteControlCurrentPathAuthority {
        let record: TrustedDeviceStore.TrustedDevice
        let deviceId: String
        switch LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: trustedPeerId,
            trustedDevices: trustedDevices
        ) {
        case .resolved(let matchedRecord, let canonicalPeerId):
            record = matchedRecord
            deviceId = canonicalPeerId
        case .missing:
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteDesktopError.connectionFailed("远控目标受信任指纹映射不唯一: \(summary)")
        }

        guard let fingerprint = record.protocolPublicKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        }
        let primaryFingerprint = fingerprint.lowercased()

        var identityLookupCandidates = Array(
            LANRemoteControlTrustResolver.candidateAliases(for: device, trustedPeerId: trustedPeerId)
        )
        identityLookupCandidates.append(deviceId)
        if let currentDeviceId = record.currentDeviceId {
            identityLookupCandidates.append(currentDeviceId)
        }
        identityLookupCandidates.append(record.id)
        identityLookupCandidates.append(contentsOf: record.knownDeviceIds ?? [])

        let supplementalFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(
            forAny: identityLookupCandidates
        )
        let trustedFingerprints: Set<String>
        if supplementalFingerprints.contains(primaryFingerprint) {
            trustedFingerprints = supplementalFingerprints.union([primaryFingerprint])
        } else {
            trustedFingerprints = [primaryFingerprint]
            if !supplementalFingerprints.isEmpty {
                SkyBridgeLogger.shared.warning(
                    "⚠️ LAN 远控忽略未绑定到既有受信任指纹的 supplemental protocol identities: peer=\(deviceId) expected=\(primaryFingerprint) count=\(supplementalFingerprints.count)"
                )
            }
        }

        return LANRemoteControlCurrentPathAuthority(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: primaryFingerprint,
            protocolPublicKeyFingerprints: trustedFingerprints
        )
    }

    static func remoteControlSOAPeerId(for identifier: String?) -> Data? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        let persistentIdentifier = PeerIdentityAliasResolver.persistentDeviceId(from: identifier) ?? identifier
        var normalized = persistentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        guard !normalized.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(normalized.utf8)))
    }

    static func randomRemoteControlAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
}

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    public nonisolated static func shouldContinueLANBootstrap(
        activeTransportModeIsLAN: Bool,
        isCurrentLANConnection: Bool,
        state: RemoteDesktopState
    ) -> Bool {
        guard activeTransportModeIsLAN, isCurrentLANConnection else { return false }
        if case .error = state {
            return false
        }
        return true
    }

    public nonisolated static func lanRemoteControlTrustBootstrapFailureReason(
        observedReply: Bool,
        bootstrapReady: Bool
    ) -> String? {
        guard !bootstrapReady else { return nil }
        return "stage=lan_remote_trust_bootstrap reason=metadata_kem_readiness_timeout observedReply=\(observedReply ? 1 : 0) noFallback=1"
    }
}
