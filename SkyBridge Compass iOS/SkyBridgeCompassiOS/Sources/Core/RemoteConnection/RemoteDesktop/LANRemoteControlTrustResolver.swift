//
//  LANRemoteControlTrustResolver.swift
//  SkyBridgeCompassiOS
//

import Foundation

enum LANRemoteControlTrustResolution: Equatable {
    case missing
    case ambiguous(deviceIds: [String], fingerprints: [String])
    case resolved(record: TrustedDeviceStore.TrustedDevice, canonicalPeerId: String)
}

enum LANRemoteControlTrustResolver {
    static func resolve(
        device: DiscoveredDevice,
        trustedPeerId: String? = nil,
        trustedDevices: [TrustedDeviceStore.TrustedDevice]
    ) -> LANRemoteControlTrustResolution {
        let candidates = candidateAliases(for: device, trustedPeerId: trustedPeerId)
        let matches = trustedDevices.filter { trustedRecord in
            guard isActive(trustedRecord) else { return false }
            return !recordAliases(for: trustedRecord).isDisjoint(with: candidates)
        }

        guard !matches.isEmpty else {
            return .missing
        }

        let deviceIds = Array(
            Set(
                matches
                    .map(resolvedCurrentDeviceId(for:))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let fingerprints = Array(
            Set(
                matches
                    .compactMap(\.protocolPublicKeyFingerprint)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        guard deviceIds.count == 1 && fingerprints.count <= 1 else {
            return .ambiguous(deviceIds: deviceIds, fingerprints: fingerprints)
        }

        let canonicalPeerId = deviceIds[0]
        let preferredFingerprint = fingerprints.first
        let chosenRecord = matches.sorted { lhs, rhs in
            let lhsFingerprint = lhs.protocolPublicKeyFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rhsFingerprint = rhs.protocolPublicKeyFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let lhsHasPreferredFingerprint = preferredFingerprint != nil && lhsFingerprint == preferredFingerprint
            let rhsHasPreferredFingerprint = preferredFingerprint != nil && rhsFingerprint == preferredFingerprint
            if lhsHasPreferredFingerprint != rhsHasPreferredFingerprint {
                return lhsHasPreferredFingerprint && !rhsHasPreferredFingerprint
            }

            let lhsHasAuthority = !(lhs.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let rhsHasAuthority = !(rhs.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if lhsHasAuthority != rhsHasAuthority {
                return lhsHasAuthority && !rhsHasAuthority
            }

            if lhs.addedAt != rhs.addedAt {
                return lhs.addedAt < rhs.addedAt
            }
            return lhs.id < rhs.id
        }.first!
        return .resolved(record: chosenRecord, canonicalPeerId: canonicalPeerId)
    }

    static func candidateAliases(
        for device: DiscoveredDevice,
        trustedPeerId: String? = nil
    ) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: trustedPeerId))
        if let ipAddress = device.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        return Set(aliases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func recordAliases(
        for trustedRecord: TrustedDeviceStore.TrustedDevice
    ) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: trustedRecord.id))
        if let currentDeviceId = trustedRecord.currentDeviceId {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: currentDeviceId))
        }
        for knownDeviceId in trustedRecord.knownDeviceIds ?? [] {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: knownDeviceId))
        }
        if let ipAddress = trustedRecord.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        return aliases
    }

    static func resolvedCurrentDeviceId(
        for trustedRecord: TrustedDeviceStore.TrustedDevice
    ) -> String {
        trustedRecord.currentDeviceId ?? trustedRecord.id
    }

    private static func isActive(_ trustedRecord: TrustedDeviceStore.TrustedDevice) -> Bool {
        (trustedRecord.currentPathLifecycleState ?? .active) == .active
    }
}
