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
        for key in peerKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: trimmed) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                connectionsByKey.removeValue(forKey: normalized)
            }
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

    func activeSessions() -> [ClassicTransferSessionSnapshot] {
        Array(sessionsById.values)
    }
}
