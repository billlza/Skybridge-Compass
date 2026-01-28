import Foundation
import OSLog

/// A small, UI-friendly bridge that tracks whether we currently have any active, established
/// secure sessions (post-handshake).
///
/// Why:
/// - The actual handshake lives in lower-level discovery/control loops (Bonjour / WebRTC).
/// - The macOS UI wants a single place to observe: "connected?", plus human-readable crypto info.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class ConnectionPresenceService: ObservableObject {
    public static let shared = ConnectionPresenceService()
    
    public struct ActiveConnection: Identifiable, Sendable, Hashable {
        public let id: String // peerId (e.g. bonjour:<name>@local.)
        public let displayName: String
        public let cryptoKind: String // ApplePQC / Hybrid / Classic (user-facing category)
        public let suite: String // e.g. ML-KEM-768, X-Wing, X25519
        public let connectedAt: Date
        
        public init(
            id: String,
            displayName: String,
            cryptoKind: String,
            suite: String,
            connectedAt: Date = Date()
        ) {
            self.id = id
            self.displayName = displayName
            self.cryptoKind = cryptoKind
            self.suite = suite
            self.connectedAt = connectedAt
        }
    }
    
    @Published public private(set) var activeConnections: [ActiveConnection] = []
    
    public struct RekeyStatus: Sendable, Hashable {
        public let peerId: String
        public let fromKind: String
        public let fromSuite: String
        public let toKind: String
        public let toSuite: String
        public let startedAt: Date
        
        public init(
            peerId: String,
            fromKind: String,
            fromSuite: String,
            toKind: String,
            toSuite: String,
            startedAt: Date = Date()
        ) {
            self.peerId = peerId
            self.fromKind = fromKind
            self.fromSuite = fromSuite
            self.toKind = toKind
            self.toSuite = toSuite
            self.startedAt = startedAt
        }
    }
    
    /// Active in-band rekey status (Classic -> PQC, etc). Keyed by peerId.
    @Published public private(set) var rekeyStatusByPeerId: [String: RekeyStatus] = [:]
    
    public var isConnected: Bool { !activeConnections.isEmpty }
    public var connectedCount: Int { activeConnections.count }
    public func isRekeying(peerId: String) -> Bool { rekeyStatusByPeerId[peerId] != nil }
    
    private let logger = Logger(subsystem: "com.skybridge.core", category: "ConnectionPresence")
    
    private init() {}
    
    public func markConnected(
        peerId: String,
        displayName: String,
        cryptoKind: String,
        suite: String
    ) {
        let conn = ActiveConnection(
            id: peerId,
            displayName: displayName,
            cryptoKind: cryptoKind,
            suite: suite,
            connectedAt: Date()
        )
        
        // Upsert (avoid duplicates on reconnect/rekey)
        if let idx = activeConnections.firstIndex(where: { $0.id == peerId }) {
            activeConnections[idx] = conn
        } else {
            activeConnections.append(conn)
        }
        
        logger.info("✅ presence connected: peer=\(peerId, privacy: .public) kind=\(cryptoKind, privacy: .public) suite=\(suite, privacy: .public)")
        // If we were in a "rekeying" state for this peer, clear it on successful connection update.
        rekeyStatusByPeerId.removeValue(forKey: peerId)
    }
    
    public func markRekeying(_ status: RekeyStatus) {
        rekeyStatusByPeerId[status.peerId] = status
        logger.info("🔁 presence rekeying: peer=\(status.peerId, privacy: .public) \(status.fromKind, privacy: .public)·\(status.fromSuite, privacy: .public) -> \(status.toKind, privacy: .public)·\(status.toSuite, privacy: .public)")
    }
    
    public func clearRekeying(peerId: String) {
        rekeyStatusByPeerId.removeValue(forKey: peerId)
    }
    
    public func markDisconnected(peerId: String) {
        activeConnections.removeAll { $0.id == peerId }
        rekeyStatusByPeerId.removeValue(forKey: peerId)
        logger.info("⏹️ presence disconnected: peer=\(peerId, privacy: .public)")
    }
}


