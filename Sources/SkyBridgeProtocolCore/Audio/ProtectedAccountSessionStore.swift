import Foundation

public enum ProtectedAccountSessionError: Error, Equatable, Sendable {
    case changed, missingSession, audioRevoked, invalidRecord, capacity, unsupportedVersion
    case verificationRequired
    case keychainStatus(Int32)
}

public struct ProtectedAccountObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case credential, devices }
    public let id: UUID
    public let kind: Kind
    public init(id: UUID = UUID(), kind: Kind) { self.id = id; self.kind = kind }
}

public enum ProtectedAudioCheckpointUpdate: Sendable {
    case unchanged
    case replace(Data?)
}

/// One protected value and its independently queryable, non-reusable revision.
public struct ProtectedAccountSessionValue: Sendable, Equatable {
    public let revision: UUID
    public let data: Data

    public init(revision: UUID, data: Data) {
        self.revision = revision; self.data = data
    }
}

/// Implementations must compare and replace atomically across processes. A Swift
/// actor alone, or the macOS file-Keychain SecItemUpdate shim, does not satisfy this.
public protocol ProtectedAccountSessionStorage: Sendable {
    func load() throws -> ProtectedAccountSessionValue?
    func insert(_ value: ProtectedAccountSessionValue) throws -> Bool
    func replace(expectedRevision: UUID, with value: ProtectedAccountSessionValue) throws -> Bool
}

/// Credentials, durable login identity, audio revocation and its finite checkpoint
/// occupy ONE protected item. Clearing writes a tombstone instead of deleting the
/// item, so an old request cannot recreate an absent record after logout.
///
/// This type performs synchronous storage I/O. Native callers must use their
/// existing off-main Keychain executor. A failed CAS is explicit, never retried
/// against a newer login, and never published as a successful mutation.
public struct ProtectedAccountSessionStore<Session: Codable & Equatable & Sendable>: Sendable {
    public static var maximumEncodedBytes: Int { 256 * 1024 }
    public static var maximumSessionBytes: Int { 64 * 1024 }
    public static var maximumObservations: Int { 32 }

    public struct Snapshot: Sendable, Equatable {
        public let version: Int
        public let revision: UUID
        public let session: Session?
        public let loginID: UUID?
        public let audioRevision: UUID
        public let audioRevoked: Bool
        public let audioCheckpoint: Data?
        public let observations: [ProtectedAccountObservation]
        public var requiresCredentialVerification: Bool {
            version == 1 || observations.contains { $0.kind == .credential }
        }
        public var requiresAudioVerification: Bool { version == 1 || !observations.isEmpty }

        fileprivate init(_ document: Document) {
            version = document.version
            revision = document.revision; session = document.session; loginID = document.loginID
            audioRevision = document.audioRevision
            audioRevoked = document.audioRevoked; audioCheckpoint = document.audioCheckpoint
            observations = document.observations ?? []
        }
    }

    fileprivate struct Document: Codable {
        let version: Int
        let revision: UUID
        let session: Session?
        let loginID: UUID?
        let audioRevision: UUID
        let audioRevoked: Bool
        let audioCheckpoint: Data?
        let observations: [ProtectedAccountObservation]?
    }

    private let storage: any ProtectedAccountSessionStorage

    public init(storage: any ProtectedAccountSessionStorage) { self.storage = storage }

    /// Nil means the versioned namespace has never been initialized. A cleared
    /// snapshot is authoritative and must never fall back to legacy credentials.
    public func load() throws -> Snapshot? {
        guard let stored = try storage.load() else { return nil }
        guard stored.data.count <= Self.maximumEncodedBytes else { throw ProtectedAccountSessionError.capacity }
        let document = try JSONDecoder().decode(Document.self, from: stored.data)
        try validate(document)
        guard document.revision == stored.revision else { throw ProtectedAccountSessionError.invalidRecord }
        return Snapshot(document)
    }

