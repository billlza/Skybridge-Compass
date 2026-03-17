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

    public enum PresenceRouteSource: String, Sendable, Hashable {
        case inbound
        case outbound
        case presence
        case webrtc
        case compatibility
    }

    public struct PresenceRouteDescriptor: Sendable, Hashable {
        public let peerId: String
        public let deviceName: String
        public let displayAddress: String
        public let transferAddress: String
        public let transferPort: Int
        public let routeSource: PresenceRouteSource
        public let connectedAt: Date

        public init(
            peerId: String,
            deviceName: String,
            displayAddress: String,
            transferAddress: String,
            transferPort: Int,
            routeSource: PresenceRouteSource,
            connectedAt: Date = Date()
        ) {
            self.peerId = peerId
            self.deviceName = deviceName
            self.displayAddress = displayAddress
            self.transferAddress = transferAddress
            self.transferPort = transferPort
            self.routeSource = routeSource
            self.connectedAt = connectedAt
        }

        public var isComplete: Bool {
            !peerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !displayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !transferAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (0...65535).contains(transferPort)
        }
    }
    
    public struct ActiveConnection: Identifiable, Sendable, Hashable {
        public let id: String // peerId (e.g. bonjour:<name>@local.)
        public let displayName: String
        public let address: String? // IP/Host address for file transfer
        public let cryptoKind: String // X-Wing / Apple PQC / liboqs / Classic (user-facing category)
        public let suite: String // e.g. ML-KEM-768, X-Wing, X25519
        public let connectedAt: Date
        
        public init(
            id: String,
            displayName: String,
            address: String? = nil,
            cryptoKind: String,
            suite: String,
            connectedAt: Date = Date()
        ) {
            self.id = id
            self.displayName = displayName
            self.address = address
            self.cryptoKind = cryptoKind
            self.suite = suite
            self.connectedAt = connectedAt
        }
    }
    
    @Published public private(set) var activeConnections: [ActiveConnection] = []
    @Published public private(set) var routeDescriptorsByPeerId: [String: PresenceRouteDescriptor] = [:]
    
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
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor? = nil
    ) {
        if let routeDescriptor {
            _ = publishConnectedAtomically(
                peerId: peerId,
                displayName: displayName,
                address: address,
                cryptoKind: cryptoKind,
                suite: suite,
                routeDescriptor: routeDescriptor
            )
            return
        }

        let conn = ActiveConnection(
            id: peerId,
            displayName: displayName,
            address: address,
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

        if let compatibilityRoute = makeCompatibilityRouteDescriptor(
            peerId: peerId,
            displayName: displayName,
            address: address,
            connectedAt: conn.connectedAt
        ),
           routeDescriptorsByPeerId[peerId]?.routeSource == nil ||
           routeDescriptorsByPeerId[peerId]?.routeSource == .compatibility {
            routeDescriptorsByPeerId[peerId] = compatibilityRoute
        }
        
        logger.info("✅ presence connected: peer=\(peerId, privacy: .public) addr=\(address ?? "nil", privacy: .public) kind=\(cryptoKind, privacy: .public) suite=\(suite, privacy: .public)")
        // If we were in a "rekeying" state for this peer, clear it on successful connection update.
        rekeyStatusByPeerId.removeValue(forKey: peerId)
    }

    @discardableResult
    public func publishConnectedAtomically(
        peerId: String,
        displayName: String,
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor
    ) -> Bool {
        guard routeDescriptor.isComplete else {
            logger.error("❌ presence route contract incomplete: peer=\(peerId, privacy: .public)")
            return false
        }

        let conn = ActiveConnection(
            id: peerId,
            displayName: displayName,
            address: address ?? routeDescriptor.displayAddress,
            cryptoKind: cryptoKind,
            suite: suite,
            connectedAt: routeDescriptor.connectedAt
        )

        routeDescriptorsByPeerId[peerId] = routeDescriptor

        if let idx = activeConnections.firstIndex(where: { $0.id == peerId }) {
            activeConnections[idx] = conn
        } else {
            activeConnections.append(conn)
        }

        rekeyStatusByPeerId.removeValue(forKey: peerId)
        logger.info(
            """
            ✅ presence connected+route: peer=\(peerId, privacy: .public) \
            display=\(routeDescriptor.displayAddress, privacy: .public) \
            transfer=\(routeDescriptor.transferAddress, privacy: .public):\(routeDescriptor.transferPort, privacy: .public) \
            source=\(routeDescriptor.routeSource.rawValue, privacy: .public)
            """
        )
        return true
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
        routeDescriptorsByPeerId.removeValue(forKey: peerId)
        logger.info("⏹️ presence disconnected: peer=\(peerId, privacy: .public)")
    }

    public func activeRouteDescriptors() -> [PresenceRouteDescriptor] {
        routeDescriptorsByPeerId.values.sorted { $0.connectedAt > $1.connectedAt }
    }

    private func makeCompatibilityRouteDescriptor(
        peerId: String,
        displayName: String,
        address: String?,
        connectedAt: Date
    ) -> PresenceRouteDescriptor? {
        guard let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAddress.isEmpty else {
            return nil
        }

        return PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: displayName,
            displayAddress: trimmedAddress,
            transferAddress: trimmedAddress,
            transferPort: 8080,
            routeSource: .compatibility,
            connectedAt: connectedAt
        )
    }
}
