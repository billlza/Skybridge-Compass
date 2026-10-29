import Foundation

enum TrustMirrorRecoveryPlanError: String, Error, LocalizedError, Sendable {
    case noCurrentKeychainAuthority = "no_current_keychain_authority"
    case multipleKeychainAuthorities = "multiple_keychain_authorities"
    case noStaleMirrorAliases = "no_stale_mirror_aliases"
    case activeRevocation = "active_revocation"
    case inactiveAuthority = "inactive_authority"
    case crossDeviceClaim = "cross_device_claim"
    case newerMirrorRecord = "newer_mirror_record"
    case changedSnapshot = "trust_snapshot_changed"
    case reusedRecoveryID = "recovery_id_already_exists"
    case unverifiedRecord = "unverified_record_source"
    case mirrorChangedDuringRecovery = "mirror_changed_during_recovery"
    case sharedPeerScopeMismatch = "shared_peer_scope_mismatch"

    var errorDescription: String? { rawValue }
}

/// An explicitly requested retirement of stale MIRROR rows, preserving an
/// already pinned Keychain authority. This cannot rotate or replace a key.
@available(macOS 14.0, iOS 17.0, *)
struct TrustMirrorRecoveryPlan {
    let authority: TrustRecoverySourceRecord
    let retiring: [TrustRecoverySourceRecord]
    let preserving: [TrustRecoverySourceRecord]

    static func resolve(sources: [TrustRecoverySourceRecord], peerID: String,
                        fingerprint: String, preservingSharedPeerID: String? = nil) throws -> Self {
        let target = claims([peerID])
        let targetUUID = UUID(uuidString: peerID)
        let preservedUUID = preservingSharedPeerID.flatMap(UUID.init(uuidString:))
        guard targetUUID != nil,
              preservingSharedPeerID == nil || (preservedUUID != nil && preservedUUID != targetUUID) else {
            throw TrustMirrorRecoveryPlanError.sharedPeerScopeMismatch
        }
        let keychainMatches = sources.filter {
            $0.storage != "protected_mirror" && !directClaims($0.record).isDisjoint(with: target)
        }
        guard keychainMatches.count <= 1 else { throw TrustMirrorRecoveryPlanError.multipleKeychainAuthorities }
        guard let authority = keychainMatches.first,
              authority.record.currentPathAuthorityPins.contains(where: { $0.fingerprint == fingerprint }) else {
            throw TrustMirrorRecoveryPlanError.noCurrentKeychainAuthority
        }
        guard authority.record.isAuthenticationEligible else { throw TrustMirrorRecoveryPlanError.inactiveAuthority }
        let retiring = sources.filter {
            $0.storage == "protected_mirror" && !directClaims($0.record).isDisjoint(with: target)
        }
        guard !retiring.isEmpty else { throw TrustMirrorRecoveryPlanError.noStaleMirrorAliases }
        var retirementClaims = target
        for source in retiring {
            let record = source.record
            // Even explicit shared-alias retirement cannot delete a row whose
            // own stable identity is another peer. Only its metadata may refer
            // to the separately preserved peer.
            let stableIDs = [record.deviceId, record.currentDeviceIdMetadata].compactMap { $0 }.compactMap(stableID)
            guard !stableIDs.isEmpty, stableIDs.allSatisfy({ $0 == targetUUID }) else {
                throw TrustMirrorRecoveryPlanError.crossDeviceClaim
            }
            if record.isTombstone && !record.isExpired { throw TrustMirrorRecoveryPlanError.activeRevocation }
            guard !record.isTombstone && record.isAuthenticationEligible else {
                throw TrustMirrorRecoveryPlanError.inactiveAuthority
            }
            guard record.updatedAt <= authority.record.updatedAt else { throw TrustMirrorRecoveryPlanError.newerMirrorRecord }
            retirementClaims.formUnion(directClaims(record))
            retirementClaims.formUnion(claims(record.knownDeviceIdsMetadata ?? []))
        }
        let retiringIDs = Set(retiring.map { $0.record.deviceId })
        var preserving: [TrustRecoverySourceRecord] = []
        for source in sources {
            if source.storage == authority.storage && source.backingReferenceSHA256 == authority.backingReferenceSHA256 { continue }
            if source.storage == "protected_mirror" && retiringIDs.contains(source.record.deviceId) { continue }
            if !directClaims(source.record).isDisjoint(with: retirementClaims) {
                let direct = [source.record.deviceId, source.record.currentDeviceIdMetadata].compactMap { $0 }
                guard let preservedUUID, !direct.isEmpty,
                      direct.allSatisfy({ stableID($0) == preservedUUID }) else {
                    throw TrustMirrorRecoveryPlanError.crossDeviceClaim
                }
                if source.record.isTombstone && !source.record.isExpired { throw TrustMirrorRecoveryPlanError.activeRevocation }
                guard source.record.isAuthenticationEligible else { throw TrustMirrorRecoveryPlanError.inactiveAuthority }
                preserving.append(source)
            }
        }
        guard (preservingSharedPeerID == nil) == preserving.isEmpty else {
            throw TrustMirrorRecoveryPlanError.sharedPeerScopeMismatch
        }
        return Self(authority: authority, retiring: retiring, preserving: preserving)
    }

    private static func stableID(_ value: String) -> UUID? {
        let raw = value.lowercased().hasPrefix("id:") ? String(value.dropFirst(3)) : value
        return UUID(uuidString: raw)
    }

    private static func claims(_ values: [String]) -> Set<String> {
        Set(values.flatMap { PeerTrustLookup.lookupCandidates(for: $0) }.map { $0.lowercased() })
    }

    private static func directClaims(_ record: TrustRecord) -> Set<String> {
        claims([record.deviceId, record.currentDeviceIdMetadata].compactMap { $0 })
    }
}