    /// Canonical state always wins, including a cleared record. Only a genuinely
    /// absent namespace may consult legacy credentials. Concurrent initialization
    /// is resolved by the atomic insert; its winner is reloaded, never overwritten.
    public func loadMigratingLegacy(
        _ loadLegacy: () throws -> Session?, requireCurrent: () throws -> Void
    ) throws -> Snapshot? {
        try requireCurrent()
        if let current = try load() { return current }
        guard let legacy = try loadLegacy() else { return nil }
        try requireCurrent()
        do { return try install(legacy, replacing: nil) }
        catch ProtectedAccountSessionError.changed {
            guard let winner = try load() else { throw ProtectedAccountSessionError.changed }
            return winner
        }
    }

    /// Explicit login/account replacement always creates a new durable login ID,
    /// even when the server returns byte-identical credentials.
    public func install(_ session: Session, replacing expected: Snapshot?) throws -> Snapshot {
        try commit(session: session, loginID: UUID(), audioRevision: UUID(), audioRevoked: false,
                   audioCheckpoint: nil, observations: [], replacing: expected)
    }

    /// The native authentication owner must first validate refreshed subject,
    /// tenant and authority. Refresh preserves the original audio lifetime.
    public func refresh(_ session: Session, replacing expected: Snapshot) throws -> Snapshot {
        guard expected.session != nil, let loginID = expected.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        guard !expected.requiresCredentialVerification else { throw ProtectedAccountSessionError.verificationRequired }
        return try commit(session: session, loginID: loginID, audioRevision: expected.audioRevision, audioRevoked: expected.audioRevoked,
                          audioCheckpoint: expected.audioCheckpoint, observations: expected.observations, replacing: expected)
    }

    public func clear(replacing expected: Snapshot?) throws -> Snapshot {
        try commit(session: nil, loginID: nil, audioRevision: UUID(), audioRevoked: true,
                   audioCheckpoint: nil, observations: [], replacing: expected)
    }

    /// A confirmed authentication-session rejection clears grants in the same
    /// commit that revokes this login's audio authority. Individual peer removal
    /// instead saves a filtered checkpoint; it does not require a new login.
    public func revokeAudio(replacing expected: Snapshot) throws -> Snapshot {
        guard let session = expected.session, let loginID = expected.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        return try commit(session: session, loginID: loginID, audioRevision: UUID(), audioRevoked: true,
                          audioCheckpoint: nil, observations: expected.observations, replacing: expected)
    }

    /// The audio store supplies bytes from AudioMembershipCheckpoint, bound to
    /// this exact login and account. This layer never manufactures/renews grants.
    public func saveAudioCheckpoint(_ checkpoint: Data?, replacing expected: Snapshot) throws -> Snapshot {
        guard let session = expected.session, let loginID = expected.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        guard !expected.audioRevoked else { throw ProtectedAccountSessionError.audioRevoked }
        guard expected.version == 2 else { throw ProtectedAccountSessionError.verificationRequired }
        return try commit(session: session, loginID: loginID, audioRevision: UUID(), audioRevoked: false,
                          audioCheckpoint: checkpoint, observations: expected.observations, replacing: expected)
    }

    /// The native owner supplies IDs of requests still owned by this process. Unknown
    /// interrupted requests retire their checkpoint before another network request starts.
    /// A device query cannot settle an interrupted credential verification.
    public func beginObservation(_ observation: ProtectedAccountObservation, owned: Set<UUID>,
                                 replacing expected: Snapshot) throws -> Snapshot {
        guard let session = expected.session, let loginID = expected.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        try Self.validateIdentifier(observation.id)
        guard !expected.observations.contains(where: { $0.id == observation.id }) else {
            throw ProtectedAccountSessionError.changed
        }
        let unowned = expected.observations.filter { !owned.contains($0.id) }
        if observation.kind == .devices,
           expected.version == 1 || unowned.contains(where: { $0.kind == .credential }) {
            throw ProtectedAccountSessionError.verificationRequired
        }
        let retained = expected.observations.filter { owned.contains($0.id) }
        guard retained.count < Self.maximumObservations else { throw ProtectedAccountSessionError.capacity }
        let retireCheckpoint = expected.version == 1 || !unowned.isEmpty
        return try commit(session: session, loginID: loginID,
            audioRevision: retireCheckpoint ? UUID() : expected.audioRevision, audioRevoked: expected.audioRevoked,
            audioCheckpoint: retireCheckpoint ? nil : expected.audioCheckpoint,
            observations: retained + [observation], replacing: expected)
    }

