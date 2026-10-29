import Foundation

public enum AudioMembershipCheckpointError: Error, Equatable, Sendable {
    case capacity, unsupportedVersion, invalidIdentifier, invalidTime, duplicateEntry
    case accountChanged, loginChanged, bootChanged
}

/// Serialization of locally obtained evidence, not a remotely verifiable credential.
/// The caller must bind the bytes to protected local login storage before restoration.
/// Receiving these bytes from a peer or a device-list cache never grants authority.
public enum AudioMembershipCheckpoint {
    public static let maximumEntries = 32
    public static let maximumEncodedBytes = 64 * 1024

    public struct Restoration: Sendable {
        public let evidence: [AudioAccountMembership]
        public let expiredEntryCount: Int
    }

    /// A checkpoint retains the original ID and BOTH original expiry anchors.
    /// Neither saving, restoring nor reconnecting computes a new validity period.
    public static func encode(
        _ evidence: [AudioAccountMembership], account: AudioAccountIdentity,
        loginID: UUID, bootSessionID: UUID, nowMilliseconds: Int64,
        monotonicNow: ContinuousClock.Instant = .now
    ) throws -> Data {
        try requireIdentifier(loginID)
        try requireIdentifier(bootSessionID)
        guard evidence.count <= maximumEntries else { throw AudioMembershipCheckpointError.capacity }
        var entries: [Entry] = []
        for item in evidence {
            try item.validate(account: account, local: item.localIdentity, peer: item.peerIdentity,
                nowMilliseconds: nowMilliseconds, monotonicNow: monotonicNow)
            entries.append(try Entry(item))
        }
        let checkpoint = Document(version: 1, account: Account(account), loginID: loginID,
                                  bootSessionID: bootSessionID, entries: entries)
        _ = try checkpoint.validatedEvidence()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checkpoint)
        guard data.count <= maximumEncodedBytes else { throw AudioMembershipCheckpointError.capacity }
        return data
    }

    /// The protected store supplies the durable login identifier. A live channel
    /// must still pass pairing, exact identity, account-epoch and receiver approval.
    public static func restore(
        _ data: Data, account: AudioAccountIdentity, loginID: UUID, bootSessionID: UUID,
        nowMilliseconds: Int64, monotonicNow: ContinuousClock.Instant = .now
    ) throws -> Restoration {
        try requireIdentifier(loginID)
        try requireIdentifier(bootSessionID)
        guard data.count <= maximumEncodedBytes else { throw AudioMembershipCheckpointError.capacity }
        let checkpoint = try JSONDecoder().decode(Document.self, from: data)
        guard checkpoint.version == 1 else { throw AudioMembershipCheckpointError.unsupportedVersion }
        let restoredAccount = try checkpoint.account.validated()
        guard restoredAccount == account else { throw AudioMembershipCheckpointError.accountChanged }
        try requireIdentifier(checkpoint.loginID)
        try requireIdentifier(checkpoint.bootSessionID)
        guard checkpoint.loginID == loginID else { throw AudioMembershipCheckpointError.loginChanged }
        guard checkpoint.bootSessionID == bootSessionID else { throw AudioMembershipCheckpointError.bootChanged }
        let entries = try checkpoint.validatedEvidence()
        var current: [AudioAccountMembership] = []
        var expired = 0
        for entry in entries {
            do {
                try entry.validate(account: account, local: entry.localIdentity, peer: entry.peerIdentity,
                    nowMilliseconds: nowMilliseconds, monotonicNow: monotonicNow)
                current.append(entry)
            } catch AudioMembershipError.expired {
                // Expiry is an expected cache lifecycle result; report its count.
                // Every other failure, including rollback, rejects the checkpoint.
                expired += 1
            }
        }
        return Restoration(evidence: current, expiredEntryCount: expired)
    }

    private struct Document: Codable {
        let version: Int
        let account: Account
        let loginID: UUID
        let bootSessionID: UUID
        let entries: [Entry]

        func validatedEvidence() throws -> [AudioAccountMembership] {
            guard version == 1 else { throw AudioMembershipCheckpointError.unsupportedVersion }
            guard entries.count <= maximumEntries else { throw AudioMembershipCheckpointError.capacity }
            try requireIdentifier(loginID)
            try requireIdentifier(bootSessionID)
            let account = try account.validated()
            var identifiers = Set<UUID>()
            var pairs = Set<IdentityPair>()
            var result: [AudioAccountMembership] = []
            for entry in entries {
                let evidence = try entry.validated(account: account)
                guard identifiers.insert(evidence.id).inserted,
                      pairs.insert(IdentityPair(local: evidence.localIdentity, peer: evidence.peerIdentity)).inserted else {
                    throw AudioMembershipCheckpointError.duplicateEntry
                }
                result.append(evidence)
            }
            return result
        }
    }

    private struct IdentityPair: Hashable {
        let local: AudioProtocolIdentity
        let peer: AudioProtocolIdentity
    }

    private struct Account: Codable {
        let authority: String
        let tenantID: String
        let userID: String
        init(_ account: AudioAccountIdentity) {
            authority = account.authority; tenantID = account.tenantID; userID = account.userID
        }
        func validated() throws -> AudioAccountIdentity {
            try AudioAccountIdentity(authority: authority, tenantID: tenantID, userID: userID)
        }
    }

    private struct Identity: Codable {
        let deviceID: String
        let algorithm: String
        let fingerprint: String
        init(_ identity: AudioProtocolIdentity) {
            deviceID = identity.deviceID; algorithm = identity.algorithm.rawValue; fingerprint = identity.fingerprint
        }
        func validated() throws -> AudioProtocolIdentity {
            guard let algorithm = ProtocolSigningAlgorithm(rawValue: algorithm) else {
                throw AudioMembershipError.invalidIdentity
            }
            return try AudioProtocolIdentity(deviceID: deviceID, algorithm: algorithm, fingerprint: fingerprint)
        }
    }

    /// Public Swift clock epochs avoid serializing Instant's private layout or
    /// inferring a deadline from wall time. These offsets are local to one boot.
    private struct ClockOffset: Codable {
        let seconds: Int64
        let attoseconds: Int64

        init(_ instant: ContinuousClock.Instant) throws {
            let components = ContinuousClock().systemEpoch.duration(to: instant).components
            seconds = components.seconds; attoseconds = components.attoseconds
            _ = try validated()
        }

        func validated() throws -> ContinuousClock.Instant {
            guard seconds >= 0, attoseconds >= 0, attoseconds < 1_000_000_000_000_000_000 else {
                throw AudioMembershipCheckpointError.invalidTime
            }
            return ContinuousClock().systemEpoch.advanced(by:
                Duration(secondsComponent: seconds, attosecondsComponent: attoseconds))
        }
    }

    private struct Entry: Codable {
        let id: UUID
        let local: Identity
        let peer: Identity
        let issuedAtMilliseconds: Int64
        let expiresAtMilliseconds: Int64
        let issuedAtMonotonic: ClockOffset
        let expiresAtMonotonic: ClockOffset

        init(_ evidence: AudioAccountMembership) throws {
            id = evidence.id; local = Identity(evidence.localIdentity); peer = Identity(evidence.peerIdentity)
            issuedAtMilliseconds = evidence.issuedAtMilliseconds; expiresAtMilliseconds = evidence.expiresAtMilliseconds
            issuedAtMonotonic = try ClockOffset(evidence.issuedAtMonotonic)
            expiresAtMonotonic = try ClockOffset(evidence.expiresAtMonotonic)
        }

        func validated(account: AudioAccountIdentity) throws -> AudioAccountMembership {
            try requireIdentifier(id)
            let local = try local.validated(), peer = try peer.validated()
            guard local.deviceID != peer.deviceID else { throw AudioMembershipError.selfPlayback }
            guard issuedAtMilliseconds > 0, expiresAtMilliseconds > issuedAtMilliseconds,
                  expiresAtMilliseconds - issuedAtMilliseconds <= AudioAccountMembership.maximumLifetimeMilliseconds else {
                throw AudioMembershipCheckpointError.invalidTime
            }
            let issued = try issuedAtMonotonic.validated(), expires = try expiresAtMonotonic.validated()
            guard expires > issued,
                  issued.duration(to: expires) == .milliseconds(expiresAtMilliseconds - issuedAtMilliseconds) else {
                throw AudioMembershipCheckpointError.invalidTime
            }
            return AudioAccountMembership(id: id, account: account, localIdentity: local, peerIdentity: peer,
                issuedAtMilliseconds: issuedAtMilliseconds, expiresAtMilliseconds: expiresAtMilliseconds,
                issuedAtMonotonic: issued, expiresAtMonotonic: expires)
        }
    }

    private static func requireIdentifier(_ value: UUID) throws {
        guard value != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw AudioMembershipCheckpointError.invalidIdentifier
        }
    }
}
