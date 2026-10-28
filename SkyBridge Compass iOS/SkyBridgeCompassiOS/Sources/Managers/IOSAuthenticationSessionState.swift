import Foundation
import os
import SkyBridgeProtocolCore

typealias IOSAuthSessionRecord = ProtectedAccountSessionStore<AuthSession>.Snapshot

/// Native owner of one durably prepared refresh; persisted IDs alone cannot
/// recreate request ownership after process interruption.
final class IOSAuthSessionObservation: Sendable {
    let observation: ProtectedAccountObservation
    let loginID: UUID
    let source: AuthSession
    let intent: IOSAuthenticationIntent
    let requiresCredentialRecovery: Bool
    init(observation: ProtectedAccountObservation, loginID: UUID, source: AuthSession,
         intent: IOSAuthenticationIntent, requiresCredentialRecovery: Bool) {
        self.observation = observation; self.loginID = loginID; self.source = source
        self.intent = intent; self.requiresCredentialRecovery = requiresCredentialRecovery
    }
}

struct IOSAuthenticationPersistenceFailure: LocalizedError {
    let original: any Error
    let persistence: any Error
    var errorDescription: String? { "账户更新未能写入安全存储，请稍后重试。" }
}

/// Checked inside the Keychain actor immediately before a synchronous mutation.
/// A mutation already admitted may finish after invalidation, but the actor runs
/// it before any newer write, and the owner rejects its late publication. Queued
/// stale mutations fail before touching storage. Invalidation never waits for I/O.
final class IOSAuthenticationIntent: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: true)

    var isCurrent: Bool { active.withLock { $0 } }

    func invalidate() { active.withLock { $0 = false } }

    func requireCurrent() throws {
        guard isCurrent else { throw IOSAuthenticationSessionError.changed }
    }
}

enum IOSAuthenticationSessionError: LocalizedError, Equatable {
    case changed
    case missing
    case publicationInProgress
    case unownedSessionOperation

    var errorDescription: String? {
        switch self {
        case .changed: return "账户会话已变化，请重新发起操作。"
        case .missing: return "请先登录账户。"
        case .publicationInProgress: return "账户正在更新，请稍后重试。"
        case .unownedSessionOperation: return "账户操作缺少有效的会话所有者。"
        }
    }
}

/// The single owner of in-memory and persisted iOS account sessions. UI remains
/// at its previous state if persistence fails, but the previous audio authority
/// is irreversibly revoked as soon as a replacement/logout intent begins.
@MainActor
final class IOSAuthenticationSessionState {
    struct Storage: Sendable {
        let load: @Sendable (IOSAuthenticationIntent) async throws -> IOSAuthSessionRecord?
        let store: @Sendable (AuthSession, IOSAuthenticationIntent) async throws -> IOSAuthSessionRecord
        let replace: @Sendable (AuthSession, AuthSession, UUID, IOSAuthenticationIntent) async throws -> Bool
        let delete: @Sendable (IOSAuthenticationIntent) async throws -> Void
        let beginObservation: @Sendable (AuthSession, UUID, IOSAuthenticationIntent) async throws -> IOSAuthSessionObservation
        let finishObservation: @Sendable (IOSAuthSessionObservation, AuthSession?, Bool) async throws -> IOSAuthSessionRecord
        let abandonObservation: @Sendable (IOSAuthSessionObservation) async -> Void
        let revokeAudio: @Sendable (AuthSession, UUID, IOSAuthenticationIntent) async throws -> Void