    /// Native request ownership is consumed before this CAS. A false CAS may only be
    /// reconciled by that owner against the same login and marker, never an uncertain write.
    /// Keeping a credential marker after a temporary failure preserves its unresolved state.
    public func finishObservation(_ observation: ProtectedAccountObservation, replacementSession: Session? = nil,
                                  checkpoint: ProtectedAudioCheckpointUpdate = .unchanged,
                                  keepUnverifiedCredential: Bool = false, replacing expected: Snapshot) throws -> Snapshot {
        guard let current = expected.session, let loginID = expected.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        guard expected.version == 2, expected.observations.contains(observation),
              replacementSession == nil || observation.kind == .credential,
              !keepUnverifiedCredential || (observation.kind == .credential && replacementSession == nil) else {
            throw ProtectedAccountSessionError.changed
        }
        let bytes: Data?, audioRevision: UUID
        switch checkpoint {
        case .unchanged: bytes = expected.audioCheckpoint; audioRevision = expected.audioRevision
        case .replace(let replacement):
            guard !expected.audioRevoked else { throw ProtectedAccountSessionError.audioRevoked }
            bytes = replacement; audioRevision = UUID()
        }
        let observations = keepUnverifiedCredential ? expected.observations :
            expected.observations.filter { $0.id != observation.id }
        return try commit(session: replacementSession ?? current, loginID: loginID,
            audioRevision: audioRevision, audioRevoked: expected.audioRevoked,
            audioCheckpoint: bytes, observations: observations, replacing: expected)
    }

    private func commit(session: Session?, loginID: UUID?, audioRevision: UUID, audioRevoked: Bool, audioCheckpoint: Data?,
                        observations: [ProtectedAccountObservation], replacing expected: Snapshot?) throws -> Snapshot {
        let document = Document(version: 2, revision: UUID(), session: session, loginID: loginID, audioRevision: audioRevision,
                                audioRevoked: audioRevoked, audioCheckpoint: audioCheckpoint, observations: observations)
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumEncodedBytes else { throw ProtectedAccountSessionError.capacity }
        let value = ProtectedAccountSessionValue(revision: document.revision, data: data)
        let committed: Bool
        if let expected {
            committed = try storage.replace(expectedRevision: expected.revision, with: value)
        } else {
            committed = try storage.insert(value)
        }
        guard committed else { throw ProtectedAccountSessionError.changed }
        return Snapshot(document)
    }

    private func validate(_ document: Document) throws {
        guard document.version == 1 || document.version == 2 else { throw ProtectedAccountSessionError.unsupportedVersion }
        if document.version == 1 {
            guard document.observations == nil else { throw ProtectedAccountSessionError.invalidRecord }
        } else {
            guard let observations = document.observations, observations.count <= Self.maximumObservations,
                  Set(observations.map(\.id)).count == observations.count else {
                throw ProtectedAccountSessionError.invalidRecord
            }
            for observation in observations { try Self.validateIdentifier(observation.id) }
        }
        try Self.validateIdentifier(document.revision)
        try Self.validateIdentifier(document.audioRevision)
        if let session = document.session {
            guard let loginID = document.loginID else { throw ProtectedAccountSessionError.invalidRecord }
            try Self.validateIdentifier(loginID)
            guard try JSONEncoder().encode(session).count <= Self.maximumSessionBytes else {
                throw ProtectedAccountSessionError.capacity
            }
        } else {
            guard document.loginID == nil, document.audioRevoked, document.audioCheckpoint == nil,
                  document.observations?.isEmpty != false else {
                throw ProtectedAccountSessionError.invalidRecord
            }
        }
        if let checkpoint = document.audioCheckpoint {
            guard !document.audioRevoked else { throw ProtectedAccountSessionError.invalidRecord }
            guard checkpoint.count <= AudioMembershipCheckpoint.maximumEncodedBytes else {
                throw ProtectedAccountSessionError.capacity
            }
        }
    }

    private static func validateIdentifier(_ identifier: UUID) throws {
        guard identifier != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw ProtectedAccountSessionError.invalidRecord
        }
    }
}
