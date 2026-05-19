import CryptoKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct ClassicTransferSessionSnapshot: Sendable {
    let sessionId: String
    let matchDeviceId: String
    let resolvedPeerDeviceId: String
    let aliases: [String]
    let endpointHostOrIP: String?
    let capabilities: [String]
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
        lastSeenAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.matchDeviceId = matchDeviceId
        self.resolvedPeerDeviceId = resolvedPeerDeviceId
        self.aliases = aliases
        self.endpointHostOrIP = endpointHostOrIP
        self.capabilities = capabilities
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

    private var connectionsByKey: [String: P2PConnection] = [:]
    private var sessionsById: [String: ClassicTransferSessionSnapshot] = [:]

    private init() {}

    func upsert(connection: P2PConnection, peerKeys: [String]) {
        for key in peerKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: trimmed) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                connectionsByKey[normalized] = connection
            }
        }
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
                connectionsByKey.removeValue(forKey: normalized)
            }
        }

        guard !normalizedPeerKeys.isEmpty else { return }
        sessionsById = sessionsById.filter { _, snapshot in
            normalizedPeerKeys.isDisjoint(with: normalizedLookupCandidates(for: snapshot))
        }
    }

    func activeConnections() -> [P2PConnection] {
        var deduped: [ObjectIdentifier: P2PConnection] = [:]
        for connection in connectionsByKey.values {
            deduped[ObjectIdentifier(connection)] = connection
        }
        return Array(deduped.values)
    }

    func upsert(session snapshot: ClassicTransferSessionSnapshot) {
        sessionsById[snapshot.sessionId] = snapshot
    }

    func remove(sessionId: String) {
        sessionsById.removeValue(forKey: sessionId)
    }

    func activeSessions(now: Date = Date()) -> [ClassicTransferSessionSnapshot] {
        pruneExpiredSessions(now: now)
        return sessionsById.values.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            return lhs.sessionId > rhs.sessionId
        }
    }

    private func pruneExpiredSessions(now: Date) {
        sessionsById = sessionsById.filter { _, snapshot in
            now.timeIntervalSince(snapshot.lastSeenAt) <= Self.sessionSnapshotTimeToLive
        }
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
}
