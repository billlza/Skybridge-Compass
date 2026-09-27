import Foundation

public struct TrustRecoveryRecordEvidence: Codable, Sendable {
    public let storage: String
    public let record_sha256: String
    public let device_id: String
    public let current_device_id: String?
    public let known_device_ids: [String]
    public let direct_identity_match: Bool
    public let local_signature_verified: Bool
    public let signature_payload_version: Int?
    public let version: Int
    public let tombstone: Bool
    public let expired: Bool
    public let lifecycle: String
    public let protocol_pins: [ProtocolIdentityPin]
    public let protocol_public_key_bytes: Int
    public let preserved_shared_peer: Bool
}

public struct TrustRecoveryPreview: Codable, Sendable {
    public let runtime_target: String
    public let peer_id: String
    public let expected_fingerprint: String
    public let snapshot_sha256: String
    public let records: [TrustRecoveryRecordEvidence]
    public let blockers: [String]
    public let eligible_for_explicit_recovery: Bool
    public let writes_performed: Bool
    public let preserving_shared_peer_id: String?
}

struct TrustRecoverySourceRecord: Codable, Sendable {
    let storage: String
    let backingReferenceSHA256: String
    let recordSHA256: String
    let record: TrustRecord
}

public struct TrustMirrorRecoveryAuthorization: Sendable {
    public let recoveryID: UUID
    public let peerID: String
    public let expectedFingerprint: String
    public let snapshotSHA256: String
    public let preservingSharedPeerID: String?

    public init(recoveryID: UUID, peerID: String, expectedFingerprint: String, snapshotSHA256: String,
                preservingSharedPeerID: String? = nil) throws {
        func validHash(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard UUID(uuidString: peerID) != nil, validHash(expectedFingerprint), validHash(snapshotSHA256) else {
            throw TrustSyncError.decodingError("invalid explicit mirror recovery authorization")
        }
        self.recoveryID = recoveryID; self.peerID = peerID
        self.expectedFingerprint = expectedFingerprint; self.snapshotSHA256 = snapshotSHA256
        if let preservingSharedPeerID {
            guard let preserved = UUID(uuidString: preservingSharedPeerID), preserved != UUID(uuidString: peerID) else {
                throw TrustSyncError.decodingError("shared peer preservation requires a different stable UUID")
            }
            self.preservingSharedPeerID = preserved.uuidString
        } else { self.preservingSharedPeerID = nil }
    }
}

struct TrustMirrorRecoveryArchive: Codable, Sendable {
    let recoveryID: UUID
    let peerID: String
    let protocolFingerprint: String
    let snapshotSHA256: String
    let protocolTransactionReference: String
    let createdAt: Date
    let preservedKeychainAuthority: TrustRecord
    let originalMirrorData: Data
    let replacementMirrorSHA256: String
    let retiredRecordIDs: [String]
    let preservingSharedPeerID: String?
    let preservedSharedRecords: [TrustRecoverySourceRecord]?
}

public struct TrustMirrorRecoveryResult: Codable, Sendable {
    public let runtime_target: String
    public let recovery_id: String
    public let peer_id: String
    public let expected_fingerprint: String
    public let success: Bool
    public let status: String
    public let retired_mirror_records: Int?
    public let keychain_authority_preserved: Bool
    public let authenticated_connection: Bool
    public let error_code: String?
    public let preserving_shared_peer_id: String?
    public let shared_peer_records_preserved: Bool?
}