        static func live(keychain: KeychainManager = .shared) -> Self {
            Self(load: { try await keychain.loadAuthSessionRecordStrict(intent: $0) },
                 store: { try await keychain.storeAuthSession($0, intent: $1) },
                 replace: { try await keychain.replaceAuthSession(expected: $0, expectedLoginID: $2, with: $1, intent: $3) },
                 delete: { try await keychain.deleteAuthSession(intent: $0) },
                 beginObservation: { try await keychain.beginAccountObservation(kind: .credential,
                    expected: $0, loginID: $1, intent: $2) },
                 finishObservation: { try await keychain.finishAccountObservation($0,
                    replacement: $1, temporaryFailure: $2) },
                 abandonObservation: { await keychain.abandonAccountObservation($0) },
                 revokeAudio: { try await keychain.revokeAudioAuthorization(expected: $0, loginID: $1, intent: $2) })
        }
    }

    struct Witness: Sendable {
        let intent: IOSAuthenticationIntent
        let revision: UUID
        let loginID: UUID
        let session: AuthSession
        let audioAuthorization: AccountAudioAuthorization?

        func hasSameCredentials(as other: Witness) -> Bool {
            intent === other.intent && loginID == other.loginID && audioAuthorization === other.audioAuthorization &&
                session.userIdentifier == other.session.userIdentifier &&
                session.accessToken == other.session.accessToken && session.refreshToken == other.session.refreshToken
        }
    }

    private let storage: Storage
    private var intent = IOSAuthenticationIntent()
    private var revision = UUID()
    private var publicationID: UUID?
    private let audio = AccountAudioAuthorizationState()
    private(set) var session: AuthSession?
    private var loginID: UUID?
    private(set) var needsCredentialVerification = false

    init(storage: Storage = .live()) { self.storage = storage }

    var currentIntent: IOSAuthenticationIntent { intent }
    var audioAuthorization: AccountAudioAuthorization? { audio.current }

    @discardableResult
    func beginMutation() -> IOSAuthenticationIntent {
        intent.invalidate()
        audio.beginMutation()
        intent = IOSAuthenticationIntent()
        revision = UUID()
        publicationID = nil
        loginID = nil
        needsCredentialVerification = false
        return intent
    }

    func requireCurrent(_ expected: IOSAuthenticationIntent) throws {
        guard intent === expected else { throw IOSAuthenticationSessionError.changed }
        try expected.requireCurrent()
    }

    func witness() throws -> Witness {
        guard let session, let loginID else { throw IOSAuthenticationSessionError.missing }
        try intent.requireCurrent()
        return Witness(intent: intent, revision: revision, loginID: loginID, session: session,
                       audioAuthorization: audio.current)
    }

    func requireCurrent(_ expected: Witness) throws {
        try requireCurrent(expected.intent)
        guard revision == expected.revision, loginID == expected.loginID, session == expected.session else {
            throw IOSAuthenticationSessionError.changed
        }
    }

    func witness(matchingCredentials expected: Witness) throws -> Witness {
        let current = try witness()
        guard current.hasSameCredentials(as: expected) else { throw IOSAuthenticationSessionError.changed }
        return current
    }

    func restore(intent expected: IOSAuthenticationIntent, matching: AuthSession? = nil) async throws -> AuthSession? {
        try requireCurrent(expected)
        let publication = try beginPublication()
        defer { endPublication(publication) }
        let loaded = try await storage.load(expected)
        try requireCurrent(expected)
        if let matching, loaded?.session != matching { throw IOSAuthenticationSessionError.changed }
        if let loaded, loaded.session != nil { try publish(loaded) }
        else { try clearPublishedSession(intent: expected) }
        return loaded?.session
    }

    func install(_ replacement: AuthSession, intent expected: IOSAuthenticationIntent) async throws {
        try Task.checkCancellation()
        try requireCurrent(expected)
        let publication = try beginPublication()
        defer { endPublication(publication) }
        let saved = try await storage.store(replacement, expected)
        // Once persisted, finish publication without a cancellation check. A newer
        // intent is the only reason the just-persisted session must not publish.
        try requireCurrent(expected)
        guard saved.session == replacement else { throw ProtectedAccountSessionError.invalidRecord }
        try publish(saved)
    }

