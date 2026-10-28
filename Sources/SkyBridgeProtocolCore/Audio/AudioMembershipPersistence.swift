import Foundation

/// Opaque revision of the audio portion of the protected login record. Credential
/// refresh may change the record revision without changing this witness.
public struct AudioMembershipPersistenceSnapshot: Sendable, Equatable {
    public let revision: UUID
    public let checkpoint: Data?

    public init(revision: UUID, checkpoint: Data?) {
        self.revision = revision; self.checkpoint = checkpoint
    }
}

/// A request may settle only its own native prepared observation. The checkpoint
/// and removal of that observation can be committed by the same protected CAS.
public struct AudioMembershipPersistenceObservation: Sendable {
    public let finish: @MainActor (UUID?, ProtectedAudioCheckpointUpdate) async throws -> AudioMembershipPersistenceSnapshot
    public let abandon: @MainActor () async -> Void

    public init(finish: @escaping @MainActor (UUID?, ProtectedAudioCheckpointUpdate) async throws -> AudioMembershipPersistenceSnapshot,
                abandon: @escaping @MainActor () async -> Void) {
        self.finish = finish; self.abandon = abandon
    }
}

/// Native adapters must verify the exact durable login before and after I/O.
/// Save is a compare-and-swap against the audio revision, never a blind overwrite.
@MainActor
public struct AudioMembershipPersistence {
    public let bootSessionID: @Sendable () async throws -> UUID
    public let load: @MainActor (AudioAccountContext) async throws -> AudioMembershipPersistenceSnapshot
    public let save: @MainActor (AudioAccountContext, UUID, Data?) async throws -> AudioMembershipPersistenceSnapshot
    public let beginObservation: @MainActor (AudioAccountContext) async throws -> AudioMembershipPersistenceObservation

    public init(bootSessionID: @escaping @Sendable () async throws -> UUID,
                load: @escaping @MainActor (AudioAccountContext) async throws -> AudioMembershipPersistenceSnapshot,
                save: @escaping @MainActor (AudioAccountContext, UUID, Data?) async throws -> AudioMembershipPersistenceSnapshot,
                beginObservation: @escaping @MainActor (AudioAccountContext) async throws -> AudioMembershipPersistenceObservation) {
        self.bootSessionID = bootSessionID; self.load = load; self.save = save; self.beginObservation = beginObservation
    }
}

public enum AudioMembershipRestorationStatus: Sendable, Equatable {
    case notConfigured, pending, empty, differentBoot, verificationRequired
    case restored(entries: Int, expired: Int)
    case failed
}
