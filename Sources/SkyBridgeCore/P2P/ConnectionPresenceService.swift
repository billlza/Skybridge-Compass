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

    struct PresenceLease: Sendable, Hashable {
        fileprivate let ownerId: UUID
        let peerId: String
    }

    private enum PresenceOwner: Equatable {
        case legacy
        case lease(UUID)
    }

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
            (1...65535).contains(transferPort)
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
    private var presenceOwnersByPeerId: [String: PresenceOwner] = [:]
    
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
            .union(presenceOwnersByPeerId.keys)

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

        presenceOwnersByPeerId = presenceOwnersByPeerId.filter { key, _ in
            let matches = !aliasSet(for: key).isDisjoint(with: aliases)
            return !matches || key == keptPeerId
        }
    }

    private func removePresenceArtifacts(forCanonicalPeerId peerId: String) {
        activeConnections.removeAll { $0.id == peerId }
        routeDescriptorsByPeerId.removeValue(forKey: peerId)
        rekeyStatusByPeerId.removeValue(forKey: peerId)
        presenceOwnersByPeerId.removeValue(forKey: peerId)
        // Drops the per-session row only; the rolling relay-budget window keeps the sample so a
        // relay-dominated deployment stays visible after sessions end.
        ConnectionRouteAttributionRecorder.shared.forget(sessionKey: peerId)
    }

    @discardableResult
    private func publishConnected(
        peerId: String,
        displayName: String,
        address: String?,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor?,
        owner: PresenceOwner
    ) -> String? {
        if let routeDescriptor, !routeDescriptor.isComplete {
            logger.error("❌ presence route contract incomplete: peer=\(peerId, privacy: .public)")
            return nil
        }

        let canonicalPeerId = canonicalPresencePeerId(for: peerId)
        purgePresenceArtifacts(matching: peerId, keeping: canonicalPeerId)

        let canonicalRouteDescriptor = routeDescriptor.map { routeDescriptor in
            PresenceRouteDescriptor(
                peerId: canonicalPeerId,
                deviceName: routeDescriptor.deviceName,
                displayAddress: routeDescriptor.displayAddress,
                transferAddress: routeDescriptor.transferAddress,
                transferPort: routeDescriptor.transferPort,
                routeSource: routeDescriptor.routeSource,
                connectedAt: routeDescriptor.connectedAt
            )
        }
        let connectedAt = canonicalRouteDescriptor?.connectedAt ?? Date()
        let conn = ActiveConnection(
            id: canonicalPeerId,
            displayName: displayName,
            address: address ?? canonicalRouteDescriptor?.displayAddress,
            cryptoKind: cryptoKind,
            suite: suite,
            connectedAt: connectedAt
        )

        if let canonicalRouteDescriptor {
            routeDescriptorsByPeerId[canonicalPeerId] = canonicalRouteDescriptor
        }
        if let idx = activeConnections.firstIndex(where: { $0.id == canonicalPeerId }) {
            activeConnections[idx] = conn
        } else {
            activeConnections.append(conn)
        }
        presenceOwnersByPeerId[canonicalPeerId] = owner
        rekeyStatusByPeerId.removeValue(forKey: canonicalPeerId)

        if let canonicalRouteDescriptor,
           let route = ConnectionTransportRoute(canonicalRouteDescriptor.routeSource) {
            ConnectionRouteAttributionRecorder.shared.record(
                sessionKey: canonicalPeerId,
                route: route
            )
        }

        if let canonicalRouteDescriptor {
            logger.info(
                """
                ✅ presence connected+route: peer=\(canonicalPeerId, privacy: .public) \
                display=\(canonicalRouteDescriptor.displayAddress, privacy: .public) \
                transfer=\(canonicalRouteDescriptor.transferAddress, privacy: .public):\(canonicalRouteDescriptor.transferPort, privacy: .public) \
                source=\(canonicalRouteDescriptor.routeSource.rawValue, privacy: .public)
                """
            )
        } else {
            logger.info("✅ presence connected: peer=\(canonicalPeerId, privacy: .public) addr=\(address ?? "nil", privacy: .public) kind=\(cryptoKind, privacy: .public) suite=\(suite, privacy: .public)")
        }
        return canonicalPeerId
    }

    public func markConnected(
        peerId: String,
        displayName: String,
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor? = nil
    ) {
        _ = publishConnected(
            peerId: peerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            routeDescriptor: routeDescriptor,
            owner: .legacy
        )
    }

    @discardableResult
    func markConnectedOwned(
        peerId: String,
        displayName: String,
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor? = nil
    ) -> PresenceLease? {
        let ownerId = UUID()
        guard let canonicalPeerId = publishConnected(
            peerId: peerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            routeDescriptor: routeDescriptor,
            owner: .lease(ownerId)
        ) else {
            return nil
        }
        return PresenceLease(ownerId: ownerId, peerId: canonicalPeerId)
    }

    @discardableResult
    func refreshConnectedIfOwned(
        _ lease: PresenceLease,
        displayName: String,
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor? = nil
    ) -> Bool {
        guard presenceOwnersByPeerId[lease.peerId] == .lease(lease.ownerId) else {
            return false
        }
        return publishConnected(
            peerId: lease.peerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            routeDescriptor: routeDescriptor,
            owner: .lease(lease.ownerId)
        ) == lease.peerId
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
        publishConnected(
            peerId: peerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            routeDescriptor: routeDescriptor,
            owner: .legacy
        ) != nil
    }

    @discardableResult
    func publishConnectedOwnedAtomically(
        peerId: String,
        displayName: String,
        address: String? = nil,
        cryptoKind: String,
        suite: String,
        routeDescriptor: PresenceRouteDescriptor
    ) -> PresenceLease? {
        markConnectedOwned(
            peerId: peerId,
            displayName: displayName,
            address: address,
            cryptoKind: cryptoKind,
            suite: suite,
            routeDescriptor: routeDescriptor
        )
    }
    
    public func markRekeying(_ status: RekeyStatus) {
        rekeyStatusByPeerId[status.peerId] = status
        logger.info("🔁 presence rekeying: peer=\(status.peerId, privacy: .public) \(status.fromKind, privacy: .public)·\(status.fromSuite, privacy: .public) -> \(status.toKind, privacy: .public)·\(status.toSuite, privacy: .public)")
    }
    
    public func clearRekeying(peerId: String) {
        rekeyStatusByPeerId.removeValue(forKey: peerId)
    }
    
    public func markDisconnected(peerId: String) {
        let aliases = aliasSet(for: peerId)
        var legacyPeerIds: [String] = []
        for (candidatePeerId, owner) in presenceOwnersByPeerId {
            if owner == .legacy,
               !aliasSet(for: candidatePeerId).isDisjoint(with: aliases) {
                legacyPeerIds.append(candidatePeerId)
            }
        }
        guard !legacyPeerIds.isEmpty else {
            logger.debug(
                "Ignoring legacy presence disconnect without legacy ownership: peer=\(peerId, privacy: .public)"
            )
            return
        }
        for canonicalPeerId in legacyPeerIds {
            removePresenceArtifacts(forCanonicalPeerId: canonicalPeerId)
        }
        logger.info("⏹️ legacy presence disconnected: peer=\(peerId, privacy: .public)")
    }

    @discardableResult
    func disconnectIfOwned(_ lease: PresenceLease) -> Bool {
        guard presenceOwnersByPeerId[lease.peerId] == .lease(lease.ownerId) else {
            return false
        }
        removePresenceArtifacts(forCanonicalPeerId: lease.peerId)
        logger.info("⏹️ presence disconnected by exact owner: peer=\(lease.peerId, privacy: .public)")
        return true
    }

    public func activeRouteDescriptors() -> [PresenceRouteDescriptor] {
        routeDescriptorsByPeerId.values.sorted { $0.connectedAt > $1.connectedAt }
    }
}