    /// Profile and validated token refresh both use exact-session CAS. Neither
    /// changes the account publication epoch; concurrent old writes fail closed.
    func replace(_ replacement: AuthSession, expected: Witness) async throws {
        try Task.checkCancellation()
        try requireCurrent(expected)
        let publication = try beginPublication()
        defer { endPublication(publication) }
        let replaced = try await storage.replace(expected.session, replacement, expected.loginID, expected.intent)
        try requireCurrent(expected)
        guard replaced else { throw IOSAuthenticationSessionError.changed }
        session = replacement
        revision = UUID()
    }

    /// Reserve the publication before a refresh can rotate a remote token. A
    /// competing profile write fails explicitly before storage; a competing
    /// refresh fails before HTTP. A returned token is never discarded merely
    /// because a profile committed while its refresh request was in flight.
    func refresh(expected: Witness,
                 isTemporaryFailure: @MainActor (any Error) -> Bool = AudioMembershipRequestFailurePolicy.isTemporaryNetworkError,
                 fetch: @MainActor (AuthSession) async throws -> AuthSession) async throws -> AuthSession {
        try Task.checkCancellation()
        try requireCurrent(expected)
        let publication = try beginPublication()
        defer { endPublication(publication) }
        // Persist intent before any remote token rotation or rejection can be observed.
        let observation = try await storage.beginObservation(expected.session, expected.loginID, expected.intent)
        var enteredRequest = false
        var settlementAttempted = false
        do {
            try Task.checkCancellation()
            try requireCurrent(expected)
            needsCredentialVerification = true
            enteredRequest = true
            let replacement = try await fetch(expected.session)
            try Task.checkCancellation()
            try requireCurrent(expected)
            settlementAttempted = true
            let saved = try await storage.finishObservation(observation, replacement, false)
            // A successful durable commit must be published even if this waiter was
            // cancelled afterwards. A newer login intent still defeats publication.
            try requireCurrent(expected)
            guard saved.session == replacement, saved.loginID == expected.loginID else {
                throw ProtectedAccountSessionError.invalidRecord
            }
            session = replacement
            revision = UUID()
            needsCredentialVerification = saved.requiresCredentialVerification
            if audio.current == nil, !saved.audioRevoked, !saved.requiresCredentialVerification {
                audio.publishAuthenticatedSession(loginID: expected.loginID)
            }
            await storage.abandonObservation(observation)
            return replacement
        } catch {
            if !settlementAttempted, intent === expected.intent, revision == expected.revision,
               loginID == expected.loginID, session == expected.session,
               !enteredRequest || isTemporaryFailure(error) {
                do {
                    let settled = try await storage.finishObservation(observation, nil, true)
                    if intent === expected.intent, loginID == expected.loginID, session == expected.session {
                        needsCredentialVerification = settled.requiresCredentialVerification
                    }
                }
                catch let settlement {
                    await storage.abandonObservation(observation)
                    throw IOSAuthenticationPersistenceFailure(original: error, persistence: settlement)
                }
            }
            await storage.abandonObservation(observation)
            throw error
        }
    }

    func clear(intent expected: IOSAuthenticationIntent) async throws {
        try requireCurrent(expected)
        let publication = try beginPublication()
        defer { endPublication(publication) }
        try await storage.delete(expected)
        try requireCurrent(expected)
        session = nil
        loginID = nil
        needsCredentialVerification = false
        revision = UUID()
    }

    /// Startup/test-only empty state; never grants or restores an audio epoch.
    func clearPublishedSession(intent expected: IOSAuthenticationIntent) throws {
        try requireCurrent(expected)
        session = nil
        loginID = nil
        needsCredentialVerification = false
        revision = UUID()
        audio.beginMutation()
    }

