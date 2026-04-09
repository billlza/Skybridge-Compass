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

    private func aliasSet(for peerId: String) -> Set<String> {
        Set(
            PeerTrustLookup.lookupCandidates(for: peerId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func stableDevicePeerId(ifPossible peerId: String) -> String? {
        guard let trimmed = PeerTrustLookup.trimmedIdentifier(peerId) else { return nil }
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("id:") {
            let raw = String(normalized.dropFirst(3))
            return UUID(uuidString: raw) == nil ? nil : normalized
        }
        guard UUID(uuidString: normalized) != nil else { return nil }
        return "id:\(normalized)"
    }

    private func canonicalPresencePeerId(for peerId: String) -> String {
        let aliases = aliasSet(for: peerId)

        let existingPeerIds = Set(activeConnections.map(\.id))
            .union(routeDescriptorsByPeerId.keys)
            .union(rekeyStatusByPeerId.keys)

        let matchingPeerIds = existingPeerIds.filter { candidate in
            !aliasSet(for: candidate).isDisjoint(with: aliases)
        }

        if let stableMatch = matchingPeerIds.first(where: { candidate in
            candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("id:")
        }) {
            return stableMatch
        }

        if let persistentPeerId = stableDevicePeerId(ifPossible: peerId) {
            return persistentPeerId
        }

        if let existingMatch = matchingPeerIds.first {
            return existingMatch
        }

        return peerId
    }

    private func purgePresenceArtifacts(
        matching peerId: String,
        keeping keptPeerId: String? = nil
    ) {
        let aliases = aliasSet(for: peerId)

        activeConnections.removeAll { connection in
            let matches = !aliasSet(for: connection.id).isDisjoint(with: aliases)
            return matches && connection.id != keptPeerId
        }

        routeDescriptorsByPeerId = routeDescriptorsByPeerId.filter { key, _ in
            let matches = !aliasSet(for: key).isDisjoint(with: aliases)
            return !matches || key == keptPeerId
        }

        rekeyStatusByPeerId = rekeyStatusByPeerId.filter { key, _ in
            let matches = !aliasSet(for: key).isDisjoint(with: aliases)
            return !matches || key == keptPeerId
        }
    }
    
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

        let canonicalPeerId = canonicalPresencePeerId(for: peerId)
        purgePresenceArtifacts(matching: peerId, keeping: canonicalPeerId)

        let conn = ActiveConnection(
            id: canonicalPeerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            connectedAt: Date()
        )
        
        // Upsert (avoid duplicates on reconnect/rekey)
        if let idx = activeConnections.firstIndex(where: { $0.id == canonicalPeerId }) {
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
           routeDescriptorsByPeerId[canonicalPeerId]?.routeSource == nil ||
           routeDescriptorsByPeerId[canonicalPeerId]?.routeSource == .compatibility {
            routeDescriptorsByPeerId[canonicalPeerId] = PresenceRouteDescriptor(
                peerId: canonicalPeerId,
                deviceName: compatibilityRoute.deviceName,
                displayAddress: compatibilityRoute.displayAddress,
                transferAddress: compatibilityRoute.transferAddress,
                transferPort: compatibilityRoute.transferPort,
                routeSource: compatibilityRoute.routeSource,
                connectedAt: compatibilityRoute.connectedAt
            )
        }
        
        logger.info("✅ presence connected: peer=\(canonicalPeerId, privacy: .public) addr=\(address ?? "nil", privacy: .public) kind=\(cryptoKind, privacy: .public) suite=\(suite, privacy: .public)")
        // If we were in a "rekeying" state for this peer, clear it on successful connection update.
        rekeyStatusByPeerId.removeValue(forKey: canonicalPeerId)
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

        let canonicalPeerId = canonicalPresencePeerId(for: peerId)
        purgePresenceArtifacts(matching: peerId, keeping: canonicalPeerId)
        let canonicalRouteDescriptor = PresenceRouteDescriptor(
            peerId: canonicalPeerId,
            deviceName: routeDescriptor.deviceName,
            displayAddress: routeDescriptor.displayAddress,
            transferAddress: routeDescriptor.transferAddress,
            transferPort: routeDescriptor.transferPort,
            routeSource: routeDescriptor.routeSource,
            connectedAt: routeDescriptor.connectedAt
        )

        let conn = ActiveConnection(
            id: canonicalPeerId,
            displayName: displayName,
            address: address ?? canonicalRouteDescriptor.displayAddress,
            cryptoKind: cryptoKind,
            suite: suite,
            connectedAt: canonicalRouteDescriptor.connectedAt
        )

        routeDescriptorsByPeerId[canonicalPeerId] = canonicalRouteDescriptor

        if let idx = activeConnections.firstIndex(where: { $0.id == canonicalPeerId }) {
            activeConnections[idx] = conn
        } else {
            activeConnections.append(conn)
        }

        rekeyStatusByPeerId.removeValue(forKey: canonicalPeerId)
        logger.info(
            """
            ✅ presence connected+route: peer=\(canonicalPeerId, privacy: .public) \
            display=\(canonicalRouteDescriptor.displayAddress, privacy: .public) \
            transfer=\(canonicalRouteDescriptor.transferAddress, privacy: .public):\(canonicalRouteDescriptor.transferPort, privacy: .public) \
            source=\(canonicalRouteDescriptor.routeSource.rawValue, privacy: .public)
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
        purgePresenceArtifacts(matching: peerId)
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
        guard let transferPort = ServiceEndpointRegistry.shared.snapshot().fileTransferPort,
              (1...65535).contains(Int(transferPort)) else {
            return nil
        }

        return PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: displayName,
            displayAddress: trimmedAddress,
            transferAddress: trimmedAddress,
            transferPort: Int(transferPort),
            routeSource: .compatibility,
            connectedAt: connectedAt
        )
    }
}
