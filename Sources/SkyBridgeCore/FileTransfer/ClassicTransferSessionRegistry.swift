import CryptoKit
import Foundation
import struct SkyBridgeProtocolCore.ClassicTransferPeerCapabilities

/// One immutable read of the keys that actually protect this file transfer.
/// The opaque reference and key cannot be taken from different rekey generations.
@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferKeyMaterial: Sendable {
    let transferKey: SymmetricKey
    let sessionReference: String?
    let role: HandshakeRole
    let negotiatedSuite: CryptoSuite
    let approvalCapability: Bool?

    func matches(_ other: Self) -> Bool {
        guard sessionReference == other.sessionReference, role == other.role,
              negotiatedSuite == other.negotiatedSuite else { return false }
        return transferKey.withUnsafeBytes { lhs in
            other.transferKey.withUnsafeBytes { rhs in
                guard lhs.count == rhs.count else { return false }
                var difference: UInt8 = 0
                for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
                return difference == 0
            }
        }
    }

    init(sessionKeys: SessionKeys, transferId: String, capabilityEvidence: ClassicTransferPeerCapabilities? = nil) {
        transferKey = sessionKeys.deriveClassicFileTransferKey(transferId: transferId)
        sessionReference = P2PEvidenceReference.sessionIncarnation(
            sessionID: sessionKeys.sessionId,
            transcriptHash: sessionKeys.transcriptHash
        )
        role = sessionKeys.role
        negotiatedSuite = sessionKeys.negotiatedSuite
        approvalCapability = capabilityEvidence?.approvalSupport(sessionID: sessionKeys.sessionId, transcriptHash: sessionKeys.transcriptHash)
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferSessionSnapshot: Sendable {
    let sessionId: String
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let aliases: [String]
    let endpointHostOrIP: String?
    let capabilities: [String]
    let capabilityEvidence: ClassicTransferPeerCapabilities?
    let sessionKeys: SessionKeys
    let lastSeenAt: Date

    init(
        sessionId: String,
        matchDeviceId: String,
        resolvedPeerDeviceId: String,
        aliases: [String],
        endpointHostOrIP: String?,
        capabilities: [String],
        sessionKeys: SessionKeys,
        capabilityEvidence: ClassicTransferPeerCapabilities? = nil,
        lastSeenAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.matchDeviceId = matchDeviceId
        self.resolvedPeerDeviceId = resolvedPeerDeviceId
        self.aliases = aliases
        self.endpointHostOrIP = endpointHostOrIP
        self.capabilities = capabilities
        self.capabilityEvidence = capabilityEvidence
        self.sessionKeys = sessionKeys
        self.lastSeenAt = lastSeenAt
    }

    func deriveClassicFileTransferKey(transferId: String) -> SymmetricKey {
        sessionKeys.deriveClassicFileTransferKey(transferId: transferId)
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension SessionKeys {
    func deriveClassicFileTransferKey(transferId: String) -> SymmetricKey {
        let orderedKeys = [sendKey, receiveKey].sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        let combinedMaterial = orderedKeys.reduce(into: Data()) { partial, key in
            partial.append(key)
        }

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combinedMaterial),
            salt: Data("skybridge-classic-file-transfer-v1".utf8),
            info: Data(transferId.utf8),
            outputByteCount: 32
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
actor ClassicTransferSessionRegistry {
    static let shared = ClassicTransferSessionRegistry()
    static let sessionSnapshotTimeToLive: TimeInterval = 120

    struct SessionLease: Sendable, Hashable {
        fileprivate let ownerId: UUID
        let sessionId: String
    }

    struct ConnectionLease: Sendable, Hashable {
        fileprivate let ownerId: UUID
        fileprivate let normalizedPeerKeys: Set<String>
    }

    private enum ConnectionOwner: Equatable {
        case legacy
        case lease(UUID)
    }

    private struct ConnectionRegistration {
        let connection: P2PConnection
        let owner: ConnectionOwner
    }

    private enum SessionOwner: Equatable {
        case legacy
        case lease(UUID)
    }

    struct SessionReadHandle: Sendable {
        let snapshot: ClassicTransferSessionSnapshot
        fileprivate let generation: UUID
    }

    private struct SessionRegistration {
        let generation: UUID
        let snapshot: ClassicTransferSessionSnapshot
        let owner: SessionOwner
    }

    private var connectionsByKey: [String: ConnectionRegistration] = [:]
    private var sessionsById: [String: SessionRegistration] = [:]

    private init() {}

    func upsert(connection: P2PConnection, peerKeys: [String]) {
        for normalized in normalizedPeerKeys(peerKeys) {
            connectionsByKey[normalized] = ConnectionRegistration(
                connection: connection,
                owner: .legacy
            )
        }
    }

    @discardableResult
    func upsertOwned(connection: P2PConnection, peerKeys: [String]) -> ConnectionLease {
        let ownerId = UUID()
        let normalizedKeys = normalizedPeerKeys(peerKeys)
        for normalized in normalizedKeys {
            connectionsByKey[normalized] = ConnectionRegistration(
                connection: connection,
                owner: .lease(ownerId)
            )
        }
        return ConnectionLease(ownerId: ownerId, normalizedPeerKeys: normalizedKeys)
    }

    func remove(peerKeys: [String]) {
        var normalizedPeerKeys = Set<String>()
        for key in peerKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: trimmed) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                normalizedPeerKeys.insert(normalized)
                if connectionsByKey[normalized]?.owner == .legacy {
                    connectionsByKey.removeValue(forKey: normalized)
                }
            }
        }

        guard !normalizedPeerKeys.isEmpty else { return }
        var legacySessionIdsToRemove: [String] = []
        for (sessionId, registration) in sessionsById {
            if registration.owner == .legacy,
               !normalizedPeerKeys.isDisjoint(
                    with: normalizedLookupCandidates(for: registration.snapshot)
               ) {
                legacySessionIdsToRemove.append(sessionId)
            }
        }
        for sessionId in legacySessionIdsToRemove {
            sessionsById.removeValue(forKey: sessionId)
        }
    }

    func activeConnections() -> [P2PConnection] {
        var deduped: [ObjectIdentifier: P2PConnection] = [:]
        for registration in connectionsByKey.values {
            let connection = registration.connection
            deduped[ObjectIdentifier(connection)] = connection
        }
        return Array(deduped.values)
    }

    @discardableResult
    func remove(ifOwned lease: ConnectionLease) -> Bool {
        var removedAny = false
        for normalized in lease.normalizedPeerKeys
        where connectionsByKey[normalized]?.owner == .lease(lease.ownerId) {
            connectionsByKey.removeValue(forKey: normalized)
            removedAny = true
        }
        return removedAny
    }

    func upsert(session snapshot: ClassicTransferSessionSnapshot) {
        sessionsById[snapshot.sessionId] = SessionRegistration(
            generation: UUID(),
            snapshot: snapshot,
            owner: .legacy
        )
    }

    @discardableResult
    func upsertOwned(session snapshot: ClassicTransferSessionSnapshot) -> SessionLease {
        let ownerId = UUID()
        sessionsById[snapshot.sessionId] = SessionRegistration(
            generation: UUID(),
            snapshot: snapshot,
            owner: .lease(ownerId)
        )
        return SessionLease(ownerId: ownerId, sessionId: snapshot.sessionId)
    }

    /// Replaces an authenticated snapshot without changing its exact owner.
    ///
    /// Callers may use this only after validating identity-bearing fields through
    /// the authenticated SOA/PIB path. Heartbeats must use `refreshIfOwned`, which
    /// deliberately preserves identity, aliases, and session keys.
    @discardableResult
    func updateAuthenticatedSessionIfOwned(
        _ lease: SessionLease,
        snapshot: ClassicTransferSessionSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard snapshot.sessionId == lease.sessionId,
              let registration = liveSessionRegistration(ifOwned: lease, now: now) else {
            return false
        }
        sessionsById[lease.sessionId] = SessionRegistration(
            generation: registration.generation,
            snapshot: snapshot,
            owner: registration.owner
        )
        return true
    }

    /// Refreshes liveness and non-authoritative route hints for one exact owner.
    /// Identity-bearing fields and cryptographic session material are copied from
    /// the existing authenticated snapshot and cannot be changed by heartbeat data.
    @discardableResult
    func refreshIfOwned(
        _ lease: SessionLease,
        capabilities: [String]? = nil,
        fileTransferPort: UInt16? = nil,
        remoteControlPort: UInt16? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let registration = liveSessionRegistration(ifOwned: lease, now: now) else {
            return false
        }
        let current = registration.snapshot
        let refreshed = ClassicTransferSessionSnapshot(
            sessionId: current.sessionId,
            matchDeviceId: current.matchDeviceId,
            resolvedPeerDeviceId: current.resolvedPeerDeviceId,
            aliases: current.aliases,
            endpointHostOrIP: current.endpointHostOrIP,
            capabilities: refreshedCapabilities(
                current: current.capabilities,
                advertised: capabilities,
                fileTransferPort: fileTransferPort,
                remoteControlPort: remoteControlPort
            ),
            sessionKeys: current.sessionKeys,
            capabilityEvidence: current.capabilityEvidence,
            lastSeenAt: now
        )
        sessionsById[lease.sessionId] = SessionRegistration(
            generation: registration.generation,
            snapshot: refreshed,
            owner: registration.owner
        )
        return true
    }

    func remove(sessionId: String) {
        guard sessionsById[sessionId]?.owner == .legacy else { return }
        sessionsById.removeValue(forKey: sessionId)
    }

    @discardableResult
    func remove(ifOwned lease: SessionLease) -> Bool {
        guard sessionsById[lease.sessionId]?.owner == .lease(lease.ownerId) else {
            return false
        }
        sessionsById.removeValue(forKey: lease.sessionId)
        return true
    }

    func activeSessionHandles(now: Date = Date()) -> [SessionReadHandle] {
        pruneExpiredSessions(now: now)
        return sessionsById.values.map {
            SessionReadHandle(snapshot: $0.snapshot, generation: $0.generation)
        }
    }

    func currentKeyMaterial(
        for handle: SessionReadHandle, transferId: String, now: Date = Date()
    ) -> ClassicTransferKeyMaterial? {
        pruneExpiredSessions(now: now)
        guard let registration = sessionsById[handle.snapshot.sessionId],
              registration.generation == handle.generation else { return nil }
        return ClassicTransferKeyMaterial(sessionKeys: registration.snapshot.sessionKeys, transferId: transferId, capabilityEvidence: registration.snapshot.capabilityEvidence)
    }

    func activeSessions(now: Date = Date()) -> [ClassicTransferSessionSnapshot] {
        pruneExpiredSessions(now: now)
        return sessionsById.values.map(\.snapshot).sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            return lhs.sessionId > rhs.sessionId
        }
    }

    private func pruneExpiredSessions(now: Date) {
        let expiredSessionIds = sessionsById.compactMap { sessionId, registration in
            now.timeIntervalSince(registration.snapshot.lastSeenAt) > Self.sessionSnapshotTimeToLive
                ? sessionId
                : nil
        }
        for sessionId in expiredSessionIds {
            sessionsById.removeValue(forKey: sessionId)
        }
    }

    private func liveSessionRegistration(
        ifOwned lease: SessionLease,
        now: Date
    ) -> SessionRegistration? {
        guard let registration = sessionsById[lease.sessionId],
              registration.owner == .lease(lease.ownerId) else {
            return nil
        }
        guard now.timeIntervalSince(registration.snapshot.lastSeenAt)
                <= Self.sessionSnapshotTimeToLive else {
            sessionsById.removeValue(forKey: lease.sessionId)
            return nil
        }
        return registration
    }

    private func refreshedCapabilities(
        current: [String],
        advertised: [String]?,
        fileTransferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> [String] {
        var base = advertised ?? current

        func removeAssignment(_ normalizedKey: String) {
            base.removeAll { capability in
                let key = capability.split(separator: "=", maxSplits: 1).first
                    .map(String.init) ?? capability
                return key
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber } == normalizedKey
            }
        }

        if fileTransferPort != nil {
            removeAssignment("filetransferport")
        }
        if remoteControlPort != nil {
            removeAssignment("remotecontrolport")
        }
        return ClassicTransferCapability.normalizedRemoteCapabilities(
            base,
            fileTransferPort: fileTransferPort,
            remoteControlPort: remoteControlPort
        )
    }

    private func normalizedLookupCandidates(for snapshot: ClassicTransferSessionSnapshot) -> Set<String> {
        let values = [
            [snapshot.sessionId, snapshot.matchDeviceId, snapshot.resolvedPeerDeviceId],
            snapshot.aliases,
            [snapshot.endpointHostOrIP].compactMap { $0 }
        ].flatMap { $0 }

        return values.reduce(into: Set<String>()) { result, value in
            for candidate in PeerTrustLookup.lookupCandidates(for: value) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                result.insert(normalized)
            }
        }
    }

    private func normalizedPeerKeys(_ peerKeys: [String]) -> Set<String> {
        peerKeys.reduce(into: Set<String>()) { result, key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            for candidate in PeerTrustLookup.lookupCandidates(for: trimmed) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                result.insert(normalized)
            }
        }
    }
}