    func revokeAudio(expected: Witness) async throws {
        guard intent === expected.intent, loginID == expected.loginID, let session,
              session.userIdentifier == expected.session.userIdentifier,
              session.accessToken == expected.session.accessToken,
              session.refreshToken == expected.session.refreshToken,
              audio.current === expected.audioAuthorization else { return }
        // Revoke live consumers before suspension; only a successful write makes
        // this rejection durable. An unsettled refresh marker covers failed writes.
        audio.beginMutation()
        try await storage.revokeAudio(session, expected.loginID, expected.intent)
    }

    func requireAudioAuthorization(_ expected: AccountAudioAuthorization) throws {
        try audio.requireCurrent(expected)
    }

    private func audioPersistenceOwner(_ authorization: AccountAudioAuthorization) throws -> Witness {
        try requireAudioAuthorization(authorization)
        let owner = try witness()
        guard owner.loginID == authorization.loginID, owner.audioAuthorization === authorization else {
            throw AudioMembershipLeaseFailure.accountChanged
        }
        return owner
    }

    func loadAudioMembershipCheckpoint(for authorization: AccountAudioAuthorization,
                                       keychain: KeychainManager) async throws -> AudioMembershipPersistenceSnapshot {
        let owner = try audioPersistenceOwner(authorization)
        let snapshot = try await keychain.loadAudioMembershipCheckpoint(loginID: owner.loginID, intent: owner.intent)
        _ = try audioPersistenceOwner(authorization)
        return snapshot
    }

    func saveAudioMembershipCheckpoint(_ bytes: Data?, replacing revision: UUID,
                                       for authorization: AccountAudioAuthorization,
                                       keychain: KeychainManager) async throws -> AudioMembershipPersistenceSnapshot {
        let owner = try audioPersistenceOwner(authorization)
        let snapshot = try await keychain.saveAudioMembershipCheckpoint(bytes,
            replacing: revision, loginID: owner.loginID, intent: owner.intent)
        _ = try audioPersistenceOwner(authorization)
        return snapshot
    }

    func beginAudioMembershipObservation(for authorization: AccountAudioAuthorization,
                                         keychain: KeychainManager) async throws -> AudioMembershipPersistenceObservation {
        let owner = try audioPersistenceOwner(authorization)
        let ticket = try await keychain.beginAccountObservation(kind: .devices,
            expected: owner.session, loginID: owner.loginID, intent: owner.intent)
        do { _ = try audioPersistenceOwner(authorization) }
        catch { await keychain.abandonAccountObservation(ticket); throw error }
        return AudioMembershipPersistenceObservation(finish: { [self] revision, checkpoint in
            _ = try audioPersistenceOwner(authorization)
            let saved = try await keychain.finishAccountObservation(ticket,
                checkpoint: checkpoint, expectedAudioRevision: revision)
            _ = try audioPersistenceOwner(authorization)
            return .init(revision: saved.audioRevision, checkpoint: saved.audioCheckpoint)
        }, abandon: { await keychain.abandonAccountObservation(ticket) })
    }

    private func publish(_ record: IOSAuthSessionRecord) throws {
        guard let replacement = record.session, let loginID = record.loginID else {
            throw ProtectedAccountSessionError.missingSession
        }
        session = replacement
        self.loginID = loginID
        revision = UUID()
        needsCredentialVerification = record.requiresCredentialVerification
        audio.beginMutation()
        // This is an account epoch, not peer playback evidence. An interrupted
        // device query must allow a fresh authenticated GET, while the native
        // checkpoint boundary rejects its old evidence until that query settles.
        // Unverified credentials and known account revocation still publish none.
        if !record.audioRevoked, !record.requiresCredentialVerification {
            audio.publishAuthenticatedSession(loginID: loginID)
        }
    }

    private func beginPublication() throws -> UUID {
        guard publicationID == nil else { throw IOSAuthenticationSessionError.publicationInProgress }
        let id = UUID(); publicationID = id
        return id
    }

    private func endPublication(_ id: UUID) {
        if publicationID == id { publicationID = nil }
    }
}
