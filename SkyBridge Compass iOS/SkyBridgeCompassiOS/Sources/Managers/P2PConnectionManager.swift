import Foundation
import Network
import CryptoKit
import ActivityKit
import Combine
import SkyBridgeProtocolCore
#if canImport(UIKit)
import UIKit
#endif

struct P2PConnectionLease<Connection: AnyObject & Sendable>: Sendable {
    let peerId: String
    let generation: UUID
    let sequence: UInt64
    let connection: Connection
}

struct P2PConnectionLeaseStore<Connection: AnyObject & Sendable> {
    enum LeaseError: Error, Sendable, Equatable {
        case sequenceExhausted
    }

    private var leasesByPeerId: [String: P2PConnectionLease<Connection>] = [:]
    private var nextSequence: UInt64 = 0

    init() {}

    #if DEBUG || SKYBRIDGE_TESTING
    init(testingNextSequence: UInt64) {
        nextSequence = testingNextSequence
    }
    #endif

    var isEmpty: Bool { leasesByPeerId.isEmpty }
    var count: Int { leasesByPeerId.count }
    var keys: [String] { Array(leasesByPeerId.keys) }
    var values: [Connection] { leasesByPeerId.values.map(\.connection) }

    subscript(peerId: String) -> Connection? {
        leasesByPeerId[peerId]?.connection
    }

    func lease(for peerId: String) -> P2PConnectionLease<Connection>? {
        leasesByPeerId[peerId]
    }

    mutating func install(
        _ connection: Connection,
        for peerId: String
    ) throws -> P2PConnectionLease<Connection> {
        let increment = nextSequence.addingReportingOverflow(1)
        guard !increment.overflow else {
            throw LeaseError.sequenceExhausted
        }
        nextSequence = increment.partialValue
        let lease = P2PConnectionLease(
            peerId: peerId,
            generation: UUID(),
            sequence: nextSequence,
            connection: connection
        )
        leasesByPeerId[peerId] = lease
        return lease
    }

    func isCurrent(
        _ lease: P2PConnectionLease<Connection>,
        for peerId: String
    ) -> Bool {
        guard let current = leasesByPeerId[peerId] else { return false }
        return current.generation == lease.generation
            && current.connection === lease.connection
    }

    @discardableResult
    mutating func removeIfOwned(
        _ lease: P2PConnectionLease<Connection>,
        for peerId: String
    ) -> Connection? {
        guard isCurrent(lease, for: peerId) else { return nil }
        return leasesByPeerId.removeValue(forKey: peerId)?.connection
    }

    @discardableResult
    mutating func removeValue(forKey peerId: String) -> Connection? {
        leasesByPeerId.removeValue(forKey: peerId)?.connection
    }
}

@available(iOS 17.0, *)
enum P2PAdvertisingAuthorityStabilizationError: LocalizedError, Equatable {
    case authorityChangedTooFrequently
    case invalidMaximumAttempts(Int)

    var errorDescription: String? {
        switch self {
        case .authorityChangedTooFrequently:
            return "协议身份在 P2P 监听启动期间反复变化，广播已安全停用"
        case .invalidMaximumAttempts(let value):
            return "P2P 广播身份稳定尝试次数必须为正数：\(value)"
        }
    }
}

@available(iOS 17.0, *)
@MainActor
enum P2PAdvertisingAuthorityStabilizer {
    static func applyLatest(
        maximumAttempts: Int = 4,
        loadCommittedAuthority: () async throws -> ProtocolIdentitySnapshot,
        applyAuthority: (ProtocolIdentitySnapshot) async throws -> Void
    ) async throws -> ProtocolIdentitySnapshot {
        guard maximumAttempts > 0 else {
            throw P2PAdvertisingAuthorityStabilizationError
                .invalidMaximumAttempts(maximumAttempts)
        }
        for _ in 0..<maximumAttempts {
            try Task.checkCancellation()
            let candidate = try await loadCommittedAuthority()
            try Task.checkCancellation()
            try await applyAuthority(candidate)
            try Task.checkCancellation()
            let latest = try await loadCommittedAuthority()
            try Task.checkCancellation()
            if latest == candidate {
                return latest
            }
        }
        throw P2PAdvertisingAuthorityStabilizationError.authorityChangedTooFrequently
    }
}

@available(iOS 17.0, *)
private struct P2PStoredHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
    let trustMaterialCandidates: [String]
    let requirePinnedProtocolIdentity: Bool

    private func candidateDeviceIds(for requestedDeviceId: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !PeerIdentityAliasResolver.isEndpointAlias(trimmed),
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }

        for raw in [requestedDeviceId] + trustMaterialCandidates {
            append(raw)
            for alias in PeerIdentityAliasResolver.lookupCandidates(for: raw)
            where !PeerIdentityAliasResolver.isEndpointAlias(alias) {
                append(alias)
            }
        }

        return ordered
    }

    func trustedFingerprint(for deviceId: String) async -> String? {
        await trustedFingerprints(for: deviceId).sorted().first
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        let candidates = candidateDeviceIds(for: deviceId)
        guard await TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: candidates) else {
            return []
        }
        let protocolStoreFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: candidates)
        let trustedDeviceFingerprints = await TrustedDeviceStore.shared.currentPathFingerprints(forAny: candidates)
        return protocolStoreFingerprints.union(trustedDeviceFingerprints)
    }

    func trustedProtocolIdentityPublicKey(
        for deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) async -> Data? {
        guard algorithm == .mlDSA87 else { return nil }
        let candidates = candidateDeviceIds(for: deviceId)
        var matchingKeys = Set<Data>()
        for candidate in candidates {
            if let publicKey = await TrustedDeviceStore.shared
                .currentPathProtocolIdentityKeyBinding(
                    for: candidate,
                    algorithm: algorithm
                )?
                .publicKeyBytes {
                matchingKeys.insert(publicKey)
            }
        }
        guard matchingKeys.count == 1 else { return nil }
        return matchingKeys.first
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let candidates = candidateDeviceIds(for: deviceId)
        guard requirePinnedProtocolIdentity else {
            return await KEMTrustStore.shared.kemPublicKeys(forAny: candidates)
        }
        let pinnedFingerprints = await trustedFingerprints(for: deviceId)
        return await KEMTrustStore.shared.signedRefreshKEMPublicKeys(
            forAny: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        _ = deviceId
        return nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return requirePinnedProtocolIdentity
    }
}

@available(iOS 17.0, *)
enum PairingIdentityAcceptedMaterialDigest {
    private struct Material: Codable, Sendable {
        let declaredDeviceId: String
        let authorizedDeviceIds: [String]
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let protocolPublicKey: Data
        let kemPublicKeys: [KEMPublicKeyInfo]
    }

    nonisolated static func canonicalAuthorityKey(_ deviceId: String) -> String {
        PeerSessionArbiter.canonicalSOAIdentifier(deviceId)
    }

    nonisolated static func compute(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: ValidatedPairingIdentityAuthority
    ) throws -> Data {
        guard let normalizedPayload = payload.normalizedBootstrapPayload else {
            throw PairingIdentityAuthorityValidationError.invalidPayload
        }
        let authorizedDeviceIds = authority.authorizedDeviceIds.map {
            canonicalAuthorityKey($0)
        }.filter { !$0.isEmpty }.sorted()
        let material = Material(
            declaredDeviceId: canonicalAuthorityKey(authority.declaredDeviceId),
            authorizedDeviceIds: authorizedDeviceIds,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint,
            protocolPublicKey: authority.protocolPublicKey,
            kemPublicKeys: normalizedPayload.kemPublicKeys
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(material)))
    }
}

/// P2P 连接管理器 - 管理与其他设备的点对点连接
/// 使用完整的 HandshakeDriver 协议实现与 macOS 的互操作
/// 支持双向握手：iOS 可以发起，也可以响应 macOS 的握手请求
@available(iOS 17.0, *)
@MainActor
public class P2PConnectionManager: ObservableObject {
    public static let instance = P2PConnectionManager()
    private static let pathRecoveryInProgressMessage = "网络路径切换，正在恢复直连"

    public struct RekeyPresentationStatus: Sendable, Equatable {
        public let fromSuite: String
        public let toSuite: String
        public let startedAt: Date

        public init(
            fromSuite: String,
            toSuite: String,
            startedAt: Date = Date()
        ) {
            self.fromSuite = fromSuite
            self.toSuite = toSuite
            self.startedAt = startedAt
        }
    }

    public struct ClassicTransferAuthenticatedPeerDescriptor: Sendable, Equatable {
        public let matchDeviceId: String
        public let resolvedPeerDeviceId: String
        public let aliases: [String]
        public let endpointHostOrIP: String?
        public let capabilities: [String]

        public init(
            matchDeviceId: String,
            resolvedPeerDeviceId: String,
            aliases: [String],
            endpointHostOrIP: String?,
            capabilities: [String]
        ) {
            self.matchDeviceId = matchDeviceId
            self.resolvedPeerDeviceId = resolvedPeerDeviceId
            self.aliases = aliases
            self.endpointHostOrIP = endpointHostOrIP
            self.capabilities = capabilities
        }
    }

    // MARK: - Published Properties

    /// Observable advertising lifecycle.
    ///
    /// Advertising is a *desired state* supervised continuously, not a one-shot startup.
    /// Publishing the state is part of the fix: a silent failure is indistinguishable from
    /// "no peers nearby", which is exactly how a pending local-network permission prompt
    /// used to look like a broken app.
    public enum AdvertisingLifecycleState: Equatable, Sendable {
        case idle
        case starting
        case advertising(port: UInt16)
        case awaitingLocalNetworkAuthorization(nextRetryInSeconds: TimeInterval)
        case retrying(attempt: Int, nextRetryInSeconds: TimeInterval)
        /// Advertising was never attempted because a startup precondition failed.
        ///
        /// Distinct from `idle`: `idle` means "not wanted", this means "wanted but refused".
        /// Without it, a failed identity-authority recovery left the whole app silent — the
        /// listener, discovery and presence were all skipped and nothing was shown anywhere.
        case blockedByStartupFailure(reason: String)

        /// A user-actionable blocker exists and the operator must resolve it.
        public var requiresUserAction: Bool {
            if case .awaitingLocalNetworkAuthorization = self { return true }
            return false
        }

        /// The device is not currently announcing itself to peers.
        public var isSilent: Bool {
            switch self {
            case .advertising: false
            case .idle, .starting, .awaitingLocalNetworkAuthorization, .retrying,
                 .blockedByStartupFailure: true
            }
        }
    }

    /// Records a startup precondition failure that prevents advertising from being attempted.
    func reportAdvertisingBlockedByStartupFailure(reason: String) {
        advertisingLifecycle = .blockedByStartupFailure(reason: reason)
    }

    @Published public private(set) var activeConnections: [Connection] = []
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var advertisingLifecycle: AdvertisingLifecycleState = .idle
    @Published public private(set) var currentHandshakeState: String = "空闲"
    @Published public private(set) var lastError: String?
    /// 每个设备的连接状态（用于 UI 展示“已连接/连接中/已断开”等）
    @Published public private(set) var connectionStatusByDeviceId: [String: ConnectionStatus] = [:]
    /// 每个设备最近一次连接错误（用于定位“莫名其妙断开”原因）
    @Published public private(set) var connectionErrorByDeviceId: [String: String] = [:]
    /// 每个设备当前协商的加密套件（用于 UI/LiveActivity 在 rekey 后正确刷新）
    /// 注意：`sessionKeys` 不是 @Published，因此仅更新 `sessionKeys` 不会触发 SwiftUI 刷新。
    @Published public private(set) var negotiatedSuiteByDeviceId: [String: CryptoSuite] = [:]
    /// 每个设备当前的 rekey 展示态（Classic -> PQC / X-Wing 等），用于 UI 在切换期间展示真实进度。
    @Published public private(set) var rekeyStatusByDeviceId: [String: RekeyPresentationStatus] = [:]

    var shouldPreserveReachabilityInBackground: Bool {
        !connections.isEmpty
            || !sessionKeys.isEmpty
            || !activeConnections.isEmpty
            || !inFlightConnectAliasesByPeerId.isEmpty
            || !reconnectTasks.isEmpty
            || !bootstrapRekeyTasks.isEmpty
            || !rekeyInProgress.isEmpty
            || !rekeyStatusByDeviceId.isEmpty
            || pendingPairingTrustRequest != nil
    }

    var protectedDiscoveryIdentifiers: Set<String> {
        var rootIdentifiers = Set<String>()
        rootIdentifiers.formUnion(connections.keys)
        rootIdentifiers.formUnion(sessionKeys.keys)
        rootIdentifiers.formUnion(inFlightConnectAliasesByPeerId.keys)
        rootIdentifiers.formUnion(inFlightConnectAliasesByPeerId.values.flatMap { $0 })
        rootIdentifiers.formUnion(reconnectTasks.keys)
        rootIdentifiers.formUnion(pathRecoveryTasks.keys)
        rootIdentifiers.formUnion(heartbeatTasks.keys)
        rootIdentifiers.formUnion(bootstrapRekeyTasks.keys)
        rootIdentifiers.formUnion(rekeyInProgress)
        rootIdentifiers.formUnion(rekeyStatusByDeviceId.keys)
        rootIdentifiers.formUnion(peerPresentationIdByRuntimePeerId.keys)
        rootIdentifiers.formUnion(peerPresentationIdByRuntimePeerId.values)
        rootIdentifiers.formUnion(activeConnections.map(\.device.id))

        var identifiers = Set<String>()
        for identifier in rootIdentifiers {
            identifiers.insert(identifier)
            identifiers.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: identifier))

            if let device = lastKnownDevices[identifier] {
                identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
                if let canonical = discoveryManager.canonicalDiscoveredDevice(for: device) {
                    identifiers.insert(canonical.id)
                    identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: canonical))
                }
            }
        }

        for connection in activeConnections {
            identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            if let canonical = discoveryManager.canonicalDiscoveredDevice(for: connection.device) {
                identifiers.insert(canonical.id)
                identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: canonical))
            }
        }
        return identifiers
    }

    var activeDiscoveryIdentifiers: Set<String> {
        var identifiers = Set<String>()
        for connection in activeConnections {
            identifiers.insert(connection.device.id)
            identifiers.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
            identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            if let canonical = discoveryManager.canonicalDiscoveredDevice(for: connection.device) {
                identifiers.insert(canonical.id)
                identifiers.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: canonical.id))
                identifiers.formUnion(PeerIdentityAliasResolver.aliasKeys(for: canonical))
            }
        }
        return identifiers
    }

    // MARK: - Private Properties

    private struct ListeningStartupOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private enum ListeningAuthorityError: LocalizedError {
        case refreshSuperseded

        var errorDescription: String? {
            switch self {
            case .refreshSuperseded:
                return "Bonjour authority 刷新已被更新的协议身份替代"
            }
        }

    }

    enum ListeningFailureDisposition: Sendable, Equatable {
        case retry
        case awaitingLocalNetworkAuthorization
        case blocked(reason: String)
        case superseded
    }

    nonisolated static func listeningFailureDisposition(
        after error: Error
    ) -> ListeningFailureDisposition {
        if error is CancellationError {
            return .superseded
        }
        if DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(error) {
            return .awaitingLocalNetworkAuthorization
        }
        if DeviceDiscoveryManager.shouldRetryAdvertising(after: error) {
            return .retry
        }
        if let rotationError = error as? IOSCurrentPathDeviceIdentityRotationError {
            switch rotationError {
            case .localAuthorityCommittedRecoveryRequired:
                return .retry
            case .authenticationStateChanged,
                 .localConfigurationChanged,
                 .preparedIdentityMismatch,
                 .proofVerificationFailed,
                 .pendingRotationConflictsWithLocalAuthority,
                 .pendingRotationJournalUnsupported,
                 .challengeExpired:
                return .blocked(reason: rotationError.localizedDescription)
            }
        }
        if error is P2PAdvertisingAuthorityStabilizationError {
            return .retry
        }
        return .blocked(reason: error.localizedDescription)
    }

    private var listeningStartupOperation: ListeningStartupOperation?
    /// Bounded recovery for a failed advertising/listening startup. Bonjour publication can
    /// fail for reasons that resolve on their own within seconds (pending local-network
    /// authorization, a control port not yet released by a previous process). Without this
    /// the device stays permanently undiscoverable until the app is backgrounded and
    /// foregrounded again, because nothing else re-drives `startListening()`.
    private var listeningRecoveryTask: Task<Void, Never>?
    private var listeningRecoveryAttempts: Int = 0
    /// Desired state owned by the supervisor. `stopListening()` is the only way to clear it,
    /// so a transient failure can never silently downgrade the device to "not discoverable".
    private var desiredListening: Bool = false
    private var advertisingHealthObservation: AnyCancellable?
    private var listeningPathMonitor: NWPathMonitor?
    private var lastSupervisorNudgeAt: Date?
    /// Flap suppression for the immediate (attempt-resetting) retry triggers. Without it a
    /// bouncing Wi-Fi interface would keep resetting the backoff and hammer startup.
    private static let supervisorNudgeMinimumInterval: TimeInterval = 10
    private var advertisingAuthorityRefreshGeneration: UInt64 = 0
    private var advertisingAuthorityRefreshInProgress = false

    private var connections = P2PConnectionLeaseStore<NWConnection>()
    private static let maximumProvisionalInboundConnections = 32
    private static let provisionalInboundTimeoutSeconds: TimeInterval = 10
    private var provisionalInboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private var provisionalInboundTimeoutTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private struct ProvisionalInboundFrameClassification: Sendable {
        let unwrappedPayload: Data
        let bootstrapMessage: AppMessage?
        let handshakeMessageA: HandshakeMessageA?
    }
    private var sessionKeys: [String: SessionKeys] = [:] // device.id -> SessionKeys
    private var sessionKeyConnectionGenerationByPeerId: [String: UUID] = [:]
    private struct InboundRekeyRollbackRecord {
        let connectionGeneration: UUID
        let handshakeOperationToken: UUID
        let previousKeys: SessionKeys
        let releasedArbiterBinding: ArbiterSessionBinding?
    }
    private var inboundRekeyRollbackByPeerId: [String: InboundRekeyRollbackRecord] = [:]
    private struct SessionPairingAuthority: Sendable {
        let connectionGeneration: UUID
        let binding: AuthenticatedHandshakePeerBinding
        let wasPreauthorizedForAutomaticPairing: Bool
    }
    private struct AuthenticatedAuthorityPersistenceResult: Sendable {
        let binding: AuthenticatedHandshakePeerBinding
        let wasPreauthorizedForAutomaticPairing: Bool
    }
    /// Pairing authority is a capability of one authenticated connection, not
    /// durable peer metadata. Generation binding prevents a stale callback from
    /// authorizing writes on, or clearing the authority of, a replacement link.
    private var sessionPairingAuthorityByPeerId: [String: SessionPairingAuthority] = [:]
    /// 握手驱动器缓存（用于响应方角色）
    private var handshakeDrivers: [String: HandshakeDriver] = [:]
    /// Every driver is owned by exactly one connection incarnation. Keeping
    /// this separate from the actor reference closes the old-connection ABA
    /// window without weakening the existing driver API.
    private var handshakeDriverConnectionGenerationByPeerId: [String: UUID] = [:]
    private var handshakeDriverOperationTokenByPeerId: [String: UUID] = [:]
    private struct HandshakeOperationOwner: Equatable, Sendable {
        let token: UUID
        let peerId: String
        let connectionGeneration: UUID
    }
    private var handshakeOperationOwnerByPeerId: [String: HandshakeOperationOwner] = [:]
    private struct AuthenticatedConnectionReceipt: Sendable {
        let lease: P2PConnectionLease<NWConnection>
        let sessionId: String
        let negotiatedSuite: CryptoSuite
    }
    private struct AuthenticatedTextMessageAuthorityReceipt: Sendable {
        let connection: AuthenticatedConnectionReceipt
        let keys: SessionKeys
        let binding: AuthenticatedHandshakePeerBinding
        let conversationFingerprint: String
    }
    private struct ArbiterSessionBinding: Sendable, Equatable {
        let connectionGeneration: UUID
        let lease: PeerSessionArbiter.EstablishedLease
    }
    private var arbiterSessionBindingByPeerId: [String: ArbiterSessionBinding] = [:]
    /// 兼容旧逻辑：握手过程中/早期阶段可能缓存 shared secret（最终以 sessionKeys 为准）
    private var sharedSecrets: [String: SecureBytes] = [:] // device.id -> shared secret
    private let queue = DispatchQueue(label: "com.skybridge.p2p", qos: .userInitiated)
    private var connectingCount: Int = 0
    private var inFlightConnectAliasesByPeerId: [String: Set<String>] = [:]
    private struct InFlightConnectWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private static let maximumInFlightConnectWaitersPerPeer = 32
    private var inFlightConnectWaitersByPeerId: [String: [InFlightConnectWaiter]] = [:]
    private var userInitiatedDisconnects: Set<String> = []
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private struct HeartbeatOperation: Sendable, Equatable {
        let token: UUID
        let connectionGeneration: UUID
        let sessionId: String
    }
    private var heartbeatOperationByPeerId: [String: HeartbeatOperation] = [:]
    private var lastActivityByDeviceId: [String: Date] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var pathRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var reconnectTaskTokens: [String: UUID] = [:]
    private var pathRecoveryTaskTokens: [String: UUID] = [:]
    private var betterPathRecoveryDeferredSince: [String: Date] = [:]
    private let betterPathRecoveryDeferIntervalSeconds: TimeInterval = 5
    private let betterPathRecoveryMaxDeferralSeconds: TimeInterval = 30
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectSuppressedDeviceIds: Set<String> = []
    private var lastKnownDevices: [String: DiscoveredDevice] = [:]
    private var selectedEndpointDescriptionByDeviceId: [String: String] = [:]
    private struct PendingSOAPairKey: Sendable, Equatable {
        let connectionGeneration: UUID
        let pairKey: Data
    }
    private var pendingSOAPairKeyByDeviceId: [String: PendingSOAPairKey] = [:]
    private var strictInboundStablePeerIdByRuntimePeerId: [String: String] = [:]
    private var peerAliasToCanonicalDeviceId: [String: String] = [:]
    private var peerPresentationIdByRuntimePeerId: [String: String] = [:]
    
    /// Prevent pairing identity exchange ping-pong loops.
    private struct PairingIdentitySendObservation: Sendable {
        let connectionGeneration: UUID
        let sessionId: String
        let acceptedMaterialDigest: Data?
        let sentAt: Date
    }
    private enum PairingIdentitySendOutcome: Sendable, Equatable {
        case contentProcessedCurrent
        case contentProcessedButSuperseded
    }
    private struct PairingIdentityAcceptanceKey: Hashable {
        let declaredDeviceId: String
    }
    private struct PairingIdentityPresentationMaterial: Sendable, Equatable {
        let deviceName: String?
        let modelName: String?
        let platform: String?
        let osVersion: String?
        let chip: String?
        let accountDisplayName: String?
        let nebulaId: String?
        let remoteVideoFormats: [String]?
        let capabilities: [String]?
        let fileTransferPort: UInt16?
        let remoteControlPort: UInt16?

        init(payload: AppMessage.PairingIdentityExchangePayload) {
            deviceName = payload.deviceName
            modelName = payload.modelName
            platform = payload.platform
            osVersion = payload.osVersion
            chip = payload.chip
            accountDisplayName = payload.accountDisplayName
            nebulaId = payload.nebulaId
            remoteVideoFormats = payload.remoteVideoFormats
            capabilities = payload.capabilities
            fileTransferPort = payload.fileTransferPort
            remoteControlPort = payload.remoteControlPort
        }
    }
    private struct PairingIdentityAcceptanceOperation {
        let token: UUID
        let connectionIdentifier: ObjectIdentifier
        let connectionGeneration: UUID
        let sessionId: String
        let acceptedMaterialDigest: Data
        let presentationMaterial: PairingIdentityPresentationMaterial
        let validatedAuthority: ValidatedPairingIdentityAuthority
        let trustPeer: Bool
        let persistTrust: Bool
        let pairingPolicy: PairingTrustDecision?
        let task: Task<Void, Error>
    }
    private var pairingIdentityAcceptanceOperations: [
        PairingIdentityAcceptanceKey: PairingIdentityAcceptanceOperation
    ] = [:]
    private struct PairingIdentityReceiveObservation: Sendable {
        let connectionGeneration: UUID
        let sessionId: String
        let observedAt: Date
    }
    private var lastPairingIdentityExchangeSentAt: [String: PairingIdentitySendObservation] = [:]
    private var lastPairingIdentityExchangeReceivedAt: [String: PairingIdentityReceiveObservation] = [:]
    private var lastPairingIdentityBootstrapReadyAt: [String: PairingIdentityReceiveObservation] = [:]
    private var lastAcceptedPairingIdentityDeviceIdByPeerId: [String: String] = [:]
    
    /// Bootstrap rekey tasks (Classic -> PQC) keyed by peerId.
    private var bootstrapRekeyTasks: [String: Task<Void, Never>] = [:]
    private struct BootstrapRekeyOperation: Sendable, Equatable {
        let token: UUID
        let connectionGeneration: UUID
        let initialSessionId: String
        let targetCanonicalWireId: UInt16
    }
    private var bootstrapRekeyOperationByPeerId: [String: BootstrapRekeyOperation] = [:]

    /// In-band rekey flag (pause heartbeat / non-essential business sends to reduce ciphertext-handshake interleaving).
    private var rekeyInProgress: Set<String> = []

    private func registerProvisionalInboundConnection(
        _ connection: NWConnection,
        peerId _: String
    ) -> Bool {
        let identifier = ObjectIdentifier(connection)
        if provisionalInboundConnections[identifier] != nil {
            return true
        }
        guard provisionalInboundConnections.count < Self.maximumProvisionalInboundConnections else {
            smokeInboundTrace(
                "p2p-inbound provisional-rejected reason=capacity limit=\(Self.maximumProvisionalInboundConnections)"
            )
            connection.cancel()
            return false
        }

        let timeoutTask = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(for: .seconds(Self.provisionalInboundTimeoutSeconds))
            } catch {
                return
            }
            guard let self,
                  let connection,
                  self.provisionalInboundConnections.removeValue(forKey: identifier) != nil else {
                return
            }
            self.provisionalInboundTimeoutTasks.removeValue(forKey: identifier)
            self.smokeInboundTrace(
                "p2p-inbound provisional-timeout peer=\(Self.protocolIdentityLogRedaction) seconds=\(Int(Self.provisionalInboundTimeoutSeconds))"
            )
            connection.cancel()
        }
        provisionalInboundConnections[identifier] = connection
        provisionalInboundTimeoutTasks[identifier] = timeoutTask
        return true
    }

    private func finishProvisionalInboundConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        provisionalInboundConnections.removeValue(forKey: identifier)
        provisionalInboundTimeoutTasks.removeValue(forKey: identifier)?.cancel()
    }

    private func cancelAllProvisionalInboundConnections(reason: String) {
        let connections = Array(provisionalInboundConnections.values)
        let tasks = Array(provisionalInboundTimeoutTasks.values)
        provisionalInboundConnections.removeAll(keepingCapacity: false)
        provisionalInboundTimeoutTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        for connection in connections {
            connection.cancel()
        }
        if !connections.isEmpty {
            smokeInboundTrace(
                "p2p-inbound provisional-cancelled-all count=\(connections.count) reason=\(Self.smokeSanitize(reason))"
            )
        }
    }

    private func smokeInboundTrace(_ line: String) {
        SkyBridgeDiagnosticTrace.appendStatus(line)
        SkyBridgeDiagnosticTrace.append(line)
    }

    private nonisolated static func smokeSanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static var protocolIdentityLogRedaction: String { "<redacted>" }

    private nonisolated static var signedLANRefreshReasonCodeUserInfoKey: String {
        "SkyBridgeSignedLANRefreshReasonCode"
    }

    private nonisolated static func normalizedDiagnosticReasonCode(
        _ raw: String?
    ) -> String? {
        guard let raw else { return nil }
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty,
              value.utf8.count <= 64,
              value.utf8.allSatisfy({
                  (97...122).contains($0)
                      || (48...57).contains($0)
                      || $0 == 95
              }) else {
            return nil
        }
        return value
    }

    private nonisolated static func diagnosticErrorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        var summary = "error_domain=\(nsError.domain) code=\(nsError.code)"
        if let reasonCode = normalizedDiagnosticReasonCode(
            nsError.userInfo[signedLANRefreshReasonCodeUserInfoKey] as? String
        ) {
            summary += " remote_reason_code=\(reasonCode)"
        }
        return summary
    }

    private nonisolated static func diagnosticConnectionState(_ state: NWConnection.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .waiting:
            return "waiting"
        case .preparing:
            return "preparing"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    private nonisolated static func diagnosticHandshakeFailureCode(_ reason: HandshakeFailureReason) -> String {
        switch reason {
        case .timeout:
            return "timeout"
        case .peerRejected:
            return "peer_rejected"
        case .cryptoError:
            return "crypto_error"
        case .transportError:
            return "transport_error"
        case .cancelled:
            return "cancelled"
        case .versionMismatch:
            return "version_mismatch"
        case .suiteNegotiationFailed:
            return "suite_negotiation_failed"
        case .signatureVerificationFailed:
            return "signature_verification_failed"
        case .invalidMessageFormat:
            return "invalid_message_format"
        case .identityMismatch:
            return "identity_mismatch"
        case .replayDetected:
            return "replay_detected"
        case .secureEnclavePoPRequired:
            return "secure_enclave_pop_required"
        case .secureEnclaveSignatureInvalid:
            return "secure_enclave_signature_invalid"
        case .keyConfirmationFailed:
            return "key_confirmation_failed"
        case .suiteSignatureMismatch:
            return "suite_signature_mismatch"
        case .pqcProviderUnavailable:
            return "pqc_provider_unavailable"
        case .missingPeerKEMPublicKey:
            return "missing_peer_kem_public_key"
        case .suiteNotSupported:
            return "suite_not_supported"
        case .supersededByConcurrentAttempt:
            return "superseded_by_concurrent_attempt"
        case .unknownSuite:
            return "unknown_suite"
        }
    }
    
    // MARK: - Pairing / Trust Prompt
    
    public enum PairingTrustDecision: String, Sendable {
        case alwaysAllow
        case allowOnce
        case reject
        case timedOut
    }

    public enum PairingTrustResolutionError: LocalizedError, Equatable, Sendable {
        case requestNoLongerPending
        case missingDecisionWaiter
        case sessionNoLongerCurrent

        public var errorDescription: String? {
            switch self {
            case .requestNoLongerPending:
                return "此配对/信任请求已不再等待处理，未应用重复决策。"
            case .missingDecisionWaiter:
                return "配对/信任审批状态不完整，当前请求已安全拒绝。"
            case .sessionNoLongerCurrent:
                return "收到配对请求的认证会话已结束或被替换，请在当前连接上重新发起配对。"
            }
        }
    }

    enum ProtocolIdentityBindingStoredPolicyAction: Equatable {
        case approve(operatorLabel: String)
        case reject
    }

    public enum PairingTrustPurpose: String, Sendable {
        case kemIdentityExchange
        case protocolIdentityBinding
    }
    
    public struct PairingTrustRequest: Identifiable, Sendable {
        public let id: UUID
        public let purpose: PairingTrustPurpose
        public let peerId: String
        public let declaredDeviceId: String
        public let deviceName: String
        public let platform: DevicePlatform
        public let modelName: String
        public let osVersion: String
        public let kemKeyCount: Int
        public let verificationCode: String?
        public let protocolIdentityFingerprint: String?
        public let receivedAt: Date
    }
    
    /// A pending pairing/trust request that requires user approval.
    @Published public private(set) var pendingPairingTrustRequest: PairingTrustRequest?
    @Published public private(set) var pairingTrustPersistenceError: String?
    
    private enum PendingPairingContext: Sendable {
        case pairingIdentityExchange(
            peerId: String,
            connectionGeneration: UUID,
            payload: AppMessage.PairingIdentityExchangePayload
        )
        case protocolIdentityBinding(PendingProtocolIdentityBindingContext)
        case requesterProtocolIdentityBinding(PendingRequesterProtocolIdentityBindingContext)
    }

    private struct PendingProtocolIdentityBindingContext: Sendable {
        let peerId: String
        let candidates: [String]
        let payload: AppMessage.SignedProtocolIdentityBindingPayload
    }

    private struct PendingRequesterProtocolIdentityBindingContext: Sendable {
        let policyKey: String
        let requesterDeviceIds: [String]
        let requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        let requesterProtocolIdentityPublicKey: Data
        let requesterProtocolIdentityFingerprint: String
        let verificationCode: String
        let displayName: String
    }

    private struct PendingPairingDecisionWaiter {
        let token: UUID
        let continuation: CheckedContinuation<PairingTrustDecision, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private static let maximumPendingPairingDecisionWaiters = 1
    private static let pairingIdentityExchangeApprovalTimeoutSeconds = 180
    private typealias PairingTimeoutSleep = @Sendable (Duration) async throws -> Void
    private var pendingPairingContextByRequestId: [UUID: PendingPairingContext] = [:]
    private var pendingPairingDecisionWaitersByRequestId: [UUID: PendingPairingDecisionWaiter] = [:]
    private var pendingStandalonePairingTimeoutTasksByRequestId: [UUID: Task<Void, Never>] = [:]
    private var pendingStandalonePairingTimeoutGenerationByRequestId: [UUID: UUID] = [:]
#if DEBUG || SKYBRIDGE_TESTING
    private var uiTestPairingRequestIDs: Set<UUID> = []
#endif
    
    private static let pairingPolicyStore = CodablePersistenceStore<[String: String]>(
        location: .protectedApplicationSupport(
            path: "P2P/pairing-policy.json",
            legacyUserDefaultsKey: "pairing_policy.v1"
        )
    )
    /// peerId -> decisionRawValue (only persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var pairingPolicyByPeerId: [String: String] = [:]
    private var pairingPolicyRevisionByPeerId: [String: UInt64] = [:]
    private var pairingPolicyPersistenceAvailable = true

    private let heartbeatIntervalSeconds: TimeInterval = 20
    private let maxReconnectAttempts: Int = 8
    private static let lanControlNetworkSubmitTimeoutSeconds: TimeInterval = 8
    private static let lanInteractiveNetworkSubmitTimeoutSeconds: TimeInterval = 30

    private static func currentModelDisplayName() -> String {
        AppleMobileDeviceIdentity.currentSnapshot().modelName
    }

    private static func currentChipDisplayName() -> String {
        AppleMobileDeviceIdentity.currentSnapshot().chip
    }
    
    // PQC 加密管理器
    private var pqcManager: PQCCryptoManager { PQCCryptoManager.instance }
    
    // 传输层适配器
    private var transport: NWConnectionTransport?
    
    // SkyBridge 核心
    private var skyBridgeCore: SkyBridgeiOSCore { SkyBridgeiOSCore.shared }
    
    // 发现管理器
    private var discoveryManager: DeviceDiscoveryManager { DeviceDiscoveryManager.instance }
    private var discoveryCancellables = Set<AnyCancellable>()
    
    private init() {
        do {
            pairingPolicyByPeerId = try Self.pairingPolicyStore.loadOrThrow() ?? [:]
        } catch {
            pairingPolicyByPeerId = [:]
            pairingPolicyPersistenceAvailable = false
            pairingTrustPersistenceError = "读取配对策略失败：\(error.localizedDescription)"
            SkyBridgeLogger.shared.error(
                "⛔️ 配对策略持久化不可用，所有 stored allow 已禁用：\(Self.diagnosticErrorSummary(error))"
            )
        }

        // 设置入站连接回调
        Task { @MainActor [self] in
            discoveryManager.onNewConnection = { [weak self] connection, peerId in
                Task { @MainActor in
                    await self?.handleIncomingConnection(connection, peerId: peerId)
                }
            }
        }

        discoveryManager.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.activeConnections.isEmpty || !self.lastKnownDevices.isEmpty else { return }

                self.activeConnections = self.activeConnections.map { connection in
                    let resolvedDevice = self.resolvedActiveConnectionDevice(from: connection.device)
                    return Connection(
                        id: connection.id,
                        device: resolvedDevice,
                        status: connection.status,
                        encryptionType: connection.encryptionType,
                        latency: connection.latency,
                        bandwidth: connection.bandwidth,
                        connectedAt: connection.connectedAt
                    )
                }

                for key in Array(self.lastKnownDevices.keys) {
                    guard let device = self.lastKnownDevices[key] else { continue }
                    self.lastKnownDevices[key] = self.resolvedActiveConnectionDevice(from: device)
                }
            }
            .store(in: &discoveryCancellables)
    }
    
    /// Decide an effective selection policy given the user preference.
    ///
    /// Paper alignment:
    /// - strictPQC must fail closed when the local runtime cannot provide a PQC implementation.
    private func effectiveSelectionPolicy(enforcePQC: Bool) -> CryptoProviderFactory.SelectionPolicy {
        guard enforcePQC else { return .classicOnly }
        return .requirePQC
    }

    private func inboundResponderSelectionPolicy(
        peerHasPQCGroup: Bool
    ) -> CryptoProviderFactory.SelectionPolicy {
        guard peerHasPQCGroup else { return .classicOnly }
        return effectiveSelectionPolicy(enforcePQC: pqcManager.enforcePQCHandshake)
    }

    private func ensureStrictPQCAvailability() throws {
        let capability = CryptoProviderFactory.detectCapability()
        guard capability.hasApplePQC || capability.hasLiboqs else {
            let message =
                "严格 PQC 已启用，但当前构建/设备没有可用的 PQC Provider。" +
                "请使用启用了 Apple PQC SDK 或 liboqs 的构建；当前不会再静默降级到 Classic。"
            SkyBridgeLogger.shared.error(
                "⛔️ strictPQC unavailable locally (hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs))"
            )
            currentHandshakeState = message
            lastError = message
            throw P2PError.pqcRequiredUnavailable
        }
    }

    private func rejectStrictPQCClassicBootstrap(for peerId: String) -> P2PError {
        let message =
            "严格 PQC 已启用，但对端只提供 Classic suites；当前已拒绝 classic bootstrap / legacy bootstrap 路径。peer=redacted"
        SkyBridgeLogger.shared.error("⛔️ \(message)")
        currentHandshakeState = message
        lastError = message
        return .pqcRequiredUnavailable
    }

    static func localizedConnectionErrorMessage(_ error: Error) -> String {
        let localized = P2PHandshakeErrorFormatter.localizedMessage(for: error)
        let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return error.localizedDescription
    }

    private func userVisibleConnectionError(_ error: Error) -> String {
        Self.localizedConnectionErrorMessage(error)
    }

    private var requiresSignedKEMRefreshEvidenceForStrictPQC: Bool {
        return true
    }

    private func trustedPeerKEM(for device: DiscoveredDevice) async -> (peerId: String, suites: [CryptoSuite: Data])? {
        let candidates = peerKEMLookupCandidates(for: device)
        let keys = await Self.trustedPeerKEMPublicKeysFromAllStores(forAny: candidates)
        guard !keys.isEmpty else { return nil }
        guard let stablePeerId = stableProtocolIdentityCandidate(from: candidates) else {
            SkyBridgeLogger.shared.warning(
                "⛔️ trusted peer KEM ignored: missing stable protocol identity for peer=\(Self.protocolIdentityLogRedaction); refusing endpoint alias target"
            )
            return nil
        }
        return (stablePeerId, keys)
    }

    private func peerKEMLookupCandidates(for device: DiscoveredDevice) -> [String] {
        let resolvedDevice = resolvedPeerDevice(for: device)
        let runtimePeerId = runtimePeerId(forAnyPeerId: resolvedDevice.id)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let trustedPeerId = preferredTrustedPeerIdentifier(for: resolvedDevice)
            ?? preferredTrustedPeerIdentifier(for: device)

        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed).inserted else { return }
            candidates.append(trimmed)
        }

        for candidate in [trustedPeerId, presentationPeerId, resolvedDevice.id, device.id, runtimePeerId] {
            appendCandidate(candidate)
            for alias in PeerIdentityAliasResolver.lookupCandidates(for: candidate) {
                appendCandidate(alias)
            }
        }

        return candidates
    }

    private func stableProtocolIdentityCandidate(from candidates: [String]) -> String? {
        var visited = Set<String>()

        func inspect(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, visited.insert(normalized).inserted else { return nil }

            if let stable = PeerIdentityAliasResolver.persistentDeviceId(from: normalized) {
                return stable
            }
            if let mapped = peerAliasToCanonicalDeviceId[normalized],
               let stable = inspect(mapped) {
                return stable
            }
            if let stable = TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: normalized) {
                return stable
            }
            if let knownDevice = lastKnownDevices[normalized] {
                if let stable = inspect(knownDevice.id) {
                    return stable
                }
                for alias in PeerIdentityAliasResolver.aliasKeys(for: knownDevice) {
                    if let stable = inspect(peerAliasToCanonicalDeviceId[alias] ?? alias) {
                        return stable
                    }
                }
            }
            if let discovered = discoveryManager.discoveredDevices.first(where: { candidate in
                let aliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                return candidate.id.lowercased() == normalized || aliases.contains(normalized)
            }) {
                if let stable = inspect(discovered.id) {
                    return stable
                }
            }
            return nil
        }

        for candidate in candidates {
            if let stable = inspect(candidate) {
                return stable
            }
        }
        return nil
    }

    private func stableProtocolIdentityCandidates(from messageA: HandshakeMessageA?) async -> [String] {
        guard let messageA,
              let soa = messageA.soaExtension,
              soa.initiatorPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength else {
            return []
        }

        var ordered: [String] = []
        var seen = Set<String>()

        func appendStableMatch(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return
            }

            let candidates = [raw] + PeerIdentityAliasResolver.lookupCandidates(for: raw)
            for candidate in candidates {
                guard let stablePeerId = stableProtocolIdentityCandidate(from: [candidate])
                    ?? PeerIdentityAliasResolver.persistentDeviceId(from: candidate) else {
                    continue
                }
                let normalizedStablePeerId =
                    PeerIdentityAliasResolver.persistentDeviceId(from: stablePeerId)
                    ?? stablePeerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalizedStablePeerId.isEmpty,
                      let stableSOAPeerId = soaPeerIdBytes(for: normalizedStablePeerId),
                      stableSOAPeerId == soa.initiatorPeerId,
                      seen.insert(normalizedStablePeerId).inserted else {
                    continue
                }
                ordered.append(normalizedStablePeerId)
            }
        }

        func appendDevice(_ device: DiscoveredDevice) {
            appendStableMatch(device.id)
            for alias in PeerIdentityAliasResolver.aliasKeys(for: device) {
                appendStableMatch(alias)
            }
        }

        func appendTrustedRecord(_ record: TrustedDeviceStore.TrustedDevice) {
            guard (record.currentPathLifecycleState ?? .active) == .active else { return }
            appendStableMatch(record.currentDeviceId)
            appendStableMatch(record.id)
            for knownDeviceId in record.knownDeviceIds ?? [] {
                appendStableMatch(knownDeviceId)
            }
        }

        let messageAProtocolIdentityFingerprint: String?
        do {
            messageAProtocolIdentityFingerprint = try messageA
                .decodedIdentityPublicKeys()
                .authoritativeProtocolFingerprint()
        } catch {
            messageAProtocolIdentityFingerprint = nil
        }

        if let fingerprint = messageAProtocolIdentityFingerprint,
           let trustedRecord = TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint) {
            appendTrustedRecord(trustedRecord)
        }
        if let fingerprint = messageAProtocolIdentityFingerprint {
            for deviceId in await ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint) {
                appendStableMatch(deviceId)
            }
        }

        let trustedAuthoritySnapshot: [TrustedDeviceStore.TrustedDevice]
        do {
            trustedAuthoritySnapshot = try TrustedDeviceStore.shared
                .activeAuthoritySnapshot()
        } catch {
            SkyBridgeLogger.shared.error(
                "⛔️ strict PQC SOA candidate resolution blocked by unavailable trusted authority: \(Self.diagnosticErrorSummary(error))"
            )
            return []
        }
        for trustedRecord in trustedAuthoritySnapshot {
            appendTrustedRecord(trustedRecord)
        }
        for canonicalPeerId in peerAliasToCanonicalDeviceId.values {
            appendStableMatch(canonicalPeerId)
        }
        for alias in peerAliasToCanonicalDeviceId.keys {
            appendStableMatch(alias)
        }
        for runtimePeerId in peerPresentationIdByRuntimePeerId.keys {
            appendStableMatch(runtimePeerId)
        }
        for presentationPeerId in peerPresentationIdByRuntimePeerId.values {
            appendStableMatch(presentationPeerId)
        }
        for runtimePeerId in lastAcceptedPairingIdentityDeviceIdByPeerId.keys {
            appendStableMatch(runtimePeerId)
        }
        for declaredDeviceId in lastAcceptedPairingIdentityDeviceIdByPeerId.values {
            appendStableMatch(declaredDeviceId)
        }
        for device in discoveryManager.discoveredDevices {
            appendDevice(device)
        }
        for device in lastKnownDevices.values {
            appendDevice(device)
        }
        for activeConnection in activeConnections {
            appendDevice(activeConnection.device)
        }

        return ordered
    }

    private func strictInboundHandshakeTrustContext(
        for peerId: String,
        stage: String,
        messageA: HandshakeMessageA? = nil
    ) async -> (stablePeerId: String, provider: P2PStoredHandshakeTrustProvider)? {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        let messageAStableCandidates = await stableProtocolIdentityCandidates(from: messageA)
        guard messageAStableCandidates.count <= 1 else {
            SkyBridgeLogger.shared.warning(
                "⛔️ strict PQC \(stage) rejected ambiguous MessageA SOA identity: peer=\(Self.protocolIdentityLogRedaction) matchCount=\(messageAStableCandidates.count) reason=ambiguous_message_a_soa_identity"
            )
            return nil
        }
        let candidates = messageAStableCandidates + [peerId, runtimePeerId, presentationPeerId, canonicalPeerId]
            + connectionStatePeerIds(for: runtimePeerId)
        guard let stablePeerId = stableProtocolIdentityCandidate(from: candidates) else {
            SkyBridgeLogger.shared.warning(
                "⛔️ strict PQC \(stage) rejected endpoint-only peer: peer=\(Self.protocolIdentityLogRedaction) reason=missing_stable_protocol_identity"
            )
            return nil
        }
        if messageAStableCandidates.contains(stablePeerId) {
            SkyBridgeLogger.shared.info(
                "🧩 strict PQC \(stage) resolved stable peer from MessageA SOA: endpoint=\(Self.protocolIdentityLogRedaction) stablePeer=\(Self.protocolIdentityLogRedaction)"
            )
        }

        let provider = P2PStoredHandshakeTrustProvider(
            trustMaterialCandidates: [stablePeerId] + candidates,
            requirePinnedProtocolIdentity: true
        )
        let pinnedFingerprints = await provider.trustedFingerprints(for: stablePeerId)
        guard !pinnedFingerprints.isEmpty else {
            SkyBridgeLogger.shared.warning(
                "⛔️ strict PQC \(stage) rejected unpinned peer: peer=\(Self.protocolIdentityLogRedaction) stablePeer=\(Self.protocolIdentityLogRedaction) reason=missing_pinned_protocol_identity"
            )
            return nil
        }

        return (stablePeerId, provider)
    }

    private func preferredStrictPQCHandshakeTargetSuite() -> CryptoSuite? {
        guard let raw = preferredRekeyTargetSuite() else { return nil }
        return CryptoSuite(rawValue: raw)
    }

    private func shouldUseClassicBootstrapForStrictPQC(device: DiscoveredDevice) async throws -> Bool {
        guard pqcManager.enforcePQCHandshake else { return false }
        try ensureStrictPQCAvailability()

        let preferredTargetSuite = preferredStrictPQCHandshakeTargetSuite()
        let trustedKEM = await trustedPeerKEM(for: device)
        let trustedSuites: Set<CryptoSuite>
        if let trustedKEM {
            trustedSuites = Set(trustedKEM.suites.keys)
        } else {
            trustedSuites = []
        }
        if Self.canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: trustedSuites,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return false
        }

        return false
    }

    private func ensureStrictPQCKEMTrustReady(for device: DiscoveredDevice) async throws {
        guard pqcManager.enforcePQCHandshake else { return }
        try ensureStrictPQCAvailability()

        let preferredTargetSuite = preferredStrictPQCHandshakeTargetSuite()
        let candidates = peerKEMLookupCandidates(for: device)
        let trustedKeys = await Self.trustedPeerKEMPublicKeysFromAllStores(forAny: candidates)
        let allTrustedSuites = Set(trustedKeys.keys)
        let requiresSignedRefreshEvidence = requiresSignedKEMRefreshEvidenceForStrictPQC
        let initialSignedRefreshEvidence: KEMTrustStore.SignedRefreshEvidence?
        if requiresSignedRefreshEvidence {
            initialSignedRefreshEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates)
        } else {
            initialSignedRefreshEvidence = nil
        }
        let trustedSuites = requiresSignedRefreshEvidence
            ? Self.signedRefreshEvidenceSuites(initialSignedRefreshEvidence)
            : allTrustedSuites
        var pinnedFingerprints = await trustedProtocolFingerprints(forAny: candidates)
        let initialPreflightAction = Self.strictPQCPreflightAction(
            trustedPeerKEMSuites: allTrustedSuites,
            signedRefreshEvidence: initialSignedRefreshEvidence,
            pinnedProtocolFingerprints: pinnedFingerprints,
            preferredTargetSuite: preferredTargetSuite,
            requiresSignedRefreshEvidence: requiresSignedRefreshEvidence
        )
        if initialPreflightAction == .proceed {
            return
        }

        var signedRefreshFailureReason: String?
        if initialPreflightAction == .attemptSignedLANRefresh {
            do {
                try await attemptSignedLANKEMRefresh(
                    for: device,
                    candidates: candidates,
                    pinnedProtocolFingerprints: pinnedFingerprints,
                    preferredTargetSuite: preferredTargetSuite
                )
                let refreshedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates)
                let refreshedSuites = Self.signedRefreshEvidenceSuites(refreshedEvidence)
                if Self.canSatisfyStrictPQCWithTrustedKEM(
                    trustedPeerKEMSuites: refreshedSuites,
                    preferredTargetSuite: preferredTargetSuite
                ) {
                    SkyBridgeLogger.shared.info(
                        "🔐 SKR-1 signed LAN KEM refresh verified and imported: peer=\(Self.protocolIdentityLogRedaction) suites=\(refreshedSuites.map(\.rawValue).sorted().joined(separator: ","))"
                    )
                    return
                }
                SkyBridgeLogger.shared.warning(
                    "⛔️ SKR-1 refresh completed but strict suite still unsatisfied: peer=\(Self.protocolIdentityLogRedaction) expected=\(preferredTargetSuite?.rawValue ?? "PQC") importedSuites=\(refreshedSuites.map(\.rawValue).sorted().joined(separator: ","))"
                )
            } catch {
                signedRefreshFailureReason = Self.smokeSanitize(error.localizedDescription)
                let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-kem-refresh reason=\(Self.protocolIdentityLogRedaction) pinnedProtocolIdentity=1 lifecycle=missing-kem>failed"
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
            }
        } else if initialPreflightAction == .attemptOOBProtocolIdentityBindingThenRefresh && pinnedFingerprints.isEmpty {
            SkyBridgeLogger.shared.warning(
                "🔐 SKR-1 refresh skipped: no pinned protocol identity for peer=\(Self.protocolIdentityLogRedaction) candidates=\(Self.protocolIdentityLogRedaction)"
            )
        }

        let recoveryPreflightAction = Self.strictPQCPreflightAction(
            trustedPeerKEMSuites: allTrustedSuites,
            signedRefreshEvidence: initialSignedRefreshEvidence,
            pinnedProtocolFingerprints: pinnedFingerprints,
            preferredTargetSuite: preferredTargetSuite,
            signedRefreshFailureReason: signedRefreshFailureReason,
            requiresSignedRefreshEvidence: requiresSignedRefreshEvidence
        )
        if initialPreflightAction == .attemptOOBProtocolIdentityBindingThenRefresh
            || recoveryPreflightAction == .attemptOOBProtocolIdentityBindingThenRefresh {
            var identityBindingCompleted = false
            do {
                let reboundFingerprint = try await attemptOOBProtocolIdentityBinding(
                    for: device,
                    candidates: candidates
                )
                identityBindingCompleted = true
                pinnedFingerprints = [reboundFingerprint]
                signedRefreshFailureReason = nil
                try await attemptSignedLANKEMRefresh(
                    for: device,
                    candidates: candidates,
                    pinnedProtocolFingerprints: pinnedFingerprints,
                    preferredTargetSuite: preferredTargetSuite
                )
                let refreshedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates)
                let refreshedSuites = Self.signedRefreshEvidenceSuites(refreshedEvidence)
                if Self.canSatisfyStrictPQCWithTrustedKEM(
                    trustedPeerKEMSuites: refreshedSuites,
                    preferredTargetSuite: preferredTargetSuite
                ) {
                    SkyBridgeLogger.shared.info(
                        "🔐 PIB-1 -> SKR-1 recovery completed: peer=\(Self.protocolIdentityLogRedaction) suites=\(refreshedSuites.map(\.rawValue).sorted().joined(separator: ","))"
                    )
                    return
                }
                signedRefreshFailureReason = "PIB-1 completed but SKR-1 did not import required suite"
            } catch {
                let line: String
                if identityBindingCompleted {
                    signedRefreshFailureReason = "SKR-1 signed LAN KEM refresh failed after PIB-1: \(Self.diagnosticErrorSummary(error))"
                    line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-kem-refresh reason=\(Self.protocolIdentityLogRedaction) pinnedProtocolIdentity=1 lifecycle=identity-oob>pinned>missing-kem>failed"
                } else {
                    signedRefreshFailureReason = "PIB-1 protocol identity binding failed: \(Self.diagnosticErrorSummary(error))"
                    line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-identity-binding reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>failed"
                }
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
            }
        }

        let expectedSuite = preferredTargetSuite?.rawValue ?? "PQC"
        let canonicalExpectedSuite = preferredTargetSuite?.canonicalKEMSuite.rawValue ?? expectedSuite
        let knownSuites = trustedSuites
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let unprovenKnownSuites = allTrustedSuites
            .subtracting(trustedSuites)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let candidateSummary = candidates
            .prefix(5)
            .joined(separator: ",")
        let missingPinnedIdentityReason = pinnedFingerprints.isEmpty
            ? " reason=missing_pinned_identity_requires_oob oob=short_authentication_string"
            : ""
        let recoveryGuidance: String
        if pinnedFingerprints.isEmpty {
            recoveryGuidance = "当前没有已固定的协议身份，不能自动恢复；需要双端显示同一设备确认码并人工确认后重新配对。"
        } else if let signedRefreshFailureReason {
            recoveryGuidance = "已保留协议身份 pin；已尝试 signed LAN KEM refresh 但失败，stage=kem_refresh reason=\(signedRefreshFailureReason)。当前不会继续伪成功。"
        } else {
            recoveryGuidance = "已保留协议身份 pin；signed LAN KEM refresh 未能导入可用 KEM，当前不会继续伪成功。"
        }
        let message =
            "strictPQC trust preflight failed: missing peer KEM " +
            "suite=\(expectedSuite) canonicalSuite=\(canonicalExpectedSuite) " +
            "knownSuites=\(knownSuites.isEmpty ? "-" : knownSuites) " +
            "signedRefreshRequired=\(requiresSignedRefreshEvidence ? 1 : 0) " +
            "unsignedOrUnprovenSuites=\(unprovenKnownSuites.isEmpty ? "-" : unprovenKnownSuites) " +
            "candidates=\(candidateSummary.isEmpty ? "-" : candidateSummary)" +
            "\(missingPinnedIdentityReason). " +
            "当前不会启动 classic bootstrap/fallback，也不会继续伪成功；\(recoveryGuidance)"
        currentHandshakeState = message
        lastError = message

        let runtimePeerId = canonicalPeerLookupKey(device.id)
        let affectedPeerIds = Set([device.id, runtimePeerId] + connectionStatePeerIds(for: runtimePeerId))
        for peerId in affectedPeerIds {
            connectionStatusByDeviceId[peerId] = .failed
            connectionErrorByDeviceId[peerId] = message
            reconnectSuppressedDeviceIds.insert(peerId)
            cancelReconnectTask(deviceId: peerId)
        }

        SkyBridgeLogger.shared.warning("🔐 \(message)")
        throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: expectedSuite))
    }

    private func trustedProtocolFingerprints(forAny candidates: [String]) async -> Set<String> {
        guard TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: candidates) else {
            return []
        }
        let protocolStoreFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: candidates)
        let trustedDeviceFingerprints = TrustedDeviceStore.shared.currentPathFingerprints(forAny: candidates)
        return protocolStoreFingerprints.union(trustedDeviceFingerprints)
    }

    private func attemptSignedLANKEMRefresh(
        for device: DiscoveredDevice,
        candidates: [String],
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?
    ) async throws {
        let routeCandidates = connectionEndpointCandidates(for: device)
        guard !routeCandidates.isEmpty else {
            throw signedLANRefreshFailure("no LAN endpoint candidates")
        }
        let directEndpoints = routeCandidates.filter {
            Self.signedLANRefreshEndpointClass($0) == "direct-host"
        }
        let directHostCandidate = !directEndpoints.isEmpty
        let bonjourServiceEndpoints = routeCandidates.filter {
            Self.signedLANRefreshEndpointClass($0) == "bonjour-service"
        }
        // `connectionEndpointCandidates` has already proven that each service endpoint is the
        // complete primary DNS-SD tuple observed by NWBrowser. Such a tuple is a direct LAN route:
        // Network.framework resolves its host and SRV port atomically. It must not be rejected
        // merely because no independently sourced TXT host/port pair was synthesized.
        let endpoints = directEndpoints + bonjourServiceEndpoints
        let directLANCandidate = !endpoints.isEmpty
        guard directLANCandidate else {
            throw signedLANRefreshFailure("missing provenance-bound direct LAN endpoint candidate")
        }

        let requestedSuites = signedLANRefreshRequestedSuites(preferredTargetSuite: preferredTargetSuite)
        let requesterProtocolIdentityFingerprint = try await localProtocolIdentityFingerprintForSignedLANRefresh()
        guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates) else {
            throw signedLANRefreshFailure("missing stable protocol identity target; refusing endpoint alias target")
        }
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: try localStablePersistentDeviceIdentifier(),
            targetDeviceId: targetProtocolDeviceId,
            requesterProtocolIdentityFingerprint: requesterProtocolIdentityFingerprint,
            targetProtocolIdentityFingerprint: pinnedProtocolFingerprints.count == 1 ? pinnedProtocolFingerprints.sorted().first : nil,
            requestedSuiteWireIds: requestedSuites.map(\.wireId),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: signedLANRefreshEndpointDigest(for: device),
            nonce: signedLANRefreshNonce()
        )

        let refreshStartedAt = Date()
        let bonjourServiceCandidateCount = bonjourServiceEndpoints.count
        let connectStartLine = "🔐 SKR-1 signed LAN KEM refresh connect-start: peer=\(Self.protocolIdentityLogRedaction) endpointCount=\(endpoints.count) directLANCandidates=\(endpoints.count) bonjourServiceCandidates=\(bonjourServiceCandidateCount) classicFallbackSuppressed=1 pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>connect"
        SkyBridgeLogger.shared.info(connectStartLine)
        SignedKEMRefreshSmokeStatusWriter.append(connectStartLine)
        let connectionResult: ReadyConnectionResult
        do {
            connectionResult = try await establishReadyConnectionWithMetrics(to: endpoints, for: device)
        } catch {
            throw signedLANRefreshFailure(
                "bootstrap control connection failed: \(Self.smokeSanitize(error.localizedDescription))"
            )
        }
        let connection = connectionResult.connection
        let selectedEndpoint = connectionResult.endpoint
        let selectedEndpointClass = Self.signedLANRefreshEndpointClass(selectedEndpoint)
        let selectedEndpointDirect = selectedEndpointClass == "direct-host"
        let selectedEndpointDirectLAN = selectedEndpointDirect
            || selectedEndpointClass == "bonjour-service"
        defer { connection.cancel() }

        let responseTimeoutSeconds = Self.signedLANRefreshResponseTimeoutSeconds()
        let requestLine = "🔐 SKR-1 signed LAN KEM refresh request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) selectedEndpointClass=\(selectedEndpointClass) selectedEndpointDirect=\(selectedEndpointDirect ? 1 : 0) selectedEndpointDirectLAN=\(selectedEndpointDirectLAN ? 1 : 0) selectedEndpointPeerToPeer=\(connectionResult.selectedEndpointPeerToPeer ? 1 : 0) directHostCandidate=\(directHostCandidate ? 1 : 0) directLANCandidate=\(directLANCandidate ? 1 : 0) requesterProtocolIdentity=\(Self.protocolIdentityLogRedaction) suites=\(requestedSuites.map(\.rawValue).joined(separator: ",")) suiteWireIds=\(requestedSuites.map { String(format: "0x%04X", $0.wireId) }.joined(separator: ",")) responseTimeoutSeconds=\(Int(responseTimeoutSeconds)) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>request"
        SkyBridgeLogger.shared.info(requestLine)
        SignedKEMRefreshSmokeStatusWriter.append(requestLine)
        let exchangeStartedAt = Date()
        try await sendPlainFramed(JSONEncoder().encode(AppMessage.kemRefreshRequest(request)), over: connection)
        let responseFrame = try await receivePlainFrame(
            over: connection,
            timeoutSeconds: responseTimeoutSeconds
        )
        let responseLatencyMs = Date().timeIntervalSince(exchangeStartedAt) * 1_000.0
        let response = try AppMessage.decodeWireMessage(from: responseFrame)
        if case .kemRefreshFailure(let failure) = response {
            throw signedLANRefreshFailure(
                "remote rejected SKR-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode)",
                reasonCode: failure.reasonCode
            )
        }
        guard case .signedKEMRefresh(let payload) = response else {
            throw signedLANRefreshFailure("unexpected SKR-1 response type")
        }

        let minimumGeneration = await KEMTrustStore.shared.maximumKEMGeneration(forAny: candidates)
        let validated = try payload.validatedForStrictPQCImport(
            request: request,
            now: Date(),
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: validated.protocolSigningAlgorithm) else {
            throw signedLANRefreshFailure("invalid signature algorithm")
        }

        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let verified = try await signatureProvider.verify(
            validated.signaturePreimage,
            signature: validated.signature,
            publicKey: validated.protocolIdentityPublicKey
        )
        guard verified else {
            throw signedLANRefreshFailure("signature verification failed")
        }

        try await KEMTrustStore.shared.upsertSignedKEMRefresh(
            deviceIds: candidates + [device.id],
            payload: validated,
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        let protocolIdentityKey = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: validated.protocolSigningAlgorithm,
            publicKey: validated.protocolIdentityPublicKey
        )
        for deviceId in Set(candidates + [device.id, validated.deviceId] + validated.aliases) {
            await ProtocolIdentityTrustStore.shared.upsert(
                deviceId: deviceId,
                protocolIdentityPublicKeys: [protocolIdentityKey]
            )
        }

        let totalLatencyMs = Date().timeIntervalSince(refreshStartedAt) * 1_000.0
        let retryCount = max(0, connectionResult.attemptCount - 1)
        let applicationLossPct = connectionResult.attemptCount > 0
            ? (Double(connectionResult.failedAttemptCount) * 100.0 / Double(connectionResult.attemptCount))
            : 100.0
        let verifiedLine = String(
            format: "🔐 SKR-1 signed LAN KEM refresh verified and imported: peer=%@ suites=%@ wireId=%@ pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=%.1f responseLatencyMs=%.1f connectLatencyMs=%.1f selectedEndpointPeerToPeer=%d jitterMs=%.1f applicationLossPct=%.1f retryCount=%d lifecycle=served>verified metricScope=application-control-channel",
            Self.protocolIdentityLogRedaction,
            validated.kemPublicKeys.map { CryptoSuite(wireId: $0.suiteWireId).rawValue }.sorted().joined(separator: ","),
            validated.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.sorted().joined(separator: ","),
            totalLatencyMs,
            responseLatencyMs,
            connectionResult.connectLatencyMs,
            connectionResult.selectedEndpointPeerToPeer ? 1 : 0,
            connectionResult.attemptJitterMs,
            applicationLossPct,
            retryCount
        )
        SkyBridgeLogger.shared.info(verifiedLine)
        SignedKEMRefreshSmokeStatusWriter.append(verifiedLine)
    }

    private func attemptOOBProtocolIdentityBinding(
        for device: DiscoveredDevice,
        candidates: [String]
    ) async throws -> String {
        let endpoints = connectionEndpointCandidates(for: device)
        guard !endpoints.isEmpty else {
            throw protocolIdentityBindingFailure("no LAN endpoint candidates")
        }

        let requesterIdentity = try await localProtocolIdentityProofForProtocolBinding()
        guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates) else {
            throw protocolIdentityBindingFailure("missing stable protocol identity target; refusing endpoint alias target")
        }
        let unsignedRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: try localStablePersistentDeviceIdentifier(),
            targetDeviceId: targetProtocolDeviceId,
            requestedProtocolSigningAlgorithms: localProtocolIdentityAlgorithmCandidates()
                .map(\.rawValue),
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: Data(),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: signedLANRefreshEndpointDigest(for: device),
            nonce: signedLANRefreshNonce()
        )
        let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(for: requesterIdentity.algorithm)
        let requesterSignature = try await requesterSignatureProvider.sign(
            unsignedRequest.canonicalPreimage,
            key: requesterIdentity.keyHandle
        )
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            transactionId: unsignedRequest.transactionId,
            requesterDeviceId: unsignedRequest.requesterDeviceId,
            targetDeviceId: unsignedRequest.targetDeviceId,
            requestedProtocolSigningAlgorithms: unsignedRequest.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: requesterSignature,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: unsignedRequest.routeScope,
            bonjourEndpointDigest: unsignedRequest.bonjourEndpointDigest,
            nonce: unsignedRequest.nonce,
            sentAt: unsignedRequest.sentAt
        )

        let connectStartLine = "🔐 PIB-1 protocol identity binding connect-start: peer=\(Self.protocolIdentityLogRedaction) endpoints=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>connect"
        SkyBridgeLogger.shared.info(connectStartLine)
        SignedKEMRefreshSmokeStatusWriter.append(connectStartLine)
        let connectionResult = try await establishReadyConnectionWithMetrics(to: endpoints, for: device)
        let connection = connectionResult.connection
        defer { connection.cancel() }

        let responseTimeoutSeconds = Self.protocolIdentityBindingCandidateResponseTimeoutSeconds()
        let requestLine = "🔐 PIB-1 protocol identity binding request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) algorithms=\(request.requestedProtocolSigningAlgorithms.joined(separator: ",")) responseTimeoutSeconds=\(Int(responseTimeoutSeconds)) lifecycle=identity-oob>request"
        SkyBridgeLogger.shared.info(requestLine)
        SignedKEMRefreshSmokeStatusWriter.append(requestLine)
        try await sendPlainFramed(JSONEncoder().encode(AppMessage.protocolIdentityBindingRequest(request)), over: connection)
        let responseFrame = try await receivePlainFrame(
            over: connection,
            timeoutSeconds: responseTimeoutSeconds
        )
        let response = try AppMessage.decodeWireMessage(from: responseFrame)
        if case .kemRefreshFailure(let failure) = response {
            throw protocolIdentityBindingFailure(
                "remote rejected PIB-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode) reason=redacted"
            )
        }
        guard case .signedProtocolIdentityBinding(let payload) = response else {
            throw protocolIdentityBindingFailure("unexpected PIB-1 response type")
        }

        let validated = try payload.validatedForOOBBinding(request: request)
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: validated.protocolSigningAlgorithm) else {
            throw protocolIdentityBindingFailure("invalid signature algorithm")
        }
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let verified = try await signatureProvider.verify(
            validated.signaturePreimage,
            signature: validated.signature,
            publicKey: validated.protocolIdentityPublicKey
        )
        guard verified else {
            throw protocolIdentityBindingFailure("signature verification failed")
        }

        let code = validated.shortAuthenticationCode(request: request)
        let verifiedLine = "🔐 PIB-1 protocol identity binding signature verified: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>verified"
        SkyBridgeLogger.shared.info(verifiedLine)
        SignedKEMRefreshSmokeStatusWriter.append(verifiedLine)

        // PIB-1 v3 deliberately releases the candidate connection before any
        // operator interaction. This prevents the responder from waiting on its
        // own prompt while the requester is still waiting for the candidate.
        connection.cancel()

        let decision = await requestOOBProtocolIdentityApproval(
            for: device,
            candidates: candidates,
            payload: validated,
            verificationCode: code
        )
        switch decision {
        case .alwaysAllow, .allowOnce:
            break
        case .reject:
            throw protocolIdentityBindingFailure("operator rejected PIB-1 verification code")
        case .timedOut:
            throw protocolIdentityBindingFailure("operator approval timed out for PIB-1 verification code")
        }

        let confirmCreatedAt = Date()
        let unsignedConfirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: request.transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: validated.deviceId,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            responderProtocolIdentityFingerprint: validated.protocolIdentityFingerprint,
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: validated.canonicalCandidateHashHex,
            sasTranscriptHashHex: validated.sasTranscriptHashHex(request: request),
            confirmationNonce: signedLANRefreshNonce(),
            sentAt: confirmCreatedAt,
            expiresAt: min(validated.expiresAt, confirmCreatedAt.addingTimeInterval(300)),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            requesterSignature: Data()
        )
        let confirmSignature = try await requesterSignatureProvider.sign(
            unsignedConfirm.signaturePreimage,
            key: requesterIdentity.keyHandle
        )
        let confirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: unsignedConfirm.transactionId,
            requesterDeviceId: unsignedConfirm.requesterDeviceId,
            responderDeviceId: unsignedConfirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: unsignedConfirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: unsignedConfirm.responderProtocolIdentityFingerprint,
            requestNonce: unsignedConfirm.requestNonce,
            requestHashHex: unsignedConfirm.requestHashHex,
            candidateHashHex: unsignedConfirm.candidateHashHex,
            sasTranscriptHashHex: unsignedConfirm.sasTranscriptHashHex,
            confirmationNonce: unsignedConfirm.confirmationNonce,
            sentAt: unsignedConfirm.sentAt,
            expiresAt: unsignedConfirm.expiresAt,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            requesterSignature: confirmSignature
        )

        let confirmConnectionResult = try await establishReadyConnectionWithMetrics(to: endpoints, for: device)
        let confirmConnection = confirmConnectionResult.connection
        defer { confirmConnection.cancel() }
        guard confirmConnection !== connection else {
            throw protocolIdentityBindingFailure("PIB-1 confirm must use a new short connection")
        }
        let confirmLine = "🔐 PIB-1 protocol identity binding confirm sent: peer=\(Self.protocolIdentityLogRedaction) transaction=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>confirm"
        SkyBridgeLogger.shared.info(confirmLine)
        SignedKEMRefreshSmokeStatusWriter.append(confirmLine)
        try await sendPlainFramed(
            JSONEncoder().encode(AppMessage.protocolIdentityBindingConfirm(confirm)),
            over: confirmConnection
        )
        let finalAckResponseTimeoutSeconds = Self.protocolIdentityBindingResponseTimeoutSeconds()
        let finalAckFrame = try await receivePlainFrame(
            over: confirmConnection,
            timeoutSeconds: finalAckResponseTimeoutSeconds
        )
        let finalAckMessage = try AppMessage.decodeWireMessage(from: finalAckFrame)
        if case .kemRefreshFailure(let failure) = finalAckMessage {
            throw protocolIdentityBindingFailure(
                "remote rejected PIB-1 confirm stage=\(failure.stage) reasonCode=\(failure.reasonCode) reason=redacted"
            )
        }
        guard case .signedProtocolIdentityBindingFinalAck(let finalAckPayload) = finalAckMessage else {
            throw protocolIdentityBindingFailure("unexpected PIB-1 final acknowledgement type")
        }
        let finalAck = try finalAckPayload.validatedForFinalization(
            request: request,
            candidate: validated,
            confirm: confirm
        )
        let finalAckVerified = try await signatureProvider.verify(
            finalAck.signaturePreimage,
            signature: finalAck.responderSignature,
            publicKey: validated.protocolIdentityPublicKey
        )
        guard finalAckVerified else {
            throw protocolIdentityBindingFailure("PIB-1 final acknowledgement signature verification failed")
        }
        guard await installOOBProtocolIdentityBinding(.init(
            peerId: device.id,
            candidates: Self.protocolIdentityBindingPolicyCandidates(
                for: device,
                candidates: candidates,
                payload: validated
            ),
            payload: validated
        )) else {
            throw protocolIdentityBindingFailure("PIB-1 final acknowledgement verified but authority pin promotion failed")
        }
        let completedLine = "🔐 PIB-1 v3 protocol identity binding final acknowledgement verified and pinned: peer=\(Self.protocolIdentityLogRedaction) transaction=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>final-ack>pinned"
        SkyBridgeLogger.shared.info(completedLine)
        SignedKEMRefreshSmokeStatusWriter.append(completedLine)
        return validated.protocolIdentityFingerprint.lowercased()
    }

    @MainActor
    private func clearPendingPairingApprovalState(
        requestId: UUID,
        cancelStandaloneTimeoutTask: Bool = true
    ) {
        pendingPairingContextByRequestId.removeValue(forKey: requestId)
        if let timeoutTask = pendingStandalonePairingTimeoutTasksByRequestId.removeValue(
            forKey: requestId
        ), cancelStandaloneTimeoutTask {
            timeoutTask.cancel()
        }
        pendingStandalonePairingTimeoutGenerationByRequestId.removeValue(
            forKey: requestId
        )
        if pendingPairingTrustRequest?.id == requestId {
            pendingPairingTrustRequest = nil
        }
    }

    private func invalidatePendingPairingIdentityRequests(
        for peerId: String,
        connectionGeneration: UUID
    ) {
        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        let invalidRequestIds = pendingPairingContextByRequestId.compactMap {
            requestId, context -> UUID? in
            guard case .pairingIdentityExchange(
                let contextPeerId,
                let contextGeneration,
                _
            ) = context,
                canonicalPeerLookupKey(contextPeerId) == canonicalPeerId,
                contextGeneration == connectionGeneration
            else {
                return nil
            }
            return requestId
        }

        for requestId in invalidRequestIds {
            clearPendingPairingApprovalState(requestId: requestId)
            if let waiter = takePendingPairingDecisionWaiter(requestId: requestId) {
                waiter.continuation.resume(returning: .reject)
            }
        }
    }

    private func scheduleStandalonePairingApprovalTimeout(
        requestId: UUID,
        timeout: Duration,
        timeoutStatusLine: String,
        sleep: @escaping PairingTimeoutSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        pendingStandalonePairingTimeoutTasksByRequestId.removeValue(forKey: requestId)?.cancel()
        let timeoutGeneration = UUID()
        pendingStandalonePairingTimeoutGenerationByRequestId[requestId] = timeoutGeneration
        pendingStandalonePairingTimeoutTasksByRequestId[requestId] = Task { @MainActor [weak self] in
            do {
                try await sleep(timeout)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.pendingStandalonePairingTimeoutGenerationByRequestId[requestId]
                        == timeoutGeneration else {
                    return
                }
                self.clearPendingPairingApprovalState(
                    requestId: requestId,
                    cancelStandaloneTimeoutTask: false
                )
                if let waiter = self.takePendingPairingDecisionWaiter(requestId: requestId) {
                    waiter.continuation.resume(returning: .reject)
                }
                let status = "Pairing approval timer failed; request rejected fail closed"
                self.lastError = status
                SkyBridgeLogger.shared.error(
                    "Pairing approval timer failed; code=timer-operation-failed"
                )
                return
            }

            guard let self,
                  self.pendingStandalonePairingTimeoutGenerationByRequestId[requestId]
                    == timeoutGeneration,
                  let context = self.pendingPairingContextByRequestId[requestId],
                  case .pairingIdentityExchange = context,
                  self.pendingPairingTrustRequest?.id == requestId else {
                self?.pendingStandalonePairingTimeoutTasksByRequestId.removeValue(
                    forKey: requestId
                )
                return
            }

            self.clearPendingPairingApprovalState(
                requestId: requestId,
                cancelStandaloneTimeoutTask: false
            )
            self.lastError = timeoutStatusLine
            SkyBridgeLogger.shared.warning(timeoutStatusLine)
        }
    }

    @discardableResult
    private func completePendingPairingDecision(
        requestId: UUID,
        token: UUID,
        decision: PairingTrustDecision,
        cancelTimeoutTask: Bool = true
    ) -> Bool {
        guard let waiter = pendingPairingDecisionWaitersByRequestId[requestId],
              waiter.token == token else {
            return false
        }
        pendingPairingDecisionWaitersByRequestId.removeValue(forKey: requestId)
        if cancelTimeoutTask {
            waiter.timeoutTask?.cancel()
        }
        clearPendingPairingApprovalState(requestId: requestId)
        waiter.continuation.resume(returning: decision)
        return true
    }

    private func takePendingPairingDecisionWaiter(
        requestId: UUID
    ) -> PendingPairingDecisionWaiter? {
        guard let waiter = pendingPairingDecisionWaitersByRequestId.removeValue(forKey: requestId) else {
            return nil
        }
        waiter.timeoutTask?.cancel()
        return waiter
    }

    private func awaitOperatorPairingTrustDecision(
        request: PairingTrustRequest,
        context: PendingPairingContext,
        timeout: Duration,
        awaitingStatusLine: String,
        timeoutStatusLine: String,
        cancellationStatusLine: String,
        busyStatusLine: String
    ) async -> PairingTrustDecision {
        guard pendingPairingTrustRequest == nil,
              pendingPairingContextByRequestId.count < Self.maximumPendingPairingDecisionWaiters,
              pendingPairingDecisionWaitersByRequestId.count < Self.maximumPendingPairingDecisionWaiters else {
            SkyBridgeLogger.shared.warning(busyStatusLine)
            SignedKEMRefreshSmokeStatusWriter.append(busyStatusLine)
            return .reject
        }

        let requestId = request.id
        let token = UUID()
        pendingPairingContextByRequestId[requestId] = context
        pendingPairingTrustRequest = request
        SkyBridgeLogger.shared.info(awaitingStatusLine)
        SignedKEMRefreshSmokeStatusWriter.append(awaitingStatusLine)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    clearPendingPairingApprovalState(requestId: requestId)
                    SkyBridgeLogger.shared.info(cancellationStatusLine)
                    SignedKEMRefreshSmokeStatusWriter.append(cancellationStatusLine)
                    continuation.resume(returning: .reject)
                    return
                }

                pendingPairingDecisionWaitersByRequestId[requestId] = PendingPairingDecisionWaiter(
                    token: token,
                    continuation: continuation,
                    timeoutTask: nil
                )
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let self,
                              self.completePendingPairingDecision(
                                requestId: requestId,
                                token: token,
                                decision: .reject,
                                cancelTimeoutTask: false
                              ) else {
                            return
                        }
                        let nsError = error as NSError
                        let timerFailureLine = "⛔️ Pairing approval timer failed unexpectedly; rejected fail closed domain=\(nsError.domain) code=\(nsError.code)"
                        SkyBridgeLogger.shared.error(timerFailureLine)
                        SignedKEMRefreshSmokeStatusWriter.append(timerFailureLine)
                        return
                    }
                    guard let self,
                          self.completePendingPairingDecision(
                            requestId: requestId,
                            token: token,
                            decision: .timedOut,
                            cancelTimeoutTask: false
                          ) else {
                        return
                    }
                    SkyBridgeLogger.shared.warning(timeoutStatusLine)
                    SignedKEMRefreshSmokeStatusWriter.append(timeoutStatusLine)
                }

                guard var waiter = pendingPairingDecisionWaitersByRequestId[requestId],
                      waiter.token == token else {
                    timeoutTask.cancel()
                    return
                }
                waiter.timeoutTask = timeoutTask
                pendingPairingDecisionWaitersByRequestId[requestId] = waiter
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.completePendingPairingDecision(
                        requestId: requestId,
                        token: token,
                        decision: .reject
                      ) else {
                    return
                }
                SkyBridgeLogger.shared.info(cancellationStatusLine)
                SignedKEMRefreshSmokeStatusWriter.append(cancellationStatusLine)
            }
        }
    }

    private func requestOOBProtocolIdentityApproval(
        for device: DiscoveredDevice,
        candidates: [String],
        payload: AppMessage.SignedProtocolIdentityBindingPayload,
        verificationCode: String
    ) async -> PairingTrustDecision {
        let policyCandidates = Self.protocolIdentityBindingPolicyCandidates(
            for: device,
            candidates: candidates,
            payload: payload
        )
        let hasActiveDurableTrust = TrustedDeviceStore.shared.hasActiveDurableTrust(
            forAny: policyCandidates
        )
        let trustedFingerprints = await trustedProtocolFingerprints(forAny: policyCandidates)
        if let storedPolicyAction = Self.protocolIdentityBindingStoredPolicyAction(
            pairingPolicyByPeerId: pairingPolicyByPeerId,
            policyCandidates: policyCandidates,
            trustedProtocolFingerprints: trustedFingerprints,
            payloadFingerprint: payload.protocolIdentityFingerprint,
            hasActiveDurableTrust: hasActiveDurableTrust
        ) {
            switch storedPolicyAction {
            case .approve(let operatorLabel):
                let line = "🔐 PIB-1 protocol identity binding candidate approved: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=\(operatorLabel) lifecycle=identity-oob>candidate-approved"
                SkyBridgeLogger.shared.info(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
                return .alwaysAllow
            case .reject:
                let line = "🛑 PIB-1 protocol identity binding rejected: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=stored-policy lifecycle=identity-oob>rejected"
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
                return .reject
            }
        }

        let requestId = UUID()
        let displayName = payload.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = PairingTrustRequest(
            id: requestId,
            purpose: .protocolIdentityBinding,
            peerId: device.id,
            declaredDeviceId: payload.deviceId,
            deviceName: displayName?.isEmpty == false ? displayName! : device.name,
            platform: device.platform,
            modelName: device.modelName,
            osVersion: device.osVersion,
            kemKeyCount: 0,
            verificationCode: verificationCode,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            receivedAt: Date()
        )

        let approvalTimeoutSeconds = Self.protocolIdentityBindingApprovalTimeoutSeconds()
        let awaitingLine = "🔐 PIB-1 protocol identity binding awaiting operator approval: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(approvalTimeoutSeconds) lifecycle=identity-oob>awaiting-approval"
        let timeoutLine = "⏳ PIB-1 protocol identity binding approval timed out: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(approvalTimeoutSeconds) lifecycle=identity-oob>timeout"
        let cancellationLine = "ℹ️ PIB-1 protocol identity binding approval cancelled with its handshake: peer=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>cancelled"
        let busyLine = "🛑 PIB-1 protocol identity binding rejected because another operator approval is pending: peer=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>busy-rejected"
        return await awaitOperatorPairingTrustDecision(
            request: request,
            context: .protocolIdentityBinding(.init(
                peerId: device.id,
                candidates: policyCandidates,
                payload: payload
            )),
            timeout: .seconds(approvalTimeoutSeconds),
            awaitingStatusLine: awaitingLine,
            timeoutStatusLine: timeoutLine,
            cancellationStatusLine: cancellationLine,
            busyStatusLine: busyLine
        )
    }

    private func installOOBProtocolIdentityBinding(
        _ context: PendingProtocolIdentityBindingContext,
        clearExisting: Bool = true
    ) async -> Bool {
        let payload = context.payload
        guard ProtocolSigningAlgorithm(rawValue: payload.protocolSigningAlgorithm) != nil else {
            let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) reason=unsupported_protocol_signing_algorithm lifecycle=identity-oob>failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            return false
        }
        do {
            guard try TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
                peerId: context.peerId,
                deviceId: payload.deviceId,
                aliases: context.candidates + payload.aliases,
                displayName: payload.deviceName,
                protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: payload.protocolIdentityFingerprint,
                protocolPublicKeyBytes: payload.protocolIdentityPublicKey
            ) else {
                throw TrustedDeviceStore.AuthorityUpdateError.missingStableDeviceIdentifier
            }
        } catch {
            let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) reason=authority_pin_not_persisted lifecycle=identity-oob>failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            return false
        }
        let protocolIdentityKey = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            publicKey: payload.protocolIdentityPublicKey
        )
        let installIds = Array(Set(context.candidates + [context.peerId, payload.deviceId] + payload.aliases))
        if clearExisting {
            for deviceId in installIds {
                await ProtocolIdentityTrustStore.shared.clear(deviceId: deviceId)
            }
        }
        for deviceId in installIds {
            await ProtocolIdentityTrustStore.shared.upsert(
                deviceId: deviceId,
                protocolIdentityPublicKeys: [protocolIdentityKey]
            )
        }
        let line = "🔐 PIB-1 protocol identity binding pinned: peer=\(Self.protocolIdentityLogRedaction) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) candidates=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>pinned"
        SkyBridgeLogger.shared.info(line)
        SignedKEMRefreshSmokeStatusWriter.append(line)
        return true
    }

    private func installInboundRequesterProtocolIdentityBinding(
        _ context: PendingRequesterProtocolIdentityBindingContext
    ) async -> Bool {
        do {
            guard try TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
                peerId: context.requesterDeviceIds.first ?? context.displayName,
                deviceId: context.requesterDeviceIds.first ?? context.displayName,
                aliases: context.requesterDeviceIds,
                displayName: context.displayName,
                protocolSigningAlgorithm: context.requesterProtocolSigningAlgorithm.rawValue,
                protocolPublicKeyFingerprint: context.requesterProtocolIdentityFingerprint,
                protocolPublicKeyBytes: context.requesterProtocolIdentityPublicKey
            ) else {
                throw TrustedDeviceStore.AuthorityUpdateError.missingStableDeviceIdentifier
            }
        } catch {
            let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_pin_not_persisted lifecycle=identity-oob>requester-pin-failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            return false
        }
        let key = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: context.requesterProtocolSigningAlgorithm.rawValue,
            publicKey: context.requesterProtocolIdentityPublicKey
        )
        for deviceId in Set(context.requesterDeviceIds) {
            await ProtocolIdentityTrustStore.shared.upsert(
                deviceId: deviceId,
                protocolIdentityPublicKeys: [key]
            )
        }
        let line = "🔐 PIB-1 requester protocol identity pinned: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>requester-pinned"
        SkyBridgeLogger.shared.info(line)
        SignedKEMRefreshSmokeStatusWriter.append(line)
        return true
    }

    private func signedLANRefreshRequestedSuites(preferredTargetSuite: CryptoSuite?) -> [CryptoSuite] {
        let preferred = preferredTargetSuite?.canonicalKEMSuite
        if let preferred, preferred.isKnown, preferred.isPQCGroup {
            return [preferred]
        }
        return [.xwingMLDSA]
    }

    private func signedLANRefreshEndpointDigest(for device: DiscoveredDevice) -> String? {
        let material = [
            device.bonjourServiceName,
            device.bonjourServiceType,
            device.bonjourServiceDomain,
            device.ipAddress,
            device.portMap.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        guard !material.isEmpty else { return nil }
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func signedLANRefreshNonce() -> Data {
        Data((0..<24).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    private func sendFramedContentProcessed(
        _ framed: Data,
        over connection: NWConnection,
        timeoutSeconds: TimeInterval,
        operation: String
    ) async throws {
        try await NetworkContentProcessedSubmission.send(
            framed,
            over: connection,
            timeoutSeconds: timeoutSeconds,
            operation: operation,
            transport: "LAN"
        )
    }

    private func sendPlainFramed(_ data: Data, over connection: NWConnection) async throws {
        let framed = try P2PControlFramePolicy.frame(body: data)
        try await sendFramedContentProcessed(
            framed,
            over: connection,
            timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
            operation: "bootstrap-control"
        )
    }

    private func receivePlainFrame(over connection: NWConnection, timeoutSeconds: Double) async throws -> Data {
        let header = try await receiveExactly(4, from: connection, timeoutSeconds: timeoutSeconds)
        let encodedLength = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard let length = try? P2PControlFramePolicy.inboundBodyByteCount(
            from: encodedLength
        ) else {
            throw signedLANRefreshFailure("invalid response frame length \(encodedLength)")
        }
        return try await receiveExactly(length, from: connection, timeoutSeconds: timeoutSeconds)
    }

    private func receiveExactly(
        _ length: Int,
        from connection: NWConnection,
        timeoutSeconds: Double
    ) async throws -> Data {
        let gate = PlainFrameReceiveGate()
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
            if let error {
                gate.finish(.failure(error))
                return
            }
            guard let data, data.count == length else {
                let reason = isComplete ? "peer closed during SKR-1 receive" : "short SKR-1 read"
                gate.finish(.failure(Self.signedLANRefreshFailure(reason)))
                return
            }
            gate.finish(.success(data))
        }
        return try await gate.wait(timeoutSeconds: timeoutSeconds)
    }

    nonisolated static func signedLANRefreshFailure(
        _ reason: String,
        reasonCode: String? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: reason]
        if let reasonCode = normalizedDiagnosticReasonCode(reasonCode) {
            userInfo[signedLANRefreshReasonCodeUserInfoKey] = reasonCode
        }
        return NSError(
            domain: "SkyBridge.SignedLANRefresh",
            code: 1,
            userInfo: userInfo
        )
    }

    private func signedLANRefreshFailure(
        _ reason: String,
        reasonCode: String? = nil
    ) -> NSError {
        Self.signedLANRefreshFailure(reason, reasonCode: reasonCode)
    }

    nonisolated private static func protocolIdentityBindingFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.ProtocolIdentityBinding",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private func protocolIdentityBindingFailure(_ reason: String) -> NSError {
        Self.protocolIdentityBindingFailure(reason)
    }

    private func performBootstrapAssistedPQCHandshake(
        connection: NWConnection,
        device: DiscoveredDevice
    ) async throws -> AuthenticatedConnectionReceipt {
        let peerId = canonicalPeerLookupKey(device.id)
        let targetSuite = preferredRekeyTargetSuite() ?? CryptoSuite.xwing.rawValue

        SkyBridgeLogger.shared.info(
            "🧩 P2P classic bootstrap start: peer=\(Self.protocolIdentityLogRedaction) targetSuite=\(targetSuite)"
        )
        currentHandshakeState = "经典 bootstrap 中..."

        let classicReceipt = try await performPQCHandshake(
            connection: connection,
            device: device,
            preferPQC: false,
            selectionPolicyOverride: .classicOnly
        )

        try requireCurrentAuthenticatedConnection(classicReceipt)
        scheduleBootstrapRekeyIfNeeded(
            peerId: peerId,
            suiteRaw: targetSuite,
            expectedReceipt: classicReceipt
        )
        let observedAt = Date()
        let sendOutcome = try await sendPairingIdentityExchange(
            to: peerId,
            expectedLease: classicReceipt.lease,
            expectedSessionId: classicReceipt.sessionId,
            acceptedMaterialDigest: nil
        )
        guard sendOutcome == .contentProcessedCurrent else {
            throw P2PError.staleConnectionIncarnation
        }
        SkyBridgeLogger.shared.info(
            "📤 已发送 pairingIdentityExchange 触发 PQC bootstrap: peer=\(Self.protocolIdentityLogRedaction)"
        )

        let observedReply = await waitForPairingIdentityExchangeActivity(
            with: peerId,
            since: observedAt,
            expectedReceipt: classicReceipt,
            timeout: .seconds(8)
        )
        if observedReply {
            SkyBridgeLogger.shared.info(
                "🔁 bootstrap pairingIdentityExchange 已往返: peer=\(Self.protocolIdentityLogRedaction)"
            )
        } else {
            SkyBridgeLogger.shared.info(
                "⏳ bootstrap 等待对端批准/回传 KEM identity: peer=\(Self.protocolIdentityLogRedaction)"
            )
        }

        return try await waitForBootstrapRekeyCompletion(
            peerId: peerId,
            expectedLease: classicReceipt.lease,
            targetSuite: targetSuite
        )
    }

    private func waitForBootstrapRekeyCompletion(
        peerId: String,
        expectedLease: P2PConnectionLease<NWConnection>,
        targetSuite: String,
        timeout: Duration = .seconds(35)
    ) async throws -> AuthenticatedConnectionReceipt {
        let runtimePeerId = canonicalPeerLookupKey(peerId)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            guard connections.isCurrent(expectedLease, for: runtimePeerId),
                  sessionKeyConnectionGenerationByPeerId[runtimePeerId]
                    == expectedLease.generation,
                  let keys = sessionKeys[runtimePeerId] else {
                throw P2PError.staleConnectionIncarnation
            }
            if keys.negotiatedSuite.isPQCGroup {
                let suite = keys.negotiatedSuite
                SkyBridgeLogger.shared.info(
                    "✅ bootstrap-assisted PQC rekey 完成: peer=\(Self.protocolIdentityLogRedaction) suite=\(suite.rawValue)"
                )
                return AuthenticatedConnectionReceipt(
                    lease: expectedLease,
                    sessionId: keys.sessionId,
                    negotiatedSuite: suite
                )
            }

            let peerIds = connectionStatePeerIds(for: runtimePeerId)
            if let failure = peerIds
                .compactMap({ connectionErrorByDeviceId[$0] })
                .first(where: { $0.contains("PQC 切换失败") }) {
                throw NSError(
                    domain: "P2PConnectionManager",
                    code: 72,
                    userInfo: [NSLocalizedDescriptionKey: failure]
                )
            }

            try await Task.sleep(for: .milliseconds(150))
        }

        guard connections.isCurrent(expectedLease, for: runtimePeerId) else {
            throw P2PError.staleConnectionIncarnation
        }
        let message = "等待对端批准配对/受信任申请以完成 PQC 切换超时（targetSuite=\(targetSuite)）"
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            connectionErrorByDeviceId[peerId] = message
        }
        currentHandshakeState = message
        lastError = message
        throw NSError(
            domain: "P2PConnectionManager",
            code: 73,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
    
    private enum PairingPolicyPersistenceError: LocalizedError {
        case unavailable(String)
        case writeFailed(String)
        case concurrentModification
        case authorityTransactionQuarantined
        case revisionExhausted

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "配对策略存储不可用：\(reason)"
            case .writeFailed(let reason):
                return "保存配对策略失败：\(reason)"
            case .concurrentModification:
                return "配对策略在回滚期间已被另一项操作修改"
            case .authorityTransactionQuarantined:
                return "配对接受事务尚未完成恢复，配对策略 authority 已隔离"
            case .revisionExhausted:
                return "配对策略修订序列已耗尽，拒绝继续修改"
            }
        }
    }

    private struct PairingPolicyMutationReceipt {
        let peerId: String
        let previousValue: String?
        let committedValue: String
        let committedRevision: UInt64
    }

    private func setPairingPolicy(
        _ decision: PairingTrustDecision,
        for peerId: String
    ) throws {
        _ = try commitPairingPolicy(decision, for: peerId)
    }

    private func commitPairingPolicy(
        _ decision: PairingTrustDecision,
        for peerId: String
    ) throws -> PairingPolicyMutationReceipt? {
        try requirePairingPolicyPersistenceAvailable(outerPermit: nil)
        guard let persistedValue = Self.pairingPolicyValueToPersist(for: decision) else {
            return nil
        }
        let previousValue = pairingPolicyByPeerId[peerId]
        guard previousValue != persistedValue else {
            // Preserve the intent as an in-process revision so an older
            // in-flight receipt cannot later remove an equal policy (ABA).
            _ = try advancePairingPolicyRevision(for: peerId)
            return nil
        }
        let candidate = try Self.persistedPairingPolicyCandidate(
            current: pairingPolicyByPeerId,
            mutate: { $0[peerId] = persistedValue },
            persist: { try persistPairingPolicy($0) }
        )
        pairingPolicyByPeerId = candidate
        let revision = try advancePairingPolicyRevision(for: peerId)
        return PairingPolicyMutationReceipt(
            peerId: peerId,
            previousValue: previousValue,
            committedValue: persistedValue,
            committedRevision: revision
        )
    }

    private func rollbackPairingPolicy(
        _ receipt: PairingPolicyMutationReceipt
    ) throws {
        guard pairingPolicyByPeerId[receipt.peerId] == receipt.committedValue,
              pairingPolicyRevisionByPeerId[receipt.peerId] == receipt.committedRevision else {
            throw PairingPolicyPersistenceError.concurrentModification
        }
        var candidate = pairingPolicyByPeerId
        if let previousValue = receipt.previousValue {
            candidate[receipt.peerId] = previousValue
        } else {
            candidate.removeValue(forKey: receipt.peerId)
        }
        try persistPairingPolicy(candidate)
        pairingPolicyByPeerId = candidate
        _ = try advancePairingPolicyRevision(for: receipt.peerId)
    }

    private func advancePairingPolicyRevision(for peerId: String) throws -> UInt64 {
        let current = pairingPolicyRevisionByPeerId[peerId] ?? 0
        let increment = current.addingReportingOverflow(1)
        guard !increment.overflow else {
            throw PairingPolicyPersistenceError.revisionExhausted
        }
        pairingPolicyRevisionByPeerId[peerId] = increment.partialValue
        return increment.partialValue
    }

    static func pairingPolicyValueToPersist(for decision: PairingTrustDecision) -> String? {
        switch decision {
        case .alwaysAllow, .reject:
            return decision.rawValue
        case .allowOnce, .timedOut:
            return nil
        }
    }

    private func removePairingPolicies(matching candidateSet: Set<String>) throws {
        let keysToRemove = stateKeysMatchingAliases(candidateSet, keys: pairingPolicyByPeerId.keys)
        guard !keysToRemove.isEmpty else { return }
        let previous = pairingPolicyByPeerId
        let candidate = try Self.persistedPairingPolicyCandidate(
            current: pairingPolicyByPeerId,
            mutate: { candidate in
                for key in keysToRemove {
                    candidate.removeValue(forKey: key)
                }
            },
            persist: { try persistPairingPolicy($0) }
        )
        pairingPolicyByPeerId = candidate
        for key in keysToRemove where previous[key] != candidate[key] {
            _ = try advancePairingPolicyRevision(for: key)
        }
    }

    private static func persistedPairingPolicyCandidate(
        current: [String: String],
        mutate: (inout [String: String]) -> Void,
        persist: ([String: String]) throws -> Void
    ) throws -> [String: String] {
        var candidate = current
        mutate(&candidate)
        guard candidate != current else { return current }
        try persist(candidate)
        return candidate
    }

#if DEBUG || SKYBRIDGE_TESTING
    enum TestPairingApprovalError: Error, Sendable, Equatable {
        case stateNotReset
    }

    enum TestStateInstallationError: Error, Sendable, Equatable {
        case authenticatedSessionLeaseNotOwned
    }

    static func testOnlyPersistedPairingPolicyCandidate(
        current: [String: String],
        peerId: String,
        decision: PairingTrustDecision,
        persist: ([String: String]) throws -> Void
    ) throws -> [String: String] {
        guard let persistedValue = pairingPolicyValueToPersist(for: decision) else {
            return current
        }
        return try persistedPairingPolicyCandidate(
            current: current,
            mutate: { $0[peerId] = persistedValue },
            persist: persist
        )
    }
#endif

    private func persistPairingPolicy(
        _ candidate: [String: String],
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        do {
            try Self.pairingPolicyStore.save(candidate)
        } catch {
            pairingPolicyPersistenceAvailable = false
            let message = "保存配对策略失败：\(error.localizedDescription)"
            pairingTrustPersistenceError = message
            lastError = message
            SkyBridgeLogger.shared.error(
                "⛔️ 保存配对策略失败，stored allow 已禁用：\(Self.diagnosticErrorSummary(error))"
            )
            throw PairingPolicyPersistenceError.writeFailed(error.localizedDescription)
        }
    }

    private func requirePairingPolicyPersistenceAvailable(
        outerPermit: PairingIdentityAuthorityMutationPermit?
    ) throws {
        guard pairingPolicyPersistenceAvailable else {
            throw PairingPolicyPersistenceError.unavailable(
                pairingTrustPersistenceError ?? "未知错误"
            )
        }
        if PairingAcceptanceJournalStore.defaultJournalExists() {
            guard let outerPermit,
                  PairingAcceptanceJournalStore.permitOwnsActiveJournal(outerPermit) else {
                throw PairingPolicyPersistenceError.authorityTransactionQuarantined
            }
        }
    }

    private var isPairingPolicyAuthorityAvailable: Bool {
        pairingPolicyPersistenceAvailable
            && !PairingAcceptanceJournalStore.defaultJournalExists()
    }

    public func dismissPairingTrustPersistenceError() {
        pairingTrustPersistenceError = nil
    }

    /// Called by UI to resolve a pending pairing/trust request.
    @MainActor
    public func resolvePairingTrustRequest(
        _ request: PairingTrustRequest,
        decision: PairingTrustDecision
    ) async throws {
#if DEBUG || SKYBRIDGE_TESTING
        if uiTestPairingRequestIDs.remove(request.id) != nil {
            if pendingPairingTrustRequest?.id == request.id {
                pendingPairingTrustRequest = nil
            }
            return
        }
#endif

        guard let ctx = pendingPairingContextByRequestId.removeValue(forKey: request.id) else {
            if pendingPairingTrustRequest?.id == request.id {
                pendingPairingTrustRequest = nil
            }
            let error = PairingTrustResolutionError.requestNoLongerPending
            lastError = error.localizedDescription
            SkyBridgeLogger.shared.warning(
                "⛔️ Pairing/trust decision ignored because the request was no longer pending"
            )
            throw error
        }

        pendingStandalonePairingTimeoutTasksByRequestId.removeValue(
            forKey: request.id
        )?.cancel()
        let pendingDecisionWaiter = takePendingPairingDecisionWaiter(requestId: request.id)
        if pendingPairingTrustRequest?.id == request.id {
            pendingPairingTrustRequest = nil
        }

        do {
        switch ctx {
        case .pairingIdentityExchange(let peerId, let connectionGeneration, let payload):
            switch decision {
            case .alwaysAllow:
                guard payload.normalizedBootstrapPayload != nil else {
                    throw PairingIdentityAcceptanceError.invalidPayload
                }
                try await acceptPairingIdentityExchange(
                    from: peerId,
                    expectedConnectionGeneration: connectionGeneration,
                    payload: payload,
                    trustPeer: true,
                    persistTrust: true,
                    pairingPolicy: .alwaysAllow
                )
            case .allowOnce:
                try await acceptPairingIdentityExchange(
                    from: peerId,
                    expectedConnectionGeneration: connectionGeneration,
                    payload: payload,
                    trustPeer: false,
                    persistTrust: false
                )
            case .reject:
                guard let policyKey = Self.stablePairingPolicyKey(for: payload) else {
                    throw PairingIdentityAcceptanceError.invalidPayload
                }
                try setPairingPolicy(.reject, for: policyKey)
                SkyBridgeLogger.shared.warning("🛑 Pairing/trust request rejected: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
            case .timedOut:
                SkyBridgeLogger.shared.warning("⏳ Pairing/trust request timed out: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
            }
            pendingDecisionWaiter?.continuation.resume(returning: decision)
        case .protocolIdentityBinding(let context):
            guard let pendingDecisionWaiter else {
                SkyBridgeLogger.shared.error(
                    "⛔️ PIB-1 approval state was missing its decision waiter; rejected fail closed"
                )
                throw PairingTrustResolutionError.missingDecisionWaiter
            }
            switch decision {
            case .alwaysAllow, .allowOnce:
                // PIB-1 v3 requester approval authorizes only the signed
                // confirm. The responder pin is installed after finalAck
                // validation, never at candidate/SAS approval time.
                let line = "🔐 PIB-1 protocol identity binding candidate approved: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>candidate-approved"
                SkyBridgeLogger.shared.info(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
            case .reject:
                try setPairingPolicy(.reject, for: context.peerId)
                SkyBridgeLogger.shared.warning(
                    "🛑 PIB-1 protocol identity binding rejected: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            case .timedOut:
                SkyBridgeLogger.shared.warning(
                    "⏳ PIB-1 protocol identity binding timed out: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            }
            pendingDecisionWaiter.continuation.resume(returning: decision)
        case .requesterProtocolIdentityBinding(let context):
            guard let pendingDecisionWaiter else {
                SkyBridgeLogger.shared.error(
                    "⛔️ PIB-1 requester approval state was missing its decision waiter; rejected fail closed"
                )
                throw PairingTrustResolutionError.missingDecisionWaiter
            }
            switch decision {
            case .alwaysAllow:
                try setPairingPolicy(.alwaysAllow, for: context.policyKey)
                let line = "🔐 PIB-1 requester confirm approved: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>confirm-approved"
                SkyBridgeLogger.shared.info(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
            case .allowOnce:
                let line = "🔐 PIB-1 requester confirm approved once: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>confirm-approved"
                SkyBridgeLogger.shared.info(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
            case .reject:
                try setPairingPolicy(.reject, for: context.policyKey)
                SkyBridgeLogger.shared.warning(
                    "🛑 PIB-1 requester protocol identity binding rejected: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            case .timedOut:
                SkyBridgeLogger.shared.warning(
                    "⏳ PIB-1 requester protocol identity binding timed out: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            }
            pendingDecisionWaiter.continuation.resume(returning: decision)
        }
        } catch {
            if let acceptanceError = error as? PairingIdentityAcceptanceError,
               case .durableCommitRetained = acceptanceError {
                // The operator's trust decision is already durable. Reporting a
                // rejection here would contradict local state and can prompt an
                // unsafe second approval attempt. The exact failed session is
                // closed by the acceptance path; a later connection may reuse
                // the committed authority material.
                pendingDecisionWaiter?.continuation.resume(returning: decision)
                let message = "配对身份已在本地持久化，但当前连接未完成；请重新连接，无需再次批准：\(error.localizedDescription)"
                lastError = message
                SkyBridgeLogger.shared.warning(
                    "⚠️ 配对身份已持久化，但当前会话未完成回复：\(Self.diagnosticErrorSummary(error))"
                )
                throw error
            }
            pendingDecisionWaiter?.continuation.resume(returning: .reject)
            let isPersistenceFailure = error is PairingPolicyPersistenceError
                || error is TrustedDeviceStore.PersistenceError
                || error is AuthorityBoundPairingIdentityPersistenceError
                || (error as? PairingIdentityAcceptanceError)?.isPersistenceFailure == true
            let message = isPersistenceFailure
                ? "配对/信任持久化未能确认安全收敛，当前连接已中止且状态保持隔离：\(error.localizedDescription)"
                : "配对/信任请求无效或无法接受，当前请求已拒绝：\(error.localizedDescription)"
            if isPersistenceFailure {
                pairingTrustPersistenceError = message
            }
            lastError = message
            if isPersistenceFailure {
                SkyBridgeLogger.shared.error(
                    "⛔️ 配对/信任决策持久化失败：\(Self.diagnosticErrorSummary(error))"
                )
            } else {
                SkyBridgeLogger.shared.warning(
                    "⛔️ 配对/信任请求被拒绝：\(Self.diagnosticErrorSummary(error))"
                )
            }
            throw error
        }
    }

    public func clearTrustMaterialForForgottenDevice(deviceIds rawDeviceIds: [String]) async throws {
        let candidates = Self.expandedTrustMaterialCandidates(for: rawDeviceIds)
        guard !candidates.isEmpty else { return }
        let candidateSet = Set(candidates)
        var detachedConnectionLeases: [P2PConnectionLease<NWConnection>] = []
        var detachedHandshakeDrivers: [HandshakeDriver] = []
        var detachedArbiterBindings: [ArbiterSessionBinding] = []

        // The durable tombstone is written by the forget coordinator before
        // entering this cleanup. Stop live I/O and retry tasks synchronously
        // before awaiting actor-backed trust-store cleanup.
        for key in stateKeysMatchingAliases(candidateSet, keys: connections.keys) {
            if let lease = connections.lease(for: key) {
                invalidatePendingPairingIdentityRequests(
                    for: key,
                    connectionGeneration: lease.generation
                )
                lease.connection.cancel()
                if connections.removeIfOwned(lease, for: key) != nil {
                    detachedConnectionLeases.append(lease)
                }
                if let driver = detachHandshakeOperationIfOwned(
                    for: key,
                    connectionGeneration: lease.generation
                ) {
                    detachedHandshakeDrivers.append(driver)
                }
                if let binding = detachArbiterSessionBinding(
                    for: key,
                    expectedConnectionGeneration: lease.generation
                ) {
                    detachedArbiterBindings.append(binding)
                }
                _ = removeSessionKeysIfOwned(
                    for: key,
                    connectionGeneration: lease.generation
                )
                clearSessionPairingAuthority(
                    for: key,
                    connectionGeneration: lease.generation
                )
            }
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: reconnectTasks.keys) {
            cancelReconnectTask(deviceId: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: pathRecoveryTasks.keys) {
            cancelPathRecoveryTask(deviceId: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: heartbeatTasks.keys) {
            heartbeatTasks[key]?.cancel()
            heartbeatTasks.removeValue(forKey: key)
            heartbeatOperationByPeerId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: bootstrapRekeyTasks.keys) {
            bootstrapRekeyTasks[key]?.cancel()
            bootstrapRekeyTasks.removeValue(forKey: key)
            bootstrapRekeyOperationByPeerId.removeValue(forKey: key)
        }

        for key in stateKeysMatchingAliases(candidateSet, keys: sessionKeys.keys) {
            sessionKeys.removeValue(forKey: key)
            sessionKeyConnectionGenerationByPeerId.removeValue(forKey: key)
            clearSessionPairingAuthority(for: key)
            inboundRekeyRollbackByPeerId.removeValue(forKey: key)
            sharedSecrets.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: handshakeDrivers.keys) {
            if let generation = handshakeDriverConnectionGenerationByPeerId[key],
               let driver = detachHandshakeOperationIfOwned(
                   for: key,
                   connectionGeneration: generation
               ) {
                detachedHandshakeDrivers.append(driver)
            }
        }

        for driver in detachedHandshakeDrivers {
            await driver.cancel()
        }
        for lease in detachedConnectionLeases {
            _ = await transport?.removeConnection(
                lease.connection,
                for: lease.peerId,
                leaseSequence: lease.sequence
            )
        }
        for binding in detachedArbiterBindings {
            await releaseArbiterSessionBinding(binding)
        }

        for candidate in candidates {
            await KEMTrustStore.shared.clear(deviceId: candidate)
            await ProtocolIdentityTrustStore.shared.clear(deviceId: candidate)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: reconnectSuppressedDeviceIds) {
            reconnectSuppressedDeviceIds.remove(key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: reconnectAttempts.keys) {
            reconnectAttempts.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: connectionStatusByDeviceId.keys) {
            connectionStatusByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: connectionErrorByDeviceId.keys) {
            connectionErrorByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: lastKnownDevices.keys) {
            lastKnownDevices.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: selectedEndpointDescriptionByDeviceId.keys) {
            selectedEndpointDescriptionByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: lastPairingIdentityExchangeSentAt.keys) {
            lastPairingIdentityExchangeSentAt.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: lastPairingIdentityExchangeReceivedAt.keys) {
            lastPairingIdentityExchangeReceivedAt.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: lastPairingIdentityBootstrapReadyAt.keys) {
            lastPairingIdentityBootstrapReadyAt.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: lastAcceptedPairingIdentityDeviceIdByPeerId.keys) {
            lastAcceptedPairingIdentityDeviceIdByPeerId.removeValue(forKey: key)
        }
        try removePairingPolicies(matching: candidateSet)
        activeConnections.removeAll { connection in
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
                .union(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return !aliases.isDisjoint(with: candidateSet)
        }
        rekeyInProgress.subtract(candidateSet)

        SkyBridgeLogger.shared.info(
            "🧹 已彻底清理受信任设备 P2P/KEM 状态: candidates=\(candidates.prefix(6).joined(separator: ","))"
        )
    }

    public func forgetTrustedDevice(deviceId: String) async throws {
        let aliases = try TrustedDeviceStore.shared.untrust(deviceId: deviceId)
        try await clearTrustMaterialForForgottenDevice(deviceIds: aliases)
    }

    public func forgetAllTrustedDevices() async throws {
        let authorityRecords = try TrustedDeviceStore.shared.authorityRecordsSnapshot()
        let aliases = authorityRecords.flatMap { record in
            var values = [record.id]
            if let currentDeviceId = record.currentDeviceId {
                values.append(currentDeviceId)
            }
            values.append(contentsOf: record.knownDeviceIds ?? [])
            return values
        }
        try TrustedDeviceStore.shared.clearAll()
        try await clearTrustMaterialForForgottenDevice(deviceIds: aliases)
    }
    
    // MARK: - Public Methods
    
    /// 开始监听连接（使用 DeviceDiscoveryManager 的广播功能）
    public func startListening() async throws {
        beginListeningSupervision()

        if let listeningStartupOperation {
            return try await listeningStartupOperation.task.value
        }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            if case .idle = self.advertisingLifecycle {
                self.advertisingLifecycle = .starting
            }
            do {
                try await self.performStartListeningTransaction()
                self.cancelListeningRecovery()
                self.advertisingLifecycle = .advertising(
                    port: self.discoveryManager.advertisingReadinessSnapshot.actualPort ?? 9527
                )
            } catch {
                self.discoveryManager.stopAdvertising()
                self.isListening = false
                self.lastError = error.localizedDescription
                self.scheduleListeningRecovery(after: error)
                throw error
            }
        }
        listeningStartupOperation = ListeningStartupOperation(
            id: operationID,
            task: task
        )
        defer {
            if listeningStartupOperation?.id == operationID {
                listeningStartupOperation = nil
            }
        }
        try await task.value
    }

    private func performStartListeningTransaction() async throws {
        try await PairingAcceptancePersistence.recoverIfNeeded(
            policyParticipant: self
        )
        guard PairingAcceptancePersistence.isRecoveryReady else {
            throw PairingAcceptancePersistenceError.recoveryRequired
        }
        _ = try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
        try Task.checkCancellation()

        if isListening, !discoveryManager.isAdvertising {
            // Recover from stale state (e.g. listener failed/cancelled but flag not updated).
            SkyBridgeLogger.shared.warning("⚠️ P2P 监听状态与 Bonjour 广播状态不一致，正在重新建立监听器")
            isListening = false
        }

        // 确保 SkyBridgeCore 已按当前设置初始化（允许按 policy 重新初始化）
        if pqcManager.enforcePQCHandshake {
            // 强制 PQC = strictPQC（论文语义）：不允许 classic fallback。
            try ensureStrictPQCAvailability()
            let policy = effectiveSelectionPolicy(enforcePQC: true)
            try await skyBridgeCore.initialize(policy: policy)
        } else {
            try await skyBridgeCore.initialize(policy: .classicOnly)
        }
        
        // 初始化传输层
        if transport == nil {
            transport = NWConnectionTransport()
        }

        // Capture the committed authority as late as possible, then re-read it after every
        // async advertisement operation. Rotation and startup share the MainActor, so an
        // equal final re-read plus the synchronous readiness check is the linearization point.
        let controlPort: UInt16 = 9527
        let latestAuthority = try await P2PAdvertisingAuthorityStabilizer.applyLatest(
            loadCommittedAuthority: {
                try await self.skyBridgeCore
                    .committedActiveProtocolIdentitySnapshot()
                    .snapshot
            },
            applyAuthority: { authority in
                let beforeStart = self.discoveryManager.advertisingReadinessSnapshot
                if beforeStart.isReady(for: controlPort, authority: authority) {
                    SkyBridgeLogger.shared.debug(
                        "📡 P2P Bonjour 广播已就绪，继续确认传输层"
                    )
                    return
                }
                try await self.discoveryManager.startAdvertising(
                    port: controlPort,
                    authority: authority
                )
            }
        )
        let readiness = discoveryManager.advertisingReadinessSnapshot
        guard readiness.isReady(for: controlPort, authority: latestAuthority) else {
            let message = "P2P 广播监听未进入可用状态: requestedPort=\(controlPort) actualPort=\(readiness.actualPort.map(String.init) ?? "-") handlerInstalled=\(readiness.handlerInstalled ? 1 : 0) generation=\(readiness.readyGeneration)"
            throw NSError(
                domain: "P2PConnectionManager",
                code: -2201,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        isListening = true
        lastError = nil

        SkyBridgeLogger.shared.info("🎧 P2P 监听器已启动（通过 Bonjour 广播，端口 \(readiness.actualPort ?? controlPort)）")
    }

    func refreshAdvertisingAuthorityIfActive(
        _ authority: ProtocolIdentitySnapshot
    ) async throws {
        guard isListening || discoveryManager.isAdvertising else { return }
        let committedBeforeUpdate = try await skyBridgeCore
            .committedActiveProtocolIdentitySnapshot()
            .snapshot
        guard committedBeforeUpdate == authority else {
            throw ListeningAuthorityError.refreshSuperseded
        }
        advertisingAuthorityRefreshGeneration &+= 1
        let refreshGeneration = advertisingAuthorityRefreshGeneration
        advertisingAuthorityRefreshInProgress = true
        defer {
            if refreshGeneration == advertisingAuthorityRefreshGeneration {
                advertisingAuthorityRefreshInProgress = false
            }
        }
        do {
            try await discoveryManager.updateAdvertisingAuthority(authority)
            guard refreshGeneration == advertisingAuthorityRefreshGeneration else {
                throw ListeningAuthorityError.refreshSuperseded
            }
            let committedAfterUpdate = try await skyBridgeCore
                .committedActiveProtocolIdentitySnapshot()
                .snapshot
            guard committedAfterUpdate == authority else {
                throw ListeningAuthorityError.refreshSuperseded
            }
            let readiness = discoveryManager.advertisingReadinessSnapshot
            guard let port = readiness.actualPort,
                  readiness.isReady(for: port, authority: authority) else {
                throw NSError(
                    domain: "P2PConnectionManager",
                    code: -2202,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "协议身份已切换，但 Bonjour authority 未应用"
                    ]
                )
            }
            isListening = true
            lastError = nil
        } catch {
            let latestCommittedAuthority = try? await skyBridgeCore
                .committedActiveProtocolIdentitySnapshot()
                .snapshot
            let readiness = discoveryManager.advertisingReadinessSnapshot
            let alreadyPublishesLatest = latestCommittedAuthority.flatMap { latest in
                readiness.actualPort.map { readiness.isReady(for: $0, authority: latest) }
            } ?? false
            if refreshGeneration == advertisingAuthorityRefreshGeneration,
               !alreadyPublishesLatest {
                discoveryManager.stopAdvertising()
                isListening = false
                lastError = error.localizedDescription
            }
            throw error
        }
    }
    
    /// Retry spacing for advertising/listening recovery.
    ///
    /// The schedule escalates and then holds at a ceiling; it never returns "give up".
    /// Discoverability is a desired state, so the only thing that stops retrying is an
    /// explicit `stopListening()`. The blockers seen in practice (pending local-network
    /// permission, a control port not yet released, an interface still coming up) are all
    /// resolvable later without any further user interaction with this app.
    enum ListeningRecoveryDelayError: Error, Sendable, Equatable {
        case invalidAttempt(Int)
    }

    nonisolated static func listeningRecoveryDelay(
        forAttempt attempt: Int
    ) -> Result<TimeInterval, ListeningRecoveryDelayError> {
        guard attempt >= 1 else {
            return .failure(.invalidAttempt(attempt))
        }
        let schedule: [TimeInterval] = [3, 8, 20, 45, 60]
        return .success(schedule[min(attempt - 1, schedule.count - 1)])
    }

    // MARK: - Advertising Supervision

    /// Marks advertising as desired and installs the supervision triggers.
    ///
    /// Startup alone is not a sufficient trigger: the listener can also be lost to an
    /// interface change or a Bonjour republish failure long after a successful start.
    private func beginListeningSupervision() {
        desiredListening = true

        // Both triggers capture `self` weakly: the manager owns the cancellable and the
        // monitor, so a strong capture here would be a retain cycle.
        if advertisingHealthObservation == nil {
            advertisingHealthObservation = discoveryManager.$isAdvertising
                .removeDuplicates()
                .sink { [weak self] isAdvertising in
                    Task { @MainActor in
                        self?.handleAdvertisingHealthChange(isAdvertising: isAdvertising)
                    }
                }
        }

        if listeningPathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let isSatisfied = path.status == .satisfied
                Task { @MainActor in
                    self?.handleListeningPathUpdate(isSatisfied: isSatisfied)
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.skybridge.p2p.listening-path"))
            listeningPathMonitor = monitor
        }
    }

    private func endListeningSupervision() {
        desiredListening = false
        advertisingHealthObservation?.cancel()
        advertisingHealthObservation = nil
        listeningPathMonitor?.cancel()
        listeningPathMonitor = nil
        lastSupervisorNudgeAt = nil
    }

    /// Reacts to losing a listener that had already reached ready.
    private func handleAdvertisingHealthChange(isAdvertising: Bool) {
        guard desiredListening, !isAdvertising else { return }
        // Only a *healthy* listener disappearing is news here. Startup failures are already
        // owned by `scheduleListeningRecovery`, and reacting to them again would double-drive
        // the backoff.
        guard isListening,
              listeningStartupOperation == nil,
              !advertisingAuthorityRefreshInProgress else { return }

        isListening = false
        SkyBridgeLogger.shared.warning("⚠️ Bonjour 广播意外中断，监督器将重建 P2P 监听器")
        nudgeListeningSupervisor(reason: "advertising-dropped")
    }

    private func handleListeningPathUpdate(isSatisfied: Bool) {
        guard desiredListening, isSatisfied, !isListening else { return }
        nudgeListeningSupervisor(reason: "network-path-satisfied")
    }

    /// Retries immediately and restarts the backoff, because the trigger represents a
    /// genuinely new condition rather than another failure of the same attempt.
    /// Flapping triggers are suppressed so they cannot reset the backoff repeatedly.
    private func nudgeListeningSupervisor(reason: String) {
        guard desiredListening, !isListening else { return }

        let now = Date()
        if let lastSupervisorNudgeAt,
           now.timeIntervalSince(lastSupervisorNudgeAt) < Self.supervisorNudgeMinimumInterval {
            SkyBridgeLogger.shared.debug(
                "P2P 监听器监督触发被抖动抑制（\(reason)），沿用既有退避计划"
            )
            return
        }
        lastSupervisorNudgeAt = now
        listeningRecoveryAttempts = 0

        SkyBridgeLogger.shared.info("🔁 P2P 监听器监督触发重建：\(reason)")
        scheduleListeningRetry(delay: 0, attempt: 0, reason: reason)
    }

    private func cancelListeningRecovery() {
        listeningRecoveryTask?.cancel()
        listeningRecoveryTask = nil
        listeningRecoveryAttempts = 0
        lastSupervisorNudgeAt = nil
    }

    private func scheduleListeningRecovery(after error: Error) {
        guard desiredListening else {
            advertisingLifecycle = .idle
            return
        }
        let disposition = Self.listeningFailureDisposition(after: error)
        switch disposition {
        case .superseded:
            listeningRecoveryTask?.cancel()
            listeningRecoveryTask = nil
            return
        case .blocked(let reason):
            listeningRecoveryTask?.cancel()
            listeningRecoveryTask = nil
            advertisingLifecycle = .blockedByStartupFailure(reason: reason)
            SkyBridgeLogger.shared.error(
                "⛔️ P2P 监听启动被完整性/配置错误阻止，不会自动重试: \(reason)"
            )
            return
        case .retry, .awaitingLocalNetworkAuthorization:
            break
        }

        let increment = listeningRecoveryAttempts.addingReportingOverflow(1)
        guard !increment.overflow else {
            advertisingLifecycle = .blockedByStartupFailure(
                reason: "listening-recovery-attempt-sequence-exhausted"
            )
            SkyBridgeLogger.shared.error(
                "P2P listener recovery stopped; code=attempt-sequence-exhausted"
            )
            return
        }
        let attempt = increment.partialValue
        listeningRecoveryAttempts = attempt
        let delay: TimeInterval
        switch Self.listeningRecoveryDelay(forAttempt: attempt) {
        case .success(let value):
            delay = value
        case .failure:
            advertisingLifecycle = .blockedByStartupFailure(
                reason: "listening-recovery-attempt-invalid"
            )
            SkyBridgeLogger.shared.error(
                "P2P listener recovery stopped; code=invalid-attempt"
            )
            return
        }

        if disposition == .awaitingLocalNetworkAuthorization {
            advertisingLifecycle = .awaitingLocalNetworkAuthorization(
                nextRetryInSeconds: delay
            )
            SkyBridgeLogger.shared.error(
                """
                ⛔️ P2P 广播未获得本地网络访问授权；请在「设置 › 隐私与安全性 › 本地网络」中\
                允许 SkyBridge。监督器将每 \(Int(delay)) 秒重试
                """
            )
        } else {
            advertisingLifecycle = .retrying(attempt: attempt, nextRetryInSeconds: delay)
        }

        scheduleListeningRetry(delay: delay, attempt: attempt, reason: "startup-failed")
    }

    private func scheduleListeningRetry(
        delay: TimeInterval,
        attempt: Int,
        reason: String
    ) {
        listeningRecoveryTask?.cancel()
        listeningRecoveryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.desiredListening,
                  !self.isListening else {
                return
            }

            SkyBridgeLogger.shared.info(
                "🔁 P2P 监听器恢复重试 reason=\(reason) attempt=\(attempt) delay=\(Int(delay))s"
            )
            do {
                try await self.startListening()
            } catch {
                // startListening() already recorded the error, updated the lifecycle state
                // and scheduled the next attempt; this only avoids an unhandled rethrow.
                SkyBridgeLogger.shared.debug(
                    "P2P 监听器恢复重试失败 attempt=\(attempt): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }
    }

    /// 停止监听
    public func stopListening() {
        endListeningSupervision()
        cancelListeningRecovery()
        advertisingAuthorityRefreshGeneration &+= 1
        advertisingAuthorityRefreshInProgress = false
        listeningStartupOperation?.task.cancel()
        discoveryManager.stopAdvertising()
        cancelAllProvisionalInboundConnections(reason: "P2P 监听器已停止")
        isListening = false
        advertisingLifecycle = .idle

        SkyBridgeLogger.shared.info("⏹️ P2P 监听器已停止")
    }

    /// 握手验证码（6 位数字）——用于“配对/信任”阶段的人工可视比对（论文中的 OOB pairing ceremony）。
    ///
    /// - Important: Code is deterministically derived from the *handshake transcript hash* to bind user verification
    ///   to the negotiated suite + policy + key shares. Both peers compute the same value after a successful handshake.
    public func pairingVerificationCode(for deviceId: String) -> String? {
        guard let current = exactAuthenticatedSessionForStableDeviceIdentifier(
            deviceId,
            requireConnectedStatus: false
        ) else { return nil }

        return Self.pairingVerificationCode(transcriptHash: current.keys.transcriptHash)
    }

    /// Promotes the authority authenticated by one exact, still-current P2P
    /// session after the operator compares its short authentication string.
    ///
    /// Route aliases and previously stored pins are deliberately excluded:
    /// the stable identifier, transcript, negotiated suite, algorithm,
    /// fingerprint, and raw public key must all come from the same connection
    /// incarnation. The legacy protocol-key projection is written first and
    /// remains inert until the revocation-aware TrustedDeviceStore activation
    /// succeeds. A stale session or persistence failure rolls that projection
    /// back before this method returns.
    public func approveCurrentAuthenticatedSessionTrust(
        for device: DiscoveredDevice,
        verificationCode: String,
        requirePQC: Bool
    ) async throws {
        guard verificationCode.count == 6,
              verificationCode.allSatisfy(\.isNumber),
              let stableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
                  from: device.id
              ),
              !PeerIdentityAliasResolver.isEndpointAlias(device.id),
              let current = exactAuthenticatedSessionForStableDeviceIdentifier(
                  device.id,
                  requireConnectedStatus: true
              ) else {
            throw SessionTrustApprovalError.invalidOrStaleSession
        }
        try requireCurrentAuthenticatedConnection(current.receipt)

        guard !requirePQC || current.receipt.negotiatedSuite.isPQCGroup else {
            throw SessionTrustApprovalError.pqcRequired
        }
        let expectedCode = Self.pairingVerificationCode(
            transcriptHash: current.keys.transcriptHash
        )
        guard Self.constantTimeEqual(verificationCode, expectedCode) else {
            throw SessionTrustApprovalError.verificationCodeMismatch
        }

        guard let sessionAuthority = sessionPairingAuthorityByPeerId[current.peerId],
              sessionAuthority.connectionGeneration == current.receipt.lease.generation,
              let publicKey = sessionAuthority.binding.authority.protocolPublicKeyBytes,
              !publicKey.isEmpty,
              let algorithm = ProtocolSigningAlgorithm(
                  rawValue: sessionAuthority.binding.authority.protocolSigningAlgorithm
              ) else {
            throw SessionTrustApprovalError.missingAuthenticatedAuthority
        }
        let protocolIdentityKey = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: algorithm.rawValue,
            publicKey: publicKey
        )
        guard let authenticatedFingerprint = protocolIdentityKey.authoritativeFingerprint,
              authenticatedFingerprint.caseInsensitiveCompare(
                  sessionAuthority.binding.authority.protocolPublicKeyFingerprint
              ) == .orderedSame else {
            throw SessionTrustApprovalError.missingAuthenticatedAuthority
        }

        let protocolMutationReceipt: ProtocolIdentityTrustStore.AuthorityBoundMutationReceipt
        do {
            protocolMutationReceipt = try await ProtocolIdentityTrustStore.shared
                .upsertAuthorityBound(
                    deviceId: stableDeviceId,
                    protocolIdentityPublicKeys: [protocolIdentityKey]
                )
        } catch {
            throw SessionTrustApprovalError.persistenceFailed(
                Self.diagnosticErrorSummary(error)
            )
        }

        do {
            try requireCurrentAuthenticatedConnection(current.receipt)
            guard sessionPairingAuthorityByPeerId[current.peerId]?.connectionGeneration
                    == current.receipt.lease.generation,
                  sessionPairingAuthorityByPeerId[current.peerId]?.binding
                    == sessionAuthority.binding else {
                throw SessionTrustApprovalError.invalidOrStaleSession
            }

            let stableAliases = Self.stableIdentifierSpellings(
                deviceId: device.id,
                normalizedStableDeviceId: stableDeviceId
            )
            guard try TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
                peerId: current.peerId,
                deviceId: stableDeviceId,
                aliases: stableAliases,
                displayName: device.name,
                protocolSigningAlgorithm: algorithm.rawValue,
                protocolPublicKeyFingerprint: authenticatedFingerprint,
                protocolPublicKeyBytes: publicKey
            ) else {
                throw SessionTrustApprovalError.persistenceFailed(
                    "trusted authority was not persisted"
                )
            }

            // No actor suspension occurs between the exact receipt check and
            // durable activation. This assertion documents that the mutation
            // can only authorize the session the operator actually compared.
            guard isCurrentAuthenticatedConnection(current.receipt),
                  sessionPairingAuthorityByPeerId[current.peerId]?.binding
                    == sessionAuthority.binding else {
                throw SessionTrustApprovalError.invalidOrStaleSession
            }
        } catch {
            do {
                try await ProtocolIdentityTrustStore.shared
                    .rollbackAuthorityBoundMutation(protocolMutationReceipt)
            } catch let rollbackError {
                throw SessionTrustApprovalError.rollbackIncomplete(
                    original: Self.diagnosticErrorSummary(error),
                    rollback: Self.diagnosticErrorSummary(rollbackError)
                )
            }
            throw error
        }
    }

    private enum SessionTrustApprovalError: LocalizedError {
        case invalidOrStaleSession
        case pqcRequired
        case verificationCodeMismatch
        case missingAuthenticatedAuthority
        case persistenceFailed(String)
        case rollbackIncomplete(original: String, rollback: String)

        var errorDescription: String? {
            switch self {
            case .invalidOrStaleSession:
                return "认证连接已结束、被替换或缺少稳定设备身份"
            case .pqcRequired:
                return "当前认证会话未协商后量子密码套件"
            case .verificationCodeMismatch:
                return "设备验证码不匹配"
            case .missingAuthenticatedAuthority:
                return "当前会话缺少可持久化的认证协议身份"
            case .persistenceFailed(let reason):
                return "保存认证设备身份失败：\(reason)"
            case .rollbackIncomplete(let original, let rollback):
                return "保存认证设备身份失败（\(original)），且协议身份回滚失败（\(rollback)）"
            }
        }
    }

    private func exactAuthenticatedSessionForStableDeviceIdentifier(
        _ deviceId: String,
        requireConnectedStatus: Bool
    ) -> (
        peerId: String,
        receipt: AuthenticatedConnectionReceipt,
        keys: SessionKeys
    )? {
        guard let stableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
            from: deviceId
        ), !PeerIdentityAliasResolver.isEndpointAlias(deviceId) else {
            return nil
        }

        let spellings = Self.stableIdentifierSpellings(
            deviceId: deviceId,
            normalizedStableDeviceId: stableDeviceId
        )
        let matches = spellings.compactMap { candidate in
            exactAuthenticatedSession(
                for: candidate,
                requireConnectedStatus: requireConnectedStatus
            )
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private nonisolated static func stableIdentifierSpellings(
        deviceId: String,
        normalizedStableDeviceId: String
    ) -> [String] {
        let bareStableDeviceId = String(normalizedStableDeviceId.dropFirst("id:".count))
        var seen = Set<String>()
        return [deviceId, normalizedStableDeviceId, bareStableDeviceId].filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    nonisolated static func pairingVerificationCode(transcriptHash: Data) -> String {
        var material = Data("SkyBridge-Pairing-SAS|".utf8)
        material.append(transcriptHash)

        let digest = SHA256.hash(data: material)
        let raw = digest.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
        let code = Int(raw % 1_000_000)
        return String(format: "%06d", code)
    }

    private nonisolated static func constantTimeEqual(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }

    /// 连接到设备
    public func connect(to device: DiscoveredDevice) async throws {
        var resolvedTargetDevice = try await resolveConnectableDeviceAwaitingControlRoute(from: device)
        resolvedTargetDevice = resolveLatestConnectableDevice(from: resolvedTargetDevice)
        let preferredTrustedPeerId = preferredTrustedPeerIdentifier(for: resolvedTargetDevice)
        let canonicalTargetId = registerCanonicalPeerIdentity(
            candidate: resolvedTargetDevice,
            primaryPeerId: preferredTrustedPeerId ?? resolvedTargetDevice.id
        )
        let targetDevice = canonicalizedDevice(
            resolvedTargetDevice,
            canonicalPeerId: canonicalTargetId
        )
        if targetDevice.id != device.id {
            SkyBridgeLogger.shared.info(
                "ℹ️ P2P 连接目标已补全: \(Self.protocolIdentityLogRedaction) -> \(Self.protocolIdentityLogRedaction)"
            )
        }
        if let preferredTrustedPeerId, preferredTrustedPeerId == targetDevice.id {
            SkyBridgeLogger.shared.info(
                "🔐 P2P 连接已命中受信任设备别名: \(Self.protocolIdentityLogRedaction) -> \(Self.protocolIdentityLogRedaction)"
            )
        }

        if try isSelfConnectionTarget(targetDevice) {
            connectionStatusByDeviceId[targetDevice.id] = .failed
            connectionErrorByDeviceId[targetDevice.id] = "已阻止自连接"
            SkyBridgeLogger.shared.warning(
                "⚠️ 已阻止可能的自连接目标: \(Self.protocolIdentityLogRedaction)"
            )
            throw P2PError.selfConnectionBlocked
        }

        let runtimePeerId = canonicalPeerLookupKey(targetDevice.id)
        if hasActiveAuthenticatedSession(for: targetDevice.id) {
            let effectiveDevice = canonicalizedDevice(targetDevice, canonicalPeerId: runtimePeerId)
            for peerId in connectionStatePeerIds(for: runtimePeerId) {
                connectionStatusByDeviceId[peerId] = .connected
                connectionErrorByDeviceId.removeValue(forKey: peerId)
            }
            upsertActiveConnection(device: effectiveDevice, status: .connected)
            syncPresentationState(for: runtimePeerId, preferredDevice: effectiveDevice)
            return
        }

        if let inFlightKey = matchingInFlightConnectKey(for: targetDevice, runtimePeerId: runtimePeerId) {
            SkyBridgeLogger.shared.info(
                "ℹ️ P2P 连接已在进行中，等待同一设备建连完成: peer=\(targetDevice.id) canonical=\(inFlightKey)"
            )
            try await waitForInFlightConnect(inFlightKey)
            try Task.checkCancellation()
            if hasActiveAuthenticatedSession(for: targetDevice.id) {
                let effectiveDevice = canonicalizedDevice(targetDevice, canonicalPeerId: runtimePeerId)
                for peerId in connectionStatePeerIds(for: runtimePeerId) {
                    connectionStatusByDeviceId[peerId] = .connected
                    connectionErrorByDeviceId.removeValue(forKey: peerId)
                }
                upsertActiveConnection(device: effectiveDevice, status: .connected)
                syncPresentationState(for: runtimePeerId, preferredDevice: effectiveDevice)
                return
            }
            throw P2PError.connectionFailed
        }

        // 并发限制（来自 Settings）
        let limit = max(1, SettingsManager.instance.maxConcurrentConnections)
        guard connectingCount < limit else {
            throw P2PError.tooManyConcurrentConnections
        }
        let inFlightConnectKey = registerInFlightConnect(for: targetDevice, runtimePeerId: runtimePeerId)
        defer { finishInFlightConnect(inFlightConnectKey) }
        if connections[targetDevice.id] != nil || connections[runtimePeerId] != nil || hasStoredSessionMaterial(for: targetDevice.id) {
            let detachedArbiterBindings = await clearStaleInboundSessionState(
                for: targetDevice.id,
                reason: "connect_requires_authenticated_session"
            )
            for binding in detachedArbiterBindings {
                await releaseArbiterSessionBinding(binding)
            }
            let aliases = connectionAliasSet(for: runtimePeerId)
                .union(PeerIdentityAliasResolver.lookupCandidates(for: targetDevice.id))
                .union([targetDevice.id, runtimePeerId])
            for key in stateKeysMatchingAliases(aliases, keys: connections.keys) {
                if let lease = connections.lease(for: key) {
                    invalidatePendingPairingIdentityRequests(
                        for: key,
                        connectionGeneration: lease.generation
                    )
                    lease.connection.cancel()
                    _ = connections.removeIfOwned(lease, for: key)
                    _ = await transport?.removeConnection(
                        lease.connection,
                        for: key,
                        leaseSequence: lease.sequence
                    )
                }
            }
            SkyBridgeLogger.shared.warning(
                "⛔️ 已拒绝仅凭传输连接标记为已连接: peer=\(Self.protocolIdentityLogRedaction) reason=missing_authenticated_session"
            )
        }
        connectingCount += 1
        defer { connectingCount -= 1 }
        reconnectSuppressedDeviceIds.remove(targetDevice.id)

        let endpoints = connectionEndpointCandidates(for: targetDevice)
        guard !endpoints.isEmpty else {
            throw P2PError.noLiveControlRoute
        }

        // 更新状态（UI：连接中）
        connectionStatusByDeviceId[targetDevice.id] = .connecting
        connectionErrorByDeviceId.removeValue(forKey: targetDevice.id)
        lastKnownDevices[targetDevice.id] = targetDevice

        var didAttemptStaleKEMRefresh = false
        var establishedReceipt: AuthenticatedConnectionReceipt?

        while true {
            try await ensureStrictPQCKEMTrustReady(for: targetDevice)

            let (connection, selectedEndpoint) = try await establishReadyConnection(
                to: endpoints,
                for: targetDevice
            )
            let connectionLease = try installTrackedConnection(
                connection,
                for: targetDevice.id
            )
            installConnectionObservers(connectionLease, for: targetDevice)
            selectedEndpointDescriptionByDeviceId[targetDevice.id] = selectedEndpoint.debugDescription
            await handleConnectionStateChange(
                .ready,
                for: targetDevice,
                lease: connectionLease
            )

            SkyBridgeLogger.shared.info("🔗 已连接候选端点：device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction)")

            // 发起方也必须开始接收（握手 MessageB 需要被路由到 HandshakeDriver）
            startReceiving(from: connection, peerId: targetDevice.id)

            do {
                let receipt: AuthenticatedConnectionReceipt
                if try await shouldUseClassicBootstrapForStrictPQC(device: targetDevice) {
                    receipt = try await performBootstrapAssistedPQCHandshake(
                        connection: connection,
                        device: targetDevice
                    )
                } else {
                    receipt = try await performPQCHandshake(
                        connection: connection,
                        device: targetDevice,
                        preferPQC: pqcManager.enforcePQCHandshake
                    )
                }
                try requireCurrentAuthenticatedConnection(receipt)
                guard receipt.lease.generation == connectionLease.generation,
                      receipt.lease.connection === connectionLease.connection else {
                    throw P2PError.staleConnectionIncarnation
                }
                establishedReceipt = receipt
                break
            } catch {
                // strictPQC is fail-closed: stale KEM may enter SKR-1 recovery;
                // it must not establish a Classic bootstrap channel or fake success.
                connection.cancel()
                if connections.removeIfOwned(connectionLease, for: targetDevice.id) != nil {
                    invalidatePendingPairingIdentityRequests(
                        for: targetDevice.id,
                        connectionGeneration: connectionLease.generation
                    )
                    removeSessionKeysIfOwned(
                        for: targetDevice.id,
                        connectionGeneration: connectionLease.generation
                    )
                    clearSessionPairingAuthority(
                        for: targetDevice.id,
                        connectionGeneration: connectionLease.generation
                    )
                    inboundRekeyRollbackByPeerId.removeValue(forKey: targetDevice.id)
                    let detachedHandshakeDriver = detachHandshakeOperationIfOwned(
                        for: targetDevice.id,
                        connectionGeneration: connectionLease.generation
                    )
                    sharedSecrets.removeValue(forKey: targetDevice.id)
                    activeConnections.removeAll { $0.device.id == targetDevice.id }
                    await detachedHandshakeDriver?.cancel()
                    _ = await transport?.removeConnection(
                        connection,
                        for: targetDevice.id,
                        leaseSequence: connectionLease.sequence
                    )
                }

                if !didAttemptStaleKEMRefresh {
                    do {
                        if try await recoverStalePeerKEMWithSignedLANRefresh(error, for: targetDevice) {
                            didAttemptStaleKEMRefresh = true
                            connectionStatusByDeviceId[targetDevice.id] = .connecting
                            connectionErrorByDeviceId.removeValue(forKey: targetDevice.id)
                            continue
                        }
                    } catch {
                        connectionStatusByDeviceId[targetDevice.id] = .failed
                        connectionErrorByDeviceId[targetDevice.id] = userVisibleConnectionError(error)
                        throw error
                    }
                }

                connectionStatusByDeviceId[targetDevice.id] = .failed
                connectionErrorByDeviceId[targetDevice.id] = userVisibleConnectionError(error)
                if let prep = error as? AttemptPreparationError,
                   case .fallbackRateLimited(_, let cooldownSeconds) = prep {
                    SkyBridgeLogger.shared.warning("⏳ 降级被限流：将在 \(cooldownSeconds)s 后再尝试重连（避免反复触发 TCP RST/flow_failed）")
                    scheduleReconnectIfNeeded(deviceId: targetDevice.id, delayOverrideSeconds: Double(cooldownSeconds))
                } else if let hs = error as? HandshakeError,
                          case .failed(.missingPeerKEMPublicKey(let suite)) = hs {
                    let message = "🔐 strictPQC 缺少对端 PQC KEM 公钥（suite=\(suite)）。当前不会再自动 classic bootstrap，也不会继续伪成功；需要重新建立受信任 KEM 后再连接。"
                    SkyBridgeLogger.shared.warning(message)
                    connectionErrorByDeviceId[targetDevice.id] = message
                    reconnectSuppressedDeviceIds.insert(targetDevice.id)
                    cancelReconnectTask(deviceId: targetDevice.id)
                } else if await handleStalePeerKEMFailureIfNeeded(error, for: targetDevice) {
                    cancelReconnectTask(deviceId: targetDevice.id)
                } else {
                    scheduleReconnectIfNeeded(deviceId: targetDevice.id)
                }
                throw error
            }
        }

        guard let establishedReceipt else {
            throw P2PError.staleConnectionIncarnation
        }
        try requireCurrentAuthenticatedConnection(establishedReceipt)

        if pqcManager.enforcePQCHandshake,
           !establishedReceipt.negotiatedSuite.isPQCGroup {
            let negotiated = establishedReceipt.negotiatedSuite
            let message = "严格 PQC 已启用，但会话竟然协商到了 Classic suite=\(negotiated.rawValue)；已拒绝保留该连接。"
            SkyBridgeLogger.shared.error("⛔️ \(message)")
            establishedReceipt.lease.connection.cancel()
            if connections.removeIfOwned(
                establishedReceipt.lease,
                for: targetDevice.id
            ) != nil {
                invalidatePendingPairingIdentityRequests(
                    for: targetDevice.id,
                    connectionGeneration: establishedReceipt.lease.generation
                )
                removeSessionKeysIfOwned(
                    for: targetDevice.id,
                    connectionGeneration: establishedReceipt.lease.generation,
                    sessionId: establishedReceipt.sessionId
                )
                clearSessionPairingAuthority(
                    for: targetDevice.id,
                    connectionGeneration: establishedReceipt.lease.generation
                )
                inboundRekeyRollbackByPeerId.removeValue(forKey: targetDevice.id)
                let detachedHandshakeDriver = detachHandshakeOperationIfOwned(
                    for: targetDevice.id,
                    connectionGeneration: establishedReceipt.lease.generation
                )
                sharedSecrets.removeValue(forKey: targetDevice.id)
                activeConnections.removeAll { $0.device.id == targetDevice.id }
                await detachedHandshakeDriver?.cancel()
                await transport?.removeConnection(
                    establishedReceipt.lease.connection,
                    for: targetDevice.id,
                    leaseSequence: establishedReceipt.lease.sequence
                )
            }
            connectionStatusByDeviceId[targetDevice.id] = .failed
            connectionErrorByDeviceId[targetDevice.id] = message
            throw P2PError.pqcRequiredUnavailable
        }
        try requireCurrentAuthenticatedConnection(establishedReceipt)
        
        // Paper-aligned contract:
        // connected == handshake finished && session keys ready (not just transport ready).
        SkyBridgeLogger.shared.info("✅ 已连接到 \(targetDevice.name)")
        connectionStatusByDeviceId[targetDevice.id] = .connected
        connectionErrorByDeviceId.removeValue(forKey: targetDevice.id)
        let authenticatedTargetDevice = canonicalizedDevice(
            targetDevice,
            canonicalPeerId: targetDevice.id
        )
        upsertActiveConnection(device: authenticatedTargetDevice, status: .connected)
        discoveryManager.setConnectionLiveness(
            for: authenticatedTargetDevice,
            isConnected: true
        )
        startHeartbeatIfNeeded(deviceId: targetDevice.id)

        // 更新灵动岛状态（iOS 17+）
        let suite = establishedReceipt.negotiatedSuite.rawValue
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentAuthenticatedConnection(establishedReceipt) else {
                return
            }
            await LiveActivityManager.shared.setConnected(
                deviceName: targetDevice.name,
                cryptoSuite: suite
            )
        }
    }
    
    /// 断开连接
    @discardableResult
    public func disconnect(from device: DiscoveredDevice) async -> Bool {
        let resolvedTargetDevice = resolveLatestConnectableDevice(from: device)
        let provisionalTargetDevice = canonicalizedDevice(
            resolvedTargetDevice,
            canonicalPeerId: registerCanonicalPeerIdentity(
                candidate: resolvedTargetDevice,
                primaryPeerId: resolvedTargetDevice.id
            )
        )
        let runtimePeerIds = runtimePeerIdsMatching(device: provisionalTargetDevice)
        var didDisconnect = false

        for runtimePeerId in runtimePeerIds {
            let targetDevice = canonicalizedDevice(
                lastKnownDevices[runtimePeerId] ?? provisionalTargetDevice,
                canonicalPeerId: runtimePeerId
            )
            let peerIds = connectionStatePeerIds(for: runtimePeerId)
            let hadRuntimeConnection = connections[runtimePeerId] != nil

            if hadRuntimeConnection {
                if let current = exactAuthenticatedSession(
                    for: runtimePeerId,
                    requireConnectedStatus: false
                ) {
                    await sendPeerDisconnectingNotice(
                        device: targetDevice,
                        expectedReceipt: current.receipt,
                        keySnapshot: current.keys
                    )
                }
                for peerId in peerIds {
                    connectionStatusByDeviceId[peerId] = .disconnecting
                }
                userInitiatedDisconnects.insert(runtimePeerId)
                heartbeatTasks[runtimePeerId]?.cancel()
                heartbeatTasks.removeValue(forKey: runtimePeerId)
                heartbeatOperationByPeerId.removeValue(forKey: runtimePeerId)
                cancelReconnectTask(deviceId: runtimePeerId)
                reconnectAttempts.removeValue(forKey: runtimePeerId)
                cancelPeerProtectionRoots(for: runtimePeerId)
                let disconnectedLease = connections.lease(for: runtimePeerId)
                let detachedHandshakeDriver = disconnectedLease.flatMap {
                    detachHandshakeOperationIfOwned(
                        for: runtimePeerId,
                        connectionGeneration: $0.generation
                    )
                }
                let detachedArbiterBinding = disconnectedLease.flatMap {
                    detachArbiterSessionBinding(
                        for: runtimePeerId,
                        expectedConnectionGeneration: $0.generation
                    )
                }
                disconnectedLease?.connection.cancel()
                if let disconnectedLease {
                    _ = connections.removeIfOwned(disconnectedLease, for: runtimePeerId)
                }
                if let disconnectedLease {
                    invalidatePendingPairingIdentityRequests(
                        for: runtimePeerId,
                        connectionGeneration: disconnectedLease.generation
                    )
                }
                sharedSecrets.removeValue(forKey: runtimePeerId)
                if let disconnectedLease {
                    removeSessionKeysIfOwned(
                        for: runtimePeerId,
                        connectionGeneration: disconnectedLease.generation
                    )
                }
                clearSessionPairingAuthority(
                    for: runtimePeerId,
                    connectionGeneration: disconnectedLease?.generation
                )
                inboundRekeyRollbackByPeerId.removeValue(forKey: runtimePeerId)
                negotiatedSuiteByDeviceId.removeValue(forKey: runtimePeerId)
                if let disconnectedLease {
                    await detachedHandshakeDriver?.cancel()
                    _ = await transport?.removeConnection(
                        disconnectedLease.connection,
                        for: runtimePeerId,
                        leaseSequence: disconnectedLease.sequence
                    )
                    if let detachedArbiterBinding {
                        await releaseArbiterSessionBinding(detachedArbiterBinding)
                    }
                }

                // 更新活动连接列表与展示态残留
                purgeTerminalConnectionPresentationState(for: runtimePeerId)
                discoveryManager.setConnectionLiveness(for: targetDevice, isConnected: false)
                for peerId in peerIds {
                    connectionStatusByDeviceId[peerId] = .disconnected
                    connectionErrorByDeviceId.removeValue(forKey: peerId)
                }

                SkyBridgeLogger.shared.info("🔌 已断开与 \(Self.protocolIdentityLogRedaction) 的连接")
                didDisconnect = true
            } else if purgeStalePresentationState(for: targetDevice) {
                SkyBridgeLogger.shared.warning("🧹 已清理陈旧的连接展示态: \(Self.protocolIdentityLogRedaction)")
                didDisconnect = true
            }
        }

        if !didDisconnect, purgeStalePresentationState(for: provisionalTargetDevice) {
            SkyBridgeLogger.shared.warning("🧹 已清理陈旧的连接展示态: \(Self.protocolIdentityLogRedaction)")
            didDisconnect = true
        }

        guard didDisconnect else {
            SkyBridgeLogger.shared.warning("ℹ️ 未找到可断开的运行时连接: \(Self.protocolIdentityLogRedaction)")
            return false
        }

        // 更新灵动岛状态（iOS 17+）
        Task {
            await LiveActivityManager.shared.setDisconnected()
        }
        return didDisconnect
    }
    
    /// 接受连接请求
    public func acceptConnection(from deviceID: String) async {
        // 实现连接接受逻辑
        SkyBridgeLogger.shared.info("✅ 接受来自 \(Self.protocolIdentityLogRedaction) 的连接")
    }
    
    /// 拒绝连接请求
    public func rejectConnection(from deviceID: String) async {
        SkyBridgeLogger.shared.info("❌ 拒绝来自 \(Self.protocolIdentityLogRedaction) 的连接")
    }
    
    // MARK: - Private Methods
    
    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            SkyBridgeLogger.shared.info("✅ 监听器就绪")

        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 监听器失败: \(Self.diagnosticErrorSummary(error))")
            isListening = false
            lastError = userVisibleConnectionError(error)
            
        case .cancelled:
            SkyBridgeLogger.shared.info("⏹️ 监听器已取消")
            isListening = false
            
        default:
            break
        }
    }
    
    /// 处理入站连接（作为响应方）
    private func handleIncomingConnection(_ connection: NWConnection, peerId: String) async {
        guard registerProvisionalInboundConnection(connection, peerId: peerId) else {
            return
        }
        SkyBridgeLogger.shared.info("📞 处理入站连接: \(Self.protocolIdentityLogRedaction)")
        smokeInboundTrace("p2p-inbound handle-start peer=\(Self.protocolIdentityLogRedaction)")

        let inboundDevice = makeActiveConnectionDevice(peerId: peerId, connection: connection)
        let canonicalPeerId = registerCanonicalPeerIdentity(candidate: inboundDevice, primaryPeerId: peerId)
        smokeInboundTrace(
            "p2p-inbound canonical peer=\(Self.protocolIdentityLogRedaction) canonical=\(Self.protocolIdentityLogRedaction)"
        )
        let canonicalDevice = canonicalizedDevice(inboundDevice, canonicalPeerId: canonicalPeerId)

        // Delay responder driver creation until the first MessageA arrives.
        // The offered suites in MessageA decide whether the inbound path must
        // initialize as Classic, ML-KEM, or X-Wing. Creating a driver here would
        // freeze whatever policy was left from a previous connection and can
        // reject a valid PQC MessageA with suiteNegotiationFailed.
        // The first frame also decides whether this is an ephemeral bootstrap
        // control channel. TCP-only reachability probes and bootstrap-control
        // exchanges must not replace the active P2P session for the same peer.
        startReceiving(from: connection, peerId: canonicalPeerId, promoteInboundDevice: canonicalDevice)
        SkyBridgeLogger.shared.info("🔐 等待来自 \(Self.protocolIdentityLogRedaction) 的握手消息")
        smokeInboundTrace(
            "p2p-inbound awaiting-message peer=\(Self.protocolIdentityLogRedaction)"
        )
    }
    
    /// 开始从连接接收消息
    private func startReceiving(
        from connection: NWConnection,
        peerId: String,
        promoteInboundDevice: DiscoveredDevice? = nil
    ) {
        // 与 macOS 端一致：4-byte big-endian length framing
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lengthData, _, isComplete, error in
            Task { @MainActor in
                if let error = error {
                    SkyBridgeLogger.shared.error("❌ 接收长度头错误: \(Self.diagnosticErrorSummary(error))")
                    self?.smokeInboundTrace(
                        "p2p-inbound rx-header-error peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                    )
                    self?.handleInboundReceiveFailure(
                        connection,
                        peerId: peerId,
                        reason: "接收长度头错误: \(Self.diagnosticErrorSummary(error))",
                        promoteInboundDevice: promoteInboundDevice
                    )
                    return
                }
                guard let lengthData, lengthData.count == 4 else {
                    self?.smokeInboundTrace(
                        "p2p-inbound rx-header-short peer=\(Self.protocolIdentityLogRedaction) bytes=\(lengthData?.count ?? 0) complete=\(isComplete ? 1 : 0)"
                    )
                    if !isComplete {
                        self?.startReceiving(from: connection, peerId: peerId, promoteInboundDevice: promoteInboundDevice)
                    } else {
                        self?.handleInboundReceiveFailure(
                            connection,
                            peerId: peerId,
                            reason: "连接在首帧长度头前关闭",
                            promoteInboundDevice: promoteInboundDevice
                        )
                    }
                    return
                }
                
                let length = lengthData.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
                }
                let bodyLen = Int(length)
                self?.smokeInboundTrace(
                    "p2p-inbound rx-header peer=\(Self.protocolIdentityLogRedaction) bodyBytes=\(bodyLen)"
                )
                guard (try? P2PControlFramePolicy.inboundBodyByteCount(from: length)) != nil else {
                    if self?.looksLikeTLSRecordHeader(lengthData) == true {
                        SkyBridgeLogger.shared.warning("⚠️ 检测到 TLS 记录头，但当前通道期望 length-framed 明文握手，已关闭该入站连接")
                        self?.smokeInboundTrace(
                            "p2p-inbound rx-header-invalid peer=\(Self.protocolIdentityLogRedaction) reason=tls-record bodyBytes=\(bodyLen)"
                        )
                        self?.cleanupBrokenInboundConnection(connection, peerId: peerId, reason: "传输协议不匹配（收到 TLS 记录头）")
                    } else {
                        SkyBridgeLogger.shared.error("❌ 接收长度头非法: \(bodyLen) peer=\(Self.protocolIdentityLogRedaction) header=\(Self.protocolIdentityLogRedaction)（可能连接到了错误协议或端口）")
                        self?.smokeInboundTrace(
                            "p2p-inbound rx-header-invalid peer=\(Self.protocolIdentityLogRedaction) reason=length bodyBytes=\(bodyLen) header=\(Self.protocolIdentityLogRedaction)"
                        )
                        self?.cleanupBrokenInboundConnection(connection, peerId: peerId, reason: "非法消息长度头: \(bodyLen)")
                    }
                    return
                }

                connection.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { [weak self] payload, _, isComplete2, error2 in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error2 = error2 {
                            SkyBridgeLogger.shared.error("❌ 接收消息体错误: \(Self.diagnosticErrorSummary(error2))")
                            self.smokeInboundTrace(
                                "p2p-inbound rx-body-error peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error2))"
                            )
                            self.handleInboundReceiveFailure(
                                connection,
                                peerId: peerId,
                                reason: "接收消息体错误: \(Self.diagnosticErrorSummary(error2))",
                                promoteInboundDevice: promoteInboundDevice
                            )
                            return
                        }
                        guard let payload, payload.count == bodyLen else {
                            self.smokeInboundTrace(
                                "p2p-inbound rx-body-short peer=\(Self.protocolIdentityLogRedaction) expected=\(bodyLen) actual=\(payload?.count ?? 0) complete=\(isComplete2 ? 1 : 0)"
                            )
                            self.handleInboundReceiveFailure(
                                connection,
                                peerId: peerId,
                                reason: "连接在完整消息体到达前关闭",
                                promoteInboundDevice: promoteInboundDevice
                            )
                            return
                        }
                        if !payload.isEmpty {
                            let classification = await Task.detached(priority: .userInitiated) {
                                let unwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
                                let handshakeFrame = HandshakePadding.unwrapIfNeeded(unwrapped, label: "rx")
                                return ProvisionalInboundFrameClassification(
                                    unwrappedPayload: unwrapped,
                                    bootstrapMessage: try? AppMessage.decodeWireMessage(from: handshakeFrame),
                                    handshakeMessageA: try? HandshakeMessageA.decode(from: handshakeFrame)
                                )
                            }.value
                            self.smokeInboundTrace(
                                "p2p-inbound rx-body peer=\(Self.protocolIdentityLogRedaction) bytes=\(payload.count)"
                            )
                            if let promoteInboundDevice {
                                if await self.handlePreHandshakeBootstrapControlMessage(
                                    classification.unwrappedPayload,
                                    from: peerId,
                                    over: connection,
                                    decodedMessage: classification.bootstrapMessage
                                ) {
                                    self.finishProvisionalInboundConnection(connection)
                                    self.smokeInboundTrace(
                                        "p2p-inbound provisional-bootstrap-control-consumed peer=\(Self.protocolIdentityLogRedaction)"
                                    )
                                    connection.cancel()
                                    return
                                }

                                guard classification.handshakeMessageA != nil else {
                                    let line = "⛔️ inbound pre-handshake frame rejected: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-frame-classification reason=unsupported_or_malformed"
                                    SkyBridgeLogger.shared.warning(line)
                                    SignedKEMRefreshSmokeStatusWriter.append(line)
                                    self.handleInboundReceiveFailure(
                                        connection,
                                        peerId: peerId,
                                        reason: "入站连接首帧不是有效握手协议帧",
                                        promoteInboundDevice: promoteInboundDevice
                                    )
                                    return
                                }

                                do {
                                    try await self.promoteInboundConnectionForFirstFrame(
                                        connection,
                                        peerId: peerId,
                                        device: promoteInboundDevice
                                    )
                                } catch {
                                    let message = "入站连接首帧推广失败: \(Self.diagnosticErrorSummary(error))"
                                    SkyBridgeLogger.shared.error("❌ \(message)")
                                    self.smokeInboundTrace(
                                        "p2p-inbound promote-failed peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                                    )
                                    self.handleInboundReceiveFailure(
                                        connection,
                                        peerId: peerId,
                                        reason: message,
                                        promoteInboundDevice: promoteInboundDevice
                                    )
                                    return
                                }

                                guard let lease = self.connections.lease(for: peerId),
                                    lease.connection === connection,
                                    self.connections.isCurrent(lease, for: peerId),
                                    await self.prepareProvisionalInboundHandshakeDriver(
                                    for: peerId,
                                    firstFrame: classification.unwrappedPayload,
                                    decodedMessageA: classification.handshakeMessageA,
                                    originLease: lease
                                ),
                                    self.connections.isCurrent(lease, for: peerId),
                                    self.handshakeDrivers[peerId] != nil
                                else {
                                    self.handleInboundReceiveFailure(
                                        connection,
                                        peerId: peerId,
                                        reason: "无法为当前入站连接建立握手 driver",
                                        promoteInboundDevice: promoteInboundDevice
                                    )
                                    return
                                }
                                self.handshakeDriverConnectionGenerationByPeerId[peerId] = lease.generation
                            }

                            await self.handleReceivedMessage(
                                payload,
                                from: peerId,
                                over: connection
                            )
                        } else {
                            self.smokeInboundTrace(
                                "p2p-inbound rx-body-empty peer=\(Self.protocolIdentityLogRedaction) complete=\(isComplete2 ? 1 : 0)"
                            )
                            self.handleInboundReceiveFailure(
                                connection,
                                peerId: peerId,
                                reason: "连接在消息体前关闭",
                                promoteInboundDevice: promoteInboundDevice
                            )
                            return
                        }

                        // 继续接收（只要连接未 complete）
                        if !(isComplete || isComplete2) {
                            self.startReceiving(from: connection, peerId: peerId)
                        }
                    }
                }
            }
        }
    }

    private func promoteInboundConnectionForFirstFrame(
        _ connection: NWConnection,
        peerId: String,
        device: DiscoveredDevice
    ) async throws {
        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        let canonicalDevice = canonicalizedDevice(device, canonicalPeerId: canonicalPeerId)
        if let tracked = connections[canonicalPeerId], tracked === connection {
            return
        }
        guard let transport else {
            let message = "入站连接缺少握手传输层"
            lastError = message
            throw NSError(
                domain: "P2PConnectionManager",
                code: -2301,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        if hasActiveAuthenticatedSession(for: canonicalPeerId),
           let existing = connections[canonicalPeerId],
           existing !== connection {
            throw NSError(
                domain: "P2PConnectionManager",
                code: -2303,
                userInfo: [NSLocalizedDescriptionKey: "已有已认证会话；拒绝未认证入站连接替换"]
            )
        }
        if let existing = connections[canonicalPeerId], existing !== connection {
            smokeInboundTrace(
                "p2p-inbound replacing-active-connection peer=\(Self.protocolIdentityLogRedaction)"
            )
            existing.cancel()
        }

        lastKnownDevices[canonicalPeerId] = canonicalDevice
        connectionStatusByDeviceId[canonicalPeerId] = .connecting
        connectionErrorByDeviceId.removeValue(forKey: canonicalPeerId)
        let connectionLease = try installTrackedConnection(
            connection,
            for: canonicalPeerId
        )
        installConnectionObservers(connectionLease, for: canonicalDevice)
        await handleConnectionStateChange(
            .ready,
            for: canonicalDevice,
            lease: connectionLease
        )

        guard await transport.setConnection(
            connection,
            for: canonicalPeerId,
            leaseSequence: connectionLease.sequence
        ), connections.isCurrent(connectionLease, for: canonicalPeerId) else {
            throw P2PError.staleConnectionIncarnation
        }
        guard case .ready = connection.state else {
            throw NSError(
                domain: "P2PConnectionManager",
                code: -2302,
                userInfo: [NSLocalizedDescriptionKey: "入站连接在首帧推广期间已关闭"]
            )
        }
        smokeInboundTrace(
            "p2p-inbound promoted-active peer=\(Self.protocolIdentityLogRedaction)"
        )
    }

    private func handleInboundReceiveFailure(
        _ connection: NWConnection,
        peerId: String,
        reason: String,
        promoteInboundDevice: DiscoveredDevice?
    ) {
        finishProvisionalInboundConnection(connection)
        if promoteInboundDevice != nil, !isTrackedConnection(connection) {
            smokeInboundTrace(
                "p2p-inbound provisional-closed peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.smokeSanitize(reason))"
            )
            connection.cancel()
            return
        }

        cleanupBrokenInboundConnection(connection, peerId: peerId, reason: reason)
    }

    private func prepareProvisionalInboundHandshakeDriver(
        for peerId: String,
        firstFrame: Data,
        decodedMessageA: HandshakeMessageA? = nil,
        originLease: P2PConnectionLease<NWConnection>
    ) async -> Bool {
        let handshakeFrame = HandshakePadding.unwrapIfNeeded(firstFrame, label: "rx")
        guard let messageA = decodedMessageA ?? (try? HandshakeMessageA.decode(from: handshakeFrame)),
              !messageA.supportedSuites.isEmpty else {
            smokeInboundTrace(
                "p2p-inbound provisional-rejected peer=\(Self.protocolIdentityLogRedaction) reason=invalid-first-frame bytes=\(handshakeFrame.count)"
            )
            return false
        }

        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        let driver: HandshakeDriver?
        if hasStoredSessionMaterial(for: canonicalPeerId),
           hasActiveAuthenticatedSession(for: canonicalPeerId) {
            driver = await ensureInboundRekeyDriverIfNeeded(
                for: canonicalPeerId,
                frame: handshakeFrame,
                originLease: originLease
            )
        } else {
            driver = await ensureInboundHandshakeDriverIfNeeded(
                for: canonicalPeerId,
                frame: handshakeFrame,
                originLease: originLease
            )
        }

        if driver == nil {
            smokeInboundTrace(
                "p2p-inbound provisional-rejected peer=\(Self.protocolIdentityLogRedaction) reason=driver-unavailable"
            )
        }
        return driver != nil
    }

    private func looksLikeTLSRecordHeader(_ header: Data) -> Bool {
        guard header.count == 4 else { return false }
        let bytes = [UInt8](header)
        let contentType = bytes[0]
        let majorVersion = bytes[1]
        let minorVersion = bytes[2]
        guard [0x14, 0x15, 0x16, 0x17].contains(contentType) else { return false }
        guard majorVersion == 0x03 else { return false }
        return minorVersion <= 0x04 // TLS 1.0...1.3
    }

    private func cleanupBrokenInboundConnection(_ connection: NWConnection, peerId: String, reason: String) {
        finishProvisionalInboundConnection(connection)
        let peerId = canonicalPeerLookupKey(peerId)
        smokeInboundTrace(
            "p2p-inbound cleanup-broken peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.smokeSanitize(reason))"
        )
        connection.cancel()

        guard let lease = connections.lease(for: peerId),
              lease.connection === connection,
              connections.removeIfOwned(lease, for: peerId) != nil else {
            return
        }
        invalidatePendingPairingIdentityRequests(
            for: peerId,
            connectionGeneration: lease.generation
        )
        let detachedHandshakeDriver = detachHandshakeOperationIfOwned(
            for: peerId,
            connectionGeneration: lease.generation
        )
        sharedSecrets.removeValue(forKey: peerId)
        removeSessionKeysIfOwned(
            for: peerId,
            connectionGeneration: lease.generation
        )
        clearSessionPairingAuthority(
            for: peerId,
            connectionGeneration: lease.generation
        )
        inboundRekeyRollbackByPeerId.removeValue(forKey: peerId)
        negotiatedSuiteByDeviceId.removeValue(forKey: peerId)
        heartbeatTasks[peerId]?.cancel()
        heartbeatTasks.removeValue(forKey: peerId)
        heartbeatOperationByPeerId.removeValue(forKey: peerId)
        cancelReconnectTask(deviceId: peerId)
        reconnectAttempts.removeValue(forKey: peerId)
        connectionStatusByDeviceId[peerId] = .failed
        connectionErrorByDeviceId[peerId] = reason
        discoveryManager.setConnectionLiveness(
            for: makeActiveConnectionDevice(peerId: peerId, connection: connection),
            isConnected: false
        )
        let detachedArbiterBinding = detachArbiterSessionBinding(
            for: peerId,
            expectedConnectionGeneration: lease.generation
        )
        Task { @MainActor in
            await detachedHandshakeDriver?.cancel()
            _ = await self.transport?.removeConnection(
                connection,
                for: peerId,
                leaseSequence: lease.sequence
            )
            if let detachedArbiterBinding {
                await self.releaseArbiterSessionBinding(detachedArbiterBinding)
            }
        }
    }

    /// 处理收到的消息
    private func handleReceivedMessage(
        _ data: Data,
        from peerId: String,
        over connection: NWConnection
    ) async {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let originLease = connections.lease(for: peerId),
            originLease.connection === connection,
            connections.isCurrent(originLease, for: peerId)
        else {
            SkyBridgeLogger.shared.warning(
                "⛔️ 已忽略来自陈旧 P2P connection incarnation 的消息"
            )
            return
        }
        lastActivityByDeviceId[peerId] = Date()
        // Phase C2: optional post-handshake traffic padding (SBP2).
        // This is safe to apply unconditionally because unwrap is a no-op unless magic matches.
        let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")

        SkyBridgeLogger.shared.debug("📨 收到消息 (\(unwrapped.count) bytes) from \(Self.protocolIdentityLogRedaction)")
        smokeInboundTrace(
            "p2p-inbound message peer=\(Self.protocolIdentityLogRedaction) bytes=\(unwrapped.count) existingDriver=\(handshakeDrivers[peerId] == nil ? 0 : 1) hasSession=\(hasStoredSessionMaterial(for: peerId) ? 1 : 0)"
        )

        // 已有握手驱动器：交给握手状态机处理
        if let driver = handshakeDrivers[peerId] {
            guard handshakeDriverConnectionGenerationByPeerId[peerId] == originLease.generation else {
                cleanupBrokenInboundConnection(
                    connection,
                    peerId: peerId,
                    reason: "握手 driver 与当前 connection incarnation 不一致"
                )
                return
            }
            smokeInboundTrace(
                "p2p-inbound dispatch existing-driver peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(
                unwrapped,
                from: peerId,
                initialDriver: driver,
                originLease: originLease
            )
            return
        }

        if await handlePreHandshakeBootstrapControlMessage(unwrapped, from: peerId) {
            smokeInboundTrace(
                "p2p-inbound bootstrap-control-consumed peer=\(Self.protocolIdentityLogRedaction)"
            )
            return
        }

        // 支持“握手失败后的同连接重试”：
        // 若此前 driver 已进入 failed 并被移除，需要在这里按新的 MessageA 重新创建 driver。
        if let freshInboundDriver = await ensureInboundHandshakeDriverIfNeeded(
            for: peerId,
            frame: unwrapped,
            originLease: originLease
        ) {
            guard connections.isCurrent(originLease, for: peerId) else { return }
            smokeInboundTrace(
                "p2p-inbound dispatch fresh-handshake peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(
                unwrapped,
                from: peerId,
                initialDriver: freshInboundDriver,
                originLease: originLease
            )
            return
        }

        // 支持“已建立会话上的入站 rekey”：
        // 若当前无 driver 但已存在 sessionKeys，且收到的是 MessageA，则切换回握手模式而不是误当业务密文。
        if let rekeyDriver = await ensureInboundRekeyDriverIfNeeded(
            for: peerId,
            frame: unwrapped,
            originLease: originLease
        ) {
            guard connections.isCurrent(originLease, for: peerId) else { return }
            smokeInboundTrace(
                "p2p-inbound dispatch rekey peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(
                unwrapped,
                from: peerId,
                initialDriver: rekeyDriver,
                originLease: originLease
            )
            return
        }

        // 握手完成后的业务消息（加密通道）
        if handshakeDrivers[peerId] == nil, sessionKeys[peerId] != nil {
            do {
                guard !isLikelyHandshakeControlPacket(unwrapped) else {
                    throw P2PError.unexpectedAuthenticatedHandshakeFrame
                }
                guard let keySnapshot = sessionKeys[peerId] else {
                    throw P2PError.noSessionKey
                }
                let receiveKey = keySnapshot.receiveKey
                let msg = try await Task.detached(priority: .userInitiated) {
                    let key = SymmetricKey(data: receiveKey)
                    let sealedBox = try AES.GCM.SealedBox(combined: unwrapped)
                    let plaintext = try AES.GCM.open(sealedBox, using: key)
                    return try AppMessage.decodeWireMessage(from: plaintext)
                }.value
                guard connections.isCurrent(originLease, for: peerId),
                    sessionKeyConnectionGenerationByPeerId[peerId] == originLease.generation,
                    sessionKeys[peerId]?.sessionId == keySnapshot.sessionId,
                    sessionKeys[peerId]?.receiveKey == receiveKey
                else {
                    SkyBridgeLogger.shared.debug("ℹ️ 丢弃 rekey 前已认证业务帧")
                    return
                }
                try await handleAppMessage(
                    msg,
                    from: peerId,
                    expectedReceipt: AuthenticatedConnectionReceipt(
                        lease: originLease,
                        sessionId: keySnapshot.sessionId,
                        negotiatedSuite: keySnapshot.negotiatedSuite
                    )
                )
            } catch {
                let reason = "已认证 P2P 通道业务帧验证失败: \(Self.diagnosticErrorSummary(error))"
                SkyBridgeLogger.shared.error("❌ \(reason)")
                smokeInboundTrace(
                    "p2p-inbound authenticated-channel-failed peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
                if connections.isCurrent(originLease, for: peerId) {
                    cleanupBrokenInboundConnection(
                        originLease.connection,
                        peerId: peerId,
                        reason: reason
                    )
                } else {
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ 陈旧业务帧失败未触及 replacement connection"
                    )
                }
                return
            }
        } else {
            smokeInboundTrace(
                "p2p-inbound message-unhandled peer=\(Self.protocolIdentityLogRedaction) hasDriver=0 hasSession=0"
            )
        }
    }

    private struct InboundBootstrapControlResponse: Sendable {
        let message: AppMessage
        let statusLine: String
        let isFailure: Bool
    }

    static func allowsPreHandshakeBootstrapControlRouting(
        isProvisionalConnection: Bool,
        hasHandshakeDriver: Bool,
        hasSessionKeys: Bool
    ) -> Bool {
        if isProvisionalConnection {
            return true
        }
        return !hasHandshakeDriver && !hasSessionKeys
    }

    private func handlePreHandshakeBootstrapControlMessage(
        _ data: Data,
        from peerId: String,
        over provisionalConnection: NWConnection? = nil,
        decodedMessage: AppMessage? = nil
    ) async -> Bool {
        guard Self.allowsPreHandshakeBootstrapControlRouting(
            isProvisionalConnection: provisionalConnection != nil,
            hasHandshakeDriver: handshakeDrivers[peerId] != nil,
            hasSessionKeys: sessionKeys[peerId] != nil
        ) else {
            return false
        }
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx")
        guard let message = decodedMessage ?? (try? AppMessage.decodeWireMessage(from: frame)) else {
            return false
        }
        switch message {
        case .kemRefreshRequest, .protocolIdentityBindingRequest, .protocolIdentityBindingConfirm:
            break
        default:
            return false
        }

        guard let connection = provisionalConnection ?? connections[peerId] else {
            let line = "⛔️ inbound bootstrap control rejected: peer=\(Self.protocolIdentityLogRedaction) reason=missing_connection"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            return true
        }

        if case .protocolIdentityBindingConfirm = message, provisionalConnection != nil {
            // A valid v3 confirm can wait for explicit responder approval. Stop
            // the generic 10-second first-frame timeout; the single UI waiter
            // and 300-second transcript expiry remain the hard bounds.
            finishProvisionalInboundConnection(connection)
        }

        guard let response = await makeInboundBootstrapControlResponse(for: message, peerId: peerId) else {
            return false
        }
        do {
            try await sendPlainFramed(JSONEncoder().encode(response.message), over: connection)
            if response.isFailure {
                SkyBridgeLogger.shared.warning(response.statusLine)
            } else {
                SkyBridgeLogger.shared.info(response.statusLine)
            }
            SignedKEMRefreshSmokeStatusWriter.append(response.statusLine)
        } catch {
            let line = "⛔️ inbound bootstrap control response failed: peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.protocolIdentityLogRedaction)"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
        }
        return true
    }

    private func makeInboundBootstrapControlResponse(
        for message: AppMessage,
        peerId: String
    ) async -> InboundBootstrapControlResponse? {
        switch message {
        case .kemRefreshRequest(let request):
            let responseStartedAt = Date()
            do {
                let payload = try await makeInboundSignedKEMRefreshPayload(for: request)
                let responderLatencyMs = Date().timeIntervalSince(responseStartedAt) * 1_000.0
                let line = String(
                    format: "🔐 SKR-1 signed LAN KEM refresh served: requester=%@ target=%@ keyId=%@ generation=%llu suites=%@ wireId=%@ responderLatencyMs=%.1f lifecycle=request>served",
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    payload.generation,
                    payload.kemPublicKeys.map { CryptoSuite(wireId: $0.suiteWireId).rawValue }.sorted().joined(separator: ","),
                    payload.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.sorted().joined(separator: ","),
                    responderLatencyMs
                )
                return .init(message: .signedKEMRefresh(payload), statusLine: line, isFailure: false)
            } catch {
                let responderLatencyMs = Date().timeIntervalSince(responseStartedAt) * 1_000.0
                let reasonCode = Self.signedKEMRefreshFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "kem_refresh",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: request.canonicalRequestHashHex
                )
                let line = String(
                    format: "⛔️ SKR-1 signed LAN KEM refresh rejected: requester=%@ target=%@ reasonCode=%@ reason=%@ responderLatencyMs=%.1f lifecycle=request>rejected",
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    failure.reasonCode,
                    Self.protocolIdentityLogRedaction,
                    responderLatencyMs
                )
                return .init(message: .kemRefreshFailure(failure), statusLine: line, isFailure: true)
            }

        case .protocolIdentityBindingRequest(let request):
            do {
                let payload = try await makeInboundSignedProtocolIdentityBindingPayload(
                    for: request,
                    peerId: peerId
                )
                let line = "🔐 PIB-1 protocol identity binding served: requester=\(Self.protocolIdentityLogRedaction) target=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>served"
                return .init(message: .signedProtocolIdentityBinding(payload), statusLine: line, isFailure: false)
            } catch {
                let reasonCode = Self.protocolIdentityBindingFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "identity_binding",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: request.canonicalRequestHashHex
                )
                let line = "⛔️ PIB-1 protocol identity binding rejected: requester=\(Self.protocolIdentityLogRedaction) target=\(Self.protocolIdentityLogRedaction) reasonCode=\(failure.reasonCode) reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>rejected"
                return .init(message: .kemRefreshFailure(failure), statusLine: line, isFailure: true)
            }

        case .protocolIdentityBindingConfirm(let confirm):
            do {
                let payload = try await makeInboundSignedProtocolIdentityBindingFinalAck(
                    for: confirm,
                    peerId: peerId
                )
                let line = "🔐 PIB-1 v3 final acknowledgement served: requester=\(Self.protocolIdentityLogRedaction) transaction=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>confirm>final-ack"
                return .init(
                    message: .signedProtocolIdentityBindingFinalAck(payload),
                    statusLine: line,
                    isFailure: false
                )
            } catch {
                let reasonCode = Self.protocolIdentityBindingFailureCode(for: error)
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: confirm.requesterDeviceId,
                    targetDeviceId: confirm.responderDeviceId,
                    stage: "identity_binding_confirm",
                    reasonCode: reasonCode,
                    reason: reasonCode,
                    requestHashHex: confirm.requestHashHex
                )
                let line = "⛔️ PIB-1 v3 confirm rejected: requester=\(Self.protocolIdentityLogRedaction) transaction=\(Self.protocolIdentityLogRedaction) reasonCode=\(failure.reasonCode) reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>confirm>rejected"
                return .init(message: .kemRefreshFailure(failure), statusLine: line, isFailure: true)
            }

        default:
            return nil
        }
    }

    private func makeInboundSignedKEMRefreshPayload(
        for request: AppMessage.KEMRefreshRequestPayload
    ) async throws -> AppMessage.SignedKEMRefreshPayload {
        let requestedSuites = try request.validatedStrictResponderSuites()
        guard let requesterFingerprint = Self.normalizedProtocolIdentityFingerprint(
            request.requesterProtocolIdentityFingerprint
        ) else {
            throw signedLANRefreshFailure("requester protocol identity fingerprint missing")
        }
        let requesterCandidates = Self.inboundBootstrapDeviceIdCandidates(request.requesterDeviceId)
        let requesterPins = await trustedProtocolFingerprints(forAny: requesterCandidates)
        guard requesterPins.contains(requesterFingerprint) else {
            throw signedLANRefreshFailure("requester protocol identity fingerprint not pinned")
        }

        let admissionGate = SignedKEMRefreshRequestAdmissionGate.shared
        if let cached = await admissionGate.cachedCompletedResponse(
            requestHashHex: request.canonicalRequestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        ) {
            return cached
        }
        let admission = await admissionGate.admit(
            requestHashHex: request.canonicalRequestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        switch admission {
        case .allowed:
            break
        case .replay:
            throw signedLANRefreshFailure("request replay detected")
        case .rateLimited:
            throw signedLANRefreshFailure("requester rate limited")
        }

        let selectedIdentity = try await localProtocolIdentityProofForProtocolBinding(
            targetFingerprint: request.targetProtocolIdentityFingerprint
        )
        let requestedWireIds = Set(requestedSuites.map(\.wireId))
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        .filter { requestedWireIds.contains($0.suiteWireId) }
        guard !kemKeys.isEmpty else {
            throw signedLANRefreshFailure("no requested PQC KEM public key available")
        }

        let localId = try localStablePersistentDeviceIdentifier()
        let now = Date()
        let generation = UInt64(max(0, (now.timeIntervalSince1970 * 1000.0).rounded(.down)))
        let keyId = Self.signedLANRefreshKeyId(
            protocolFingerprint: selectedIdentity.fingerprint,
            kemPublicKeys: kemKeys
        )
        let unsigned = AppMessage.SignedKEMRefreshPayload(
            deviceId: localId,
            aliases: PeerIdentityAliasResolver.lookupCandidates(for: localId),
            protocolSigningAlgorithm: selectedIdentity.algorithm.rawValue,
            protocolIdentityPublicKey: selectedIdentity.publicKey,
            protocolIdentityFingerprint: selectedIdentity.fingerprint,
            kemPublicKeys: kemKeys,
            keyId: keyId,
            generation: generation,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data()
        )
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: selectedIdentity.algorithm)
        let signature = try await signatureProvider.sign(unsigned.signaturePreimage, key: selectedIdentity.keyHandle)
        let response = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            keyId: unsigned.keyId,
            generation: unsigned.generation,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            policyRequirePQC: unsigned.policyRequirePQC,
            policyAllowClassicFallback: unsigned.policyAllowClassicFallback,
            routeScope: unsigned.routeScope,
            bonjourEndpointDigest: unsigned.bonjourEndpointDigest,
            signature: signature
        )
        await admissionGate.recordCompletedResponse(
            response,
            requestHashHex: request.canonicalRequestHashHex,
            requesterDeviceId: request.requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        return response
    }

    private func makeInboundSignedProtocolIdentityBindingPayload(
        for request: AppMessage.ProtocolIdentityBindingRequestPayload,
        peerId: String
    ) async throws -> AppMessage.SignedProtocolIdentityBindingPayload {
        guard request.version == AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion else {
            throw protocolIdentityBindingFailure("invalid request version")
        }
        guard request.policyRequirePQC, !request.policyAllowClassicFallback else {
            throw protocolIdentityBindingFailure("policy mismatch")
        }
        guard request.routeScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "lan" else {
            throw protocolIdentityBindingFailure("invalid route scope")
        }
        guard request.nonce.count >= 16 else {
            throw protocolIdentityBindingFailure("invalid request nonce")
        }
        let requestAge = Date().timeIntervalSince(request.sentAt)
        guard requestAge >= -30, requestAge <= 120 else {
            throw protocolIdentityBindingFailure("request timestamp outside accepted window")
        }
        let requestedAlgorithms: [ProtocolSigningAlgorithm]
        do {
            requestedAlgorithms = try request
                .validatedRequestedProtocolSigningAlgorithms()
        } catch {
            throw protocolIdentityBindingFailure(
                "requested protocol identity algorithms invalid"
            )
        }
        let requesterIdentity = try request.validatedRequesterProtocolIdentity()
        guard let requesterAlgorithm = requesterIdentity.normalizedAlgorithm,
              let requesterFingerprint = requesterIdentity.authoritativeFingerprint?.lowercased(),
              let requesterSignature = request.requesterSignature,
              !requesterSignature.isEmpty else {
            throw protocolIdentityBindingFailure("requester protocol identity proof invalid")
        }
        let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(for: requesterAlgorithm)
        let requesterVerified = try await requesterSignatureProvider.verify(
            request.canonicalPreimage,
            signature: requesterSignature,
            publicKey: requesterIdentity.publicKey
        )
        guard requesterVerified else {
            throw protocolIdentityBindingFailure("requester protocol identity signature invalid")
        }

        let candidateAlgorithms = localProtocolIdentityAlgorithmCandidates().filter { algorithm in
            requestedAlgorithms.contains(algorithm)
        }
        guard !candidateAlgorithms.isEmpty else {
            throw protocolIdentityBindingFailure("no requested protocol identity algorithm available")
        }
        let selectedIdentity = try await localProtocolIdentityProofForProtocolBinding(
            candidateAlgorithms: candidateAlgorithms
        )
        let localId = try localStablePersistentDeviceIdentifier()
        let localIdentityAliases = PeerIdentityAliasResolver.lookupCandidates(for: localId)
        let normalizedTarget = request.targetDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Set([localId] + localIdentityAliases).contains(normalizedTarget) else {
            throw protocolIdentityBindingFailure("request target does not identify local responder")
        }
        let now = Date()
        let unsigned = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: request.transactionId,
            deviceId: localId,
            aliases: localIdentityAliases,
            protocolSigningAlgorithm: selectedIdentity.algorithm.rawValue,
            protocolIdentityPublicKey: selectedIdentity.publicKey,
            protocolIdentityFingerprint: selectedIdentity.fingerprint,
            deviceName: AppleMobileDeviceIdentity.currentSnapshot().deviceName,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data()
        )
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: selectedIdentity.algorithm)
        let signature = try await signatureProvider.sign(unsigned.signaturePreimage, key: selectedIdentity.keyHandle)
        let signed = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: unsigned.transactionId,
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            deviceName: unsigned.deviceName,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            policyRequirePQC: unsigned.policyRequirePQC,
            policyAllowClassicFallback: unsigned.policyAllowClassicFallback,
            routeScope: unsigned.routeScope,
            bonjourEndpointDigest: unsigned.bonjourEndpointDigest,
            signature: signature
        )
        let registration = await ProtocolIdentityBindingV3StateStore.shared.registerCandidate(.init(
            request: request,
            candidate: signed,
            requesterProtocolSigningAlgorithm: requesterAlgorithm,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            responderProtocolSigningKeyHandle: selectedIdentity.keyHandle,
            peerId: peerId,
            expiresAt: signed.expiresAt
        ))
        switch registration {
        case .stored(let context), .replay(let context):
            return context.candidate
        case .transactionConflict:
            throw protocolIdentityBindingFailure("transaction id reused with a different request")
        case .capacityExceeded:
            throw protocolIdentityBindingFailure("PIB-1 responder state capacity exceeded")
        }
    }

    private func stageInboundRequesterProtocolIdentityApproval(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        peerId: String,
        requesterAlgorithm: ProtocolSigningAlgorithm,
        requesterPublicKey: Data,
        requesterFingerprint: String,
        verificationCode: String
    ) async -> PairingTrustDecision {
        guard let context = pendingInboundRequesterProtocolIdentityBindingContext(
            request: request,
            requesterAlgorithm: requesterAlgorithm,
            requesterPublicKey: requesterPublicKey,
            requesterFingerprint: requesterFingerprint,
            verificationCode: verificationCode
        ) else {
            return .reject
        }
        let requesterIds = context.requesterDeviceIds
        let stableRequesterId = requesterIds.first ?? request.requesterDeviceId
        let policyKey = context.policyKey
        let trustedRequesterPins = await trustedProtocolFingerprints(forAny: requesterIds)

        if let raw = pairingPolicyByPeerId[policyKey] ?? pairingPolicyByPeerId[stableRequesterId],
           let stored = PairingTrustDecision(rawValue: raw) {
            switch stored {
            case .alwaysAllow:
                if isPairingPolicyAuthorityAvailable,
                   TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: requesterIds),
                   trustedRequesterPins.contains(requesterFingerprint) {
                    return .alwaysAllow
                }
                SkyBridgeLogger.shared.warning(
                    "⛔️ PIB-1 ignored stored allow without durable active trust and a matching protocol identity pin"
                )
            case .reject:
                return .reject
            case .allowOnce, .timedOut:
                break
            }
        }

        // PIB-1 v3 symmetry: if this requester's protocol identity is ALREADY pinned in our
        // trust stores (i.e. a prior successful iOS→Mac pairing recorded this Mac's authority), it is
        // a known, previously-approved device — not a cold/stranger peer. Auto-approve WITHOUT raising
        // the 180s operator-approval prompt, so the operator does not have to be physically at the iPad.
        //
        // Security invariant: `requesterFingerprint` here is the signature-VERIFIED protocol identity
        // fingerprint (both the request and confirm signatures have already been verified). We only
        // auto-approve when that
        // verified fingerprint is present in the pinned set for the requester's device-id candidates.
        // This is the EXACT same revocation-aware pin check the strict-PQC KEM-refresh responder uses
        // (see `makeInboundSignedKEMRefreshPayload`, "requester protocol identity fingerprint not pinned"):
        // `trustedProtocolFingerprints(forAny:)` unions only ACTIVE (non-revoked) records from both the
        // ProtocolIdentityTrustStore and the TrustedDeviceStore current-path authority. Unpinned or
        // revoked devices fall through to the operator prompt below — never auto-approved.
        if trustedRequesterPins.contains(requesterFingerprint) {
            let approvedLine = "🔓 PIB-1 requester protocol identity auto-approved via existing pin (no prompt): requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>auto-approved-pinned"
            SkyBridgeLogger.shared.info(approvedLine)
            SignedKEMRefreshSmokeStatusWriter.append(approvedLine)
            return .alwaysAllow
        }

        let requestId = UUID()
        let pendingRequest = PairingTrustRequest(
            id: requestId,
            purpose: .protocolIdentityBinding,
            peerId: policyKey,
            declaredDeviceId: stableRequesterId,
            deviceName: request.requesterDeviceId,
            platform: .unknown,
            modelName: "",
            osVersion: "",
            kemKeyCount: 0,
            verificationCode: verificationCode,
            protocolIdentityFingerprint: requesterFingerprint,
            receivedAt: Date()
        )
        let timeoutSeconds = Self.protocolIdentityBindingApprovalTimeoutSeconds()
        let awaitingLine = "🔐 PIB-1 requester protocol identity awaiting operator approval: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) peer=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(timeoutSeconds) lifecycle=identity-oob>awaiting-requester-approval"
        let timeoutLine = "⏳ PIB-1 requester protocol identity approval timed out: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(timeoutSeconds) lifecycle=identity-oob>timeout"
        let cancellationLine = "ℹ️ PIB-1 requester protocol identity approval cancelled with its handshake: requester=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>cancelled"
        let busyLine = "🛑 PIB-1 requester protocol identity rejected because another operator approval is pending: requester=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>busy-rejected"
        return await awaitOperatorPairingTrustDecision(
            request: pendingRequest,
            context: .requesterProtocolIdentityBinding(context),
            timeout: .seconds(timeoutSeconds),
            awaitingStatusLine: awaitingLine,
            timeoutStatusLine: timeoutLine,
            cancellationStatusLine: cancellationLine,
            busyStatusLine: busyLine
        )
    }

    private func pendingInboundRequesterProtocolIdentityBindingContext(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        requesterAlgorithm: ProtocolSigningAlgorithm,
        requesterPublicKey: Data,
        requesterFingerprint: String,
        verificationCode: String
    ) -> PendingRequesterProtocolIdentityBindingContext? {
        let requesterIds = Self.inboundBootstrapDeviceIdCandidates(request.requesterDeviceId)
        guard let stableRequesterId = requesterIds.first else { return nil }
        return PendingRequesterProtocolIdentityBindingContext(
            policyKey: "PIB-1-requester|\(stableRequesterId)|\(requesterAlgorithm.rawValue)|\(requesterFingerprint)",
            requesterDeviceIds: requesterIds,
            requesterProtocolSigningAlgorithm: requesterAlgorithm,
            requesterProtocolIdentityPublicKey: requesterPublicKey,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            verificationCode: verificationCode,
            displayName: request.requesterDeviceId
        )
    }

    private func makeInboundSignedProtocolIdentityBindingFinalAck(
        for confirm: AppMessage.ProtocolIdentityBindingConfirmPayload,
        peerId: String
    ) async throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        let confirmHashHex = confirm.canonicalConfirmHashHex
        let admission = await ProtocolIdentityBindingV3StateStore.shared.beginConfirm(confirm)
        let context: ProtocolIdentityBindingV3ResponderContext
        switch admission {
        case .allowed(let allowedContext):
            context = allowedContext
        case .replay(let finalAck):
            return finalAck
        case .inFlight:
            throw protocolIdentityBindingFailure("identical PIB-1 confirm is already being processed")
        case .rejected:
            throw protocolIdentityBindingFailure("PIB-1 confirm has no matching live candidate transcript")
        }

        do {
            let validatedConfirm = try confirm.validatedForCandidate(
                request: context.request,
                candidate: context.candidate
            )
            let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(
                for: context.requesterProtocolSigningAlgorithm
            )
            let requesterVerified = try await requesterSignatureProvider.verify(
                validatedConfirm.signaturePreimage,
                signature: validatedConfirm.requesterSignature,
                publicKey: context.requesterProtocolIdentityPublicKey
            )
            guard requesterVerified else {
                throw protocolIdentityBindingFailure("PIB-1 confirm requester signature invalid")
            }

            let verificationCode = context.candidate.shortAuthenticationCode(request: context.request)
            let decision = await stageInboundRequesterProtocolIdentityApproval(
                request: context.request,
                peerId: peerId,
                requesterAlgorithm: context.requesterProtocolSigningAlgorithm,
                requesterPublicKey: context.requesterProtocolIdentityPublicKey,
                requesterFingerprint: context.requesterProtocolIdentityFingerprint,
                verificationCode: verificationCode
            )
            guard decision == .alwaysAllow || decision == .allowOnce else {
                throw protocolIdentityBindingFailure("operator rejected requester protocol identity confirm")
            }

            guard let responderAlgorithm = ProtocolSigningAlgorithm(
                rawValue: context.candidate.protocolSigningAlgorithm
            ) else {
                throw protocolIdentityBindingFailure("responder protocol identity algorithm became invalid")
            }

            let now = Date()
            let ackExpiry = min(
                min(context.expiresAt, validatedConfirm.expiresAt),
                now.addingTimeInterval(300)
            )
            guard ackExpiry > now else {
                throw protocolIdentityBindingFailure("PIB-1 candidate transcript expired before final acknowledgement")
            }
            let unsignedAck = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
                transactionId: context.request.transactionId,
                requesterDeviceId: context.request.requesterDeviceId,
                responderDeviceId: context.candidate.deviceId,
                requesterProtocolIdentityFingerprint: context.requesterProtocolIdentityFingerprint,
                responderProtocolIdentityFingerprint: context.candidate.protocolIdentityFingerprint,
                requestNonce: context.request.nonce,
                confirmationNonce: validatedConfirm.confirmationNonce,
                requestHashHex: context.request.canonicalRequestHashHex,
                candidateHashHex: context.candidate.canonicalCandidateHashHex,
                confirmHashHex: validatedConfirm.canonicalConfirmHashHex,
                sasTranscriptHashHex: context.candidate.sasTranscriptHashHex(request: context.request),
                accepted: true,
                sentAt: now,
                expiresAt: ackExpiry,
                policyRequirePQC: true,
                policyAllowClassicFallback: false,
                routeScope: "lan",
                responderSignature: Data()
            )
            let responderSignatureProvider = ProtocolSignatureProviderSelector.select(
                for: responderAlgorithm
            )
            let responderSignature = try await responderSignatureProvider.sign(
                unsignedAck.signaturePreimage,
                key: context.responderProtocolSigningKeyHandle
            )
            let finalAck = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
                transactionId: unsignedAck.transactionId,
                requesterDeviceId: unsignedAck.requesterDeviceId,
                responderDeviceId: unsignedAck.responderDeviceId,
                requesterProtocolIdentityFingerprint: unsignedAck.requesterProtocolIdentityFingerprint,
                responderProtocolIdentityFingerprint: unsignedAck.responderProtocolIdentityFingerprint,
                requestNonce: unsignedAck.requestNonce,
                confirmationNonce: unsignedAck.confirmationNonce,
                requestHashHex: unsignedAck.requestHashHex,
                candidateHashHex: unsignedAck.candidateHashHex,
                confirmHashHex: unsignedAck.confirmHashHex,
                sasTranscriptHashHex: unsignedAck.sasTranscriptHashHex,
                accepted: true,
                sentAt: unsignedAck.sentAt,
                expiresAt: unsignedAck.expiresAt,
                policyRequirePQC: true,
                policyAllowClassicFallback: false,
                routeScope: "lan",
                responderSignature: responderSignature
            )
            guard let installContext = pendingInboundRequesterProtocolIdentityBindingContext(
                request: context.request,
                requesterAlgorithm: context.requesterProtocolSigningAlgorithm,
                requesterPublicKey: context.requesterProtocolIdentityPublicKey,
                requesterFingerprint: context.requesterProtocolIdentityFingerprint,
                verificationCode: context.candidate.shortAuthenticationCode(request: context.request)
            ), await installInboundRequesterProtocolIdentityBinding(installContext) else {
                throw protocolIdentityBindingFailure(
                    "requester protocol identity pin failed before final acknowledgement"
                )
            }
            guard await ProtocolIdentityBindingV3StateStore.shared.completeConfirm(
                transactionId: context.request.transactionId,
                confirmHashHex: confirmHashHex,
                finalAck: finalAck
            ) else {
                throw protocolIdentityBindingFailure("PIB-1 responder transcript state was lost before final acknowledgement")
            }
            return finalAck
        } catch {
            await ProtocolIdentityBindingV3StateStore.shared.abortConfirm(
                transactionId: confirm.transactionId,
                confirmHashHex: confirmHashHex
            )
            throw error
        }
    }

    private static func inboundBootstrapDeviceIdCandidates(_ raw: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !PeerIdentityAliasResolver.isEndpointAlias(trimmed),
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }
        if let stable = PeerIdentityAliasResolver.persistentDeviceId(from: raw) {
            append(stable)
        }
        append(raw)
        for candidate in PeerIdentityAliasResolver.lookupCandidates(for: raw) {
            append(candidate)
        }
        return ordered
    }

    private static func signedLANRefreshKeyId(
        protocolFingerprint: String,
        kemPublicKeys: [KEMPublicKeyInfo]
    ) -> String {
        var material = Data("SkyBridge-SKR-1-KeyId\n".utf8)
        for key in kemPublicKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
            var wireId = key.suiteWireId.littleEndian
            var length = UInt32(key.publicKey.count).littleEndian
            material.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))
            material.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            material.append(key.publicKey)
        }
        let digest = SHA256.hash(data: material).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "skr1-\(protocolFingerprint.prefix(12))-\(digest)"
    }

    private static func normalizedProtocolIdentityFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func protocolIdentityBindingFailureCode(for error: Error) -> String {
        let reason = error.localizedDescription.lowercased()
        if reason.contains("invalid request version") { return "invalid_request_version" }
        if reason.contains("policy mismatch") { return "policy_mismatch" }
        if reason.contains("invalid route scope") { return "invalid_route_scope" }
        if reason.contains("invalid request nonce") { return "invalid_request_nonce" }
        if reason.contains("requester protocol identity proof invalid") { return "invalid_requester_protocol_identity" }
        if reason.contains("requester protocol identity signature invalid") { return "invalid_requester_signature" }
        if reason.contains("operator rejected requester protocol identity") { return "requester_protocol_identity_rejected_by_operator" }
        if reason.contains("no requested protocol identity algorithm available") { return "unsupported_protocol_identity_algorithm" }
        if reason.contains("missing local protocol identity proof") { return "local_protocol_identity_unavailable" }
        return "protocol_identity_binding_rejected"
    }

    private static func signedKEMRefreshFailureCode(for error: Error) -> String {
        let reason = error.localizedDescription.lowercased()
        if reason.contains("target protocol identity fingerprint mismatch") { return "pinned_protocol_identity_mismatch_requires_oob" }
        if reason.contains("target protocol identity fingerprint invalid") { return "invalid_target_protocol_identity" }
        if reason.contains("invalid request version") { return "invalid_request_version" }
        if reason.contains("policy mismatch") { return "policy_mismatch" }
        if reason.contains("policy hash mismatch") { return "policy_hash_mismatch" }
        if reason.contains("request replay detected") { return "request_replay_detected" }
        if reason.contains("requester rate limited") { return "requester_rate_limited" }
        if reason.contains("requester protocol identity fingerprint not pinned") { return "requester_protocol_identity_not_pinned" }
        if reason.contains("requester protocol identity fingerprint missing") { return "missing_requester_protocol_identity" }
        if reason.contains("classic suite rejected") { return "classic_suite_rejected" }
        if reason.contains("unknown suite") { return "unknown_suite" }
        if reason.contains("no requested pqc kem public key available") { return "missing_requested_pqc_kem" }
        return "kem_refresh_rejected"
    }

    private func ensureInboundHandshakeDriverIfNeeded(
        for peerId: String,
        frame: Data,
        originLease: P2PConnectionLease<NWConnection>
    ) async -> HandshakeDriver? {
        guard originLease.peerId == peerId,
              connections.isCurrent(originLease, for: peerId) else { return nil }
        if let existingDriver = handshakeDrivers[peerId] {
            guard handshakeDriverConnectionGenerationByPeerId[peerId] == originLease.generation else {
                return nil
            }
            return existingDriver
        }
        guard let operationOwner = try? beginHandshakeOperation(for: originLease) else {
            return nil
        }
        var operationOwnershipTransferredToDriver = false
        defer {
            if !operationOwnershipTransferredToDriver {
                finishHandshakeOperation(operationOwner)
            }
        }

        let handshakeFrame = HandshakePadding.unwrapIfNeeded(frame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame) else {
            smokeInboundTrace(
                "p2p-inbound messageA-decode-miss peer=\(Self.protocolIdentityLogRedaction) bytes=\(handshakeFrame.count)"
            )
            return nil
        }
        guard !messageA.supportedSuites.isEmpty else {
            smokeInboundTrace(
                "p2p-inbound messageA-empty-suites peer=\(Self.protocolIdentityLogRedaction)"
            )
            return nil
        }
        smokeInboundTrace(
            "p2p-inbound messageA-decoded peer=\(Self.protocolIdentityLogRedaction) suites=\(Self.smokeSanitize(messageA.supportedSuites.map(\.rawValue).joined(separator: ",")))"
        )

        if hasStoredSessionMaterial(for: peerId) {
            if !hasActiveAuthenticatedSession(for: peerId) {
                let detachedArbiterBindings = await clearStaleInboundSessionState(
                    for: peerId,
                    reason: "message_a_without_authenticated_session"
                )
                for binding in detachedArbiterBindings {
                    await releaseArbiterSessionBinding(binding)
                    guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                }
                SkyBridgeLogger.shared.warning(
                    "🧹 清理陈旧入站会话状态，按 fresh handshake 重新处理: peer=\(Self.protocolIdentityLogRedaction)"
                )
                smokeInboundTrace(
                    "p2p-inbound stale-session-cleared peer=\(Self.protocolIdentityLogRedaction)"
                )
            }
            guard !hasStoredSessionMaterial(for: peerId) else {
                smokeInboundTrace(
                    "p2p-inbound fresh-handshake-deferred-to-rekey peer=\(Self.protocolIdentityLogRedaction)"
                )
                return nil
            }
        }

        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let previousPolicy = inboundResponderSelectionPolicy(peerHasPQCGroup: peerHasPQCGroup)
        let strictTrustContext: (stablePeerId: String, provider: P2PStoredHandshakeTrustProvider)?
        if pqcManager.enforcePQCHandshake {
            guard let context = await strictInboundHandshakeTrustContext(
                for: peerId,
                stage: "inbound-handshake",
                messageA: messageA
            ) else {
                smokeInboundTrace(
                    "p2p-inbound strict-trust-missing peer=\(Self.protocolIdentityLogRedaction) stage=inbound-handshake"
                )
                return nil
            }
            guard isCurrentHandshakeOperation(operationOwner) else { return nil }
            strictTrustContext = context
            smokeInboundTrace(
                "p2p-inbound strict-trust-ready peer=\(Self.protocolIdentityLogRedaction) stable=\(Self.protocolIdentityLogRedaction) stage=inbound-handshake"
            )
        } else {
            strictTrustContext = nil
        }

        do {
            if pqcManager.enforcePQCHandshake {
                try ensureStrictPQCAvailability()
            }
            if !peerHasPQCGroup
                && pqcManager.enforcePQCHandshake
                && !pqcManager.allowClassicFallbackForCompatibility {
                throw rejectStrictPQCClassicBootstrap(for: peerId)
            } else {
                try await skyBridgeCore.initialize(policy: previousPolicy)
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                guard let transport else { throw P2PError.connectionFailed }
                let boundTransport = try await transport.boundTransport(
                    for: peerId,
                    expectedConnection: originLease.connection,
                    leaseSequence: originLease.sequence
                )
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                let stablePeerId = strictTrustContext?.stablePeerId ?? peerId
                let signingAlgorithm = try skyBridgeCore.validatedIncomingProtocolSigningAlgorithm(
                    messageA: messageA,
                    stableDeviceId: stablePeerId
                )
                let driver = try await skyBridgeCore.createHandshakeDriver(
                    transport: boundTransport,
                    peerSupportedSuites: messageA.supportedSuites,
                    localSOAPeerId: try localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: stablePeerId),
                    trustProvider: strictTrustContext?.provider,
                    authenticatedIncomingEstablishedPolicy: strictTrustContext == nil
                        ? .rejectDuplicate
                        : .replaceAuthenticated,
                    protocolSigningAlgorithm: signingAlgorithm,
                    protocolSigningKeyProtection: skyBridgeCore
                        .preferredProtocolSigningKeyProtection(for: signingAlgorithm)
                )
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                if let existingDriver = handshakeDrivers[peerId] {
                    guard handshakeDriverConnectionGenerationByPeerId[peerId]
                            == originLease.generation else {
                        return nil
                    }
                    return existingDriver
                }
                handshakeDrivers[peerId] = driver
                handshakeDriverConnectionGenerationByPeerId[peerId] = originLease.generation
                handshakeDriverOperationTokenByPeerId[peerId] = operationOwner.token
                operationOwnershipTransferredToDriver = true
                if let stablePeerId = strictTrustContext?.stablePeerId {
                    strictInboundStablePeerIdByRuntimePeerId[peerId] = stablePeerId
                } else {
                    strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
                }
            }
        } catch {
            guard isCurrentHandshakeOperation(operationOwner) else { return nil }
            SkyBridgeLogger.shared.warning("⚠️ 入站握手 driver 重建失败: \(Self.diagnosticErrorSummary(error))")
            smokeInboundTrace(
                "p2p-inbound driver-create-failed peer=\(Self.protocolIdentityLogRedaction) stage=inbound-handshake error=\(Self.diagnosticErrorSummary(error))"
            )
            return nil
        }

        currentHandshakeState = "收到新的入站握手请求，握手中..."
        SkyBridgeLogger.shared.info(
            "🔁 重新创建入站握手驱动器: peer=\(Self.protocolIdentityLogRedaction) suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        smokeInboundTrace(
            "p2p-inbound driver-created peer=\(Self.protocolIdentityLogRedaction) stage=inbound-handshake suites=\(Self.smokeSanitize(messageA.supportedSuites.map(\.rawValue).joined(separator: ",")))"
        )
        return handshakeDrivers[peerId]
    }

    private func processHandshakeFrame(
        _ frame: Data,
        from peerId: String,
        initialDriver: HandshakeDriver,
        originLease: P2PConnectionLease<NWConnection>
    ) async {
        guard connections.isCurrent(originLease, for: peerId),
            let activeDriver = handshakeDrivers[peerId],
            activeDriver === initialDriver,
            handshakeDriverConnectionGenerationByPeerId[peerId] == originLease.generation,
            let handshakeOperationToken = handshakeDriverOperationTokenByPeerId[peerId]
        else {
            return
        }
        let operationOwner = HandshakeOperationOwner(
            token: handshakeOperationToken,
            peerId: peerId,
            connectionGeneration: originLease.generation
        )
        guard isCurrentHandshakeOperation(operationOwner) else { return }

        func isCurrentHandshakeIncarnation() -> Bool {
            connections.isCurrent(originLease, for: peerId)
                && handshakeDrivers[peerId] === activeDriver
                && handshakeDriverConnectionGenerationByPeerId[peerId] == originLease.generation
                && handshakeDriverOperationTokenByPeerId[peerId] == handshakeOperationToken
                && isCurrentHandshakeOperation(operationOwner)
        }

        let peer = PeerIdentifier(deviceId: peerId)
        await activeDriver.handleMessage(frame, from: peer)
        guard isCurrentHandshakeIncarnation() else {
            await activeDriver.cancel()
            return
        }

        let state = await activeDriver.getCurrentState()
        guard isCurrentHandshakeIncarnation() else {
            await activeDriver.cancel()
            return
        }
        switch state {
        case .established(let keys):
            let strictStablePeerId = strictInboundStablePeerIdByRuntimePeerId[peerId]
            let establishedArbiterLease = await activeDriver.getEstablishedArbiterLease()
            guard isCurrentHandshakeIncarnation() else {
                await activeDriver.cancel()
                return
            }
            let localSOAPeerId: Data
            let authenticatedPeerBinding: AuthenticatedHandshakePeerBinding
            do {
                authenticatedPeerBinding = try await authenticatedHandshakePeerBinding(
                    from: activeDriver
                )
                guard isCurrentHandshakeIncarnation() else {
                    await activeDriver.cancel()
                    return
                }
                localSOAPeerId = try localSOAPeerIdBytes()
            } catch {
                guard isCurrentHandshakeIncarnation() else {
                    await activeDriver.cancel()
                    return
                }
                let message = "认证 authority 无法持久化，已终止握手：\(error.localizedDescription)"
                currentHandshakeState = "握手失败: \(message)"
                lastError = message
                rekeyInProgress.remove(peerId)
                clearRekeyPresentationStatus(for: peerId)
                connectionStatusByDeviceId[peerId] = .failed
                connectionErrorByDeviceId[peerId] = message
                SkyBridgeLogger.shared.error(
                    "⛔️ 入站握手 authority durable commit 失败: peer=\(Self.protocolIdentityLogRedaction)"
                )
                cleanupBrokenInboundConnection(
                    originLease.connection,
                    peerId: peerId,
                    reason: "入站握手 authority 持久化失败"
                )
                return
            }
            if let strictStablePeerId, strictStablePeerId != peerId {
                await replaceStrictInboundStableSession(
                    stablePeerId: strictStablePeerId,
                    currentRuntimePeerId: peerId,
                    originLease: originLease
                )
                guard isCurrentHandshakeIncarnation() else {
                    await activeDriver.cancel()
                    return
                }
            }

            let persistedAuthority: AuthenticatedAuthorityPersistenceResult
            do {
                persistedAuthority = try persistAuthenticatedRemoteAuthority(
                    authenticatedPeerBinding,
                    for: peerId
                )
            } catch {
                guard isCurrentHandshakeIncarnation() else {
                    await activeDriver.cancel()
                    return
                }
                let message = "认证 authority 无法持久化，已终止握手：\(error.localizedDescription)"
                currentHandshakeState = "握手失败: \(message)"
                lastError = message
                connectionStatusByDeviceId[peerId] = .failed
                connectionErrorByDeviceId[peerId] = message
                cleanupBrokenInboundConnection(
                    originLease.connection,
                    peerId: peerId,
                    reason: "入站握手 authority 持久化失败"
                )
                return
            }
            guard isCurrentHandshakeIncarnation() else {
                await activeDriver.cancel()
                return
            }

            finishProvisionalInboundConnection(originLease.connection)
            guard setSessionKeys(
                keys,
                for: peerId,
                connectionGeneration: originLease.generation
            ) else { return }
            do {
                try installSessionPairingAuthority(
                    persistedAuthority.binding,
                    wasPreauthorizedForAutomaticPairing: persistedAuthority
                        .wasPreauthorizedForAutomaticPairing,
                    for: peerId,
                    connection: originLease.connection
                )
            } catch {
                cleanupBrokenInboundConnection(
                    originLease.connection,
                    peerId: peerId,
                    reason: "入站握手会话 authority 绑定失败"
                )
                return
            }
            if let rollback = inboundRekeyRollbackByPeerId[peerId],
               rollback.connectionGeneration == originLease.generation,
               rollback.handshakeOperationToken == handshakeOperationToken {
                inboundRekeyRollbackByPeerId.removeValue(forKey: peerId)
            }
            let pairKeySourcePeerId = strictStablePeerId ?? peerId
            if let remotePeerId = soaPeerIdBytes(for: pairKeySourcePeerId),
               let establishedArbiterLease {
                let expectedPairKey = PeerSessionArbiter.pairKey(
                    localPeerId: localSOAPeerId,
                    remotePeerId: remotePeerId
                )
                guard establishedArbiterLease.pairKey == expectedPairKey,
                      establishedArbiterLease.sessionId == keys.sessionId else {
                    cleanupBrokenInboundConnection(
                        originLease.connection,
                        peerId: peerId,
                        reason: "入站握手 arbiter authority 不匹配"
                    )
                    return
                }
                let arbiterBinding = ArbiterSessionBinding(
                    connectionGeneration: originLease.generation,
                    lease: establishedArbiterLease
                )
                arbiterSessionBindingByPeerId[peerId] = arbiterBinding
                if pairKeySourcePeerId != peerId {
                    arbiterSessionBindingByPeerId[pairKeySourcePeerId] = arbiterBinding
                }
            } else {
                arbiterSessionBindingByPeerId.removeValue(forKey: peerId)
            }
            _ = detachHandshakeDriverIfOwned(
                for: peerId,
                connectionGeneration: originLease.generation,
                operationToken: handshakeOperationToken,
                expectedDriver: activeDriver
            )
            finishHandshakeOperation(operationOwner)
            clearRekeyInProgress(for: peerId)
            currentHandshakeState = "握手成功 (Suite: \(keys.negotiatedSuite.rawValue))"
            SkyBridgeLogger.shared.info("✅ 握手完成: \(Self.protocolIdentityLogRedaction) (Suite: \(keys.negotiatedSuite.rawValue))")
            connectionStatusByDeviceId[peerId] = .connected
            connectionErrorByDeviceId.removeValue(forKey: peerId)
            startHeartbeatIfNeeded(deviceId: peerId)
            smokeInboundTrace(
                "p2p-inbound handshake-established peer=\(Self.protocolIdentityLogRedaction) suite=\(Self.smokeSanitize(keys.negotiatedSuite.rawValue))"
            )

            let activeDevice = makeActiveConnectionDevice(
                peerId: peerId,
                connection: originLease.connection
            )
            let authenticatedActiveDevice = canonicalizedDevice(
                activeDevice,
                canonicalPeerId: peerId
            )
            upsertActiveConnection(
                device: authenticatedActiveDevice,
                status: .connected
            )
            discoveryManager.setConnectionLiveness(
                for: authenticatedActiveDevice,
                isConnected: true
            )
            syncPresentationState(for: peerId)

        case .failed(let reason):
            if let rollback = inboundRekeyRollbackByPeerId[peerId],
               rollback.connectionGeneration == originLease.generation,
               rollback.handshakeOperationToken == handshakeOperationToken {
                if await restoreActiveSessionAfterRekeyFailure(
                    for: peerId,
                    originLease: originLease,
                    activeDriver: activeDriver,
                    rollback: rollback,
                    reason: reason
                ) {
                    return
                }
            }
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
            rekeyInProgress.remove(peerId)
            clearRekeyPresentationStatus(for: peerId)
            let message = userVisibleConnectionError(reason)
            currentHandshakeState = "握手失败: \(message)"
            lastError = message
            connectionStatusByDeviceId[peerId] = .failed
            connectionErrorByDeviceId[peerId] = message
            SkyBridgeLogger.shared.error("❌ 握手失败: \(Self.protocolIdentityLogRedaction) reason=\(Self.diagnosticHandshakeFailureCode(reason))")
            smokeInboundTrace(
                "p2p-inbound handshake-failed peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.diagnosticHandshakeFailureCode(reason))"
            )
            cleanupBrokenInboundConnection(
                originLease.connection,
                peerId: peerId,
                reason: "入站初始握手认证失败"
            )

        default:
            break
        }
    }

    private func ensureInboundRekeyDriverIfNeeded(
        for peerId: String,
        frame: Data,
        originLease: P2PConnectionLease<NWConnection>
    ) async -> HandshakeDriver? {
        guard originLease.peerId == peerId,
              connections.isCurrent(originLease, for: peerId) else { return nil }
        if let existingDriver = handshakeDrivers[peerId] {
            guard handshakeDriverConnectionGenerationByPeerId[peerId] == originLease.generation else {
                return nil
            }
            return existingDriver
        }
        guard let operationOwner = try? beginHandshakeOperation(for: originLease) else {
            return nil
        }
        var operationOwnershipTransferredToDriver = false
        defer {
            if !operationOwnershipTransferredToDriver {
                finishHandshakeOperation(operationOwner)
            }
        }
        guard hasStoredSessionMaterial(for: peerId) else { return nil }
        guard hasActiveAuthenticatedSession(for: peerId) else { return nil }

        let handshakeFrame = HandshakePadding.unwrapIfNeeded(frame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame) else {
            smokeInboundTrace(
                "p2p-inbound rekey-messageA-decode-miss peer=\(Self.protocolIdentityLogRedaction) bytes=\(handshakeFrame.count)"
            )
            return nil
        }
        guard !messageA.supportedSuites.isEmpty else {
            smokeInboundTrace(
                "p2p-inbound rekey-messageA-empty-suites peer=\(Self.protocolIdentityLogRedaction)"
            )
            return nil
        }
        smokeInboundTrace(
            "p2p-inbound rekey-messageA-decoded peer=\(Self.protocolIdentityLogRedaction) suites=\(Self.smokeSanitize(messageA.supportedSuites.map(\.rawValue).joined(separator: ",")))"
        )

        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let previousPolicy = inboundResponderSelectionPolicy(peerHasPQCGroup: peerHasPQCGroup)
        let strictTrustContext: (stablePeerId: String, provider: P2PStoredHandshakeTrustProvider)?
        if pqcManager.enforcePQCHandshake {
            guard let context = await strictInboundHandshakeTrustContext(
                for: peerId,
                stage: "inbound-rekey",
                messageA: messageA
            ) else {
                smokeInboundTrace(
                    "p2p-inbound strict-trust-missing peer=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey"
                )
                return nil
            }
            guard isCurrentHandshakeOperation(operationOwner) else { return nil }
            strictTrustContext = context
            smokeInboundTrace(
                "p2p-inbound strict-trust-ready peer=\(Self.protocolIdentityLogRedaction) stable=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey"
            )
        } else {
            strictTrustContext = nil
        }

        var createdDriver: HandshakeDriver?
        do {
            if pqcManager.enforcePQCHandshake {
                try ensureStrictPQCAvailability()
            }
            if !peerHasPQCGroup
                && pqcManager.enforcePQCHandshake
                && !pqcManager.allowClassicFallbackForCompatibility {
                throw rejectStrictPQCClassicBootstrap(for: peerId)
            } else {
                try await skyBridgeCore.initialize(policy: previousPolicy)
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                guard let transport else { throw P2PError.connectionFailed }
                let boundTransport = try await transport.boundTransport(
                    for: peerId,
                    expectedConnection: originLease.connection,
                    leaseSequence: originLease.sequence
                )
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                let stablePeerId = strictTrustContext?.stablePeerId ?? peerId
                let signingAlgorithm = try skyBridgeCore.validatedIncomingProtocolSigningAlgorithm(
                    messageA: messageA,
                    stableDeviceId: stablePeerId
                )
                let driver = try await skyBridgeCore.createHandshakeDriver(
                    transport: boundTransport,
                    peerSupportedSuites: messageA.supportedSuites,
                    localSOAPeerId: try localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: stablePeerId),
                    trustProvider: strictTrustContext?.provider,
                    authenticatedIncomingEstablishedPolicy: strictTrustContext == nil
                        ? .rejectDuplicate
                        : .replaceAuthenticated,
                    protocolSigningAlgorithm: signingAlgorithm,
                    protocolSigningKeyProtection: skyBridgeCore
                        .preferredProtocolSigningKeyProtection(for: signingAlgorithm)
                )
                guard isCurrentHandshakeOperation(operationOwner) else { return nil }
                createdDriver = driver
            }
        } catch {
            guard isCurrentHandshakeOperation(operationOwner) else { return nil }
            SkyBridgeLogger.shared.warning("⚠️ 入站 rekey driver 初始化失败: \(Self.diagnosticErrorSummary(error))")
            smokeInboundTrace(
                "p2p-inbound driver-create-failed peer=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey error=\(Self.diagnosticErrorSummary(error))"
            )
            return nil
        }

        guard let createdDriver else { return nil }
        let currentSuite = sessionKeys[peerId]?.negotiatedSuite.rawValue
            ?? resolvedNegotiatedSuite(forAnyPeerId: peerId)?.rawValue
            ?? "Classic"
        let targetSuite = preferredRekeyTargetSuite(offeredSuites: messageA.supportedSuites) ?? currentSuite
        guard let existingKeysBeforeRekey = sessionKeys[peerId],
              sessionKeyConnectionGenerationByPeerId[peerId] == originLease.generation else {
            return nil
        }
        let releasedArbiterBinding: ArbiterSessionBinding?
        do {
            releasedArbiterBinding = try await releaseArbiterState(
                for: peerId,
                expectedOperation: operationOwner
            )
        } catch {
            return nil
        }
        guard isCurrentHandshakeOperation(operationOwner),
              handshakeDrivers[peerId] == nil,
              sessionKeys[peerId]?.sessionId == existingKeysBeforeRekey.sessionId,
              sessionKeyConnectionGenerationByPeerId[peerId] == originLease.generation else {
            if let releasedArbiterBinding {
                _ = await PeerSessionArbiter.shared.restoreEstablishedIfVacant(
                    releasedArbiterBinding.lease
                )
            }
            return nil
        }
        inboundRekeyRollbackByPeerId[peerId] = InboundRekeyRollbackRecord(
            connectionGeneration: originLease.generation,
            handshakeOperationToken: operationOwner.token,
            previousKeys: existingKeysBeforeRekey,
            releasedArbiterBinding: releasedArbiterBinding
        )
        guard removeSessionKeysIfOwned(
            for: peerId,
            connectionGeneration: originLease.generation,
            sessionId: existingKeysBeforeRekey.sessionId
        ) != nil else {
            inboundRekeyRollbackByPeerId.removeValue(forKey: peerId)
            if let releasedArbiterBinding {
                _ = await PeerSessionArbiter.shared.restoreEstablishedIfVacant(
                    releasedArbiterBinding.lease
                )
            }
            return nil
        }
        handshakeDrivers[peerId] = createdDriver
        handshakeDriverConnectionGenerationByPeerId[peerId] = originLease.generation
        handshakeDriverOperationTokenByPeerId[peerId] = operationOwner.token
        operationOwnershipTransferredToDriver = true
        if let stablePeerId = strictTrustContext?.stablePeerId {
            strictInboundStablePeerIdByRuntimePeerId[peerId] = stablePeerId
        } else {
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
        }
        setRekeyPresentationStatus(for: peerId, fromSuite: currentSuite, toSuite: targetSuite)
        rekeyInProgress.insert(peerId)
        currentHandshakeState = "收到对端 rekey 请求，重新握手中..."
        SkyBridgeLogger.shared.info(
            "🔁 收到对端 rekey 请求，切换到握手模式: peer=\(Self.protocolIdentityLogRedaction) suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        smokeInboundTrace(
            "p2p-inbound driver-created peer=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey suites=\(Self.smokeSanitize(messageA.supportedSuites.map(\.rawValue).joined(separator: ",")))"
        )
        return handshakeDrivers[peerId]
    }

    private func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx")
        // Finished: 固定长度 38 bytes（magic 4 + version 1 + direction 1 + mac 32）
        if frame.count == 38, (try? HandshakeFinished.decode(from: frame)) != nil {
            return true
        }
        // MessageA / MessageB 在当前协议下都明显大于心跳/RTT 探测包，
        // 这里先做长度与版本的保守预筛，避免把普通业务密文误当成握手包，
        // 进而触发“unknown suite”告警噪声。
        guard frame.count >= 96, frame.first == HandshakeConstants.protocolVersion else {
            return false
        }
        // MessageA / MessageB：长度通常 < 2KB，且可以被解码（用于避免误解密）
        if (try? HandshakeMessageA.decode(from: frame)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: frame)) != nil { return true }
        return false
    }

    private func handleAppMessage(
        _ message: AppMessage,
        from peerId: String,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) async throws {
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        switch message {
        case .clipboard(let payload):
            guard let data = payload.decodedData else {
                throw P2PError.invalidClipboardPayload
            }
            switch ClipboardManager.shared.setRemoteClipboard(
                data: data,
                mimeType: payload.mimeType,
                fromDeviceId: peerId
            ) {
            case .applied:
                ClipboardManager.shared.recordDeviceSync(
                    deviceId: peerId,
                    mimeType: payload.mimeType,
                    bytes: data.count
                )
                SkyBridgeLogger.shared.info(
                    "📋 已应用远端剪贴板：\(Self.protocolIdentityLogRedaction) bytes=\(data.count)"
                )
            case .duplicate:
                SkyBridgeLogger.shared.debug(
                    "ℹ️ 已忽略重复远端剪贴板：\(Self.protocolIdentityLogRedaction)"
                )
            case .disabled:
                SkyBridgeLogger.shared.debug("ℹ️ 剪贴板同步已关闭，未应用远端内容")
            case .unsupportedMIMEType:
                SkyBridgeLogger.shared.warning("⛔️ 远端剪贴板 MIME 不受支持")
            case .contentTooLarge, .invalidContent:
                throw P2PError.invalidClipboardPayload
            }
        case .textMessage(let payload):
            do {
                let conversationFingerprint = try authenticatedConversationFingerprint(
                    for: peerId,
                    expectedReceipt: expectedReceipt
                )
                try await DeviceMessagingService.shared.handleIncoming(
                    payload,
                    conversationFingerprint: conversationFingerprint
                )
                if let deliveryAttemptID = payload.deliveryAttemptID {
                    try await replyTextMessageReceipt(
                        messageID: payload.id,
                        deliveryAttemptID: deliveryAttemptID,
                        expectedReceipt: expectedReceipt
                    )
                }
                SkyBridgeLogger.shared.info(
                    "📨 已接收设备文本消息：peer=\(Self.protocolIdentityLogRedaction)"
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ 设备文本消息未落库：peer=\(Self.protocolIdentityLogRedaction) reason=\(DeviceMessagingService.logSafeErrorSummary(error))"
                )
                throw error
            }
        case .textMessageReceipt(let payload):
            let conversationFingerprint = try authenticatedConversationFingerprint(
                for: peerId,
                expectedReceipt: expectedReceipt
            )
            try await DeviceMessagingService.shared.handleAuthenticatedReceipt(
                payload,
                conversationFingerprint: conversationFingerprint
            )
        case .pairingIdentityExchange(let payload):
            try await handlePairingIdentityExchangeRequest(
                from: peerId,
                payload: payload,
                expectedReceipt: expectedReceipt
            )
        case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding,
             .protocolIdentityBindingConfirm, .signedProtocolIdentityBindingFinalAck:
            break
        case .heartbeat(let payload):
            let runtimePeerId = promotePeerPresentationIdentityIfNeeded(
                runtimePeerId: peerId,
                declaredDeviceId: nil,
                deviceName: payload.deviceName,
                modelName: payload.modelName,
                platform: payload.platform,
                osVersion: payload.osVersion
            )
            mergePeerServiceMetadata(
                runtimePeerId: runtimePeerId,
                declaredDeviceId: nil,
                capabilities: payload.capabilities,
                fileTransferPort: payload.fileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
        case .authenticatedRouteBinding:
            break
        case .peerDisconnecting(let payload):
            let runtimePeerId = promotePeerPresentationIdentityIfNeeded(
                runtimePeerId: peerId,
                declaredDeviceId: nil,
                deviceName: payload.deviceName,
                modelName: nil,
                platform: nil,
                osVersion: nil
            )
            if let device = lastKnownDevices[runtimePeerId] ?? lastKnownDevices[presentationPeerId(for: runtimePeerId)] {
                _ = purgeStalePresentationState(for: device)
            }
            cancelPeerProtectionRoots(for: runtimePeerId)
            expectedReceipt.lease.connection.cancel()
        case .ping(let payload):
            try await replyPong(
                to: peerId,
                pingId: payload.id,
                expectedReceipt: expectedReceipt
            )
        case .pong:
            break
        }
    }

    private func authenticatedConversationFingerprint(
        for peerId: String,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) throws -> String {
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        guard canonicalPeerId == expectedReceipt.lease.peerId,
              let authority = currentSessionPairingAuthority(for: canonicalPeerId),
              authority.connectionGeneration == expectedReceipt.lease.generation,
              let fingerprint = validatedProtocolFingerprint(authority.binding.authority) else {
            throw P2PError.authenticatedIdentityMismatch
        }
        return fingerprint
    }

    private func hasStoredSessionMaterial(for peerId: String) -> Bool {
        currentAuthenticatedSession(forAnyPeerId: peerId, requireConnectedStatus: false) != nil
    }

    private func hasActiveAuthenticatedSession(for peerId: String) -> Bool {
        currentAuthenticatedSession(forAnyPeerId: peerId, requireConnectedStatus: true) != nil
    }

    private func currentAuthenticatedSession(
        forAnyPeerId peerId: String,
        requireConnectedStatus: Bool
    ) -> (
        peerId: String,
        receipt: AuthenticatedConnectionReceipt,
        keys: SessionKeys
    )? {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
            .union([peerId, runtimePeerId, presentationPeerId])

        var orderedCandidates = [runtimePeerId, peerId, presentationPeerId]
        orderedCandidates.append(contentsOf: aliases.sorted())
        var seen = Set<String>()
        for candidate in orderedCandidates where seen.insert(candidate).inserted {
            if let current = exactAuthenticatedSession(
                for: candidate,
                requireConnectedStatus: requireConnectedStatus
            ) {
                return current
            }
        }
        return nil
    }

    private func exactAuthenticatedSession(
        for peerId: String,
        requireConnectedStatus: Bool
    ) -> (
        peerId: String,
        receipt: AuthenticatedConnectionReceipt,
        keys: SessionKeys
    )? {
        guard let lease = connections.lease(for: peerId),
              connections.isCurrent(lease, for: peerId),
              let keys = sessionKeys[peerId],
              sessionKeyConnectionGenerationByPeerId[peerId] == lease.generation else {
            return nil
        }
        if requireConnectedStatus,
           connectionStatusByDeviceId[peerId] != .connected {
            return nil
        }
        return (
            peerId: peerId,
            receipt: AuthenticatedConnectionReceipt(
                lease: lease,
                sessionId: keys.sessionId,
                negotiatedSuite: keys.negotiatedSuite
            ),
            keys: keys
        )
    }

    private func authenticatedTextMessageAuthority(
        forAnyPeerId peerId: String,
        expectedConversationFingerprint rawExpectedFingerprint: String
    ) throws -> AuthenticatedTextMessageAuthorityReceipt {
        guard let expectedFingerprint = try? DeviceTextMessagePolicy
            .normalizedConversationFingerprint(rawExpectedFingerprint) else {
            throw P2PError.authenticatedIdentityMismatch
        }
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: peerId,
            requireConnectedStatus: true
        ) else {
            throw P2PError.noSessionKey
        }
        guard let authority = currentSessionPairingAuthority(for: current.peerId),
              authority.connectionGeneration == current.receipt.lease.generation else {
            throw P2PError.noSessionKey
        }
        guard let authenticatedFingerprint = validatedProtocolFingerprint(
            authority.binding.authority
        ), authenticatedFingerprint == expectedFingerprint else {
            throw P2PError.authenticatedIdentityMismatch
        }
        return AuthenticatedTextMessageAuthorityReceipt(
            connection: current.receipt,
            keys: current.keys,
            binding: authority.binding,
            conversationFingerprint: authenticatedFingerprint
        )
    }

    private func requireCurrentTextMessageAuthority(
        _ receipt: AuthenticatedTextMessageAuthorityReceipt
    ) throws {
        try requireCurrentAuthenticatedConnection(receipt.connection)
        let peerId = receipt.connection.lease.peerId
        guard let authority = currentSessionPairingAuthority(for: peerId),
              authority.connectionGeneration == receipt.connection.lease.generation,
              authority.binding == receipt.binding,
              validatedProtocolFingerprint(authority.binding.authority)
                == receipt.conversationFingerprint else {
            throw P2PError.authenticatedIdentityMismatch
        }
    }

    private func validatedProtocolFingerprint(
        _ authority: AuthenticatedRemoteAuthority
    ) -> String? {
        guard let algorithm = ProtocolSigningAlgorithm(
            rawValue: authority.protocolSigningAlgorithm
        ),
              let publicKey = authority.protocolPublicKeyBytes,
              !publicKey.isEmpty,
              let claimedFingerprint = try? DeviceTextMessagePolicy
                .normalizedConversationFingerprint(
                    authority.protocolPublicKeyFingerprint
                ),
              let computedFingerprint = AppMessage.ProtocolIdentityPublicKeyInfo(
                  protocolSigningAlgorithm: algorithm.rawValue,
                  publicKey: publicKey
              ).authoritativeFingerprint,
              computedFingerprint == claimedFingerprint else {
            return nil
        }
        return claimedFingerprint
    }

    private func clearStaleInboundSessionState(
        for peerId: String,
        reason: String,
        preservingPeerIds: Set<String> = []
    ) async -> [ArbiterSessionBinding] {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
            .union([peerId, runtimePeerId, presentationPeerId])

        for key in stateKeysMatchingAliases(aliases, keys: sessionKeys.keys)
        where !preservingPeerIds.contains(key) {
            sessionKeys.removeValue(forKey: key)
            sessionKeyConnectionGenerationByPeerId.removeValue(forKey: key)
            clearSessionPairingAuthority(for: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: inboundRekeyRollbackByPeerId.keys)
        where !preservingPeerIds.contains(key) {
            inboundRekeyRollbackByPeerId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: sharedSecrets.keys)
        where !preservingPeerIds.contains(key) {
            sharedSecrets.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: negotiatedSuiteByDeviceId.keys)
        where !preservingPeerIds.contains(key) {
            negotiatedSuiteByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys)
        where !preservingPeerIds.contains(key) {
            rekeyStatusByDeviceId.removeValue(forKey: key)
        }
        var detachedHandshakeDrivers: [HandshakeDriver] = []
        for key in stateKeysMatchingAliases(aliases, keys: handshakeDrivers.keys)
        where !preservingPeerIds.contains(key) {
            if let generation = handshakeDriverConnectionGenerationByPeerId[key],
               let driver = detachHandshakeOperationIfOwned(
                   for: key,
                   connectionGeneration: generation
               ) {
                detachedHandshakeDrivers.append(driver)
            }
            rekeyInProgress.remove(key)
        }
        var detachedArbiterBindings: [ArbiterSessionBinding] = []
        for key in stateKeysMatchingAliases(aliases, keys: arbiterSessionBindingByPeerId.keys)
        where !preservingPeerIds.contains(key) {
            if let binding = arbiterSessionBindingByPeerId.removeValue(forKey: key),
               !detachedArbiterBindings.contains(binding) {
                detachedArbiterBindings.append(binding)
            }
        }
        for key in stateKeysMatchingAliases(aliases, keys: strictInboundStablePeerIdByRuntimePeerId.keys)
        where !preservingPeerIds.contains(key) {
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: key)
        }

        for driver in detachedHandshakeDrivers {
            await driver.cancel()
        }
        SkyBridgeLogger.shared.debug(
            "🧹 已清理陈旧入站会话材料: peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.smokeSanitize(reason))"
        )
        return detachedArbiterBindings
    }

    private func replaceStrictInboundStableSession(
        stablePeerId: String,
        currentRuntimePeerId: String,
        originLease: P2PConnectionLease<NWConnection>
    ) async {
        let currentRuntimePeerId = canonicalPeerLookupKey(currentRuntimePeerId)
        guard connections.isCurrent(originLease, for: currentRuntimePeerId) else { return }
        let currentDriver = handshakeDrivers[currentRuntimePeerId]
        let currentDriverGeneration = handshakeDriverConnectionGenerationByPeerId[
            currentRuntimePeerId
        ]
        let stableRuntimePeerId = runtimePeerId(forAnyPeerId: stablePeerId)
        let presentationPeerId = presentationPeerId(for: stableRuntimePeerId)
        let aliases = connectionAliasSet(for: stableRuntimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: stablePeerId))
            .union([stablePeerId, stableRuntimePeerId, presentationPeerId])

        for key in stateKeysMatchingAliases(aliases, keys: connections.keys)
        where key != currentRuntimePeerId {
            guard connections.isCurrent(originLease, for: currentRuntimePeerId) else { return }
            guard let aliasLease = connections.lease(for: key) else { continue }
            invalidatePendingPairingIdentityRequests(
                for: key,
                connectionGeneration: aliasLease.generation
            )
            let detachedAliasArbiterBinding = detachArbiterSessionBinding(
                for: key,
                expectedConnectionGeneration: aliasLease.generation
            )
            aliasLease.connection.cancel()
            _ = connections.removeIfOwned(aliasLease, for: key)
            _ = await transport?.removeConnection(
                aliasLease.connection,
                for: key,
                leaseSequence: aliasLease.sequence
            )
            if let detachedAliasArbiterBinding {
                await releaseArbiterSessionBinding(detachedAliasArbiterBinding)
            }
            guard connections.isCurrent(originLease, for: currentRuntimePeerId) else { return }
        }
        let replacementProtectedPeerIds = Set(
            connections.keys.filter { $0 != currentRuntimePeerId }
        )
        let detachedArbiterBindings = await clearStaleInboundSessionState(
            for: stablePeerId,
            reason: "strict_authenticated_inbound_reconnect_replaced_stable_session",
            preservingPeerIds: replacementProtectedPeerIds
        )
        for binding in detachedArbiterBindings {
            await releaseArbiterSessionBinding(binding)
            guard connections.isCurrent(originLease, for: currentRuntimePeerId) else { return }
        }
        if let currentDriver,
            let currentDriverGeneration,
            let currentLease = connections.lease(for: currentRuntimePeerId),
            currentLease.generation == currentDriverGeneration,
            connections.isCurrent(currentLease, for: currentRuntimePeerId)
        {
            handshakeDrivers[currentRuntimePeerId] = currentDriver
            handshakeDriverConnectionGenerationByPeerId[currentRuntimePeerId] = currentDriverGeneration
        }
    }

    private func mergePeerServiceMetadata(
        runtimePeerId: String,
        declaredDeviceId: String?,
        capabilities: [String]?,
        fileTransferPort: UInt16?,
        remoteControlPort: UInt16?
    ) {
        let runtimePeerId = canonicalPeerLookupKey(runtimePeerId)
        let presentationPeerId =
            PeerIdentityAliasResolver.persistentDeviceId(from: declaredDeviceId)
            ?? presentationPeerId(for: runtimePeerId)

        var merged =
            lastKnownDevices[presentationPeerId]
            ?? lastKnownDevices[runtimePeerId]
            ?? DiscoveredDevice(
                id: presentationPeerId,
                name: presentationPeerId,
                modelName: "Unknown",
                platform: .unknown,
                osVersion: "Unknown"
            )

        let normalizedCapabilities = Set(
            (capabilities ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
            }.filter { !$0.isEmpty }
        )

        if let fileTransferPort, fileTransferPort > 0 {
            merged.portMap[DiscoveredDevice.fileTransferServiceType] = fileTransferPort
        }
        if let remoteControlPort, remoteControlPort > 0 {
            merged.portMap[DiscoveredDevice.remoteControlServiceType] = remoteControlPort
        }

        let shouldAdvertiseFileTransfer = (merged.fileTransferPort ?? 0) > 0
        let shouldAdvertiseRemoteDesktop = (merged.remoteControlPort ?? 0) > 0

        if shouldAdvertiseFileTransfer,
           !merged.services.contains(DiscoveredDevice.fileTransferServiceType) {
            merged.services.append(DiscoveredDevice.fileTransferServiceType)
        } else if merged.fileTransferPort == nil,
                  merged.bonjourServiceType != DiscoveredDevice.fileTransferServiceType {
            merged.services.removeAll { $0 == DiscoveredDevice.fileTransferServiceType }
        }
        if shouldAdvertiseRemoteDesktop,
           !merged.services.contains(DiscoveredDevice.remoteControlServiceType) {
            merged.services.append(DiscoveredDevice.remoteControlServiceType)
        } else if merged.remoteControlPort == nil,
                  merged.bonjourServiceType != DiscoveredDevice.remoteControlServiceType {
            merged.services.removeAll { $0 == DiscoveredDevice.remoteControlServiceType }
        }

        if !normalizedCapabilities.isEmpty {
            merged.capabilities = Array(Set(merged.capabilities).union(normalizedCapabilities)).sorted()
            merged.advertisedCapabilities = Array(
                Set(merged.advertisedCapabilities).union(normalizedCapabilities)
            ).sorted()
        }

        merged.lastSeen = Date()
        merged.isConnected = true

        lastKnownDevices[presentationPeerId] = merged
        lastKnownDevices[runtimePeerId] = canonicalizedDevice(merged, canonicalPeerId: runtimePeerId)
        let status = connectionStatusByDeviceId[runtimePeerId]
            ?? connectionStatusByDeviceId[presentationPeerId]
            ?? .connected
        upsertActiveConnection(device: merged, status: status)
        syncPresentationState(for: runtimePeerId, preferredDevice: merged)
    }

    private func localPeerServiceHints() -> (capabilities: [String], fileTransferPort: UInt16?, remoteControlPort: UInt16?) {
        // iOS 支持作为远程桌面的查看器端（rdview），可以通过 P2P 连接控制已配对的 Mac
        // 但不支持作为被控端（rdcontrol），因为 iOS 系统不允许外部输入注入
        var capabilities = ["clipboard_sync", "remote_desktop"]
        guard FileTransferRuntime.shared.isReady else {
            return (capabilities, nil, nil)
        }
        capabilities.append("file_transfer")
        return (capabilities, FileTransferConstants.defaultPort, nil)
    }

    private func replyPong(
        to peerId: String,
        pingId: UInt64,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) async throws {
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(peerId) { return }
        guard let keySnapshot = sessionKeys[peerId],
              keySnapshot.sessionId == expectedReceipt.sessionId else {
            throw P2PError.noSessionKey
        }

        do {
            let message = AppMessage.pong(.init(id: pingId))
            let payload = try JSONEncoder().encode(message)
            let ciphertext = try skyBridgeCore.encrypt(
                payload,
                sessionKey: keySnapshot.sendKey
            )
            try requireCurrentAuthenticatedConnection(expectedReceipt)
            try await send(
                data: ciphertext,
                over: expectedReceipt.lease.connection,
                timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
                operation: "authenticated-pong"
            )
            try requireCurrentAuthenticatedConnection(expectedReceipt)
        } catch {
            guard isCurrentAuthenticatedConnection(expectedReceipt) else {
                throw P2PError.staleConnectionIncarnation
            }
            SkyBridgeLogger.shared.error(
                "⛔️ authenticated pong reply failed; closing session: \(Self.diagnosticErrorSummary(error))"
            )
            throw P2PError.authenticatedPongReplyFailed
        }
    }

    private func replyTextMessageReceipt(
        messageID: UUID,
        deliveryAttemptID: UUID,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) async throws {
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        guard !rekeyInProgress.contains(expectedReceipt.lease.peerId),
              let keySnapshot = sessionKeys[expectedReceipt.lease.peerId],
              keySnapshot.sessionId == expectedReceipt.sessionId else {
            throw P2PError.noSessionKey
        }
        let message = AppMessage.textMessageReceipt(.init(
            messageID: messageID,
            deliveryAttemptID: deliveryAttemptID
        ))
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try skyBridgeCore.encrypt(
            payload,
            sessionKey: keySnapshot.sendKey
        )
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        try await send(
            data: ciphertext,
            over: expectedReceipt.lease.connection,
            timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
            operation: "authenticated-text-receipt"
        )
        try requireCurrentAuthenticatedConnection(expectedReceipt)
    }

    private func sendPeerDisconnectingNotice(
        device: DiscoveredDevice,
        expectedReceipt: AuthenticatedConnectionReceipt,
        keySnapshot: SessionKeys
    ) async {
        guard isCurrentAuthenticatedConnection(expectedReceipt),
              keySnapshot.sessionId == expectedReceipt.sessionId else { return }
        do {
            let message = AppMessage.peerDisconnecting(
                .init(
                    deviceId: PeerIdentityAliasResolver.persistentDeviceId(from: device.id),
                    deviceName: device.name
                )
            )
            let payload = try JSONEncoder().encode(message)
            let ciphertext = try skyBridgeCore.encrypt(
                payload,
                sessionKey: keySnapshot.sendKey
            )
            try requireCurrentAuthenticatedConnection(expectedReceipt)
            try await send(
                data: ciphertext,
                over: expectedReceipt.lease.connection,
                timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
                operation: "peer-disconnecting"
            )
            try requireCurrentAuthenticatedConnection(expectedReceipt)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ peerDisconnecting 发送失败（忽略）: \(Self.diagnosticErrorSummary(error))")
        }
    }
    
    private func handlePairingIdentityExchangeRequest(
        from peerId: String,
        payload: AppMessage.PairingIdentityExchangePayload,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) async throws {
        let peerId = canonicalPeerLookupKey(peerId)
        try requireCurrentAuthenticatedConnection(expectedReceipt)
        guard expectedReceipt.lease.peerId == peerId else {
            throw P2PError.staleConnectionIncarnation
        }
        // Admission precedes every alias, presentation, metadata, and trust
        // mutation. The explicit approval UI is not a substitute for binding
        // this payload to the authority authenticated by the current lease.
        let admissionContext = try pairingIdentityAdmissionContext(
            peerId: peerId,
            payload: payload,
            expectedConnectionGeneration: expectedReceipt.lease.generation
        )
        _ = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: payload,
            sessionBinding: admissionContext.sessionAuthority.binding,
            sessionDeviceIds: admissionContext.sessionDeviceIds,
            operatorApproval: admissionContext.operatorApproval
        )
        let canAutoAccept = admissionContext.sessionAuthority
            .wasPreauthorizedForAutomaticPairing

        // Policy: auto-accept / auto-reject if a decision exists; otherwise raise a UI prompt.
        let normalizedPolicyDeviceId = payload.normalizedBootstrapPayload?.deviceId
        let stablePolicyKey = Self.stablePairingPolicyKey(for: payload)
        if let raw = stablePolicyKey.flatMap({ pairingPolicyByPeerId[$0] })
            ?? normalizedPolicyDeviceId.flatMap({ pairingPolicyByPeerId[$0] })
            ?? pairingPolicyByPeerId[peerId],
           let policy = PairingTrustDecision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                let hasDurableTrust = isPairingPolicyAuthorityAvailable
                    && TrustedDeviceStore.shared.hasActiveDurableTrust(
                        forAny: [peerId, payload.deviceId]
                    )
                if hasDurableTrust, canAutoAccept {
                    do {
                        try await acceptPairingIdentityExchange(
                            from: peerId,
                            expectedConnectionGeneration: admissionContext.sessionAuthority
                                .connectionGeneration,
                            payload: payload,
                            trustPeer: true,
                            persistTrust: true
                        )
                        return
                    } catch {
                        let message = "自动配对接受失败：\(error.localizedDescription)"
                        lastError = message
                        SkyBridgeLogger.shared.error(
                            "⛔️ 自动配对接受失败：\(Self.diagnosticErrorSummary(error))"
                        )
                        throw error
                    }
                }
                SkyBridgeLogger.shared.warning(
                    "⛔️ 已忽略缺少 durable active trust 或本地匹配密码学 pin 的 stored allow"
                )
            case .reject:
                SkyBridgeLogger.shared.warning("🛑 Pairing/trust request auto-rejected: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
                return
            case .allowOnce, .timedOut:
                // Should not be persisted; fall through to prompt.
                break
            }
        }
        
        // Automatic acceptance is authority-bearing and therefore requires a
        // durable, active record. An in-memory bootstrap task is not trust.
        if TrustedDeviceStore.shared.hasActiveDurableTrust(
            forAny: [peerId, payload.deviceId]
        ), canAutoAccept {
            do {
                try await acceptPairingIdentityExchange(
                    from: peerId,
                    expectedConnectionGeneration: admissionContext.sessionAuthority
                        .connectionGeneration,
                    payload: payload,
                    trustPeer: true,
                    persistTrust: false
                )
                return
            } catch {
                let message = "受信任设备配对接受失败：\(error.localizedDescription)"
                lastError = message
                SkyBridgeLogger.shared.error(
                    "⛔️ 受信任设备配对接受失败：\(Self.diagnosticErrorSummary(error))"
                )
                throw error
            }
        }
        
        // If another prompt is already showing, don't overwrite it. Keep the first one.
        guard pendingPairingTrustRequest == nil else {
            SkyBridgeLogger.shared.warning("ℹ️ Pairing/trust request received but UI prompt already pending; ignoring duplicate. peer=\(Self.protocolIdentityLogRedaction)")
            return
        }
        
        // Gather device info best-effort from discovery cache.
        let device = lastKnownDevices[peerId]
            ?? discoveryManager.discoveredDevices.first(where: { $0.id == peerId })
            ?? DiscoveredDevice(id: peerId, name: peerId, modelName: "", platform: .unknown, osVersion: "Unknown")
        
        let requestId = UUID()
        pendingPairingContextByRequestId[requestId] = .pairingIdentityExchange(
            peerId: peerId,
            connectionGeneration: admissionContext.sessionAuthority.connectionGeneration,
            payload: payload
        )
        pendingPairingTrustRequest = PairingTrustRequest(
            id: requestId,
            purpose: .kemIdentityExchange,
            peerId: peerId,
            declaredDeviceId: payload.deviceId,
            deviceName: device.name,
            platform: device.platform,
            modelName: device.modelName,
            osVersion: device.osVersion,
            kemKeyCount: payload.kemPublicKeys.count,
            verificationCode: nil,
            protocolIdentityFingerprint: nil,
            receivedAt: Date()
        )
        let approvalTimeoutSeconds = Self.pairingIdentityExchangeApprovalTimeoutSeconds
        scheduleStandalonePairingApprovalTimeout(
            requestId: requestId,
            timeout: .seconds(approvalTimeoutSeconds),
            timeoutStatusLine: "⏳ Pairing identity exchange approval timed out after \(approvalTimeoutSeconds)s; request rejected fail closed"
        )

        SkyBridgeLogger.shared.info("🔔 收到配对/受信任申请：device=\(Self.protocolIdentityLogRedaction) platform=\(device.platform.displayName) os=\(device.osVersion) peerId=\(Self.protocolIdentityLogRedaction)")
    }
    
    private func scheduleBootstrapRekeyIfNeeded(
        peerId: String,
        suiteRaw: String,
        expectedReceipt: AuthenticatedConnectionReceipt
    ) {
        let runtimePeerId = canonicalPeerLookupKey(expectedReceipt.lease.peerId)
        guard canonicalPeerLookupKey(peerId) == runtimePeerId,
              isCurrentAuthenticatedConnection(expectedReceipt),
              let requestedTargetSuite = CryptoSuite(rawValue: suiteRaw) else {
            return
        }
        if let existingOperation = bootstrapRekeyOperationByPeerId[runtimePeerId] {
            if existingOperation.connectionGeneration == expectedReceipt.lease.generation,
               existingOperation.initialSessionId == expectedReceipt.sessionId,
               existingOperation.targetCanonicalWireId
                == requestedTargetSuite.canonicalKEMSuite.wireId,
               bootstrapRekeyTasks[runtimePeerId] != nil {
                return
            }
            bootstrapRekeyTasks[runtimePeerId]?.cancel()
            bootstrapRekeyTasks.removeValue(forKey: runtimePeerId)
            bootstrapRekeyOperationByPeerId.removeValue(forKey: runtimePeerId)
        }

        let operation = BootstrapRekeyOperation(
            token: UUID(),
            connectionGeneration: expectedReceipt.lease.generation,
            initialSessionId: expectedReceipt.sessionId,
            targetCanonicalWireId: requestedTargetSuite.canonicalKEMSuite.wireId
        )
        bootstrapRekeyOperationByPeerId[runtimePeerId] = operation
        let peerIds = connectionStatePeerIds(for: runtimePeerId)
        let fromSuite = expectedReceipt.negotiatedSuite.rawValue
        setRekeyPresentationStatus(
            for: runtimePeerId,
            fromSuite: fromSuite,
            toSuite: suiteRaw
        )

        // Surface a stable "pending approval/keys" state to prevent reconnect storms.
        for effectivePeerId in peerIds {
            connectionErrorByDeviceId[effectivePeerId] = "等待对端批准配对/受信任申请以完成 PQC 切换（suite=\(suiteRaw)）"
        }
        currentHandshakeState = "等待对端批准以完成 PQC 切换..."

        bootstrapRekeyTasks[runtimePeerId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.bootstrapRekeyOperationByPeerId[runtimePeerId] == operation {
                    self.bootstrapRekeyTasks.removeValue(forKey: runtimePeerId)
                    self.bootstrapRekeyOperationByPeerId.removeValue(forKey: runtimePeerId)
                }
            }

            guard self.isCurrentBootstrapRekeyOperation(
                operation,
                for: runtimePeerId,
                requireInitialSession: true
            ) else {
                return
            }

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !Task.isCancelled {
                let keys = await self.kemPublicKeysForBootstrapRekey(peerId: runtimePeerId)
                guard self.isCurrentBootstrapRekeyOperation(
                    operation,
                    for: runtimePeerId,
                    requireInitialSession: true
                ) else {
                    return
                }
                if let targetSuite = CryptoSuite(rawValue: suiteRaw),
                   keys.keys.contains(where: { Self.suiteSupportsTargetKEM($0, target: targetSuite) }) {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }

            let keysNow = await self.kemPublicKeysForBootstrapRekey(peerId: runtimePeerId)
            guard self.isCurrentBootstrapRekeyOperation(
                operation,
                for: runtimePeerId,
                requireInitialSession: true
            ) else {
                return
            }
            let targetSuite = CryptoSuite(rawValue: suiteRaw)
            let hasCompatibleSuite = targetSuite.map { targetSuite in
                keysNow.keys.contains(where: { Self.suiteSupportsTargetKEM($0, target: targetSuite) })
            } ?? false
            guard hasCompatibleSuite else {
                let known = keysNow.keys.map(\.rawValue).sorted().joined(separator: ",")
                let canonicalTarget = targetSuite?.canonicalKEMSuite.rawValue ?? suiteRaw
                let message =
                    "等待对端 KEM 公钥超时（targetSuite=\(suiteRaw) canonicalTarget=\(canonicalTarget) knownSuites=\(known)）"
                self.publishBootstrapRekeyFailure(
                    for: runtimePeerId,
                    expectedOperation: operation,
                    message: message + "。请在 macOS 弹窗选择允许后重试，或稍后手动点击“重新握手”。"
                )
                return
            }
            
            do {
                // Give the responder a brief settle window to finish post-auth
                // pairingIdentityExchange handling before the in-band rekey starts.
                // On LAN bootstrap paths the remote side can still be transitioning
                // from `waitingFinished` to steady-state app-message handling.
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                guard self.isCurrentBootstrapRekeyOperation(
                    operation,
                    for: runtimePeerId,
                    requireInitialSession: true
                ) else {
                    throw P2PError.staleConnectionIncarnation
                }
                SkyBridgeLogger.shared.info("🔁 已获得对端 KEM 公钥，开始 rekey 到 PQC… peer=\(Self.protocolIdentityLogRedaction)")
                try await self.rekeyToPreferPQC(deviceId: runtimePeerId, allowSOA: false)
                guard self.isCurrentBootstrapRekeyOperation(
                    operation,
                    for: runtimePeerId,
                    requireInitialSession: false
                ), let currentKeys = self.sessionKeys[runtimePeerId],
                   self.sessionKeyConnectionGenerationByPeerId[runtimePeerId]
                    == operation.connectionGeneration,
                   currentKeys.negotiatedSuite.isPQCGroup,
                   targetSuite.map({
                       currentKeys.negotiatedSuite.canonicalKEMSuite
                           == $0.canonicalKEMSuite
                   }) ?? false else {
                    throw P2PError.staleConnectionIncarnation
                }
                for effectivePeerId in self.connectionStatePeerIds(for: runtimePeerId) {
                    self.connectionErrorByDeviceId.removeValue(forKey: effectivePeerId)
                }
                self.currentHandshakeState = "已切换到 PQC"
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentBootstrapRekeyOperation(
                    operation,
                    for: runtimePeerId,
                    requireInitialSession: false
                ) else {
                    return
                }
                self.publishBootstrapRekeyFailure(
                    for: runtimePeerId,
                    expectedOperation: operation,
                    message: self.userVisibleConnectionError(error)
                )
                SkyBridgeLogger.shared.error("❌ rekeyToPreferPQC failed: \(Self.diagnosticErrorSummary(error))")
            }
        }
    }

    private func isCurrentBootstrapRekeyOperation(
        _ expected: BootstrapRekeyOperation,
        for runtimePeerId: String,
        requireInitialSession: Bool
    ) -> Bool {
        guard bootstrapRekeyOperationByPeerId[runtimePeerId] == expected,
              let lease = connections.lease(for: runtimePeerId),
              lease.generation == expected.connectionGeneration,
              connections.isCurrent(lease, for: runtimePeerId),
              sessionKeyConnectionGenerationByPeerId[runtimePeerId]
                == expected.connectionGeneration,
              let keys = sessionKeys[runtimePeerId] else {
            return false
        }
        return !requireInitialSession || keys.sessionId == expected.initialSessionId
    }

    private func publishBootstrapRekeyFailure(
        for runtimePeerId: String,
        expectedOperation: BootstrapRekeyOperation,
        message: String
    ) {
        guard isCurrentBootstrapRekeyOperation(
            expectedOperation,
            for: runtimePeerId,
            requireInitialSession: false
        ) else {
            return
        }
        if let keys = sessionKeys[runtimePeerId],
           keys.negotiatedSuite.isPQCGroup,
           keys.negotiatedSuite.canonicalKEMSuite.wireId
            == expectedOperation.targetCanonicalWireId {
            for peerId in connectionStatePeerIds(for: runtimePeerId) {
                connectionErrorByDeviceId.removeValue(forKey: peerId)
            }
            clearRekeyPresentationStatus(for: runtimePeerId)
            currentHandshakeState = "已切换到 PQC"
            return
        }
        clearRekeyPresentationStatus(for: runtimePeerId)
        let surfaced = "PQC 切换失败：\(message)"
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            connectionErrorByDeviceId[peerId] = surfaced
        }
        currentHandshakeState = surfaced
        lastError = surfaced
        SkyBridgeLogger.shared.warning("⏳ \(message)")
    }

    private func bootstrapKEMLookupCandidates(for peerId: String) -> [String] {
        let runtimePeerId = canonicalPeerLookupKey(peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            candidates.append(trimmed)
        }

        func appendWithAliases(_ raw: String?) {
            append(raw)
            for alias in PeerIdentityAliasResolver.lookupCandidates(for: raw) {
                append(alias)
            }
        }

        for id in [peerId, runtimePeerId, presentationPeerId] {
            appendWithAliases(id)
        }
        for id in connectionStatePeerIds(for: runtimePeerId) {
            appendWithAliases(id)
        }

        var seedAliases = Set(candidates)
        for (deviceId, device) in lastKnownDevices {
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
                .union(PeerIdentityAliasResolver.aliasKeys(for: device))
            guard !aliases.isDisjoint(with: seedAliases) else { continue }
            appendWithAliases(deviceId)
            appendWithAliases(device.id)
            for alias in aliases {
                append(alias)
            }
            seedAliases = Set(candidates)
        }

        for connection in activeConnections {
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
                .union(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            guard !aliases.isDisjoint(with: seedAliases) else { continue }
            appendWithAliases(connection.device.id)
            for alias in aliases {
                append(alias)
            }
            seedAliases = Set(candidates)
        }

        return candidates
    }

    private func kemPublicKeysForBootstrapRekey(peerId: String) async -> [CryptoSuite: Data] {
        await Self.trustedPeerKEMPublicKeysFromAllStores(
            forAny: bootstrapKEMLookupCandidates(for: peerId)
        )
    }

    private func localProtocolIdentityFingerprintForSignedLANRefresh() async throws -> String {
        let snapshots = try await committedLocalProtocolIdentityCandidates()
        guard let fingerprint = snapshots.first?.authoritativeFingerprint,
              fingerprint.count == 64,
              fingerprint.allSatisfy(\.isHexDigit) else {
            throw signedLANRefreshFailure("missing local protocol identity fingerprint")
        }
        return fingerprint
    }

    private struct LocalProtocolIdentityProof: Sendable {
        let algorithm: ProtocolSigningAlgorithm
        let publicKey: Data
        let keyHandle: SigningKeyHandle
        let fingerprint: String
    }

    private func localProtocolIdentityProofForProtocolBinding(
        candidateAlgorithms: [ProtocolSigningAlgorithm]? = nil,
        targetFingerprint: String? = nil
    ) async throws -> LocalProtocolIdentityProof {
        let normalizedTargetFingerprint = Self.normalizedProtocolIdentityFingerprint(targetFingerprint)
        let snapshots = try await committedLocalProtocolIdentityCandidates()
        let allowedAlgorithms = Set(candidateAlgorithms ?? snapshots.map(\.algorithm))
        for snapshot in snapshots
        where allowedAlgorithms.contains(snapshot.algorithm) {
            let fingerprint = snapshot.authoritativeFingerprint
            guard fingerprint.count == 64,
                  fingerprint.allSatisfy(\.isHexDigit),
                  normalizedTargetFingerprint == nil || normalizedTargetFingerprint == fingerprint else {
                continue
            }
            return LocalProtocolIdentityProof(
                algorithm: snapshot.algorithm,
                publicKey: snapshot.publicKey,
                keyHandle: snapshot.keyHandle,
                fingerprint: fingerprint
            )
        }
        throw protocolIdentityBindingFailure("missing local protocol identity proof")
    }

    private func localProtocolIdentityPublicKeysForPairing() async throws -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        let snapshots = try await committedLocalProtocolIdentityCandidates()
        guard let activeIdentity = snapshots.first else {
            throw SkyBridgeError.notInitialized
        }
        let keys = snapshots.map {
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: $0.algorithm.rawValue,
                publicKey: $0.publicKey
            )
        }
        let normalized = AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
        guard normalized.contains(where: {
            $0.normalizedAlgorithm == activeIdentity.algorithm
                && $0.publicKey == activeIdentity.publicKey
        }) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Configured protocol identity is missing from the pairing advertisement"
            )
        }
        return normalized
    }

    /// Captures the active exact `(algorithm, protection)` slot once, then adds
    /// only the established software compatibility slots. A final configuration
    /// recheck prevents an advertisement or proof from spanning a settings
    /// transition while the compatibility identities are being resolved.
    private func committedLocalProtocolIdentityCandidates() async throws
        -> [CommittedIOSProtocolIdentitySnapshot] {
        _ = try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
        let active = try await skyBridgeCore.committedActiveProtocolIdentitySnapshot()
        var snapshots = [active]
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519]
        where algorithm != active.algorithm {
            do {
                snapshots.append(
                    try await skyBridgeCore.committedProtocolIdentitySnapshot(
                        for: algorithm,
                        protection: .softwareKeychain
                    )
                )
            } catch {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ local protocol identity compatibility slot unavailable alg=\(algorithm.rawValue): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }
        let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        guard configuration.algorithm == active.algorithm,
              configuration.keyProtection == active.protection else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Protocol identity configuration changed while local authority candidates were resolving"
            )
        }
        return snapshots
    }

    private func localProtocolIdentityAlgorithmCandidates() -> [ProtocolSigningAlgorithm] {
        guard let configuration = try? ProtocolSigningIdentityPolicy.requiredConfiguration() else {
            return []
        }
        var seen = Set<ProtocolSigningAlgorithm>()
        return [
            configuration.algorithm,
            .mlDSA65,
            .ed25519
        ].filter { seen.insert($0).inserted }
    }

    private nonisolated static func canonicalPairingIdentityAuthorityKey(
        _ declaredDeviceId: String
    ) -> String {
        PairingIdentityAcceptedMaterialDigest.canonicalAuthorityKey(declaredDeviceId)
    }

    private nonisolated static func stablePairingPolicyKey(
        for payload: AppMessage.PairingIdentityExchangePayload
    ) -> String? {
        payload.normalizedBootstrapPayload.map {
            canonicalPairingIdentityAuthorityKey($0.deviceId)
        }
    }

    private nonisolated static func acceptedPairingIdentityMaterialDigest(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: ValidatedPairingIdentityAuthority
    ) throws -> Data {
        try PairingIdentityAcceptedMaterialDigest.compute(
            payload: payload,
            authority: authority
        )
    }

#if DEBUG || SKYBRIDGE_TESTING
    nonisolated static func testOnlyCanonicalPairingIdentityAuthorityKey(
        _ declaredDeviceId: String
    ) -> String {
        canonicalPairingIdentityAuthorityKey(declaredDeviceId)
    }

    nonisolated static func testOnlyStablePairingPolicyKey(
        for payload: AppMessage.PairingIdentityExchangePayload
    ) -> String? {
        stablePairingPolicyKey(for: payload)
    }

    nonisolated static func testOnlyAcceptedPairingIdentityMaterialDigest(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: ValidatedPairingIdentityAuthority
    ) throws -> Data {
        try acceptedPairingIdentityMaterialDigest(
            payload: payload,
            authority: authority
        )
    }

    nonisolated static func testOnlyPairingIdentityPresentationMaterialChanged(
        from previous: AppMessage.PairingIdentityExchangePayload,
        to current: AppMessage.PairingIdentityExchangePayload
    ) -> Bool {
        PairingIdentityPresentationMaterial(payload: previous)
            != PairingIdentityPresentationMaterial(payload: current)
    }
#endif

    private enum PairingIdentityAcceptanceError: LocalizedError {
        case invalidPayload
        case fullyCompensated(original: String)
        case durableCommitRetained(original: String)
        case rollbackIncomplete(original: String, failures: [String])

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                return "无效的配对身份交换载荷"
            case .fullyCompensated(let original):
                return "配对身份接受失败，但本地持久化变更已完整回滚：\(original)"
            case .durableCommitRetained(let original):
                return "配对身份已在本地持久化，但当前会话未完成回复：\(original)"
            case .rollbackIncomplete(let original, let failures):
                return "配对身份接受失败（\(original)）且回滚不完整：\(failures.joined(separator: "; "))"
            }
        }

        var isPersistenceFailure: Bool {
            if case .rollbackIncomplete = self { return true }
            return false
        }
    }

    private func performSerializedPairingIdentityAcceptance(
        from peerId: String,
        expectedConnectionGeneration: UUID,
        payload: AppMessage.PairingIdentityExchangePayload,
        validatedAuthority: ValidatedPairingIdentityAuthority,
        trustPeer: Bool,
        persistTrust: Bool,
        pairingPolicy: PairingTrustDecision?
    ) async throws {
        let sessionPeerId = canonicalPeerLookupKey(peerId)
        let lease = try requireCurrentConnectionLease(
            for: sessionPeerId,
            generation: expectedConnectionGeneration
        )
        guard sessionKeyConnectionGenerationByPeerId[sessionPeerId]
                == expectedConnectionGeneration,
              let sessionId = sessionKeys[sessionPeerId]?.sessionId else {
            throw P2PError.noSessionKey
        }
        let acceptedMaterialDigest = try Self.acceptedPairingIdentityMaterialDigest(
            payload: payload,
            authority: validatedAuthority
        )
        let presentationMaterial = PairingIdentityPresentationMaterial(payload: payload)
        let key = PairingIdentityAcceptanceKey(
            declaredDeviceId: Self.canonicalPairingIdentityAuthorityKey(
                validatedAuthority.declaredDeviceId
            )
        )

        if let existing = pairingIdentityAcceptanceOperations[key] {
            let isSameExactAcceptance = existing.connectionIdentifier
                    == ObjectIdentifier(lease.connection)
                && existing.connectionGeneration == expectedConnectionGeneration
                && existing.sessionId == sessionId
                && existing.acceptedMaterialDigest == acceptedMaterialDigest
                && existing.presentationMaterial == presentationMaterial
                && existing.validatedAuthority.protocolSigningAlgorithm
                    == validatedAuthority.protocolSigningAlgorithm
                && existing.validatedAuthority.protocolPublicKeyFingerprint
                    == validatedAuthority.protocolPublicKeyFingerprint
                && existing.validatedAuthority.protocolPublicKey
                    == validatedAuthority.protocolPublicKey
                && existing.trustPeer == trustPeer
                && existing.persistTrust == persistTrust
                && existing.pairingPolicy == pairingPolicy
            if isSameExactAcceptance {
                try await existing.task.value
                return
            }

            // A second incarnation or rotated material must not interleave a
            // compensating transaction for the same durable authority. Let the
            // exact current owner settle, remove only that completed owner, and
            // then restart from admission for this newer request. A failed
            // owner is propagated: in particular, rollback-incomplete residue
            // must never be silently reactivated by an automatic retry.
            let existingToken = existing.token
            do {
                try await existing.task.value
            } catch let error as PairingIdentityAcceptanceError {
                switch error {
                case .fullyCompensated, .durableCommitRetained:
                    break
                case .invalidPayload, .rollbackIncomplete:
                    throw error
                }
            }
            if pairingIdentityAcceptanceOperations[key]?.token == existingToken {
                pairingIdentityAcceptanceOperations.removeValue(forKey: key)
            }
            try await acceptPairingIdentityExchange(
                from: sessionPeerId,
                expectedConnectionGeneration: expectedConnectionGeneration,
                payload: payload,
                trustPeer: trustPeer,
                persistTrust: persistTrust,
                pairingPolicy: pairingPolicy
            )
            return
        }

        let token = UUID()
        let task = Task { @MainActor [self] in
            try await commitAcceptedPairingIdentityExchange(
                from: sessionPeerId,
                expectedConnectionGeneration: expectedConnectionGeneration,
                payload: payload,
                validatedAuthority: validatedAuthority,
                trustPeer: trustPeer,
                persistTrust: persistTrust,
                pairingPolicy: pairingPolicy
            )
        }
        pairingIdentityAcceptanceOperations[key] = PairingIdentityAcceptanceOperation(
            token: token,
            connectionIdentifier: ObjectIdentifier(lease.connection),
            connectionGeneration: expectedConnectionGeneration,
            sessionId: sessionId,
            acceptedMaterialDigest: acceptedMaterialDigest,
            presentationMaterial: presentationMaterial,
            validatedAuthority: validatedAuthority,
            trustPeer: trustPeer,
            persistTrust: persistTrust,
            pairingPolicy: pairingPolicy,
            task: task
        )
        defer {
            if pairingIdentityAcceptanceOperations[key]?.token == token {
                pairingIdentityAcceptanceOperations.removeValue(forKey: key)
            }
        }
        try await task.value
    }

    private struct PairingIdentityAdmissionContext {
        let sessionAuthority: SessionPairingAuthority
        let sessionDeviceIds: [String]
        let operatorApproval: PIBOperatorApprovalReceipt?
    }

    private func pairingIdentityAdmissionContext(
        peerId: String,
        payload: AppMessage.PairingIdentityExchangePayload,
        expectedConnectionGeneration: UUID?
    ) throws -> PairingIdentityAdmissionContext {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let sessionAuthority = currentSessionPairingAuthority(for: peerId),
            expectedConnectionGeneration == nil
                || sessionAuthority.connectionGeneration == expectedConnectionGeneration
        else {
            throw PairingTrustResolutionError.sessionNoLongerCurrent
        }
        let knownDevice = lastKnownDevices[peerId]
        let sessionDeviceIds = [
            peerId,
            knownDevice?.id,
            knownDevice.flatMap { PeerIdentityAliasResolver.persistentDeviceId(from: $0.id) },
            presentationPeerId(for: peerId)
        ].compactMap { $0 }

        let operatorApproval: PIBOperatorApprovalReceipt?
        let algorithmRaw = sessionAuthority.binding.authority.protocolSigningAlgorithm
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let algorithm = ProtocolSigningAlgorithm(rawValue: algorithmRaw)
        {
            operatorApproval = TrustedDeviceStore.shared.exactActivePIBOperatorApproval(
                forDeclaredDeviceId: payload.deviceId,
                algorithm: algorithm
            )
        } else {
            operatorApproval = nil
        }
        return PairingIdentityAdmissionContext(
            sessionAuthority: sessionAuthority,
            sessionDeviceIds: sessionDeviceIds,
            operatorApproval: operatorApproval
        )
    }

    private func acceptPairingIdentityExchange(
        from peerId: String,
        expectedConnectionGeneration: UUID,
        payload: AppMessage.PairingIdentityExchangePayload,
        trustPeer: Bool,
        persistTrust: Bool,
        pairingPolicy: PairingTrustDecision? = nil
    ) async throws {
        let peerId = canonicalPeerLookupKey(peerId)
        let context = try pairingIdentityAdmissionContext(
            peerId: peerId,
            payload: payload,
            expectedConnectionGeneration: expectedConnectionGeneration
        )
        try await AuthenticatedPairingIdentityAuthorityValidator.performAuthorizedMutation(
            payload: payload,
            sessionBinding: context.sessionAuthority.binding,
            sessionDeviceIds: context.sessionDeviceIds,
            operatorApproval: context.operatorApproval
        ) { normalizedPayload, validatedAuthority in
            try await self.performSerializedPairingIdentityAcceptance(
                from: peerId,
                expectedConnectionGeneration: expectedConnectionGeneration,
                payload: normalizedPayload,
                validatedAuthority: validatedAuthority,
                trustPeer: trustPeer,
                persistTrust: persistTrust,
                pairingPolicy: pairingPolicy
            )
        }
    }

    private func commitAcceptedPairingIdentityExchange(
        from peerId: String,
        expectedConnectionGeneration: UUID,
        payload: AppMessage.PairingIdentityExchangePayload,
        validatedAuthority: ValidatedPairingIdentityAuthority,
        trustPeer: Bool,
        persistTrust: Bool,
        pairingPolicy: PairingTrustDecision?
    ) async throws {
        let sessionPeerId = canonicalPeerLookupKey(peerId)
        let sessionLease = try requireCurrentConnectionLease(
            for: sessionPeerId,
            generation: expectedConnectionGeneration
        )
        guard sessionKeyConnectionGenerationByPeerId[sessionPeerId]
                == expectedConnectionGeneration,
              let expectedSessionId = sessionKeys[sessionPeerId]?.sessionId else {
            throw P2PError.noSessionKey
        }
        let declaredDeviceId = validatedAuthority.declaredDeviceId
        let acceptedMaterialDigest = try Self.acceptedPairingIdentityMaterialDigest(
            payload: payload,
            authority: validatedAuthority
        )
        let previousDeclaredDeviceId = lastAcceptedPairingIdentityDeviceIdByPeerId[sessionPeerId]
        let shouldForceIdentityReply = previousDeclaredDeviceId.map {
            $0.caseInsensitiveCompare(declaredDeviceId) != ComparisonResult.orderedSame
        } ?? true
        let observedAt = Date()

        let trustedDeviceCandidate: DiscoveredDevice? = trustPeer
            ? lastKnownDevices[sessionPeerId]
                ?? discoveryManager.discoveredDevices.first(where: {
                    $0.id == sessionPeerId
                })
                ?? DiscoveredDevice(
                    id: sessionPeerId,
                    name: sessionPeerId,
                    modelName: "",
                    platform: .unknown,
                    osVersion: "Unknown"
                )
            : nil
        let acceptanceAuthorityKey = Self.canonicalPairingIdentityAuthorityKey(
            declaredDeviceId
        )
        let persistedPairingPolicy = pairingPolicy.flatMap(
            Self.pairingPolicyValueToPersist
        )
        let acceptanceHandle: PairingAcceptancePersistenceHandle
        do {
            acceptanceHandle = try await PairingAcceptancePersistence.begin(
                payload: payload,
                authority: validatedAuthority,
                canonicalAcceptanceKey: acceptanceAuthorityKey,
                acceptedMaterialDigest: acceptedMaterialDigest,
                trustedDevicePreparation: { permit in
                    guard let trustedDeviceCandidate else { return nil }
                    return try TrustedDeviceStore.shared.prepareTrustResolvedPeer(
                        trustedDeviceCandidate,
                        declaredDeviceId: declaredDeviceId,
                        protocolSigningAlgorithm:
                            validatedAuthority.protocolSigningAlgorithm.rawValue,
                        protocolPublicKeyFingerprint:
                            validatedAuthority.protocolPublicKeyFingerprint,
                        outerPermit: permit
                    )
                },
                pairingPolicyPersistedValue: persistedPairingPolicy,
                policyParticipant: self
            ) {
                _ = try self.requireCurrentConnectionLease(
                    for: sessionPeerId,
                    generation: expectedConnectionGeneration,
                    sessionId: expectedSessionId
                )
            }
        } catch let error as P2PError {
            throw PairingIdentityAcceptanceError.fullyCompensated(
                original: Self.diagnosticErrorSummary(error)
            )
        }
        SkyBridgeLogger.shared.info(
            "🔑 已原子保存 authority-bound 对端身份：peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction) aliases=\(validatedAuthority.authorizedDeviceIds.count) keys=\(payload.kemPublicKeys.count)"
        )
        if trustPeer, persistTrust {
            SkyBridgeLogger.shared.info(
                "✅ 已加入受信任设备：\(Self.protocolIdentityLogRedaction) peerId=\(Self.protocolIdentityLogRedaction)"
            )
        }

        func abortBeforeVisibility(after originalError: Error) async throws {
            do {
                try await PairingAcceptancePersistence.abortBeforeReplyVisibility(
                    acceptanceHandle,
                    policyParticipant: self
                )
            } catch {
                throw PairingIdentityAcceptanceError.rollbackIncomplete(
                    original: Self.diagnosticErrorSummary(originalError),
                    failures: [
                        "outer-acceptance: \(Self.diagnosticErrorSummary(error))"
                    ]
                )
            }
        }

        var visibilityMarkerDurable = false
        var acceptanceFinalizationAttempted = false
        var acceptanceFinalized = false

        func markReplyVisibilityBeforeNetworkSubmission() async throws {
            do {
                try await PairingAcceptancePersistence.markReplyMayBeVisible(
                    acceptanceHandle
                ) {
                    _ = try self.requireCurrentConnectionLease(
                        for: sessionPeerId,
                        generation: expectedConnectionGeneration,
                        sessionId: expectedSessionId
                    )
                }
                visibilityMarkerDurable = true
            } catch {
                let markerError = error
                visibilityMarkerDurable = visibilityMarkerDurable
                    || PairingAcceptancePersistence.replyMayBeVisible(
                        acceptanceHandle
                    )
                guard visibilityMarkerDurable else {
                    throw markerError
                }
                // The protected write may have reached storage before its
                // verification boundary returned an error. Once the marker is
                // durably observable, it is monotonic and the bounded send must
                // proceed so recovery can only converge to the AFTER image.
            }
        }

        func completeBeforeNetworkSubmission(
            following originalError: Error? = nil
        ) async throws {
            // `complete` releases the global permit in defer even when journal
            // removal fails. Record the attempt first so no catch path can issue
            // an invalid compensating abort with a released permit.
            acceptanceFinalizationAttempted = true
            do {
                try await PairingAcceptancePersistence.completeAfterReplyMayBeVisible(
                    acceptanceHandle,
                    policyParticipant: self
                )
                acceptanceFinalized = true
            } catch {
                throw PairingIdentityAcceptanceError.rollbackIncomplete(
                    original: originalError.map(Self.diagnosticErrorSummary)
                        ?? "pairing identity pre-submit finalization",
                    failures: [
                        "outer-post-visibility: \(Self.diagnosticErrorSummary(error))"
                    ]
                )
            }
        }

        func finalizeBeforeNetworkSubmission() async throws {
            try await markReplyVisibilityBeforeNetworkSubmission()
            try await completeBeforeNetworkSubmission()

            // `completeAfterReplyMayBeVisible` releases the global authority
            // permit. Revalidate the exact incarnation after that async work so
            // a replacement session never receives this old session's reply.
            _ = try requireCurrentConnectionLease(
                for: sessionPeerId,
                generation: expectedConnectionGeneration,
                sessionId: expectedSessionId
            )
        }

        // Reply once (rate-limited) so both sides learn each other's KEM identity keys.
        // The first accepted identity on a session is not rate-limited; file transfer uses
        // the reply as proof that the receiver has bound the stable device id to the session.
        let hasRecentReplyForCurrentSession = !shouldForceIdentityReply
            && lastPairingIdentityExchangeSentAt[sessionPeerId].map {
                $0.connectionGeneration == expectedConnectionGeneration
                    && $0.sessionId == expectedSessionId
                    && $0.acceptedMaterialDigest == acceptedMaterialDigest
                    && Date().timeIntervalSince($0.sentAt) < 10
            } == true
        if !hasRecentReplyForCurrentSession {
            let sendOutcome: PairingIdentitySendOutcome
            do {
                sendOutcome = try await sendPairingIdentityExchange(
                    to: sessionPeerId,
                    expectedLease: sessionLease,
                    expectedSessionId: expectedSessionId,
                    acceptedMaterialDigest: acceptedMaterialDigest,
                    beforeNetworkSubmit: {
                        try await finalizeBeforeNetworkSubmission()
                    }
                )
                SkyBridgeLogger.shared.info("🔁 pairingIdentityExchange replied to peer=\(Self.protocolIdentityLogRedaction)")
            } catch {
                let replyError = error
                cleanupBrokenInboundConnection(
                    sessionLease.connection,
                    peerId: sessionPeerId,
                    reason: "已认证 pairing identity 回复发送失败"
                )
                if acceptanceFinalizationAttempted {
                    if let acceptanceError = replyError as? PairingIdentityAcceptanceError {
                        throw acceptanceError
                    }
                    guard acceptanceFinalized else {
                        throw PairingIdentityAcceptanceError.rollbackIncomplete(
                            original: Self.diagnosticErrorSummary(replyError),
                            failures: ["outer-post-visibility: finalization failed after permit release"]
                        )
                    }
                    SkyBridgeLogger.shared.error(
                        "⛔️ pairing identity local acceptance finalized before network submission; exact session closed after reply failure: \(Self.diagnosticErrorSummary(replyError))"
                    )
                    throw PairingIdentityAcceptanceError.durableCommitRetained(
                        original: Self.diagnosticErrorSummary(replyError)
                    )
                }
                visibilityMarkerDurable = visibilityMarkerDurable
                    || PairingAcceptancePersistence.replyMayBeVisible(
                        acceptanceHandle
                    )
                guard visibilityMarkerDurable else {
                    try await abortBeforeVisibility(after: replyError)
                    throw PairingIdentityAcceptanceError.fullyCompensated(
                        original: Self.diagnosticErrorSummary(replyError)
                    )
                }
                try await completeBeforeNetworkSubmission(following: replyError)
                SkyBridgeLogger.shared.error(
                    "⛔️ pairing identity reply marker was durable before submission; local acceptance retained and exact session closed: \(Self.diagnosticErrorSummary(replyError))"
                )
                throw PairingIdentityAcceptanceError.durableCommitRetained(
                    original: Self.diagnosticErrorSummary(replyError)
                )
            }
            guard sendOutcome == .contentProcessedCurrent else {
                cleanupBrokenInboundConnection(
                    sessionLease.connection,
                    peerId: sessionPeerId,
                    reason: "pairing identity 回复已进入网络栈，但旧会话已被替换"
                )
                SkyBridgeLogger.shared.info(
                    "✅ pairing identity durable commit retained after the old session was superseded; the replacement session will re-advertise before presentation"
                )
                return
            }
        } else {
            do {
                try await finalizeBeforeNetworkSubmission()
            } catch {
                let finalizationError = error
                cleanupBrokenInboundConnection(
                    sessionLease.connection,
                    peerId: sessionPeerId,
                    reason: "pairing identity 本地事务收尾失败"
                )
                if acceptanceFinalizationAttempted {
                    if let acceptanceError = finalizationError as? PairingIdentityAcceptanceError {
                        throw acceptanceError
                    }
                    guard acceptanceFinalized else {
                        throw PairingIdentityAcceptanceError.rollbackIncomplete(
                            original: Self.diagnosticErrorSummary(finalizationError),
                            failures: ["outer-post-visibility: finalization failed after permit release"]
                        )
                    }
                    throw PairingIdentityAcceptanceError.durableCommitRetained(
                        original: Self.diagnosticErrorSummary(finalizationError)
                    )
                }
                visibilityMarkerDurable = visibilityMarkerDurable
                    || PairingAcceptancePersistence.replyMayBeVisible(
                        acceptanceHandle
                    )
                guard visibilityMarkerDurable else {
                    try await abortBeforeVisibility(after: finalizationError)
                    throw PairingIdentityAcceptanceError.fullyCompensated(
                        original: Self.diagnosticErrorSummary(finalizationError)
                    )
                }
                try await completeBeforeNetworkSubmission(following: finalizationError)
                throw PairingIdentityAcceptanceError.durableCommitRetained(
                    original: Self.diagnosticErrorSummary(finalizationError)
                )
            }
        }

        do {
            _ = try requireCurrentConnectionLease(
                for: sessionPeerId,
                generation: expectedConnectionGeneration,
                sessionId: expectedSessionId
            )
        } catch {
            // The local authority/trust decision was finalized before the
            // bounded send. A stale post-send incarnation may suppress
            // presentation/rekey, but must not undo that durable local decision.
            cleanupBrokenInboundConnection(
                sessionLease.connection,
                peerId: sessionPeerId,
                reason: "pairing identity 回复后会话已被替换"
            )
            SkyBridgeLogger.shared.info(
                "✅ pairing identity durable commit retained after post-send session replacement; stale presentation was suppressed"
            )
            return
        }

        // Presentation aliases, service capabilities and rekey readiness become
        // observable only after the durable authority transaction and the exact
        // current-session reply have both succeeded.
        let promotedPeerId = promotePeerPresentationIdentityIfNeeded(
            runtimePeerId: sessionPeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: payload.deviceName,
            modelName: payload.modelName,
            platform: payload.platform,
            osVersion: payload.osVersion
        )
        lastAcceptedPairingIdentityDeviceIdByPeerId[promotedPeerId] = declaredDeviceId
        let receiveObservation = PairingIdentityReceiveObservation(
            connectionGeneration: expectedConnectionGeneration,
            sessionId: expectedSessionId,
            observedAt: observedAt
        )
        lastPairingIdentityExchangeReceivedAt[promotedPeerId] = receiveObservation
        let presentationPeerId = presentationPeerId(for: promotedPeerId)
        lastPairingIdentityExchangeReceivedAt[presentationPeerId] = receiveObservation
        lastPairingIdentityBootstrapReadyAt[promotedPeerId] = receiveObservation
        lastPairingIdentityBootstrapReadyAt[presentationPeerId] = receiveObservation
        mergePeerServiceMetadata(
            runtimePeerId: promotedPeerId,
            declaredDeviceId: declaredDeviceId,
            capabilities: payload.capabilities,
            fileTransferPort: payload.fileTransferPort,
            remoteControlPort: payload.remoteControlPort
        )

        if pqcManager.enforcePQCHandshake,
           let negotiatedSuite = resolvedNegotiatedSuite(forAnyPeerId: promotedPeerId),
           !negotiatedSuite.isPQCGroup,
           let targetSuite = preferredRekeyTargetSuite(),
           let currentKeys = sessionKeys[sessionPeerId],
           sessionKeyConnectionGenerationByPeerId[sessionPeerId]
            == expectedConnectionGeneration,
           currentKeys.sessionId == expectedSessionId {
            scheduleBootstrapRekeyIfNeeded(
                peerId: sessionPeerId,
                suiteRaw: targetSuite,
                expectedReceipt: AuthenticatedConnectionReceipt(
                    lease: sessionLease,
                    sessionId: expectedSessionId,
                    negotiatedSuite: currentKeys.negotiatedSuite
                )
            )
        }
    }

    /// 向对端发送本机 KEM identity 公钥，用于 bootstrap PQC suite 协商（首次可用 classic，收到后即可 rekey 到 PQC）。
    public func sendPairingIdentityExchange(to deviceId: String) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let lease = connections.lease(for: deviceId),
            connections.isCurrent(lease, for: deviceId)
        else {
            throw P2PError.connectionFailed
        }
        guard sessionKeyConnectionGenerationByPeerId[deviceId] == lease.generation,
              let sessionId = sessionKeys[deviceId]?.sessionId else {
            throw P2PError.noSessionKey
        }
        let sendOutcome = try await sendPairingIdentityExchange(
            to: deviceId,
            expectedLease: lease,
            expectedSessionId: sessionId,
            acceptedMaterialDigest: nil
        )
        guard sendOutcome == .contentProcessedCurrent else {
            throw P2PError.staleConnectionIncarnation
        }
    }

    private func sendPairingIdentityExchange(
        to deviceId: String,
        expectedLease: P2PConnectionLease<NWConnection>,
        expectedSessionId: String,
        acceptedMaterialDigest: Data?,
        beforeNetworkSubmit: () async throws -> Void = {}
    ) async throws -> PairingIdentitySendOutcome {
        let deviceId = canonicalPeerLookupKey(deviceId)
        let currentLease = try requireCurrentConnectionLease(
            for: deviceId,
            generation: expectedLease.generation,
            sessionId: expectedSessionId
        )
        guard currentLease.connection === expectedLease.connection,
            let keySnapshot = sessionKeys[deviceId],
            keySnapshot.sessionId == expectedSessionId
        else {
            throw P2PError.staleConnectionIncarnation
        }
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(deviceId) {
            if let negotiatedSuite = resolvedNegotiatedSuite(forAnyPeerId: deviceId),
               negotiatedSuite.isPQCGroup {
                clearRekeyInProgress(for: deviceId)
                SkyBridgeLogger.shared.info(
                    "🔁 cleared stale rekey marker before pairingIdentityExchange: peer=\(Self.protocolIdentityLogRedaction) suite=\(negotiatedSuite.rawValue)"
                )
            } else {
                SkyBridgeLogger.shared.info(
                    "⏳ pairingIdentityExchange delayed during active rekey: peer=\(Self.protocolIdentityLogRedaction)"
                )
                throw P2PError.pairingIdentityExchangeUnavailable(
                    reason: "会话正在 rekey"
                )
            }
        }

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        _ = try requireCurrentConnectionLease(
            for: deviceId,
            generation: expectedLease.generation,
            sessionId: expectedSessionId
        )
        guard !kemKeys.isEmpty else {
            throw P2PError.pairingIdentityExchangeUnavailable(
                reason: "本机 KEM 公钥为空"
            )
        }

        // 设备 ID：用于对端把我们写入 trust store 的 key（尽量与 discovery 的 deviceId 对齐）
        let snapshot = AppleMobileDeviceIdentity.currentSnapshot()
        let localId = try localStableDeviceIdentifier().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localId.isEmpty else {
            throw P2PError.pairingIdentityExchangeUnavailable(
                reason: "本机 stable deviceId 为空"
            )
        }
        let serviceHints = localPeerServiceHints()
        let protocolIdentityPublicKeys = try await localProtocolIdentityPublicKeysForPairing()
        _ = try requireCurrentConnectionLease(
            for: deviceId,
            generation: expectedLease.generation,
            sessionId: expectedSessionId
        )
        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys,
            deviceName: snapshot.deviceName,
            modelName: snapshot.modelName,
            platform: snapshot.platformName,
            osVersion: snapshot.osVersion,
            chip: snapshot.chip,
            capabilities: serviceHints.capabilities,
            fileTransferPort: serviceHints.fileTransferPort,
            remoteControlPort: serviceHints.remoteControlPort
        ))
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try skyBridgeCore.encrypt(payload, sessionKey: keySnapshot.sendKey)
        _ = try requireCurrentConnectionLease(
            for: deviceId,
            generation: expectedLease.generation,
            sessionId: expectedSessionId
        )
        try await beforeNetworkSubmit()
        try await sendPairingIdentityData(
            ciphertext,
            over: expectedLease.connection
        )
        guard let postSendLease = try? requireCurrentConnectionLease(
            for: deviceId,
            generation: expectedLease.generation,
            sessionId: expectedSessionId
        ), postSendLease.connection === expectedLease.connection else {
            SkyBridgeLogger.shared.warning(
                "⚠️ pairingIdentityExchange entered the network stack after its exact session was superseded; durable authority is retained but stale presentation is suppressed"
            )
            return .contentProcessedButSuperseded
        }
        lastPairingIdentityExchangeSentAt[deviceId] = PairingIdentitySendObservation(
            connectionGeneration: expectedLease.generation,
            sessionId: expectedSessionId,
            acceptedMaterialDigest: acceptedMaterialDigest,
            sentAt: Date()
        )
        SkyBridgeLogger.shared.info("📤 pairingIdentityExchange sent: peer=\(Self.protocolIdentityLogRedaction) keys=\(kemKeys.count)")
        return .contentProcessedCurrent
    }

    public func waitForPairingIdentityExchangeActivity(
        with deviceId: String,
        since: Date,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if hasPairingIdentityObservation(
                in: lastPairingIdentityExchangeReceivedAt,
                matching: pairingIdentityObservationAliases(for: deviceId),
                since: since
            ) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }

        return false
    }

    public func hasCurrentPairingIdentityExchangeActivity(
        with deviceId: String
    ) -> Bool {
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: true
        ) else {
            return false
        }
        return hasPairingIdentityObservation(
            in: lastPairingIdentityExchangeReceivedAt,
            matching: pairingIdentityObservationAliases(for: deviceId),
            since: .distantPast,
            expectedConnectionGeneration: current.receipt.lease.generation,
            expectedSessionId: current.receipt.sessionId
        )
    }

    private func waitForPairingIdentityExchangeActivity(
        with deviceId: String,
        since: Date,
        expectedReceipt: AuthenticatedConnectionReceipt,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        let aliases = pairingIdentityObservationAliases(for: deviceId)

        while clock.now < deadline {
            guard isCurrentAuthenticatedConnection(expectedReceipt) else { return false }
            if hasPairingIdentityObservation(
                in: lastPairingIdentityExchangeReceivedAt,
                matching: aliases,
                since: since,
                expectedConnectionGeneration: expectedReceipt.lease.generation,
                expectedSessionId: expectedReceipt.sessionId
            ) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    public func waitForPairingIdentityExchangeBootstrapReadiness(
        with deviceId: String,
        since: Date,
        timeout: Duration = .seconds(8)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            let aliases = pairingIdentityObservationAliases(for: deviceId)
            for alias in aliases {
                if await hasStrictPQCTrustBootstrapMaterial(for: alias) {
                    return true
                }
            }
            if hasPairingIdentityObservation(
                in: lastPairingIdentityBootstrapReadyAt,
                matching: aliases,
                since: since
            ) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }

        return false
    }

    private func pairingIdentityObservationAliases(for deviceId: String) -> Set<String> {
        let canonicalPeerId = canonicalPeerLookupKey(deviceId)
        let runtimePeerId = runtimePeerId(forAnyPeerId: canonicalPeerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        var aliases = connectionAliasSet(for: runtimePeerId)

        func insertAliases(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            aliases.insert(trimmed.lowercased())
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: trimmed))
        }

        for candidate in [deviceId, canonicalPeerId, runtimePeerId, presentationPeerId] {
            insertAliases(candidate)
        }

        var seedAliases = aliases
        for (deviceId, device) in lastKnownDevices {
            let deviceAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
                .union(PeerIdentityAliasResolver.aliasKeys(for: device))
            guard !deviceAliases.isDisjoint(with: seedAliases) else { continue }
            insertAliases(deviceId)
            insertAliases(device.id)
            aliases.formUnion(deviceAliases)
            seedAliases = aliases
        }

        for connection in activeConnections {
            let deviceAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
                .union(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            guard !deviceAliases.isDisjoint(with: seedAliases) else { continue }
            insertAliases(connection.device.id)
            aliases.formUnion(deviceAliases)
            seedAliases = aliases
        }

        return aliases
    }

    private func hasPairingIdentityObservation(
        in observations: [String: PairingIdentityReceiveObservation],
        matching aliases: Set<String>,
        since: Date,
        expectedConnectionGeneration: UUID? = nil,
        expectedSessionId: String? = nil
    ) -> Bool {
        for key in stateKeysMatchingAliases(aliases, keys: observations.keys) {
            if let observation = observations[key],
               observation.observedAt >= since,
               expectedConnectionGeneration.map({ $0 == observation.connectionGeneration }) ?? true,
               expectedSessionId.map({ $0 == observation.sessionId }) ?? true {
                return true
            }
        }
        return false
    }

    private func hasStrictPQCTrustBootstrapMaterial(for peerId: String) async -> Bool {
        let candidates = bootstrapKEMLookupCandidates(for: peerId)
        let kemKeys = await Self.trustedPeerKEMPublicKeysFromAllStores(forAny: candidates)
        guard kemKeys.keys.contains(where: \.isPQCGroup) else {
            return false
        }

        let expandedCandidates = Self.expandedTrustMaterialCandidates(for: candidates)
        let protocolFingerprints = await trustedProtocolFingerprints(forAny: expandedCandidates)
        return !protocolFingerprints.isEmpty
    }

    /// 发送剪贴板内容到指定设备（走已建立的会话密钥加密通道）
    public func sendClipboard(to deviceId: String, data: Data, mimeType: String) async throws {
        try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
        guard let canonicalMIMEType = P2PClipboardMIMEPolicy.canonicalWireValue(
            for: mimeType
        ) else {
            throw P2PError.invalidClipboardPayload
        }
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: true
        ) else { throw P2PError.noSessionKey }
        let deviceId = current.peerId
        // Avoid mixing business traffic during in-band rekey.
        guard !rekeyInProgress.contains(deviceId) else {
            throw P2PError.handshakeAlreadyInProgress
        }

        let message = AppMessage.clipboard(
            .init(mimeType: canonicalMIMEType, dataBase64: data.base64EncodedString())
        )
        let payload = try P2PControlJSONEncoder.encode(message)
        let ciphertext = try skyBridgeCore.encrypt(
            payload,
            sessionKey: current.keys.sendKey
        )
        try requireCurrentAuthenticatedConnection(current.receipt)
        try await send(
            data: ciphertext,
            over: current.receipt.lease.connection,
            timeoutSeconds: Self.lanInteractiveNetworkSubmitTimeoutSeconds,
            operation: "clipboard"
        )
        try requireCurrentAuthenticatedConnection(current.receipt)

        ClipboardManager.shared.recordDeviceSync(
            deviceId: deviceId,
            mimeType: canonicalMIMEType,
            bytes: data.count
        )
    }

    public func sendTextMessage(
        to deviceId: String,
        payload: AppMessage.TextMessagePayload,
        expectedConversationFingerprint: String
    ) async throws {
        let authorityReceipt = try authenticatedTextMessageAuthority(
            forAnyPeerId: deviceId,
            expectedConversationFingerprint: expectedConversationFingerprint
        )
        let current = authorityReceipt.connection
        let currentPeerId = current.lease.peerId
        guard !rekeyInProgress.contains(currentPeerId) else { throw P2PError.noSessionKey }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(AppMessage.textMessage(payload))
        } catch {
            SkyBridgeLogger.shared.error("⛔️ 设备文本消息编码失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.encryptionFailed
        }

        let ciphertext: Data
        do {
            ciphertext = try skyBridgeCore.encrypt(
                encoded,
                sessionKey: authorityReceipt.keys.sendKey
            )
        } catch {
            SkyBridgeLogger.shared.error("⛔️ 设备文本消息加密失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.encryptionFailed
        }

        do {
            try requireCurrentTextMessageAuthority(authorityReceipt)
            try await send(
                data: ciphertext,
                over: current.lease.connection,
                timeoutSeconds: Self.lanInteractiveNetworkSubmitTimeoutSeconds,
                operation: "text-message"
            )
            try requireCurrentTextMessageAuthority(authorityReceipt)
        } catch is CancellationError {
            throw CancellationError()
        } catch P2PError.authenticatedIdentityMismatch {
            throw P2PError.authenticatedIdentityMismatch
        } catch {
            guard isCurrentAuthenticatedConnection(current) else {
                throw P2PError.staleConnectionIncarnation
            }
            SkyBridgeLogger.shared.warning("⚠️ 设备文本消息发送失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.connectionFailed
        }
    }

    /// 广播剪贴板到所有已建立会话的连接
    public func broadcastClipboard(data: Data, mimeType: String) async throws {
        try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
        var attemptedCount = 0
        var firstFailure: Error?
        let peerIDs = connections.keys
        for deviceId in peerIDs {
            try Task.checkCancellation()
            guard exactAuthenticatedSession(
                for: deviceId,
                requireConnectedStatus: true
            ) != nil else { continue }
            attemptedCount += 1
            do {
                try await sendClipboard(to: deviceId, data: data, mimeType: mimeType)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
                SkyBridgeLogger.shared.warning(
                    "⚠️ 剪贴板广播发送失败: peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
            }
        }
        guard attemptedCount > 0 else {
            throw P2PError.noAuthenticatedClipboardRecipients
        }
        if let firstFailure {
            throw firstFailure
        }
    }
    
    private func handleConnectionStateChange(
        _ state: NWConnection.State,
        for device: DiscoveredDevice,
        lease: P2PConnectionLease<NWConnection>
    ) async {
        let runtimePeerId = canonicalPeerLookupKey(device.id)
        let effectiveDevice = canonicalizedDevice(device, canonicalPeerId: runtimePeerId)
        let peerIds = connectionStatePeerIds(for: runtimePeerId)

        guard connections.isCurrent(lease, for: runtimePeerId) else {
            SkyBridgeLogger.shared.info(
                "ℹ️ 忽略旧连接状态回调: \(Self.protocolIdentityLogRedaction) state=\(Self.diagnosticConnectionState(state))"
            )
            smokeInboundTrace(
                "p2p-connection stale-state-ignored peer=\(Self.protocolIdentityLogRedaction) state=\(Self.diagnosticConnectionState(state))"
            )
            return
        }

        switch state {
        case .ready:
            // Transport ready != protocol handshake complete.
            for peerId in peerIds {
                connectionStatusByDeviceId[peerId] = .connecting
                connectionErrorByDeviceId.removeValue(forKey: peerId)
            }
            userInitiatedDisconnects.remove(runtimePeerId)
            lastActivityByDeviceId[runtimePeerId] = Date()
            syncPresentationState(for: runtimePeerId)

        case .waiting(let error):
            for peerId in peerIds {
                connectionStatusByDeviceId[peerId] = .connecting
                connectionErrorByDeviceId[peerId] = userVisibleConnectionError(error)
            }
            SkyBridgeLogger.shared.warning("⏳ 连接等待网络: \(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))")
            
        case .failed(let error):
            guard connections.removeIfOwned(lease, for: runtimePeerId) != nil else {
                return
            }
            invalidatePendingPairingIdentityRequests(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            let detachedArbiterBinding = detachArbiterSessionBinding(
                for: runtimePeerId,
                expectedConnectionGeneration: lease.generation
            )
            let detachedHandshakeDriver = detachHandshakeOperationIfOwned(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            let isPathRecoverySocketFailure = Self.isRecoverablePathRecoverySocketFailure(
                error,
                pathRecoveryScheduled: pathRecoveryTasks[runtimePeerId] != nil,
                recoveryMessageActive: connectionErrorByDeviceId[runtimePeerId] == Self.pathRecoveryInProgressMessage
            )
            if isPathRecoverySocketFailure {
                SkyBridgeLogger.shared.info(
                    "ℹ️ 连接路径恢复中: \(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
            } else {
                SkyBridgeLogger.shared.error("❌ 连接失败: \(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))")
            }
            for peerId in peerIds {
                if isPathRecoverySocketFailure {
                    connectionStatusByDeviceId[peerId] = .connecting
                    connectionErrorByDeviceId[peerId] = Self.pathRecoveryInProgressMessage
                } else {
                    connectionStatusByDeviceId[peerId] = .failed
                    connectionErrorByDeviceId[peerId] = userVisibleConnectionError(error)
                }
            }
            userInitiatedDisconnects.remove(runtimePeerId)
            selectedEndpointDescriptionByDeviceId.removeValue(forKey: runtimePeerId)
            removeSessionKeysIfOwned(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            clearSessionPairingAuthority(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            inboundRekeyRollbackByPeerId.removeValue(forKey: runtimePeerId)
            sharedSecrets.removeValue(forKey: runtimePeerId)
            heartbeatTasks[runtimePeerId]?.cancel()
            heartbeatTasks.removeValue(forKey: runtimePeerId)
            heartbeatOperationByPeerId.removeValue(forKey: runtimePeerId)
            cancelPathRecoveryTask(deviceId: runtimePeerId)
            if !isPathRecoverySocketFailure {
                cancelPeerProtectionRoots(for: runtimePeerId)
            }
            await detachedHandshakeDriver?.cancel()
            _ = await transport?.removeConnection(
                lease.connection,
                for: runtimePeerId,
                leaseSequence: lease.sequence
            )
            if let detachedArbiterBinding {
                await releaseArbiterSessionBinding(detachedArbiterBinding)
            }
            guard connections[runtimePeerId] == nil else { return }
            if isPathRecoverySocketFailure {
                upsertActiveConnection(device: effectiveDevice, status: .connecting)
            } else {
                purgeTerminalConnectionPresentationState(for: runtimePeerId)
            }
            discoveryManager.setConnectionLiveness(for: effectiveDevice, isConnected: false)
            guard connections[runtimePeerId] == nil else {
                return
            }
            scheduleReconnectIfNeeded(deviceId: runtimePeerId)

        case .cancelled:
            guard connections.removeIfOwned(lease, for: runtimePeerId) != nil else {
                return
            }
            invalidatePendingPairingIdentityRequests(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            let detachedArbiterBinding = detachArbiterSessionBinding(
                for: runtimePeerId,
                expectedConnectionGeneration: lease.generation
            )
            let detachedHandshakeDriver = detachHandshakeOperationIfOwned(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            selectedEndpointDescriptionByDeviceId.removeValue(forKey: runtimePeerId)
            removeSessionKeysIfOwned(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            clearSessionPairingAuthority(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            inboundRekeyRollbackByPeerId.removeValue(forKey: runtimePeerId)
            sharedSecrets.removeValue(forKey: runtimePeerId)
            heartbeatTasks[runtimePeerId]?.cancel()
            heartbeatTasks.removeValue(forKey: runtimePeerId)
            heartbeatOperationByPeerId.removeValue(forKey: runtimePeerId)
            cancelPathRecoveryTask(deviceId: runtimePeerId)
            cancelPeerProtectionRoots(for: runtimePeerId)
            await detachedHandshakeDriver?.cancel()
            _ = await transport?.removeConnection(
                lease.connection,
                for: runtimePeerId,
                leaseSequence: lease.sequence
            )
            if let detachedArbiterBinding {
                await releaseArbiterSessionBinding(detachedArbiterBinding)
            }
            guard connections[runtimePeerId] == nil else { return }
            for peerId in peerIds {
                connectionStatusByDeviceId[peerId] = .disconnected
            }
            purgeTerminalConnectionPresentationState(for: runtimePeerId)
            discoveryManager.setConnectionLiveness(for: effectiveDevice, isConnected: false)
            let wasUser = userInitiatedDisconnects.remove(runtimePeerId) != nil
            if !wasUser, connectionErrorByDeviceId[runtimePeerId] == nil {
                connectionErrorByDeviceId[runtimePeerId] = "连接已断开（系统未提供错误原因）"
            }
            if !wasUser, let presentationPeerId = peerIds.last, presentationPeerId != runtimePeerId,
               connectionErrorByDeviceId[presentationPeerId] == nil {
                connectionErrorByDeviceId[presentationPeerId] = "连接已断开（系统未提供错误原因）"
            }
            SkyBridgeLogger.shared.info("⏹️ 连接已取消/断开: \(Self.protocolIdentityLogRedaction) user=\(wasUser)")
            guard connections[runtimePeerId] == nil else {
                return
            }
            if !wasUser {
                scheduleReconnectIfNeeded(deviceId: runtimePeerId)
            }
            
        default:
            break
        }
    }

    private func startHeartbeatIfNeeded(deviceId: String) {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let lease = connections.lease(for: deviceId),
              let keys = sessionKeys[deviceId],
              sessionKeyConnectionGenerationByPeerId[deviceId] == lease.generation,
              connections.isCurrent(lease, for: deviceId) else {
            return
        }
        if let existing = heartbeatOperationByPeerId[deviceId],
           existing.connectionGeneration == lease.generation,
           existing.sessionId == keys.sessionId,
           heartbeatTasks[deviceId] != nil {
            return
        }
        heartbeatTasks[deviceId]?.cancel()
        heartbeatTasks.removeValue(forKey: deviceId)
        heartbeatOperationByPeerId.removeValue(forKey: deviceId)
        let operation = HeartbeatOperation(
            token: UUID(),
            connectionGeneration: lease.generation,
            sessionId: keys.sessionId
        )
        heartbeatOperationByPeerId[deviceId] = operation

        heartbeatTasks[deviceId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.heartbeatOperationByPeerId[deviceId] == operation {
                    self.heartbeatTasks.removeValue(forKey: deviceId)
                    self.heartbeatOperationByPeerId.removeValue(forKey: deviceId)
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(self.heartbeatIntervalSeconds))
                } catch {
                    return
                }
                guard self.isCurrentHeartbeatOperation(operation, for: deviceId),
                      let currentLease = self.connections.lease(for: deviceId),
                      let keySnapshot = self.sessionKeys[deviceId] else {
                    return
                }
                
                // Pause heartbeat during in-band rekey to reduce ciphertext/handshake interleaving.
                if self.rekeyInProgress.contains(deviceId) { continue }

                let now = Date()
                let last = self.lastActivityByDeviceId[deviceId] ?? .distantPast
                if now.timeIntervalSince(last) < self.heartbeatIntervalSeconds { continue }
                let serviceHints = self.localPeerServiceHints()

                do {
                    let snapshot = AppleMobileDeviceIdentity.currentSnapshot()
                    let localId = try self.localStableDeviceIdentifier()
                    let identity = AuthenticationManager.instance.remoteControlSecurityIdentityMetadata
                    
                    let message = AppMessage.heartbeat(.init(
                        sentAt: now,
                        deviceId: localId,
                        deviceName: snapshot.deviceName,
                        modelName: snapshot.modelName,
                        platform: snapshot.platformName,
                        osVersion: snapshot.osVersion,
                        chip: snapshot.chip,
                        accountDisplayName: identity.accountDisplayName,
                        nebulaId: identity.nebulaId,
                        capabilities: serviceHints.capabilities,
                        fileTransferPort: serviceHints.fileTransferPort,
                        remoteControlPort: serviceHints.remoteControlPort
                    ))
                    let payload = try JSONEncoder().encode(message)
                    let ciphertext = try self.skyBridgeCore.encrypt(
                        payload,
                        sessionKey: keySnapshot.sendKey
                    )
                    guard self.isCurrentHeartbeatOperation(operation, for: deviceId),
                          currentLease.connection === self.connections[deviceId] else {
                        return
                    }
                    try await self.send(
                        data: ciphertext,
                        over: currentLease.connection,
                        timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
                        operation: "heartbeat"
                    )
                    guard self.isCurrentHeartbeatOperation(operation, for: deviceId) else {
                        return
                    }
                    self.lastActivityByDeviceId[deviceId] = now
                } catch {
                    guard self.isCurrentHeartbeatOperation(operation, for: deviceId) else {
                        return
                    }
                    self.connectionErrorByDeviceId[deviceId] = self.userVisibleConnectionError(error)
                }
            }
        }
    }

    private func isCurrentHeartbeatOperation(
        _ expected: HeartbeatOperation,
        for deviceId: String
    ) -> Bool {
        guard heartbeatOperationByPeerId[deviceId] == expected,
              let lease = connections.lease(for: deviceId),
              lease.generation == expected.connectionGeneration,
              connections.isCurrent(lease, for: deviceId),
              sessionKeyConnectionGenerationByPeerId[deviceId]
                == expected.connectionGeneration,
              sessionKeys[deviceId]?.sessionId == expected.sessionId else {
            return false
        }
        return true
    }

    private enum PathRecoveryReason: String {
        case viabilityLost = "viability_lost"
        case betterPath = "better_path"
    }

    private func schedulePathRecoveryIfNeeded(deviceId: String, reason: PathRecoveryReason) {
        guard !userInitiatedDisconnects.contains(deviceId) else { return }
        guard pathRecoveryTasks[deviceId] == nil else { return }
        guard let connectionLease = connections.lease(for: deviceId) else { return }

        guard let selectedEndpoint = selectedEndpointDescriptionByDeviceId[deviceId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedEndpoint.isEmpty else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ 跳过路径恢复：peer=\(deviceId) reason=\(reason.rawValue) missing_selected_endpoint"
            )
            return
        }
        let normalizedSelectedEndpoint = selectedEndpoint.lowercased()
        let shouldRecover: Bool
        switch reason {
        case .viabilityLost:
            shouldRecover = true
        case .betterPath:
            shouldRecover = !normalizedSelectedEndpoint.contains("service")
        }
        guard shouldRecover else { return }

        if reason == .betterPath,
           let deferralReason = criticalActivityDeferralReason(for: deviceId) {
            let now = Date()
            let deferredSince = betterPathRecoveryDeferredSince[deviceId] ?? now
            betterPathRecoveryDeferredSince[deviceId] = deferredSince
            let elapsed = now.timeIntervalSince(deferredSince)

            guard elapsed < betterPathRecoveryMaxDeferralSeconds else {
                betterPathRecoveryDeferredSince.removeValue(forKey: deviceId)
                SkyBridgeLogger.shared.info(
                    "ℹ️ 跳过 betterPath 路径恢复: peer=\(deviceId) deferred_by=\(deferralReason) elapsed=\(Int(elapsed))s"
                )
                return
            }

            SkyBridgeLogger.shared.info(
                "⏸️ 延迟 betterPath 路径恢复: peer=\(deviceId) deferred_by=\(deferralReason) retryIn=\(Int(betterPathRecoveryDeferIntervalSeconds))s"
            )
            let token = UUID()
            pathRecoveryTaskTokens[deviceId] = token
            pathRecoveryTasks[deviceId] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(self?.betterPathRecoveryDeferIntervalSeconds ?? 5))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.pathRecoveryTaskTokens[deviceId] == token,
                      !self.userInitiatedDisconnects.contains(deviceId) else { return }
                self.finishPathRecoveryTask(deviceId: deviceId, token: token)
                self.schedulePathRecoveryIfNeeded(deviceId: deviceId, reason: reason)
            }
            return
        }

        betterPathRecoveryDeferredSince.removeValue(forKey: deviceId)
        let token = UUID()
        pathRecoveryTaskTokens[deviceId] = token
        pathRecoveryTasks[deviceId] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard let self else { return }
            defer {
                self.finishPathRecoveryTask(deviceId: deviceId, token: token)
            }
            guard self.pathRecoveryTaskTokens[deviceId] == token,
                  !self.userInitiatedDisconnects.contains(deviceId),
                  self.connections.isCurrent(connectionLease, for: deviceId) else { return }
            guard let lastKnown = self.lastKnownDevices[deviceId] else { return }

            let refreshed = self.resolveLatestConnectableDevice(from: lastKnown)
            self.lastKnownDevices[deviceId] = refreshed
            self.connectionErrorByDeviceId[deviceId] = Self.pathRecoveryInProgressMessage
            SkyBridgeLogger.shared.info(
                "🔄 触发路径恢复: peer=\(deviceId) reason=\(reason.rawValue) target=\(refreshed.id)"
            )
            connectionLease.connection.cancel()
        }
    }

    private func criticalActivityDeferralReason(for deviceId: String) -> String? {
        let transferManager = FileTransferManager.instance
        if transferManager.isTransferring || !transferManager.activeTransfers.isEmpty {
            return "file_transfer"
        }

        let remoteDesktop = RemoteDesktopManager.instance
        if remoteDesktop.isStreaming {
            return "remote_desktop"
        }
        switch remoteDesktop.state {
        case .connecting, .connected, .streaming:
            return "remote_desktop"
        case .disconnected, .error:
            break
        }
        if let current = remoteDesktop.currentConnection,
           current.device.id == deviceId {
            return "remote_desktop"
        }

        return nil
    }

    private func scheduleReconnectIfNeeded(deviceId: String, delayOverrideSeconds: Double? = nil) {
        guard !userInitiatedDisconnects.contains(deviceId) else { return }
        guard reconnectTasks[deviceId] == nil else { return }
        guard let device = lastKnownDevices[deviceId] else { return }
        
        // Avoid reconnect storms when we're awaiting explicit pairing/trust approval or KEM key provisioning.
        if let err = connectionErrorByDeviceId[deviceId],
           (err.contains("缺少对端 PQC KEM 公钥")
            || err.contains("missingPeerKEMPublicKey")
            || err.contains("等待对端批准")) {
            return
        }

        if reconnectSuppressedDeviceIds.contains(deviceId) {
            return
        }

        if bootstrapRekeyTasks[deviceId] != nil
            || pendingPairingTrustRequest?.peerId == deviceId {
            return
        }

        let attempt = min(reconnectAttempts[deviceId] ?? 0, maxReconnectAttempts)
        if attempt >= maxReconnectAttempts { return }
        reconnectAttempts[deviceId] = attempt + 1

        let computedDelay = min(30.0, pow(2.0, Double(attempt)))
        let delay = min(60.0, max(delayOverrideSeconds ?? computedDelay, computedDelay))
        let token = UUID()
        reconnectTaskTokens[deviceId] = token
        reconnectTasks[deviceId] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            guard self.reconnectTaskTokens[deviceId] == token else { return }
            self.finishReconnectTask(deviceId: deviceId, token: token)
            guard !self.userInitiatedDisconnects.contains(deviceId),
                  !self.reconnectSuppressedDeviceIds.contains(deviceId),
                  self.connections[deviceId] == nil else { return }
            do {
                try await self.connect(to: device)
                self.reconnectAttempts.removeValue(forKey: deviceId)
            } catch {
                self.connectionErrorByDeviceId[deviceId] = self.userVisibleConnectionError(error)
                self.scheduleReconnectIfNeeded(deviceId: deviceId)
            }
        }
    }

    private func finishReconnectTask(deviceId: String, token: UUID) {
        guard reconnectTaskTokens[deviceId] == token else { return }
        reconnectTasks.removeValue(forKey: deviceId)
        reconnectTaskTokens.removeValue(forKey: deviceId)
    }

    private func finishPathRecoveryTask(deviceId: String, token: UUID) {
        guard pathRecoveryTaskTokens[deviceId] == token else { return }
        pathRecoveryTasks.removeValue(forKey: deviceId)
        pathRecoveryTaskTokens.removeValue(forKey: deviceId)
    }

    private func cancelReconnectTask(deviceId: String) {
        reconnectTasks.removeValue(forKey: deviceId)?.cancel()
        reconnectTaskTokens.removeValue(forKey: deviceId)
    }

    private func cancelPathRecoveryTask(deviceId: String) {
        pathRecoveryTasks.removeValue(forKey: deviceId)?.cancel()
        pathRecoveryTaskTokens.removeValue(forKey: deviceId)
    }

    nonisolated static func isRecoverablePathRecoverySocketFailure(
        _ error: NWError,
        pathRecoveryScheduled: Bool,
        recoveryMessageActive: Bool
    ) -> Bool {
        guard pathRecoveryScheduled || recoveryMessageActive else { return false }
        guard case .posix(.ENOTCONN) = error else { return false }
        return true
    }

    private func handleStalePeerKEMFailureIfNeeded(
        _ error: Error,
        for device: DiscoveredDevice
    ) async -> Bool {
        guard isLikelyStalePeerKEMFailure(error),
              await trustedPeerKEM(for: device) != nil else {
            return false
        }

        await clearStalePeerKEMTrustPreservingIdentity(for: device)
        let runtimePeerId = canonicalPeerLookupKey(device.id)
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            reconnectSuppressedDeviceIds.insert(peerId)
        }
        currentHandshakeState = "PQC KEM 缓存已清除，协议身份 pin 已保留，但本次 SKR-1 signed LAN refresh 未能完成"

        let message = "🔐 对端 PQC KEM 公钥疑似已变更，本地 stale KEM 已清除，协议身份 pin 已保留；当前不会自动降级到 Classic，也不会继续伪成功。stage=kem_refresh 未完成，需暴露失败原因后再恢复。"
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            connectionErrorByDeviceId[peerId] = message
        }
        SkyBridgeLogger.shared.warning(
            "🔐 stale peer KEM detected and cleared: peer=\(Self.protocolIdentityLogRedaction) preserveProtocolIdentity=1 nextStage=kem_refresh err=\(Self.protocolIdentityLogRedaction)"
        )
        return true
    }

    private func recoverStalePeerKEMWithSignedLANRefresh(
        _ error: Error,
        for device: DiscoveredDevice
    ) async throws -> Bool {
        guard isLikelyStalePeerKEMFailure(error),
              await trustedPeerKEM(for: device) != nil else {
            return false
        }

        await clearStalePeerKEMTrustPreservingIdentity(for: device)
        let runtimePeerId = canonicalPeerLookupKey(device.id)
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            reconnectSuppressedDeviceIds.insert(peerId)
        }

        let candidates = peerKEMLookupCandidates(for: device)
        let pinnedFingerprints = await trustedProtocolFingerprints(forAny: candidates)
        guard !pinnedFingerprints.isEmpty else {
            let message =
                "messageBPayloadAuthenticationFailed 后进入 stage=kem_refresh，但缺少 pinned protocol identity；" +
                "reason=missing_pinned_identity_requires_oob oob=short_authentication_string。当前不会 classic fallback，也不会继续伪成功。"
            currentHandshakeState = message
            lastError = message
            let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=stale-kem-refresh reason=missing_pinned_identity_requires_oob pinnedProtocolIdentity=0 lifecycle=stale-kem>failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: preferredStrictPQCHandshakeTargetSuite()?.rawValue ?? "PQC"))
        }

        let preferredTargetSuite = preferredStrictPQCHandshakeTargetSuite()
        let startLine = "🔐 SKR-1 signed LAN KEM refresh after stale KEM: peer=\(Self.protocolIdentityLogRedaction) stage=stale-kem-refresh pinnedProtocolIdentity=1 failure=messageBPayloadAuthenticationFailed lifecycle=stale-kem>kem-refresh"
        currentHandshakeState = "PQC KEM 缓存已清除，协议身份 pin 已保留，正在执行 SKR-1 signed LAN refresh"
        SkyBridgeLogger.shared.warning(startLine)
        SignedKEMRefreshSmokeStatusWriter.append(startLine)

        do {
            try await attemptSignedLANKEMRefresh(
                for: device,
                candidates: candidates,
                pinnedProtocolFingerprints: pinnedFingerprints,
                preferredTargetSuite: preferredTargetSuite
            )
        } catch {
            let message =
                "messageBPayloadAuthenticationFailed 后进入 stage=kem_refresh，但 SKR-1 signed LAN refresh 失败：" +
                "reason=redacted。当前不会 classic fallback，也不会继续伪成功。"
            currentHandshakeState = message
            lastError = message
            let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=stale-kem-refresh reason=\(Self.protocolIdentityLogRedaction) pinnedProtocolIdentity=1 lifecycle=stale-kem>failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            throw error
        }

        let refreshedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates)
        let refreshedSuites = Self.signedRefreshEvidenceSuites(refreshedEvidence)
        guard Self.canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: refreshedSuites,
            preferredTargetSuite: preferredTargetSuite
        ) else {
            let message =
                "SKR-1 signed LAN refresh 完成，但 strict PQC 目标 suite 仍未满足：" +
                "expected=\(preferredTargetSuite?.rawValue ?? "PQC") importedSuites=\(refreshedSuites.map(\.rawValue).sorted().joined(separator: ","))。"
            currentHandshakeState = message
            lastError = message
            let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=stale-kem-refresh reason=strict-suite-unsatisfied pinnedProtocolIdentity=1 lifecycle=stale-kem>failed"
            SkyBridgeLogger.shared.warning(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: preferredTargetSuite?.rawValue ?? "PQC"))
        }

        currentHandshakeState = "SKR-1 signed LAN refresh 已完成，正在重新发起 strict PQC/X-Wing 握手"
        SkyBridgeLogger.shared.info(
            "🔐 SKR-1 stale KEM recovery imported trusted KEM; retrying strict PQC handshake: peer=\(Self.protocolIdentityLogRedaction) suites=\(refreshedSuites.map(\.rawValue).sorted().joined(separator: ","))"
        )
        return true
    }

    private func isLikelyStalePeerKEMFailure(_ error: Error) -> Bool {
        Self.isLikelyStalePeerKEMCryptoFailure(error)
    }

    static func isLikelyStalePeerKEMCryptoFailure(_ error: Error) -> Bool {
        P2PHandshakeErrorFormatter.isLikelyStalePeerKEMCryptoFailure(error)
    }

    public func repairP2PTrustForTrustedDevice(deviceIds rawDeviceIds: [String]) async {
        let candidates = Self.expandedTrustMaterialCandidates(for: rawDeviceIds)
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            await KEMTrustStore.shared.clear(deviceId: candidate)
            lastPairingIdentityExchangeSentAt.removeValue(forKey: candidate)
            lastPairingIdentityExchangeReceivedAt.removeValue(forKey: candidate)
            lastPairingIdentityBootstrapReadyAt.removeValue(forKey: candidate)
            lastAcceptedPairingIdentityDeviceIdByPeerId.removeValue(forKey: candidate)
        }
        SkyBridgeLogger.shared.info(
            "🔧 已修复 P2P 信任材料: clearedKEM=1 preserveProtocolIdentity=1 candidates=\(candidates.prefix(6).joined(separator: ","))"
        )
    }

    private func clearStalePeerKEMTrustPreservingIdentity(for device: DiscoveredDevice) async {
        let candidates = Self.expandedTrustMaterialCandidates(for: peerKEMLookupCandidates(for: device))
        for candidate in candidates {
            await KEMTrustStore.shared.clear(deviceId: candidate)
            lastPairingIdentityExchangeSentAt.removeValue(forKey: candidate)
            lastPairingIdentityExchangeReceivedAt.removeValue(forKey: candidate)
            lastPairingIdentityBootstrapReadyAt.removeValue(forKey: candidate)
            lastAcceptedPairingIdentityDeviceIdByPeerId.removeValue(forKey: candidate)
        }
    }

    private func upsertActiveConnection(device: DiscoveredDevice, status: ConnectionStatus) {
        let resolvedDevice = resolvedActiveConnectionDevice(from: device)
        let resolvedAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))

        if let index = activeConnections.firstIndex(where: { connection in
            if connection.device.id == resolvedDevice.id {
                return true
            }
            let existingAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return !resolvedAliases.isEmpty && !existingAliases.isDisjoint(with: resolvedAliases)
        }) {
            let existing = activeConnections[index]
            activeConnections[index] = Connection(
                id: existing.id,
                device: resolvedDevice,
                status: status,
                encryptionType: existing.encryptionType,
                latency: existing.latency,
                bandwidth: existing.bandwidth,
                connectedAt: existing.connectedAt
            )
            return
        }
        activeConnections.append(Connection(device: resolvedDevice, status: status))
    }

    private func connectionAliasSet(for runtimePeerId: String) -> Set<String> {
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))

        if let runtimeDevice = lastKnownDevices[runtimePeerId] {
            aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: runtimeDevice))
        }
        if presentationPeerId != runtimePeerId,
           let presentationDevice = lastKnownDevices[presentationPeerId] {
            aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: presentationDevice))
        }

        for connection in activeConnections {
            let connectionAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            guard !connectionAliases.isEmpty,
                  !connectionAliases.isDisjoint(with: aliases) else {
                continue
            }
            aliases.formUnion(connectionAliases)
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
        }

        return aliases
    }

    private func stateKeysMatchingAliases<S: Sequence>(
        _ aliases: Set<String>,
        keys: S
    ) -> [String] where S.Element == String {
        guard !aliases.isEmpty else { return [] }
        return keys.filter { key in
            let keyAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: key))
            return !keyAliases.isDisjoint(with: aliases)
        }
    }

    private func connectInFlightAliases(for device: DiscoveredDevice, runtimePeerId: String) -> Set<String> {
        var aliases = connectionAliasSet(for: runtimePeerId)
        aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        aliases.insert(device.id)
        aliases.insert(runtimePeerId)
        aliases.insert(presentationPeerId(for: runtimePeerId))
        return aliases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func matchingInFlightConnectKey(for device: DiscoveredDevice, runtimePeerId: String) -> String? {
        let aliases = connectInFlightAliases(for: device, runtimePeerId: runtimePeerId)
        return inFlightConnectAliasesByPeerId.first { key, existingAliases in
            key == runtimePeerId || !existingAliases.isDisjoint(with: aliases)
        }?.key
    }

    @discardableResult
    private func registerInFlightConnect(for device: DiscoveredDevice, runtimePeerId: String) -> String {
        let aliases = connectInFlightAliases(for: device, runtimePeerId: runtimePeerId)
        let existingKey = matchingInFlightConnectKey(for: device, runtimePeerId: runtimePeerId) ?? runtimePeerId
        inFlightConnectAliasesByPeerId[existingKey, default: []].formUnion(aliases)
        return existingKey
    }

    private func waitForInFlightConnect(_ key: String) async throws {
        try Task.checkCancellation()
        guard (inFlightConnectWaitersByPeerId[key]?.count ?? 0)
                < Self.maximumInFlightConnectWaitersPerPeer else {
            throw P2PError.tooManyConcurrentConnections
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    inFlightConnectWaitersByPeerId[key, default: []].append(
                        InFlightConnectWaiter(id: id, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelInFlightConnectWaiter(key: key, id: id)
            }
        }
    }

    private func cancelInFlightConnectWaiter(key: String, id: UUID) {
        guard var waiters = inFlightConnectWaitersByPeerId[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            inFlightConnectWaitersByPeerId.removeValue(forKey: key)
        } else {
            inFlightConnectWaitersByPeerId[key] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishInFlightConnect(_ key: String) {
        inFlightConnectAliasesByPeerId.removeValue(forKey: key)
        let waiters = inFlightConnectWaitersByPeerId.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func cancelPeerProtectionRoots(for runtimePeerId: String) {
        let aliases = connectionAliasSet(for: runtimePeerId)

        for key in stateKeysMatchingAliases(aliases, keys: reconnectTasks.keys) {
            cancelReconnectTask(deviceId: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: pathRecoveryTasks.keys) {
            cancelPathRecoveryTask(deviceId: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: heartbeatTasks.keys) {
            heartbeatTasks[key]?.cancel()
            heartbeatTasks.removeValue(forKey: key)
            heartbeatOperationByPeerId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: bootstrapRekeyTasks.keys) {
            bootstrapRekeyTasks[key]?.cancel()
            bootstrapRekeyTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: reconnectAttempts.keys) {
            reconnectAttempts.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys) {
            rekeyStatusByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: rekeyInProgress) {
            rekeyInProgress.remove(key)
        }
    }

    private func purgeTerminalConnectionPresentationState(for runtimePeerId: String) {
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)

        activeConnections.removeAll { connection in
            let connectionAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return !connectionAliases.isDisjoint(with: aliases)
        }

        for key in stateKeysMatchingAliases(aliases, keys: negotiatedSuiteByDeviceId.keys) {
            negotiatedSuiteByDeviceId.removeValue(forKey: key)
        }

        for key in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys) {
            rekeyStatusByDeviceId.removeValue(forKey: key)
        }

        for key in stateKeysMatchingAliases(aliases, keys: connectionStatusByDeviceId.keys)
            where key != runtimePeerId && key != presentationPeerId {
            connectionStatusByDeviceId.removeValue(forKey: key)
        }

        for key in stateKeysMatchingAliases(aliases, keys: connectionErrorByDeviceId.keys)
            where key != runtimePeerId && key != presentationPeerId {
            connectionErrorByDeviceId.removeValue(forKey: key)
        }

        peerPresentationIdByRuntimePeerId.removeValue(forKey: runtimePeerId)
    }

    private func makeActiveConnectionDevice(peerId: String, connection: NWConnection?) -> DiscoveredDevice {
        if let discovered = discoveryManager.discoveredDevices.first(where: { $0.id == peerId }) {
            return discovered
        }

        let endpointAddress = endpointHostAddress(from: connection)
        let bonjour = parseBonjourPeerIdentifier(peerId)
        let fallbackName = bonjour?.name ?? endpointAddress ?? peerId

        var services: [String] = []
        if bonjour != nil {
            services.append(DiscoveryServiceType.skybridge.rawValue)
        }

        let provisional = DiscoveredDevice(
            id: peerId,
            name: fallbackName,
            bonjourServiceName: BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(bonjour?.name),
            modelName: "Unknown",
            platform: .macOS,
            osVersion: "Unknown",
            ipAddress: endpointAddress,
            bonjourServiceType: bonjour != nil ? DiscoveryServiceType.skybridge.rawValue : nil,
            bonjourServiceDomain: bonjour?.domain,
            services: services,
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: false,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        return resolvedActiveConnectionDevice(from: provisional)
    }

    private func resolvedActiveConnectionDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        let canonical = discoveryManager.canonicalDiscoveredDevice(for: device) ?? device
        let resolved = resolveLatestConnectableDevice(from: canonical)
        let enriched = enrichActiveConnectionDeviceMetadata(for: resolved, fallback: device)
        let resolvedServices = Set(enriched.services)
        let inputServices = Set(device.services)
        let isResolvedRicher =
            enriched.id != device.id
            || enriched.remoteControlPort != nil
            || enriched.fileTransferPort != nil
            || enriched.ipAddress != nil
            || enriched.bonjourServiceName != nil
            || enriched.supportsRemoteControl
            || enriched.supportsFileTransfer
            || resolvedServices.count > inputServices.count
            || enriched.portMap.count > device.portMap.count

        return isResolvedRicher ? enriched : device
    }

    public func activePeerHostAddress(for device: DiscoveredDevice) -> String? {
        let resolvedDevice = resolvedActiveConnectionDevice(from: device)
        if let ipAddress = connectableAddress(for: resolvedDevice) {
            return ipAddress
        }

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
        for connection in activeConnections {
            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            guard !targetAliases.isEmpty,
                  !candidateAliases.isDisjoint(with: targetAliases) else {
                continue
            }

            if let ipAddress = connectableAddress(for: connection.device) {
                return ipAddress
            }

            let runtimePeerId = runtimePeerId(forAnyPeerId: connection.device.id)
            if let ipAddress = connectableAddress(endpointHostAddress(from: connections[runtimePeerId])) {
                return ipAddress
            }
        }

        let runtimePeerId = runtimePeerId(forAnyPeerId: resolvedDevice.id)
        return connectableAddress(endpointHostAddress(from: connections[runtimePeerId]))
    }

    public func resolvedPeerDevice(for device: DiscoveredDevice) -> DiscoveredDevice {
        let runtimePeerId = runtimePeerId(forAnyPeerId: device.id)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)

        if let presented = lastKnownDevices[presentationPeerId] {
            return resolvedActiveConnectionDevice(from: presented)
        }
        if let runtime = lastKnownDevices[runtimePeerId] {
            return resolvedActiveConnectionDevice(from: runtime)
        }

        if let active = activeConnections.first(where: { connection in
            let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return connection.device.id == device.id
                || (!targetAliases.isEmpty && !candidateAliases.isDisjoint(with: targetAliases))
        })?.device {
            return resolvedActiveConnectionDevice(from: active)
        }

        return resolvedActiveConnectionDevice(from: device)
    }

    public func resolvedConnectionStatus(for device: DiscoveredDevice) -> ConnectionStatus? {
        // A current authenticated lease is stronger than terminal presentation
        // state retained under a previously promoted stable identity. Resolve it
        // before consulting alias-scoped UI caches, while keeping unauthenticated
        // active-connection snapshots unable to override a strong failure.
        if currentAuthenticatedSession(
            forAnyPeerId: device.id,
            requireConnectedStatus: true
        ) != nil {
            return .connected
        }

        let resolvedDevice = resolvedPeerDevice(for: device)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))

        if activeConnections.contains(where: { connection in
            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return !candidateAliases.isDisjoint(with: targetAliases)
        }) {
            return .connected
        }

        var matchedStatuses: [ConnectionStatus] = []
        if let direct = connectionStatusByDeviceId[device.id] {
            matchedStatuses.append(direct)
        }

        if !targetAliases.isEmpty {
            matchedStatuses.append(contentsOf: connectionStatusByDeviceId.compactMap { key, value in
                let keyAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: key))
                return keyAliases.isDisjoint(with: targetAliases) ? nil : value
            })
        }

        if !matchedStatuses.isEmpty {
            return bestResolvedConnectionStatus(from: matchedStatuses)
        }

        return nil
    }

    public func resolvedNegotiatedSuite(for device: DiscoveredDevice) -> CryptoSuite? {
        let resolvedDevice = resolvedPeerDevice(for: device)
        return getNegotiatedSuite(for: resolvedDevice.id)
            ?? getNegotiatedSuite(for: device.id)
    }

    public func resolvedRekeyStatus(for device: DiscoveredDevice) -> RekeyPresentationStatus? {
        let resolvedDevice = resolvedPeerDevice(for: device)
        let runtimePeerId = runtimePeerId(forAnyPeerId: resolvedDevice.id)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)

        let directCandidates = [
            device.id,
            resolvedDevice.id,
            runtimePeerId,
            presentationPeerId
        ]
        for candidate in directCandidates {
            if let status = rekeyStatusByDeviceId[candidate] {
                return status
            }
        }

        let aliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
        for candidate in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys) {
            if let status = rekeyStatusByDeviceId[candidate] {
                return status
            }
        }

        return nil
    }

    public func resolvedConnectionError(for device: DiscoveredDevice) -> String? {
        let resolvedDevice = resolvedPeerDevice(for: device)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))

        switch resolvedConnectionStatus(for: device) {
        case .connected, .connecting, .disconnecting:
            return nil
        default:
            break
        }

        if let direct = connectionErrorByDeviceId[device.id] {
            return direct
        }

        guard !targetAliases.isEmpty else { return nil }
        let matchedErrors = connectionErrorByDeviceId.compactMap { key, value -> String? in
            let keyAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: key))
            return keyAliases.isDisjoint(with: targetAliases) ? nil : value
        }
        return matchedErrors.first
    }

    private func bestResolvedConnectionStatus(from statuses: [ConnectionStatus]) -> ConnectionStatus {
        func priority(for status: ConnectionStatus) -> Int {
            switch status {
            case .connected:
                return 0
            case .connecting:
                return 1
            case .disconnecting:
                return 2
            case .error:
                return 3
            case .failed:
                return 4
            case .disconnected:
                return 5
            }
        }

        return statuses.min(by: { priority(for: $0) < priority(for: $1) }) ?? .disconnected
    }

    private func enrichActiveConnectionDeviceMetadata(
        for device: DiscoveredDevice,
        fallback: DiscoveredDevice
    ) -> DiscoveredDevice {
        var merged = device
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
            .union(PeerIdentityAliasResolver.aliasKeys(for: fallback))
        let targetStrongId = normalizedStrongDeviceId(for: device) ?? normalizedStrongDeviceId(for: fallback)
        let targetIP = sanitizedConnectableAddress(for: device) ?? sanitizedConnectableAddress(for: fallback)
        let targetBonjour = bonjourIdentity(for: device) ?? bonjourIdentity(for: fallback)
        let candidates =
            discoveryManager.discoveredDevices
            + Array(lastKnownDevices.values)
            + activeConnections.map(\.device)

        for candidate in candidates where shouldMergeActiveConnectionMetadata(
            candidate,
            target: merged,
            aliases: targetAliases,
            strongId: targetStrongId,
            ipAddress: targetIP,
            targetBonjourIdentity: targetBonjour
        ) {
            merged = mergeActiveConnectionMetadata(base: merged, update: candidate)
        }

        return merged
    }

    private func shouldMergeActiveConnectionMetadata(
        _ candidate: DiscoveredDevice,
        target: DiscoveredDevice,
        aliases: Set<String>,
        strongId: String?,
        ipAddress: String?,
        targetBonjourIdentity: (name: String, domain: String)?
    ) -> Bool {
        if candidate.id == target.id {
            return true
        }

        if let strongId, normalizedStrongDeviceId(for: candidate) == strongId {
            return true
        }

        if let ipAddress, sanitizedConnectableAddress(for: candidate) == ipAddress {
            return true
        }

        if let targetBonjourIdentity,
           let candidateBonjour = bonjourIdentity(for: candidate),
           candidateBonjour == targetBonjourIdentity {
            return true
        }

        let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
        return !aliases.isEmpty && !candidateAliases.isDisjoint(with: aliases)
    }

    private func mergeActiveConnectionMetadata(
        base: DiscoveredDevice,
        update: DiscoveredDevice
    ) -> DiscoveredDevice {
        var merged = base

        if merged.name.isEmpty || merged.name == "Unknown Device" || merged.name == "未知设备" {
            merged.name = update.name
        }
        if let selectedRoute = BonjourRouteTuple.preferred(
            existing: BonjourRouteTuple(base),
            update: BonjourRouteTuple(update)
        ) {
            selectedRoute.apply(to: &merged)
        } else {
            BonjourRouteTuple.clear(from: &merged)
        }
        if merged.platform == .unknown && update.platform != .unknown {
            merged.platform = update.platform
        }
        if merged.osVersion.isEmpty || merged.osVersion == "Unknown" {
            merged.osVersion = update.osVersion
        }
        if merged.modelName.isEmpty || merged.modelName == "Unknown" {
            merged.modelName = update.modelName
        }
        if merged.ipAddress == nil {
            merged.ipAddress = update.ipAddress
        }

        for service in update.services where !merged.services.contains(service) {
            merged.services.append(service)
        }
        for (key, value) in update.portMap {
            merged.portMap[key] = value
        }

        let advertisedCapabilityUnion = Set(merged.advertisedCapabilities).union(update.advertisedCapabilities)
        merged.advertisedCapabilities = Array(advertisedCapabilityUnion).sorted()

        let capabilityUnion = Set(merged.capabilities).union(update.capabilities)
        merged.capabilities = Array(capabilityUnion).sorted()

        merged.isTrusted = merged.isTrusted || update.isTrusted
        if merged.publicKey == nil {
            merged.publicKey = update.publicKey
        }
        merged.lastSeen = max(merged.lastSeen, update.lastSeen)

        return merged
    }

    private func bonjourIdentity(for device: DiscoveredDevice) -> (name: String, domain: String)? {
        let parsed = parseBonjourPeerIdentifier(device.id)
        let name = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(device.bonjourServiceName)
            ?? parsed?.name
        let domain = device.bonjourServiceDomain ?? parsed?.domain ?? "local."
        guard let name, !name.isEmpty else { return nil }
        return (name.lowercased(), domain.lowercased())
    }

    private func canonicalPeerLookupKey(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return peerAliasToCanonicalDeviceId[normalized] ?? raw
    }

    private func runtimePeerId(forAnyPeerId peerId: String) -> String {
        let canonicalPeerId = canonicalPeerLookupKey(peerId)
        if connections[canonicalPeerId] != nil {
            return canonicalPeerId
        }

        if let runtimePeerId = peerPresentationIdByRuntimePeerId.first(where: { _, presentationPeerId in
            presentationPeerId == canonicalPeerId
        })?.key,
           connections[runtimePeerId] != nil {
            return runtimePeerId
        }

        let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: canonicalPeerId))

        if let matchedRuntimePeerId = connections.keys.first(where: { candidate in
            let candidateAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: candidate))
            return !candidateAliases.isDisjoint(with: aliases)
        }) {
            return matchedRuntimePeerId
        }

        if let matchedRuntimePeerId = peerPresentationIdByRuntimePeerId.first(where: { runtimePeerId, presentationPeerId in
            let runtimeAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            let presentationAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
            return !runtimeAliases.isDisjoint(with: aliases)
                || !presentationAliases.isDisjoint(with: aliases)
        })?.key {
            return matchedRuntimePeerId
        }

        return canonicalPeerId
    }

    private func runtimePeerIdsMatching(device: DiscoveredDevice) -> [String] {
        let resolvedDevice = resolveLatestConnectableDevice(from: device)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: resolvedDevice.id))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: device.id))

        var runtimePeerIds = Set<String>()

        for candidate in [resolvedDevice.id, device.id] {
            let runtimePeerId = runtimePeerId(forAnyPeerId: candidate)
            if connections[runtimePeerId] != nil {
                runtimePeerIds.insert(runtimePeerId)
            }
        }

        for runtimePeerId in connections.keys {
            let connectionAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            if !connectionAliases.isDisjoint(with: targetAliases) {
                runtimePeerIds.insert(runtimePeerId)
            }
        }

        for connection in activeConnections {
            let connectionAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
            guard !connectionAliases.isDisjoint(with: targetAliases) else { continue }
            let runtimePeerId = runtimePeerId(forAnyPeerId: connection.device.id)
            runtimePeerIds.insert(runtimePeerId)
        }

        for (runtimePeerId, presentationPeerId) in peerPresentationIdByRuntimePeerId {
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
            if !aliases.isDisjoint(with: targetAliases) {
                runtimePeerIds.insert(runtimePeerId)
            }
        }

        if runtimePeerIds.isEmpty {
            let normalizedTargetName = normalizedPresentationName(device.name)
            if !normalizedTargetName.isEmpty {
                for connection in activeConnections where
                    normalizedPresentationName(connection.device.name) == normalizedTargetName
                        && connection.device.platform == device.platform {
                    runtimePeerIds.insert(runtimePeerId(forAnyPeerId: connection.device.id))
                }
            }
        }

        return Array(runtimePeerIds)
    }

    private func purgeStalePresentationState(for device: DiscoveredDevice) -> Bool {
        let resolvedDevice = resolvedPeerDevice(for: device)
        let normalizedTargetName = normalizedPresentationName(resolvedDevice.name)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: resolvedDevice.id))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: device.id))

        var matchingIds = Set<String>()
        matchingIds.insert(device.id)
        matchingIds.insert(resolvedDevice.id)

        for (peerId, candidate) in lastKnownDevices where
            candidate.platform == resolvedDevice.platform &&
            (
                !Set(PeerIdentityAliasResolver.aliasKeys(for: candidate)).isDisjoint(with: targetAliases)
                || (
                    !normalizedTargetName.isEmpty &&
                    normalizedPresentationName(candidate.name) == normalizedTargetName
                )
            ) {
            matchingIds.insert(peerId)
            matchingIds.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
        }

        var removedAny = false
        activeConnections.removeAll { connection in
            let connectionAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
            let nameMatches =
                !normalizedTargetName.isEmpty &&
                normalizedPresentationName(connection.device.name) == normalizedTargetName &&
                connection.device.platform == resolvedDevice.platform
            let matches =
                !connectionAliases.isDisjoint(with: targetAliases)
                || matchingIds.contains(connection.device.id)
                || nameMatches
            if matches {
                removedAny = true
            }
            return matches
        }

        let stateAliases = targetAliases.union(matchingIds.flatMap { PeerIdentityAliasResolver.lookupCandidates(for: $0) })
        for key in stateKeysMatchingAliases(stateAliases, keys: negotiatedSuiteByDeviceId.keys) {
            negotiatedSuiteByDeviceId.removeValue(forKey: key)
            removedAny = true
        }
        for key in stateKeysMatchingAliases(stateAliases, keys: connectionErrorByDeviceId.keys) {
            connectionErrorByDeviceId.removeValue(forKey: key)
            removedAny = true
        }
        for key in stateKeysMatchingAliases(stateAliases, keys: connectionStatusByDeviceId.keys) {
            connectionStatusByDeviceId.removeValue(forKey: key)
            removedAny = true
        }

        for id in matchingIds {
            connectionStatusByDeviceId[id] = .disconnected
            connectionErrorByDeviceId.removeValue(forKey: id)
        }

        for runtimePeerId in peerPresentationIdByRuntimePeerId.keys where
            stateAliases.contains(runtimePeerId)
                || matchingIds.contains(runtimePeerId)
                || stateAliases.contains(peerPresentationIdByRuntimePeerId[runtimePeerId] ?? "") {
            peerPresentationIdByRuntimePeerId.removeValue(forKey: runtimePeerId)
            removedAny = true
        }

        return removedAny
    }

    private func normalizedPresentationName(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "") ?? ""
    }

    private func presentationPeerId(for runtimePeerId: String) -> String {
        peerPresentationIdByRuntimePeerId[runtimePeerId] ?? runtimePeerId
    }

    private func connectionStatePeerIds(for runtimePeerId: String) -> [String] {
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        if presentationPeerId == runtimePeerId {
            return [runtimePeerId]
        }
        return [runtimePeerId, presentationPeerId]
    }

    private func resolvedNegotiatedSuite(forAnyPeerId peerId: String) -> CryptoSuite? {
        if let current = currentAuthenticatedSession(
            forAnyPeerId: peerId,
            requireConnectedStatus: false
        ) {
            return current.keys.negotiatedSuite
        }
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        guard let lease = connections.lease(for: runtimePeerId),
              let rollback = inboundRekeyRollbackByPeerId[runtimePeerId],
              rollback.connectionGeneration == lease.generation else {
            return nil
        }
        return rollback.previousKeys.negotiatedSuite
    }

    private func preferredRekeyTargetSuite(offeredSuites: [CryptoSuite] = []) -> String? {
        if let preferredOfferedPQC = offeredSuites.first(where: { $0.isPQCGroup }) {
            return preferredOfferedPQC.rawValue
        }
        if let firstOffered = offeredSuites.first {
            return firstOffered.rawValue
        }

        let capability = CryptoProviderFactory.detectCapability()
        guard capability.hasApplePQC || capability.hasLiboqs else {
            return nil
        }
        let provider = CryptoProviderFactory.make(policy: effectiveSelectionPolicy(enforcePQC: true))
        return Self.preferredBootstrapRekeyTargetSuite(using: provider)?.rawValue
    }

    private func setRekeyPresentationStatus(
        for runtimePeerId: String,
        fromSuite: String,
        toSuite: String,
        startedAt: Date = Date()
    ) {
        let normalizedFrom = fromSuite.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTo = toSuite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFrom.isEmpty, !normalizedTo.isEmpty else { return }

        let status = RekeyPresentationStatus(
            fromSuite: normalizedFrom,
            toSuite: normalizedTo,
            startedAt: startedAt
        )
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            rekeyStatusByDeviceId[peerId] = status
        }
    }

    private func clearRekeyPresentationStatus(for runtimePeerId: String) {
        let aliases = connectionAliasSet(for: runtimePeerId)
        for key in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys) {
            rekeyStatusByDeviceId.removeValue(forKey: key)
        }

        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            rekeyStatusByDeviceId.removeValue(forKey: peerId)
        }
    }

    private func clearRekeyInProgress(for runtimePeerId: String) {
        let aliases = connectionAliasSet(for: runtimePeerId)
        for key in stateKeysMatchingAliases(aliases, keys: rekeyInProgress) {
            rekeyInProgress.remove(key)
        }

        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            rekeyInProgress.remove(peerId)
        }
    }

    private func platform(from raw: String?) -> DevicePlatform {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return .unknown
        }

        switch normalized {
        case "ios":
            return .iOS
        case "ipados":
            return .iPadOS
        case "macos", "mac":
            return .macOS
        case "android":
            return .android
        case "windows", "win":
            return .windows
        case "linux":
            return .linux
        default:
            return .unknown
        }
    }

    private func registerRuntimePeerAliases(runtimePeerId: String, aliases: [String]) {
        for alias in aliases {
            let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            peerAliasToCanonicalDeviceId[normalized] = runtimePeerId
        }
    }

    private func syncPresentationState(
        for runtimePeerId: String,
        preferredDevice: DiscoveredDevice? = nil
    ) {
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        guard presentationPeerId != runtimePeerId else { return }

        if let status = connectionStatusByDeviceId[runtimePeerId] {
            connectionStatusByDeviceId[presentationPeerId] = status
        }

        if let error = connectionErrorByDeviceId[runtimePeerId] {
            connectionErrorByDeviceId[presentationPeerId] = error
        } else {
            connectionErrorByDeviceId.removeValue(forKey: presentationPeerId)
        }

        if let suite = negotiatedSuiteByDeviceId[runtimePeerId] {
            negotiatedSuiteByDeviceId[presentationPeerId] = suite
        } else {
            negotiatedSuiteByDeviceId.removeValue(forKey: presentationPeerId)
        }

        if let rekeyStatus = rekeyStatusByDeviceId[runtimePeerId] {
            rekeyStatusByDeviceId[presentationPeerId] = rekeyStatus
        } else {
            rekeyStatusByDeviceId.removeValue(forKey: presentationPeerId)
        }

        if let preferredDevice {
            lastKnownDevices[presentationPeerId] = preferredDevice
            upsertActiveConnection(
                device: preferredDevice,
                status: connectionStatusByDeviceId[runtimePeerId] ?? .connecting
            )
        }
    }

    @discardableResult
    private func promotePeerPresentationIdentityIfNeeded(
        runtimePeerId: String,
        declaredDeviceId: String?,
        deviceName: String? = nil,
        modelName: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil
    ) -> String {
        let runtimePeerId = canonicalPeerLookupKey(runtimePeerId)
        registerRuntimePeerAliases(
            runtimePeerId: runtimePeerId,
            aliases: PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId)
        )

        let presentationPeerId =
            PeerIdentityAliasResolver.persistentDeviceId(from: declaredDeviceId)
            ?? presentationPeerId(for: runtimePeerId)

        peerPresentationIdByRuntimePeerId[runtimePeerId] = presentationPeerId
        registerRuntimePeerAliases(
            runtimePeerId: runtimePeerId,
            aliases: PeerIdentityAliasResolver.lookupCandidates(for: declaredDeviceId)
        )

        let baseDevice =
            lastKnownDevices[presentationPeerId]
            ?? lastKnownDevices[runtimePeerId]
            ?? discoveryManager.discoveredDevices.first(where: { candidate in
                let aliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                let runtimeAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
                let declaredAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: declaredDeviceId))
                return !aliases.isDisjoint(with: runtimeAliases)
                    || !aliases.isDisjoint(with: declaredAliases)
            })
            ?? DiscoveredDevice(
                id: presentationPeerId,
                name: deviceName ?? runtimePeerId,
                modelName: modelName ?? "Unknown",
                platform: self.platform(from: platform),
                osVersion: osVersion ?? "Unknown"
            )

        let mergedDevice = DiscoveredDevice(
            id: presentationPeerId,
            name: (deviceName?.isEmpty == false ? deviceName! : baseDevice.name),
            bonjourServiceName: baseDevice.bonjourServiceName,
            modelName: (modelName?.isEmpty == false ? modelName! : baseDevice.modelName),
            platform: self.platform(from: platform) == .unknown ? baseDevice.platform : self.platform(from: platform),
            osVersion: (osVersion?.isEmpty == false ? osVersion! : baseDevice.osVersion),
            ipAddress: baseDevice.ipAddress,
            bonjourServiceType: baseDevice.bonjourServiceType,
            bonjourServiceDomain: baseDevice.bonjourServiceDomain,
            services: baseDevice.services,
            portMap: baseDevice.portMap,
            signalStrength: baseDevice.signalStrength,
            lastSeen: Date(),
            isConnected: baseDevice.isConnected,
            isTrusted: currentSessionHasExactActiveAuthority(for: runtimePeerId),
            publicKey: baseDevice.publicKey,
            advertisedCapabilities: baseDevice.advertisedCapabilities,
            capabilities: baseDevice.capabilities
        )

        lastKnownDevices[runtimePeerId] = canonicalizedDevice(mergedDevice, canonicalPeerId: runtimePeerId)
        lastKnownDevices[presentationPeerId] = mergedDevice
        syncPresentationState(for: runtimePeerId, preferredDevice: mergedDevice)
        return runtimePeerId
    }

    private func registerCanonicalPeerIdentity(candidate: DiscoveredDevice, primaryPeerId: String) -> String {
        let canonical = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPrimaryPeerId = primaryPeerId.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalId = preferredPrimaryPeerId.isEmpty ? canonical : preferredPrimaryPeerId

        func registerAlias(_ raw: String?) {
            guard let raw else { return }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return }
            peerAliasToCanonicalDeviceId[normalized] = canonicalId
        }

        registerAlias(primaryPeerId)
        registerAlias(canonicalId)
        for alias in PeerIdentityAliasResolver.aliasKeys(for: candidate) {
            registerAlias(alias)
        }
        peerPresentationIdByRuntimePeerId[canonicalId] = peerPresentationIdByRuntimePeerId[canonicalId] ?? canonicalId
        return canonicalId
    }

    private func preferredTrustedPeerIdentifier(for device: DiscoveredDevice) -> String? {
        TrustedDeviceStore.shared.stableIdentifierMatchedTrustedDeviceId(for: device)
    }

    private func canonicalizedDevice(
        _ device: DiscoveredDevice,
        canonicalPeerId: String
    ) -> DiscoveredDevice {
        // Discovery names, endpoint aliases and peer-claimed stable identifiers
        // are not trust evidence. Publish trusted state only while this exact
        // authenticated session presents a unique active raw-key authority.
        let effectiveIsTrusted = currentSessionHasExactActiveAuthority(
            for: canonicalPeerId
        )

        guard device.id != canonicalPeerId else {
            guard effectiveIsTrusted != device.isTrusted else { return device }
            var normalizedDevice = device
            normalizedDevice.isTrusted = effectiveIsTrusted
            return normalizedDevice
        }

        return DiscoveredDevice(
            id: canonicalPeerId,
            name: device.name,
            bonjourServiceName: device.bonjourServiceName,
            modelName: device.modelName,
            platform: device.platform,
            osVersion: device.osVersion,
            ipAddress: device.ipAddress,
            bonjourServiceType: device.bonjourServiceType,
            bonjourServiceDomain: device.bonjourServiceDomain,
            services: device.services,
            portMap: device.portMap,
            signalStrength: device.signalStrength,
            lastSeen: device.lastSeen,
            isConnected: device.isConnected,
            isTrusted: effectiveIsTrusted,
            publicKey: device.publicKey,
            advertisedCapabilities: device.advertisedCapabilities,
            capabilities: device.capabilities
        )
    }

    private func currentSessionHasExactActiveAuthority(for peerId: String) -> Bool {
        guard let authority = currentSessionPairingAuthority(for: peerId),
              let algorithm = ProtocolSigningAlgorithm(
                rawValue: authority.binding.authority.protocolSigningAlgorithm
              ),
              let publicKey = authority.binding.authority.protocolPublicKeyBytes
        else {
            return false
        }
        return TrustedDeviceStore.shared
            .uniqueExactActiveProtocolIdentityAuthorityDeviceId(
                algorithm: algorithm,
                fingerprint: authority.binding.authority.protocolPublicKeyFingerprint,
                publicKey: publicKey
            ) != nil
    }

    private func parseBonjourPeerIdentifier(_ peerId: String) -> (name: String, domain: String)? {
        P2PConnectionEndpointPolicy.parseBonjourPeerIdentifier(peerId)
    }

    private func shouldPreferBonjourSkyBridgeEndpoint(
        for device: DiscoveredDevice,
        bonjourName: String
    ) -> Bool {
        P2PConnectionEndpointPolicy.shouldPreferBonjourSkyBridgeEndpoint(for: device, bonjourName: bonjourName)
    }

    private func isPlausibleSkyBridgeServiceInstanceName(_ raw: String?) -> Bool {
        P2PConnectionEndpointPolicy.isPlausibleSkyBridgeServiceInstanceName(raw)
    }

    private func resolveLatestConnectableDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        var best = device
        if let canonical = discoveryManager.canonicalDiscoveredDevice(for: device) {
            best = preferredConnectableDevice(best, canonical)
        }
        if let trustedResolved = TrustedDeviceStore.shared.resolvedConnectableDevice(for: device) {
            best = preferredConnectableDevice(best, trustedResolved)
        }
        let candidates = deduplicatedConnectableCandidates(
            discoveryManager.discoveredDevices + Array(lastKnownDevices.values) + activeConnections.map(\.device)
        )

        if let exact = candidates.first(where: { $0.id == device.id }) {
            best = preferredConnectableDevice(best, exact)
        }

        if let strongId = normalizedStrongDeviceId(for: device) {
            for candidate in candidates where normalizedStrongDeviceId(for: candidate) == strongId {
                best = preferredConnectableDevice(best, candidate)
            }
        }

        if let sameNameCandidate = uniqueSameNameConnectableCandidate(for: device, candidates: candidates) {
            best = preferredConnectableDevice(best, sameNameCandidate)
        }

        if let targetIP = sanitizedConnectableAddress(for: device) {
            for candidate in candidates where sanitizedConnectableAddress(for: candidate) == targetIP {
                best = preferredConnectableDevice(best, candidate)
            }
        }

        let parsedBonjour = parseBonjourPeerIdentifier(device.id)
        let bonjourName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(device.bonjourServiceName)
            ?? parsedBonjour?.name
        let bonjourDomain = device.bonjourServiceDomain ?? parsedBonjour?.domain ?? "local."
        if let bonjourName, !bonjourName.isEmpty {
            for candidate in candidates where
                candidate.bonjourServiceName == bonjourName
                    && ((candidate.bonjourServiceDomain ?? "local.") == bonjourDomain) {
                best = preferredConnectableDevice(best, candidate)
            }
        }

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
        if !targetAliases.isEmpty {
            for candidate in candidates {
                let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                if !candidateAliases.isDisjoint(with: targetAliases) {
                    best = preferredConnectableDevice(best, candidate)
                }
            }
        }

        if let trustedResolved = TrustedDeviceStore.shared.resolvedConnectableDevice(for: best) {
            best = preferredConnectableDevice(best, trustedResolved)
        }

        return best
    }

    private func resolveConnectableDeviceAwaitingControlRoute(
        from device: DiscoveredDevice
    ) async throws -> DiscoveredDevice {
        var latest = resolveLatestConnectableDevice(from: device)
        guard P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
            for: latest,
            liveBonjourControlEndpoints: DeviceDiscoveryManager.instance
                .liveBonjourServiceEndpoints(for: latest, serviceType: .skybridge)
        ) else {
            return latest
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
            latest = resolveLatestConnectableDevice(from: device)
            if !connectionEndpointCandidates(for: latest).isEmpty {
                SkyBridgeLogger.shared.info(
                    "✅ P2P 控制路由已在多服务发现水合后就绪: peer=\(Self.protocolIdentityLogRedaction)"
                )
                return latest
            }
        }
        try Task.checkCancellation()
        return latest
    }

    private func deduplicatedConnectableCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        P2PConnectionEndpointPolicy.deduplicatedConnectableCandidates(candidates)
    }

    private func preferredConnectableDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        P2PConnectionEndpointPolicy.preferredConnectableDevice(lhs, rhs)
    }

    private func connectableDeviceScore(_ device: DiscoveredDevice) -> Int {
        P2PConnectionEndpointPolicy.connectableDeviceScore(device)
    }

    private func uniqueSameNameConnectableCandidate(
        for device: DiscoveredDevice,
        candidates: [DiscoveredDevice]
    ) -> DiscoveredDevice? {
        P2PConnectionEndpointPolicy.uniqueSameNameConnectableCandidate(for: device, candidates: candidates)
    }

    private func normalizedDeviceNameToken(_ raw: String?) -> String {
        P2PConnectionEndpointPolicy.normalizedDeviceNameToken(raw)
    }

    private func connectionEndpointCandidates(for device: DiscoveredDevice) -> [NWEndpoint] {
        P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: device,
            liveBonjourControlEndpoints: DeviceDiscoveryManager.instance
                .liveBonjourServiceEndpoints(for: device, serviceType: .skybridge)
        )
    }

    private static func signedLANRefreshEndpointClass(_ endpoint: NWEndpoint) -> String {
        P2PConnectionEndpointPolicy.signedLANRefreshEndpointClass(endpoint)
    }

    private func makeConnectionParameters(for endpoint: NWEndpoint) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
        parameters.allowLocalEndpointReuse = true
        if case .service(_, _, _, let observedInterface) = endpoint,
           let observedInterface {
            // The interface came from the same live NWBrowser.Result as the service tuple.
            // Binding it prevents an aggregate Bonjour result from being re-resolved onto a
            // different route (for example en0 after discovery over AWDL).
            parameters.requiredInterface = observedInterface
        }
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        return parameters
    }

    private static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool {
        P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(for: endpoint)
    }

    private func establishReadyConnection(
        to endpoints: [NWEndpoint],
        for device: DiscoveredDevice
    ) async throws -> (NWConnection, NWEndpoint) {
        let result = try await establishReadyConnectionWithMetrics(to: endpoints, for: device)
        return (result.connection, result.endpoint)
    }

    private func establishReadyConnectionWithMetrics(
        to endpoints: [NWEndpoint],
        for device: DiscoveredDevice
    ) async throws -> ReadyConnectionResult {
        var lastError: Error = P2PError.connectionFailed
        var attemptDurationsMs: [Double] = []
        var failedAttemptCount = 0
        let dialReference = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        )

        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            let peerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
            let connection = NWConnection(to: endpoint, using: makeConnectionParameters(for: endpoint))
            let readyGate = ConnectionReadyGate()
            let clock = ContinuousClock()
            let attemptStartedAt = clock.now
            let requiredInterface = Self.connectionAttemptInterfaceToken(endpoint)

            connection.stateUpdateHandler = { [weak connection] state in
                readyGate.onState(state)
                SignedKEMRefreshSmokeStatusWriter.append(
                    "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) state=\(Self.connectionAttemptStateToken(state)) requiredInterface=\(requiredInterface) \(Self.connectionAttemptPathSummary(connection?.currentPath))"
                )
                if case .waiting(let error) = state {
                    SkyBridgeLogger.shared.debug(
                        "⏳ 候选端点等待网络[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                    )
                }
            }
            connection.pathUpdateHandler = { path in
                SignedKEMRefreshSmokeStatusWriter.append(
                    "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) state=path-update requiredInterface=\(requiredInterface) \(Self.connectionAttemptPathSummary(path))"
                )
            }

            SkyBridgeLogger.shared.info(
                "🔗 尝试连接候选端点[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) peerToPeer=\(peerToPeer)"
            )
            SignedKEMRefreshSmokeStatusWriter.append(
                "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) state=start requiredInterface=\(requiredInterface) endpointClass=\(Self.signedLANRefreshEndpointClass(endpoint)) peerToPeer=\(peerToPeer ? 1 : 0)"
            )
            connection.start(queue: queue)

            do {
                try await readyGate.waitReady(timeoutSeconds: 8.0)
                let connectLatencyMs = Self.connectionAttemptMilliseconds(
                    attemptStartedAt.duration(to: clock.now)
                )
                attemptDurationsMs.append(connectLatencyMs)
                connection.stateUpdateHandler = nil
                connection.pathUpdateHandler = nil
                SignedKEMRefreshSmokeStatusWriter.append(
                    "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) terminal=ready requiredInterface=\(requiredInterface) elapsedMs=\(Int(connectLatencyMs.rounded())) \(Self.connectionAttemptPathSummary(connection.currentPath))"
                )
                return ReadyConnectionResult(
                    connection: connection,
                    endpoint: endpoint,
                    attemptCount: attemptDurationsMs.count,
                    failedAttemptCount: failedAttemptCount,
                    connectLatencyMs: connectLatencyMs,
                    selectedEndpointPeerToPeer: peerToPeer,
                    attemptJitterMs: Self.attemptDurationJitterMs(attemptDurationsMs)
                )
            } catch {
                let connectLatencyMs = Self.connectionAttemptMilliseconds(
                    attemptStartedAt.duration(to: clock.now)
                )
                attemptDurationsMs.append(connectLatencyMs)
                failedAttemptCount += 1
                let terminalPath = connection.currentPath
                connection.stateUpdateHandler = nil
                connection.pathUpdateHandler = nil
                connection.cancel()

                if error is CancellationError || Task.isCancelled {
                    SignedKEMRefreshSmokeStatusWriter.append(
                        "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) terminal=task-cancelled requiredInterface=\(requiredInterface) elapsedMs=\(Int(connectLatencyMs.rounded()))"
                    )
                    throw CancellationError()
                }

                let event: ApplePeerConnectivityPolicy.ConnectionEvent =
                    error is ConnectionReadyTimeoutError ? .timedOut : .failed
                let errorDescriptions: [String] = {
                    var descriptions = [
                        String(describing: error),
                        (error as NSError).localizedDescription
                    ]
                    if let timeout = error as? ConnectionReadyTimeoutError,
                       let waitingError = timeout.lastWaitingError {
                        descriptions.append(String(describing: waitingError))
                        descriptions.append(
                            (waitingError as NSError).localizedDescription
                        )
                    }
                    return descriptions
                }()
                let failureCode = ApplePeerConnectivityPolicy
                    .connectionFailureCode(
                        event: event,
                        pathReason: Self.sharedPathUnsatisfiedReason(
                            terminalPath
                        ),
                        errorDescriptions: errorDescriptions
                    )
                lastError = ConnectionAttemptFailure(code: failureCode)
                if let timeout = error as? ConnectionReadyTimeoutError {
                    let waitingError = timeout.lastWaitingError
                        .map(Self.connectionAttemptNetworkErrorToken) ?? "none"
                    SignedKEMRefreshSmokeStatusWriter.append(
                        "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) terminal=timeout requiredInterface=\(requiredInterface) elapsedMs=\(Int(connectLatencyMs.rounded())) lastState=\(timeout.lastState.rawValue) lastWaitingError=\(waitingError) failureCode=\(failureCode.rawValue)"
                    )
                } else {
                    SignedKEMRefreshSmokeStatusWriter.append(
                        "p2p-connect-attempt dialRef=\(dialReference) index=\(index + 1) terminal=failed requiredInterface=\(requiredInterface) elapsedMs=\(Int(connectLatencyMs.rounded())) error=\(Self.connectionAttemptErrorToken(error)) failureCode=\(failureCode.rawValue)"
                    )
                }
                SkyBridgeLogger.shared.warning(
                    "⚠️ 候选端点连接失败[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
            }
        }

        throw lastError
    }

    private nonisolated static func connectionAttemptMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000.0)
            + (Double(components.attoseconds) / 1_000_000_000_000_000.0)
    }

    private nonisolated static func connectionAttemptStateToken(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .waiting: return "waiting"
        case .ready: return "ready"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func connectionAttemptInterfaceToken(_ endpoint: NWEndpoint) -> String {
        guard case .service(_, _, _, let interface) = endpoint,
              let interface else {
            return "unspecified"
        }
        return connectionAttemptInterfaceToken(interface)
    }

    private nonisolated static func connectionAttemptInterfaceToken(_ interface: NWInterface) -> String {
        let name = interface.name.lowercased()
        if name.hasPrefix("awdl") { return "awdl" }
        if name.hasPrefix("p2p") { return "p2p" }
        if name.hasPrefix("utun") { return "vpn" }
        if name.hasPrefix("en") {
            return interface.type == .wiredEthernet ? "wired" : "wifi"
        }
        switch interface.type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func connectionAttemptPathSummary(_ path: NWPath?) -> String {
        guard let path else {
            return "pathStatus=missing pathReason=none pathInterfaces=none"
        }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires-connection"
        @unknown default: status = "unknown"
        }

        let reason: String
        if path.status == .satisfied {
            reason = "none"
        } else {
            switch path.unsatisfiedReason {
            case .notAvailable: reason = "not-available"
            case .cellularDenied: reason = "cellular-denied"
            case .wifiDenied: reason = "wifi-denied"
            case .localNetworkDenied: reason = "local-network-denied"
            case .vpnInactive: reason = "vpn-inactive"
            @unknown default: reason = "unknown"
            }
        }

        let interfaces = Set(path.availableInterfaces.map(connectionAttemptInterfaceToken))
            .sorted()
        return "pathStatus=\(status) pathReason=\(reason) pathInterfaces=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: ","))"
    }

    private nonisolated static func sharedPathUnsatisfiedReason(
        _ path: NWPath?
    ) -> ApplePeerConnectivityPolicy.PathUnsatisfiedReason? {
        guard let path, path.status != .satisfied else { return nil }
        switch path.unsatisfiedReason {
        case .notAvailable:
            return .notAvailable
        case .cellularDenied:
            return .cellularDenied
        case .wifiDenied:
            return .wifiDenied
        case .localNetworkDenied:
            return .localNetworkDenied
        case .vpnInactive:
            return .vpnInactive
        @unknown default:
            return .unknown
        }
    }

    private nonisolated static func connectionAttemptNetworkErrorToken(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix-\(code.rawValue)"
        case .dns(let code): return "dns-\(code)"
        case .tls(let code): return "tls-\(code)"
        case .wifiAware(let code): return "wifi-aware-\(code)"
        @unknown default: return "network-unknown"
        }
    }

    private nonisolated static func connectionAttemptErrorToken(_ error: Error) -> String {
        if let networkError = error as? NWError {
            return connectionAttemptNetworkErrorToken(networkError)
        }
        if error is ConnectionReadyCancelledError {
            return "network-cancelled"
        }
        return "non-network-\((error as NSError).code)"
    }

    private static func attemptDurationJitterMs(_ samples: [Double]) -> Double {
        guard let minValue = samples.min(), let maxValue = samples.max(), samples.count > 1 else {
            return 0.0
        }
        return maxValue - minValue
    }

    private func installTrackedConnection(
        _ connection: NWConnection,
        for peerId: String
    ) throws -> P2PConnectionLease<NWConnection> {
        cancelPathRecoveryTask(deviceId: peerId)
        let previousLease = connections.lease(for: peerId)
        let lease = try connections.install(connection, for: peerId)
        if heartbeatOperationByPeerId[peerId]?.connectionGeneration != lease.generation {
            heartbeatTasks[peerId]?.cancel()
            heartbeatTasks.removeValue(forKey: peerId)
            heartbeatOperationByPeerId.removeValue(forKey: peerId)
        }
        if bootstrapRekeyOperationByPeerId[peerId]?.connectionGeneration != lease.generation {
            bootstrapRekeyTasks[peerId]?.cancel()
            bootstrapRekeyTasks.removeValue(forKey: peerId)
            bootstrapRekeyOperationByPeerId.removeValue(forKey: peerId)
        }
        if handshakeOperationOwnerByPeerId[peerId]?.connectionGeneration != lease.generation {
            handshakeOperationOwnerByPeerId.removeValue(forKey: peerId)
        }
        if let previousLease {
            invalidatePendingPairingIdentityRequests(
                for: peerId,
                connectionGeneration: previousLease.generation
            )
            let detachedDriver = detachHandshakeOperationIfOwned(
                for: peerId,
                connectionGeneration: previousLease.generation
            )
            _ = removeSessionKeysIfOwned(
                for: peerId,
                connectionGeneration: previousLease.generation
            )
            clearSessionPairingAuthority(
                for: peerId,
                connectionGeneration: previousLease.generation
            )
            inboundRekeyRollbackByPeerId.removeValue(forKey: peerId)
            let detachedArbiterBinding = detachArbiterSessionBinding(
                for: peerId,
                expectedConnectionGeneration: previousLease.generation
            )
            if detachedDriver != nil || detachedArbiterBinding != nil {
                Task { @MainActor in
                    await detachedDriver?.cancel()
                    if let detachedArbiterBinding {
                        await self.releaseArbiterSessionBinding(detachedArbiterBinding)
                    }
                }
            }
        }
        if sessionPairingAuthorityByPeerId[peerId]?.connectionGeneration != lease.generation {
            sessionPairingAuthorityByPeerId.removeValue(forKey: peerId)
        }
        return lease
    }

    private func installConnectionObservers(
        _ lease: P2PConnectionLease<NWConnection>,
        for device: DiscoveredDevice
    ) {
        let connection = lease.connection
        connection.viabilityUpdateHandler = { [weak self] viable in
            Task { @MainActor in
                guard let self else { return }
                let peerId = self.canonicalPeerLookupKey(device.id)
                guard self.connections.isCurrent(lease, for: peerId) else { return }
                SkyBridgeLogger.shared.debug("🌐 连接可用性变化：device=\(Self.protocolIdentityLogRedaction) viable=\(viable)")
                if !viable {
                    self.connectionStatusByDeviceId[device.id] = .connecting
                    self.schedulePathRecoveryIfNeeded(
                        deviceId: peerId,
                        reason: .viabilityLost
                    )
                }
            }
        }

        connection.betterPathUpdateHandler = { [weak self] betterPath in
            Task { @MainActor in
                SkyBridgeLogger.shared.debug("🌐 更优路径可用：device=\(Self.protocolIdentityLogRedaction) betterPath=\(betterPath)")
                guard let self, betterPath else { return }
                let peerId = self.canonicalPeerLookupKey(device.id)
                guard self.connections.isCurrent(lease, for: peerId) else { return }
                self.schedulePathRecoveryIfNeeded(
                    deviceId: peerId,
                    reason: .betterPath
                )
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleConnectionStateChange(state, for: device, lease: lease)
            }
        }
    }

    private func isTrackedConnection(_ connection: NWConnection) -> Bool {
        connections.values.contains { $0 === connection }
    }

    private func normalizedStrongDeviceId(for device: DiscoveredDevice) -> String? {
        P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: device)
    }

    private func sanitizedConnectableAddress(for device: DiscoveredDevice) -> String? {
        P2PConnectionEndpointPolicy.sanitizedConnectableAddress(for: device)
    }

    private func connectableAddress(for device: DiscoveredDevice) -> String? {
        P2PConnectionEndpointPolicy.connectableAddress(for: device)
    }

    private func hostAddress(from identifier: String) -> String? {
        P2PConnectionEndpointPolicy.hostAddress(from: identifier)
    }

    private func sanitizedConnectableAddress(_ raw: String?) -> String? {
        P2PConnectionEndpointPolicy.sanitizedConnectableAddress(raw)
    }

    private func connectableAddress(_ raw: String?) -> String? {
        P2PConnectionEndpointPolicy.connectableAddress(raw)
    }

    private func endpointHostAddress(from connection: NWConnection?) -> String? {
        if let remoteEndpoint = connection?.currentPath?.remoteEndpoint,
           let resolved = endpointHostAddress(remoteEndpoint) {
            return resolved
        }
        return endpointHostAddress(connection?.endpoint)
    }

    private func endpointHostAddress(_ endpoint: NWEndpoint?) -> String? {
        P2PConnectionEndpointPolicy.endpointHostAddress(endpoint)
    }

    private func isLoopbackAddress(_ ipAddress: String) -> Bool {
        P2PConnectionEndpointPolicy.isLoopbackAddress(ipAddress)
    }

    private func isSelfConnectionTarget(_ device: DiscoveredDevice) throws -> Bool {
        let localId = try localStableDeviceIdentifier().lowercased()
        let persistentLocalId = try localStablePersistentDeviceIdentifier().lowercased()
        let normalizedDeviceId = device.id.lowercased()
        if normalizedDeviceId == localId || normalizedDeviceId == persistentLocalId {
            return true
        }

        if let ipAddress = device.ipAddress,
           isLoopbackAddress(ipAddress) {
            return true
        }

        return false
    }

    @discardableResult
    private func setSessionKeys(
        _ keys: SessionKeys,
        for deviceId: String,
        connectionGeneration: UUID,
        deviceNameHint: String? = nil
    ) -> Bool {
        guard let lease = connections.lease(for: deviceId),
              lease.generation == connectionGeneration,
              connections.isCurrent(lease, for: deviceId) else {
            return false
        }
        sessionKeys[deviceId] = keys
        sessionKeyConnectionGenerationByPeerId[deviceId] = connectionGeneration
        negotiatedSuiteByDeviceId[deviceId] = keys.negotiatedSuite
        let presentationPeerId = presentationPeerId(for: deviceId)
        if presentationPeerId != deviceId {
            negotiatedSuiteByDeviceId[presentationPeerId] = keys.negotiatedSuite
        }
        clearRekeyPresentationStatus(for: deviceId)

        // Keep Live Activity in sync with the latest negotiated suite (e.g., after Classic -> PQC rekey).
        let name =
            deviceNameHint
            ?? lastKnownDevices[deviceId]?.name
            ?? discoveryManager.discoveredDevices.first(where: { $0.id == deviceId })?.name
            ?? deviceId
        Task { @MainActor [weak self] in
            guard let self,
                  let lease = self.connections.lease(for: deviceId),
                  lease.generation == connectionGeneration,
                  self.sessionKeys[deviceId]?.sessionId == keys.sessionId else {
                return
            }
            await LiveActivityManager.shared.setConnected(deviceName: name, cryptoSuite: keys.negotiatedSuite.rawValue)
        }
        return true
    }

    @discardableResult
    private func removeSessionKeysIfOwned(
        for deviceId: String,
        connectionGeneration: UUID,
        sessionId: String? = nil
    ) -> SessionKeys? {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard sessionKeyConnectionGenerationByPeerId[deviceId] == connectionGeneration,
              let existing = sessionKeys[deviceId],
              sessionId.map({ existing.sessionId == $0 }) ?? true else {
            return nil
        }
        sessionKeys.removeValue(forKey: deviceId)
        sessionKeyConnectionGenerationByPeerId.removeValue(forKey: deviceId)
        negotiatedSuiteByDeviceId.removeValue(forKey: deviceId)
        let presentationPeerId = presentationPeerId(for: deviceId)
        if presentationPeerId != deviceId {
            negotiatedSuiteByDeviceId.removeValue(forKey: presentationPeerId)
        }
        return existing
    }

    private func installSessionPairingAuthority(
        _ binding: AuthenticatedHandshakePeerBinding,
        wasPreauthorizedForAutomaticPairing: Bool,
        for peerId: String,
        connection: NWConnection
    ) throws {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let lease = connections.lease(for: peerId),
            lease.connection === connection,
            connections.isCurrent(lease, for: peerId)
        else {
            throw PairingIdentityAuthorityValidationError.missingSessionAuthority
        }
        sessionPairingAuthorityByPeerId[peerId] = SessionPairingAuthority(
            connectionGeneration: lease.generation,
            binding: binding,
            wasPreauthorizedForAutomaticPairing: wasPreauthorizedForAutomaticPairing
        )
    }

    private func currentSessionPairingAuthority(for peerId: String) -> SessionPairingAuthority? {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let lease = connections.lease(for: peerId),
            let authority = sessionPairingAuthorityByPeerId[peerId],
            authority.connectionGeneration == lease.generation
        else {
            return nil
        }
        return authority
    }

    private func requireCurrentConnectionLease(
        for peerId: String,
        generation: UUID,
        sessionId: String? = nil
    ) throws -> P2PConnectionLease<NWConnection> {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let lease = connections.lease(for: peerId),
            lease.generation == generation,
            connections.isCurrent(lease, for: peerId)
        else {
            throw P2PError.staleConnectionIncarnation
        }
        if let sessionId {
            guard sessionKeyConnectionGenerationByPeerId[peerId] == generation,
                  sessionKeys[peerId]?.sessionId == sessionId else {
                throw P2PError.staleConnectionIncarnation
            }
        }
        return lease
    }

    private func beginHandshakeOperation(
        for lease: P2PConnectionLease<NWConnection>
    ) throws -> HandshakeOperationOwner {
        let peerId = canonicalPeerLookupKey(lease.peerId)
        guard connections.isCurrent(lease, for: peerId) else {
            throw P2PError.staleConnectionIncarnation
        }
        if let existingOwner = handshakeOperationOwnerByPeerId[peerId],
            isCurrentHandshakeOperation(existingOwner) {
            throw P2PError.handshakeAlreadyInProgress
        }
        let owner = HandshakeOperationOwner(
            token: UUID(),
            peerId: peerId,
            connectionGeneration: lease.generation
        )
        handshakeOperationOwnerByPeerId[peerId] = owner
        return owner
    }

    private func isCurrentHandshakeOperation(
        _ expected: HandshakeOperationOwner
    ) -> Bool {
        guard handshakeOperationOwnerByPeerId[expected.peerId] == expected,
              let lease = connections.lease(for: expected.peerId),
              lease.generation == expected.connectionGeneration else {
            return false
        }
        return connections.isCurrent(lease, for: expected.peerId)
    }

    @discardableResult
    private func requireCurrentHandshakeOperation(
        _ expected: HandshakeOperationOwner
    ) throws -> P2PConnectionLease<NWConnection> {
        guard isCurrentHandshakeOperation(expected),
              let lease = connections.lease(for: expected.peerId) else {
            throw P2PError.staleConnectionIncarnation
        }
        try Task.checkCancellation()
        return lease
    }

    private func finishHandshakeOperation(
        _ expected: HandshakeOperationOwner
    ) {
        if handshakeOperationOwnerByPeerId[expected.peerId] == expected {
            handshakeOperationOwnerByPeerId.removeValue(forKey: expected.peerId)
        }
    }

    private func detachHandshakeDriverIfOwned(
        for peerId: String,
        connectionGeneration: UUID,
        operationToken: UUID? = nil,
        expectedDriver: HandshakeDriver? = nil
    ) -> HandshakeDriver? {
        let peerId = canonicalPeerLookupKey(peerId)
        guard handshakeDriverConnectionGenerationByPeerId[peerId]
                == connectionGeneration,
              let driver = handshakeDrivers[peerId],
              operationToken.map({
                  handshakeDriverOperationTokenByPeerId[peerId] == $0
              }) ?? true,
              expectedDriver.map({ driver === $0 }) ?? true else {
            return nil
        }
        handshakeDrivers.removeValue(forKey: peerId)
        handshakeDriverConnectionGenerationByPeerId.removeValue(forKey: peerId)
        handshakeDriverOperationTokenByPeerId.removeValue(forKey: peerId)
        return driver
    }

    /// Terminal teardown for an exact connection incarnation. Driver state and
    /// its operation owner form one lifecycle transaction; clearing only one
    /// side leaves stale peer-keyed owners behind and makes later cleanup ABA-
    /// prone.
    private func detachHandshakeOperationIfOwned(
        for peerId: String,
        connectionGeneration: UUID,
        operationToken: UUID? = nil,
        expectedDriver: HandshakeDriver? = nil
    ) -> HandshakeDriver? {
        let peerId = canonicalPeerLookupKey(peerId)
        let detachedDriver = detachHandshakeDriverIfOwned(
            for: peerId,
            connectionGeneration: connectionGeneration,
            operationToken: operationToken,
            expectedDriver: expectedDriver
        )
        let stillOwnsDriver = handshakeDriverConnectionGenerationByPeerId[peerId]
            == connectionGeneration
        guard detachedDriver != nil || !stillOwnsDriver,
              let operationOwner = handshakeOperationOwnerByPeerId[peerId],
              operationOwner.connectionGeneration == connectionGeneration,
              operationToken.map({ operationOwner.token == $0 }) ?? true else {
            return detachedDriver
        }
        finishHandshakeOperation(operationOwner)
        return detachedDriver
    }

    private func isCurrentAuthenticatedConnection(
        _ receipt: AuthenticatedConnectionReceipt
    ) -> Bool {
        let peerId = receipt.lease.peerId
        return connections.isCurrent(receipt.lease, for: peerId)
            && sessionKeyConnectionGenerationByPeerId[peerId] == receipt.lease.generation
            && sessionKeys[peerId]?.sessionId == receipt.sessionId
            && sessionKeys[peerId]?.negotiatedSuite == receipt.negotiatedSuite
    }

    private func requireCurrentAuthenticatedConnection(
        _ receipt: AuthenticatedConnectionReceipt
    ) throws {
        guard isCurrentAuthenticatedConnection(receipt) else {
            throw P2PError.staleConnectionIncarnation
        }
        try Task.checkCancellation()
    }

    private func clearSessionPairingAuthority(
        for peerId: String,
        connectionGeneration: UUID? = nil
    ) {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let existing = sessionPairingAuthorityByPeerId[peerId] else { return }
        if let connectionGeneration,
            existing.connectionGeneration != connectionGeneration
        {
            return
        }
        sessionPairingAuthorityByPeerId.removeValue(forKey: peerId)
    }

    private func authenticatedHandshakePeerBinding(
        from driver: HandshakeDriver
    ) async throws -> AuthenticatedHandshakePeerBinding {
        guard let binding = await driver.getAuthenticatedHandshakePeerBinding() else {
            throw TrustedDeviceStore.AuthorityUpdateError.missingAuthenticatedRemoteAuthority
        }
        return binding
    }

    private func persistAuthenticatedRemoteAuthority(
        _ binding: AuthenticatedHandshakePeerBinding,
        for peerId: String,
        deviceNameHint: String? = nil
    ) throws -> AuthenticatedAuthorityPersistenceResult {
        let authority = binding.authority

        let presentationPeerId = presentationPeerId(for: peerId)
        let provisionalDevice =
            lastKnownDevices[presentationPeerId]
            ?? lastKnownDevices[peerId]
            ?? discoveryManager.discoveredDevices.first(where: { candidate in
                let targetAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
                let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                return candidate.id == peerId || !targetAliases.isDisjoint(with: candidateAliases)
            })
            ?? DiscoveredDevice(
                id: peerId,
                name: deviceNameHint ?? peerId,
                modelName: "",
                platform: .unknown,
                osVersion: "Unknown"
            )
        let resolvedDevice = resolvedPeerDevice(for: provisionalDevice)
        guard let protocolPublicKeyBytes = authority.protocolPublicKeyBytes else {
            throw TrustedDeviceStore.AuthorityUpdateError.invalidProtocolPublicKey
        }

        let preauthorized: Bool
        if let algorithm = ProtocolSigningAlgorithm(
            rawValue: authority.protocolSigningAlgorithm.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) {
            preauthorized = TrustedDeviceStore.shared
                .uniqueExactActiveProtocolIdentityAuthorityDeviceId(
                algorithm: algorithm,
                fingerprint: authority.protocolPublicKeyFingerprint,
                publicKey: protocolPublicKeyBytes
            ) != nil
        } else {
            preauthorized = false
        }

        let observationResult = try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: resolvedDevice,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: protocolPublicKeyBytes
        )

        switch observationResult {
        case .refreshedExistingAuthority:
            SkyBridgeLogger.shared.info(
                "🔐 已刷新精确匹配的对端协议身份 authority: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
            )
        case .pendingOperatorApproval:
            SkyBridgeLogger.shared.info(
                "🔐 未知对端 authority 仅保留在当前会话，等待显式配对批准: peer=\(Self.protocolIdentityLogRedaction)"
            )
        }
        return AuthenticatedAuthorityPersistenceResult(
            binding: binding,
            wasPreauthorizedForAutomaticPairing: preauthorized
        )
    }

    private func restoreActiveSessionAfterRekeyFailure(
        for peerId: String,
        originLease: P2PConnectionLease<NWConnection>,
        activeDriver: HandshakeDriver,
        rollback: InboundRekeyRollbackRecord,
        reason: HandshakeFailureReason
    ) async -> Bool {
        let operationOwner = HandshakeOperationOwner(
            token: rollback.handshakeOperationToken,
            peerId: peerId,
            connectionGeneration: rollback.connectionGeneration
        )
        func isCurrentRollbackOwner() -> Bool {
            connections.isCurrent(originLease, for: peerId)
                && rollback.connectionGeneration == originLease.generation
                && isCurrentHandshakeOperation(operationOwner)
                && handshakeDrivers[peerId] === activeDriver
                && handshakeDriverConnectionGenerationByPeerId[peerId]
                    == originLease.generation
                && handshakeDriverOperationTokenByPeerId[peerId]
                    == rollback.handshakeOperationToken
                && inboundRekeyRollbackByPeerId[peerId]?.connectionGeneration
                    == rollback.connectionGeneration
                && inboundRekeyRollbackByPeerId[peerId]?.handshakeOperationToken
                    == rollback.handshakeOperationToken
        }

        guard isCurrentRollbackOwner() else { return false }
        var restoredArbiterLease: PeerSessionArbiter.EstablishedLease?
        if let releasedBinding = rollback.releasedArbiterBinding {
            let restored = await PeerSessionArbiter.shared.restoreEstablishedIfVacant(
                releasedBinding.lease
            )
            guard isCurrentRollbackOwner() else {
                if restored {
                    _ = await PeerSessionArbiter.shared.clearEstablished(
                        releasedBinding.lease
                    )
                }
                return false
            }
            guard restored else { return false }
            restoredArbiterLease = releasedBinding.lease
        }

        guard setSessionKeys(
                rollback.previousKeys,
                for: peerId,
                connectionGeneration: originLease.generation
              ) else {
            if let restoredArbiterLease {
                _ = await PeerSessionArbiter.shared.clearEstablished(restoredArbiterLease)
            }
            return false
        }
        guard isCurrentRollbackOwner() else {
            _ = removeSessionKeysIfOwned(
                for: peerId,
                connectionGeneration: originLease.generation,
                sessionId: rollback.previousKeys.sessionId
            )
            if let restoredArbiterLease {
                _ = await PeerSessionArbiter.shared.clearEstablished(restoredArbiterLease)
            }
            return false
        }

        if let releasedBinding = rollback.releasedArbiterBinding {
            arbiterSessionBindingByPeerId[peerId] = releasedBinding
            if let stablePeerId = strictInboundStablePeerIdByRuntimePeerId[peerId],
               stablePeerId != peerId {
                arbiterSessionBindingByPeerId[stablePeerId] = releasedBinding
            }
        }
        inboundRekeyRollbackByPeerId.removeValue(forKey: peerId)
        _ = detachHandshakeDriverIfOwned(
            for: peerId,
            connectionGeneration: originLease.generation,
            operationToken: rollback.handshakeOperationToken,
            expectedDriver: activeDriver
        )
        finishHandshakeOperation(operationOwner)
        rekeyInProgress.remove(peerId)
        clearRekeyPresentationStatus(for: peerId)

        currentHandshakeState = "rekey失败，保留原会话 (Suite: \(rollback.previousKeys.negotiatedSuite.rawValue))"
        connectionStatusByDeviceId[peerId] = .connected
        connectionErrorByDeviceId.removeValue(forKey: peerId)
        startHeartbeatIfNeeded(deviceId: peerId)

        let activeDevice = makeActiveConnectionDevice(
            peerId: peerId,
            connection: connections[peerId]
        )
        upsertActiveConnection(device: activeDevice, status: .connected)
        syncPresentationState(for: peerId)

        SkyBridgeLogger.shared.warning(
            "⚠️ rekey失败，已恢复原会话: peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.diagnosticHandshakeFailureCode(reason))"
        )
        return true
    }

    private func shouldUseSOA(for device: DiscoveredDevice) -> Bool {
        device.capabilities.contains("hs_soa") || device.advertisedCapabilities.contains("hs_soa")
    }

    private func localStableDeviceIdentifier() throws -> String {
        try skyBridgeCore.requireCurrentProtocolIdentitySnapshot().deviceId
    }

    private func localStablePersistentDeviceIdentifier() throws -> String {
        let raw = try localStableDeviceIdentifier()
        return PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    private func localSOAPeerIdBytes() throws -> Data {
        var persistent = try localStablePersistentDeviceIdentifier()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if persistent.hasPrefix("id:") {
            persistent.removeFirst(3)
        }
        return canonicalPeerIdBytes(from: persistent)
    }

    private func soaPeerIdBytes(for peerId: String) -> Data? {
        guard let canonical = canonicalSOATrustedPeerIdentifier(peerId) else {
            return nil
        }
        return canonicalPeerIdBytes(from: canonical)
    }

    private func canonicalSOATrustedPeerIdentifier(_ peerId: String) -> String? {
        let normalized = peerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            return String(normalized.dropFirst(3))
        }

        if normalized.hasPrefix("host:") {
            let hostRaw = String(normalized.dropFirst(5))
            let hostNoScope = hostRaw.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostRaw
            func normalizedIP(_ raw: String?) -> String? {
                guard let raw else { return nil }
                var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if let percent = value.firstIndex(of: "%") {
                    value = String(value[..<percent])
                }
                return value
            }
            let candidates = Set([hostRaw, hostNoScope])
            if let matched = discoveryManager.discoveredDevices.first(where: {
                guard $0.id.lowercased().hasPrefix("id:"),
                      let ip = normalizedIP($0.ipAddress) else {
                    return false
                }
                return candidates.contains(ip)
            }) {
                return canonicalSOATrustedPeerIdentifier(matched.id)
            }
        }

        if normalized.hasPrefix("bonjour:"),
           let parsed = parseBonjourPeerIdentifier(peerId) {
            let parsedName = parsed.name.lowercased()
            let parsedDomain = parsed.domain.lowercased()
            if let matched = discoveryManager.discoveredDevices.first(where: {
                guard $0.id.lowercased().hasPrefix("id:"),
                      let bonjourName = BonjourServiceIdentitySanitizer
                        .sanitizedServiceInstanceName($0.bonjourServiceName)?
                        .lowercased() else {
                    return false
                }
                let domain = ($0.bonjourServiceDomain ?? "local.").lowercased()
                return bonjourName == parsedName && domain == parsedDomain
            }) {
                return canonicalSOATrustedPeerIdentifier(matched.id)
            }
        }

        if let known = lastKnownDevices[peerId]?.id, known.lowercased().hasPrefix("id:") {
            return canonicalSOATrustedPeerIdentifier(known)
        }

        return nil
    }

    private func canonicalPeerIdBytes(from canonicalId: String) -> Data {
        let digest = SHA256.hash(data: Data(canonicalId.utf8))
        return Data(digest)
    }

    private func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private func detachArbiterSessionBinding(
        for deviceId: String,
        expectedConnectionGeneration: UUID
    ) -> ArbiterSessionBinding? {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let binding = arbiterSessionBindingByPeerId[deviceId],
              binding.connectionGeneration == expectedConnectionGeneration else {
            return nil
        }
        for key in Array(arbiterSessionBindingByPeerId.keys)
        where arbiterSessionBindingByPeerId[key] == binding {
            arbiterSessionBindingByPeerId.removeValue(forKey: key)
        }
        return binding
    }

    private func releaseArbiterState(
        for deviceId: String,
        expectedConnectionGeneration: UUID
    ) async {
        guard let binding = detachArbiterSessionBinding(
            for: deviceId,
            expectedConnectionGeneration: expectedConnectionGeneration
        ) else { return }
        await releaseArbiterSessionBinding(binding)
    }

    private func releaseArbiterSessionBinding(
        _ binding: ArbiterSessionBinding
    ) async {
        _ = await PeerSessionArbiter.shared.clearEstablished(binding.lease)
    }

    private func releaseArbiterState(
        for deviceId: String,
        expectedOperation: HandshakeOperationOwner
    ) async throws -> ArbiterSessionBinding? {
        _ = try requireCurrentHandshakeOperation(expectedOperation)
        let binding = detachArbiterSessionBinding(
            for: deviceId,
            expectedConnectionGeneration: expectedOperation.connectionGeneration
        )
        if let binding {
            _ = await PeerSessionArbiter.shared.clearEstablished(binding.lease)
        }
        _ = try requireCurrentHandshakeOperation(expectedOperation)
        return binding
    }
    
    /// 执行 PQC 握手（使用完整的 HandshakeDriver 协议）
    private func performPQCHandshake(
        connection: NWConnection,
        device: DiscoveredDevice,
        preferPQC: Bool,
        selectionPolicyOverride: CryptoProviderFactory.SelectionPolicy? = nil,
        allowSOA: Bool = true,
        expectedOperation: HandshakeOperationOwner? = nil
    ) async throws -> AuthenticatedConnectionReceipt {
        let peerId = canonicalPeerLookupKey(device.id)
        guard let handshakeLease = connections.lease(for: peerId),
            handshakeLease.connection === connection,
            connections.isCurrent(handshakeLease, for: peerId)
        else {
            throw P2PError.staleConnectionIncarnation
        }
        let operationOwner: HandshakeOperationOwner
        let finishesOperationHere: Bool
        if let expectedOperation {
            guard expectedOperation.peerId == peerId,
                  expectedOperation.connectionGeneration == handshakeLease.generation,
                  isCurrentHandshakeOperation(expectedOperation) else {
                throw P2PError.staleConnectionIncarnation
            }
            operationOwner = expectedOperation
            finishesOperationHere = false
        } else {
            operationOwner = try beginHandshakeOperation(for: handshakeLease)
            finishesOperationHere = true
        }
        defer {
            if finishesOperationHere {
                finishHandshakeOperation(operationOwner)
            }
        }
        SkyBridgeLogger.shared.info("🔐 开始 PQC 握手...")
        currentHandshakeState = "握手中..."
        
        // 确保 SkyBridgeCore 已按当前设置初始化（允许按 policy 重新初始化）
        if let override = selectionPolicyOverride {
            try await skyBridgeCore.initialize(policy: override)
        } else if pqcManager.enforcePQCHandshake {
            try ensureStrictPQCAvailability()
            let policy = effectiveSelectionPolicy(enforcePQC: true)
            try await skyBridgeCore.initialize(policy: policy)
        } else {
            try await skyBridgeCore.initialize(policy: .classicOnly)
        }
        _ = try requireCurrentHandshakeOperation(operationOwner)
        
        // 创建传输层
        if transport == nil {
            transport = NWConnectionTransport()
        }
        guard await transport!.setConnection(
            connection,
            for: peerId,
            leaseSequence: handshakeLease.sequence
        ) else {
            throw P2PError.staleConnectionIncarnation
        }
        _ = try requireCurrentHandshakeOperation(operationOwner)

        var publishedSessionId: String?
        do {
            let strictTrustContext: (stablePeerId: String, provider: P2PStoredHandshakeTrustProvider)?
            if pqcManager.enforcePQCHandshake {
                guard let context = await strictInboundHandshakeTrustContext(
                    for: peerId,
                    stage: "outbound"
                ) else {
                    throw P2PError.missingPinnedProtocolIdentity
                }
                strictTrustContext = context
            } else {
                strictTrustContext = nil
            }
            _ = try requireCurrentHandshakeOperation(operationOwner)
            let outboundSOATargetPeerId = strictTrustContext?.stablePeerId ?? peerId
            let canBindSOATarget = soaPeerIdBytes(for: outboundSOATargetPeerId) != nil
            let shouldAdvertiseSOA = allowSOA && (shouldUseSOA(for: device) || canBindSOATarget)
            let localPeerId = shouldAdvertiseSOA ? try localSOAPeerIdBytes() : nil
            let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: outboundSOATargetPeerId) : nil
            if let localPeerId, let remotePeerId {
                pendingSOAPairKeyByDeviceId[peerId] = PendingSOAPairKey(
                    connectionGeneration: handshakeLease.generation,
                    pairKey: PeerSessionArbiter.pairKey(
                        localPeerId: localPeerId,
                        remotePeerId: remotePeerId
                    )
                )
            } else {
                pendingSOAPairKeyByDeviceId.removeValue(forKey: peerId)
            }
            let outboundSOA: HandshakeSOAMetadata? = try {
                guard let localPeerId, let remotePeerId else { return nil }
                return try HandshakeSOAMetadata(
                    initiatorPeerId: localPeerId,
                    targetPeerId: remotePeerId,
                    attemptId: randomAttemptIdBytes()
                )
            }()

            let boundTransport = try await transport!.boundTransport(
                for: peerId,
                expectedConnection: handshakeLease.connection,
                leaseSequence: handshakeLease.sequence
            )
            _ = try requireCurrentHandshakeOperation(operationOwner)

            // 让握手驱动器可接收来自 startReceiving 的消息
            let keys = try await skyBridgeCore.performHandshake(
                deviceId: peerId,
                transport: boundTransport,
                preferPQC: preferPQC,
                soaMetadata: outboundSOA,
                localSOAPeerId: localPeerId,
                expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId) ?? remotePeerId,
                trustProvider: strictTrustContext?.provider,
                onDriverCreated: { driver in
                    // Swift 6 并发：避免在并发回调里捕获/引用 `self`（即使是 weak self）
                    await MainActor.run {
                        let manager = P2PConnectionManager.instance
                        guard manager.isCurrentHandshakeOperation(operationOwner) else { return }
                        manager.handshakeDrivers[peerId] = driver
                        manager.handshakeDriverConnectionGenerationByPeerId[peerId] =
                            handshakeLease.generation
                        manager.handshakeDriverOperationTokenByPeerId[peerId] =
                            operationOwner.token
                    }
                }
            )
            _ = try requireCurrentHandshakeOperation(operationOwner)
            guard let activeDriver = handshakeDrivers[peerId],
                  handshakeDriverConnectionGenerationByPeerId[peerId] == handshakeLease.generation,
                  handshakeDriverOperationTokenByPeerId[peerId] == operationOwner.token else {
                throw TrustedDeviceStore.AuthorityUpdateError.missingAuthenticatedRemoteAuthority
            }
            let authenticatedBinding = try await authenticatedHandshakePeerBinding(
                from: activeDriver
            )
            _ = try requireCurrentHandshakeOperation(operationOwner)
            guard handshakeDrivers[peerId] === activeDriver,
                  handshakeDriverConnectionGenerationByPeerId[peerId] == handshakeLease.generation,
                  handshakeDriverOperationTokenByPeerId[peerId] == operationOwner.token else {
                throw P2PError.staleConnectionIncarnation
            }
            let establishedArbiterLease = await activeDriver.getEstablishedArbiterLease()
            _ = try requireCurrentHandshakeOperation(operationOwner)
            let arbiterBindingToPublish: ArbiterSessionBinding?
            if let pendingPair = pendingSOAPairKeyByDeviceId[peerId],
               pendingPair.connectionGeneration == handshakeLease.generation {
                guard let establishedArbiterLease,
                      establishedArbiterLease.pairKey == pendingPair.pairKey,
                      establishedArbiterLease.sessionId == keys.sessionId else {
                    throw P2PError.staleConnectionIncarnation
                }
                arbiterBindingToPublish = ArbiterSessionBinding(
                    connectionGeneration: handshakeLease.generation,
                    lease: establishedArbiterLease
                )
            } else {
                guard establishedArbiterLease == nil else {
                    throw P2PError.staleConnectionIncarnation
                }
                arbiterBindingToPublish = nil
            }
            let persistedAuthority = try persistAuthenticatedRemoteAuthority(
                authenticatedBinding,
                for: peerId,
                deviceNameHint: device.name
            )
            
            // 保存会话密钥 + 清理握手 driver
            _ = try requireCurrentHandshakeOperation(operationOwner)
            guard setSessionKeys(
                keys,
                for: peerId,
                connectionGeneration: handshakeLease.generation,
                deviceNameHint: device.name
            ) else {
                throw P2PError.staleConnectionIncarnation
            }
            publishedSessionId = keys.sessionId
            try installSessionPairingAuthority(
                persistedAuthority.binding,
                wasPreauthorizedForAutomaticPairing: persistedAuthority
                    .wasPreauthorizedForAutomaticPairing,
                for: peerId,
                connection: connection
            )
            if let arbiterBindingToPublish {
                arbiterSessionBindingByPeerId[peerId] = arbiterBindingToPublish
                pendingSOAPairKeyByDeviceId.removeValue(forKey: peerId)
            } else {
                arbiterSessionBindingByPeerId.removeValue(forKey: peerId)
            }
            _ = detachHandshakeDriverIfOwned(
                for: peerId,
                connectionGeneration: handshakeLease.generation,
                operationToken: operationOwner.token,
                expectedDriver: activeDriver
            )

            currentHandshakeState = "握手成功 (Suite: \(keys.negotiatedSuite.rawValue))"
            SkyBridgeLogger.shared.info("✅ PQC 握手完成 (Suite: \(keys.negotiatedSuite.rawValue))")

        } catch {
            let detachedDriver = detachHandshakeDriverIfOwned(
                for: peerId,
                connectionGeneration: handshakeLease.generation,
                operationToken: operationOwner.token
            )
            await detachedDriver?.cancel()
            guard isCurrentHandshakeOperation(operationOwner) else {
                throw P2PError.staleConnectionIncarnation
            }
            if pendingSOAPairKeyByDeviceId[peerId]?.connectionGeneration
                == handshakeLease.generation {
                pendingSOAPairKeyByDeviceId.removeValue(forKey: peerId)
            }
            if let publishedSessionId,
               sessionKeyConnectionGenerationByPeerId[peerId]
                    == handshakeLease.generation,
               sessionKeys[peerId]?.sessionId == publishedSessionId {
                cleanupBrokenInboundConnection(
                    connection,
                    peerId: peerId,
                    reason: "rekey authority 持久化失败"
                )
            }
            let message = userVisibleConnectionError(error)
            currentHandshakeState = "握手失败: \(message)"
            lastError = message
            SkyBridgeLogger.shared.error(
                "❌ PQC 握手失败: \(Self.diagnosticErrorSummary(error))"
            )
            throw error
        }
        _ = try requireCurrentHandshakeOperation(operationOwner)
        guard let establishedKeys = sessionKeys[peerId],
              sessionKeyConnectionGenerationByPeerId[peerId] == handshakeLease.generation else {
            throw P2PError.staleConnectionIncarnation
        }
        return AuthenticatedConnectionReceipt(
            lease: handshakeLease,
            sessionId: establishedKeys.sessionId,
            negotiatedSuite: establishedKeys.negotiatedSuite
        )
    }

    /// 强制用 preferPQC=true 重新握手（用于完成 KEM 公钥交换后的“立刻切换到 PQC suite”）
    public func rekeyToPreferPQC(deviceId: String, allowSOA: Bool = false) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let connectionLease = connections.lease(for: deviceId),
              let originalSessionId = sessionKeys[deviceId]?.sessionId,
              sessionKeyConnectionGenerationByPeerId[deviceId] == connectionLease.generation else {
            throw P2PError.staleConnectionIncarnation
        }
        let operationOwner = try beginHandshakeOperation(for: connectionLease)
        defer { finishHandshakeOperation(operationOwner) }
        let fromSuite = resolvedNegotiatedSuite(forAnyPeerId: deviceId)?.rawValue ?? "Classic"
        let targetSuite = preferredRekeyTargetSuite() ?? fromSuite
        let releasedArbiterBinding = allowSOA
            ? try await releaseArbiterState(
                for: deviceId,
                expectedOperation: operationOwner
            )
            : nil
        _ = try requireCurrentHandshakeOperation(operationOwner)
        guard sessionKeys[deviceId]?.sessionId == originalSessionId else {
            throw P2PError.staleConnectionIncarnation
        }
        setRekeyPresentationStatus(for: deviceId, fromSuite: fromSuite, toSuite: targetSuite)
        rekeyInProgress.insert(deviceId)
        defer {
            if isCurrentHandshakeOperation(operationOwner) {
                rekeyInProgress.remove(deviceId)
                clearRekeyPresentationStatus(for: deviceId)
            }
        }
        let device = discoveryManager.discoveredDevices.first(where: { $0.id == deviceId })
            ?? DiscoveredDevice(id: deviceId, name: deviceId, modelName: "", platform: .unknown, osVersion: "Unknown")
        do {
            let rekeyedReceipt = try await performPQCHandshake(
                connection: connectionLease.connection,
                device: device,
                preferPQC: true,
                selectionPolicyOverride: pqcManager.enforcePQCHandshake ? .requirePQC : nil,
                allowSOA: allowSOA,
                expectedOperation: operationOwner
            )
            try requireCurrentAuthenticatedConnection(rekeyedReceipt)
            guard rekeyedReceipt.lease.generation == connectionLease.generation,
                  rekeyedReceipt.negotiatedSuite.isPQCGroup else {
                throw P2PError.staleConnectionIncarnation
            }
        } catch {
            if let releasedArbiterBinding,
               isCurrentHandshakeOperation(operationOwner),
               sessionKeys[deviceId]?.sessionId == originalSessionId {
                let restored = await PeerSessionArbiter.shared.restoreEstablishedIfVacant(
                    releasedArbiterBinding.lease
                )
                _ = try requireCurrentHandshakeOperation(operationOwner)
                guard restored,
                      sessionKeys[deviceId]?.sessionId == originalSessionId else {
                    throw P2PError.staleConnectionIncarnation
                }
                arbiterSessionBindingByPeerId[deviceId] = releasedArbiterBinding
            }
            throw error
        }
    }

    /// 使用会话密钥加密数据
    public func encryptForDevice(_ data: Data, deviceId: String) throws -> Data {
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: false
        ) else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.encrypt(data, sessionKey: current.keys.sendKey)
    }
    
    /// 使用会话密钥解密数据
    public func decryptFromDevice(_ data: Data, deviceId: String) throws -> Data {
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: false
        ) else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.decrypt(data, sessionKey: current.keys.receiveKey)
    }

    func realtimeMediaKeySnapshot(for deviceId: String) -> RemoteRealtimeMediaKeySnapshot? {
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: true
        ) else { return nil }
        return RemoteRealtimeMediaKeySnapshot(
            sessionId: "lan-\(current.keys.sessionId)",
            sendKey: current.keys.sendKey,
            receiveKey: current.keys.receiveKey,
            localRole: current.keys.role,
            transcriptHash: current.keys.transcriptHash,
            mediaAdmissionToken: nil
        )
    }

    /// Derive the authenticated LAN file-transfer key from the established session keys.
    /// This mirrors the macOS derivation so local file-transfer metadata/chunks/receipts
    /// stay cryptographically bound to the already authenticated P2P session.
    public func deriveClassicFileTransferKey(transferId: String, deviceId: String) throws -> SymmetricKey {
        guard let current = currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: true
        ) else { throw P2PError.noSessionKey }
        return deriveClassicFileTransferKey(
            from: current.keys,
            transferId: transferId
        )
    }

    public func activeClassicTransferAuthenticatedPeers() -> [ClassicTransferAuthenticatedPeerDescriptor] {
        var descriptorsByKey: [String: ClassicTransferAuthenticatedPeerDescriptor] = [:]

        func merge(_ descriptor: ClassicTransferAuthenticatedPeerDescriptor) {
            let identityKey = descriptor.resolvedPeerDeviceId.lowercased()
            guard let existing = descriptorsByKey[identityKey] else {
                descriptorsByKey[identityKey] = descriptor
                return
            }

            let mergedAliases = Array(Set(existing.aliases).union(descriptor.aliases)).sorted()
            let mergedCapabilities = Array(Set(existing.capabilities).union(descriptor.capabilities)).sorted()
            let mergedEndpoint = existing.endpointHostOrIP ?? descriptor.endpointHostOrIP
            let mergedMatchDeviceId = existing.matchDeviceId.isEmpty ? descriptor.matchDeviceId : existing.matchDeviceId
            let mergedResolvedPeerDeviceId = existing.resolvedPeerDeviceId.isEmpty
                ? descriptor.resolvedPeerDeviceId
                : existing.resolvedPeerDeviceId

            descriptorsByKey[identityKey] = ClassicTransferAuthenticatedPeerDescriptor(
                matchDeviceId: mergedMatchDeviceId,
                resolvedPeerDeviceId: mergedResolvedPeerDeviceId,
                aliases: mergedAliases,
                endpointHostOrIP: mergedEndpoint,
                capabilities: mergedCapabilities
            )
        }

        for connection in activeConnections where connection.status == .connected {
            guard currentAuthenticatedSession(
                forAnyPeerId: connection.device.id,
                requireConnectedStatus: true
            ) != nil else {
                continue
            }
            let resolvedDevice = resolvedPeerDevice(for: connection.device)
            var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id))
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: resolvedDevice.id))
            aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: connection.device.ipAddress))
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: resolvedDevice.ipAddress))

            merge(
                ClassicTransferAuthenticatedPeerDescriptor(
                    matchDeviceId: resolvedDevice.id,
                    resolvedPeerDeviceId: resolvedDevice.id,
                    aliases: Array(aliases).sorted(),
                    endpointHostOrIP: resolvedDevice.ipAddress ?? connection.device.ipAddress,
                    capabilities: Array(Set(resolvedDevice.capabilities).union(connection.device.capabilities)).sorted()
                )
            )
        }

        for key in connections.keys {
            guard exactAuthenticatedSession(
                for: key,
                requireConnectedStatus: true
            ) != nil else {
                continue
            }
            let canonical = canonicalPeerLookupKey(key)
            let runtimePeerId = runtimePeerId(forAnyPeerId: canonical)
            let presentationPeerId = presentationPeerId(for: runtimePeerId)
            let aliases = connectionAliasSet(for: runtimePeerId)
                .union(PeerIdentityAliasResolver.lookupCandidates(for: key))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: canonical))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
                .union([key, canonical, runtimePeerId, presentationPeerId].filter { !$0.isEmpty })

            let resolvedPeerDeviceId = [presentationPeerId, runtimePeerId, canonical, key]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? key

            merge(
                ClassicTransferAuthenticatedPeerDescriptor(
                    matchDeviceId: canonical.isEmpty ? key : canonical,
                    resolvedPeerDeviceId: resolvedPeerDeviceId,
                    aliases: Array(aliases).sorted(),
                    endpointHostOrIP: nil,
                    capabilities: []
                )
            )
        }

        return descriptorsByKey.values.sorted {
            $0.resolvedPeerDeviceId.localizedCaseInsensitiveCompare($1.resolvedPeerDeviceId) == .orderedAscending
        }
    }

    private func deriveClassicFileTransferKey(from keys: SessionKeys, transferId: String) -> SymmetricKey {
        let orderedKeys = [keys.sendKey, keys.receiveKey].sorted { lhs, rhs in
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
    
    /// 获取设备的协商套件
    public func getNegotiatedSuite(for deviceId: String) -> CryptoSuite? {
        currentAuthenticatedSession(
            forAnyPeerId: deviceId,
            requireConnectedStatus: false
        )?.keys.negotiatedSuite
    }

    private func sendPairingIdentityData(
        _ data: Data,
        over connection: NWConnection
    ) async throws {
        let padded = try TrafficPadding.wrapForP2PControlFrame(data, label: "tx")
        let framed = try P2PControlFramePolicy.frame(body: padded)

        try await sendFramedContentProcessed(
            framed,
            over: connection,
            timeoutSeconds: Self.lanControlNetworkSubmitTimeoutSeconds,
            operation: "pairing-identity"
        )
    }
    
    private func send(
        data: Data,
        over connection: NWConnection,
        timeoutSeconds: TimeInterval,
        operation: String
    ) async throws {
        // Phase C2: optional padding for post-handshake business traffic (SBP2)
        let padded = try TrafficPadding.wrapForP2PControlFrame(data, label: "tx")

        // 与 macOS 端一致：4-byte big-endian length framing
        let framed = try P2PControlFramePolicy.frame(body: padded)

        try await sendFramedContentProcessed(
            framed,
            over: connection,
            timeoutSeconds: timeoutSeconds,
            operation: operation
        )
    }
    
    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: P2PError.noData)
                }
            }
        }
    }
}

@available(iOS 17.0, *)
extension P2PConnectionManager: PairingPolicyAuthorityParticipant {
    func preparePairingPolicyMutation(
        authorityKey: String,
        persistedValue: String?,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> PreparedPairingPolicyMutation? {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        let normalizedKey = authorityKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw PairingPolicyPersistenceError.writeFailed(
                "配对策略 authority key 为空"
            )
        }
        guard let persistedValue else { return nil }
        guard persistedValue == PairingTrustDecision.alwaysAllow.rawValue
                || persistedValue == PairingTrustDecision.reject.rawValue else {
            throw PairingPolicyPersistenceError.writeFailed(
                "配对策略值不允许持久化"
            )
        }
        let before = PairingPolicySnapshot(valuesByAuthorityID: pairingPolicyByPeerId)
        var candidate = pairingPolicyByPeerId
        candidate[normalizedKey] = persistedValue
        guard candidate != pairingPolicyByPeerId else { return nil }
        return PreparedPairingPolicyMutation(
            before: before,
            after: PairingPolicySnapshot(valuesByAuthorityID: candidate)
        )
    }

    func applyPreparedPairingPolicyMutation(
        _ prepared: PreparedPairingPolicyMutation,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        guard pairingPolicyByPeerId == prepared.before.valuesByAuthorityID else {
            throw PairingPolicyPersistenceError.concurrentModification
        }
        try persistPairingPolicy(
            prepared.after.valuesByAuthorityID,
            outerPermit: outerPermit
        )
        let changedKeys = Set(prepared.before.valuesByAuthorityID.keys)
            .union(prepared.after.valuesByAuthorityID.keys)
            .filter {
                prepared.before.valuesByAuthorityID[$0]
                    != prepared.after.valuesByAuthorityID[$0]
            }
        pairingPolicyByPeerId = prepared.after.valuesByAuthorityID
        for key in changedKeys {
            _ = try advancePairingPolicyRevision(for: key)
        }
    }

    func pairingPolicySnapshot(
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> PairingPolicySnapshot {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        return PairingPolicySnapshot(valuesByAuthorityID: pairingPolicyByPeerId)
    }

    func restorePairingPolicySnapshot(
        _ snapshot: PairingPolicySnapshot,
        expectedCurrent: [PairingPolicySnapshot],
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        guard expectedCurrent.contains(where: {
            $0.valuesByAuthorityID == pairingPolicyByPeerId
        }) else {
            throw PairingPolicyPersistenceError.concurrentModification
        }
        let previous = pairingPolicyByPeerId
        try persistPairingPolicy(
            snapshot.valuesByAuthorityID,
            outerPermit: outerPermit
        )
        pairingPolicyByPeerId = snapshot.valuesByAuthorityID
        let changedKeys = Set(previous.keys)
            .union(snapshot.valuesByAuthorityID.keys)
            .filter { previous[$0] != snapshot.valuesByAuthorityID[$0] }
        for key in changedKeys {
            _ = try advancePairingPolicyRevision(for: key)
        }
    }

    func pairingPolicySnapshotMatches(
        _ snapshot: PairingPolicySnapshot,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> Bool {
        try requirePairingPolicyPersistenceAvailable(outerPermit: outerPermit)
        return pairingPolicyByPeerId == snapshot.valuesByAuthorityID
    }
}

#if DEBUG || SKYBRIDGE_TESTING
@available(iOS 17.0, *)
extension P2PConnectionManager {
    func testOnlyStrictPQCRejectsInboundHandshake(
        supportedSuites: [CryptoSuite],
        localPQCAvailable: Bool = true
    ) -> Bool {
        guard pqcManager.enforcePQCHandshake else { return false }
        guard supportedSuites.contains(where: { $0.isPQCGroup }) else { return true }
        return !localPQCAvailable
    }

    func installUITestActiveConnections(_ connections: [Connection]) {
        activeConnections = connections
        connectionStatusByDeviceId = Dictionary(
            uniqueKeysWithValues: connections.map { ($0.device.id, $0.status) }
        )
        lastKnownDevices = Dictionary(
            uniqueKeysWithValues: connections.map { ($0.device.id, $0.device) }
        )
        lastError = nil
        currentHandshakeState = "UITest Fixture"
    }

    func testClearActiveConnectionsPreservingState() {
        activeConnections = []
    }

    func installUITestPairingPrompt(request: PairingTrustRequest) {
        pendingPairingTrustRequest = request
        uiTestPairingRequestIDs.insert(request.id)
    }

    func testOnlyAwaitPairingDecision(timeout: Duration) async -> PairingTrustDecision {
        let requestId = UUID()
        let peerId = "test-pairing-peer-\(requestId.uuidString)"
        let request = PairingTrustRequest(
            id: requestId,
            purpose: .protocolIdentityBinding,
            peerId: peerId,
            declaredDeviceId: peerId,
            deviceName: "Test Pairing Peer",
            platform: .macOS,
            modelName: "Test Model",
            osVersion: "TestOS",
            kemKeyCount: 0,
            verificationCode: "000000",
            protocolIdentityFingerprint: "test-fingerprint",
            receivedAt: Date()
        )
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: peerId,
            kemPublicKeys: []
        )
        return await awaitOperatorPairingTrustDecision(
            request: request,
            context: .pairingIdentityExchange(
                peerId: peerId,
                connectionGeneration: UUID(),
                payload: payload
            ),
            timeout: timeout,
            awaitingStatusLine: "test pairing approval awaiting",
            timeoutStatusLine: "test pairing approval timed out",
            cancellationStatusLine: "test pairing approval cancelled",
            busyStatusLine: "test pairing approval busy rejected"
        )
    }

    func testOnlyInstallStandalonePairingApproval(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) throws -> UUID {
        guard
            pendingPairingTrustRequest == nil
                && pendingPairingContextByRequestId.isEmpty
                && pendingPairingDecisionWaitersByRequestId.isEmpty
                && pendingStandalonePairingTimeoutTasksByRequestId.isEmpty
                && pendingStandalonePairingTimeoutGenerationByRequestId.isEmpty
        else {
            throw TestPairingApprovalError.stateNotReset
        }
        let requestId = UUID()
        let peerId = "test-standalone-pairing-peer-\(requestId.uuidString)"
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: peerId,
            kemPublicKeys: []
        )
        pendingPairingContextByRequestId[requestId] = .pairingIdentityExchange(
            peerId: peerId,
            connectionGeneration: UUID(),
            payload: payload
        )
        pendingPairingTrustRequest = PairingTrustRequest(
            id: requestId,
            purpose: .kemIdentityExchange,
            peerId: peerId,
            declaredDeviceId: peerId,
            deviceName: "Test Standalone Pairing Peer",
            platform: .macOS,
            modelName: "Test Model",
            osVersion: "TestOS",
            kemKeyCount: 0,
            verificationCode: nil,
            protocolIdentityFingerprint: nil,
            receivedAt: Date()
        )
        scheduleStandalonePairingApprovalTimeout(
            requestId: requestId,
            timeout: timeout,
            timeoutStatusLine: "test standalone pairing approval timed out",
            sleep: sleep
        )
        return requestId
    }

    var testOnlyPendingPairingDecisionWaiterCount: Int {
        pendingPairingDecisionWaitersByRequestId.count
    }

    var testOnlyStandalonePairingTimeoutTaskCount: Int {
        pendingStandalonePairingTimeoutTasksByRequestId.count
    }

    var testOnlyHasPendingPairingApproval: Bool {
        pendingPairingTrustRequest != nil || !pendingPairingContextByRequestId.isEmpty
    }

    func testOnlyResetPendingPairingDecisionState() {
        let waiters = Array(pendingPairingDecisionWaitersByRequestId.values)
        let standaloneTimeoutTasks = Array(
            pendingStandalonePairingTimeoutTasksByRequestId.values
        )
        pendingPairingDecisionWaitersByRequestId.removeAll()
        pendingStandalonePairingTimeoutTasksByRequestId.removeAll()
        pendingStandalonePairingTimeoutGenerationByRequestId.removeAll()
        pendingPairingContextByRequestId.removeAll()
        pendingPairingTrustRequest = nil
        uiTestPairingRequestIDs.removeAll()
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .reject)
        }
        for timeoutTask in standaloneTimeoutTasks {
            timeoutTask.cancel()
        }
    }

    func installTestPeerRuntimeState(
        runtimePeerId: String,
        status: ConnectionStatus = .connected,
        name: String = "Test Peer",
        ipAddress: String? = nil
    ) {
        let device = DiscoveredDevice(
            id: runtimePeerId,
            name: name,
            modelName: "Test Model",
            platform: .macOS,
            osVersion: "TestOS",
            ipAddress: ipAddress
        )
        lastKnownDevices[runtimePeerId] = device
        connectionStatusByDeviceId[runtimePeerId] = status
        connectionErrorByDeviceId.removeValue(forKey: runtimePeerId)
        registerRuntimePeerAliases(
            runtimePeerId: runtimePeerId,
            aliases: PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId)
        )
        peerPresentationIdByRuntimePeerId[runtimePeerId] = runtimePeerId
        activeConnections = [Connection(device: device, status: status)]
    }

    @discardableResult
    func testPromotePeerPresentationIdentity(
        runtimePeerId: String,
        declaredDeviceId: String,
        deviceName: String? = nil,
        modelName: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil
    ) -> String {
        promotePeerPresentationIdentityIfNeeded(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: deviceName,
            modelName: modelName,
            platform: platform,
            osVersion: osVersion
        )
    }

    func testInstallNegotiatedSuitePresentationCache(
        _ suite: CryptoSuite,
        for runtimePeerId: String
    ) {
        negotiatedSuiteByDeviceId[runtimePeerId] = suite
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        if presentationPeerId != runtimePeerId {
            negotiatedSuiteByDeviceId[presentationPeerId] = suite
        }
    }

    func testInstallAuthenticatedSession(
        _ suite: CryptoSuite,
        for runtimePeerId: String
    ) throws {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let lease = try installTrackedConnection(connection, for: runtimePeerId)
        let sessionNonce = UUID().uuidString
        let keys = SessionKeys(
            sendKey: Data(repeating: 0x41, count: 32),
            receiveKey: Data(repeating: 0x42, count: 32),
            negotiatedSuite: suite,
            transcriptHash: Data(sessionNonce.utf8),
            sessionId: "test-authenticated-\(sessionNonce)"
        )
        guard setSessionKeys(
            keys,
            for: runtimePeerId,
            connectionGeneration: lease.generation
        ) else {
            throw TestStateInstallationError.authenticatedSessionLeaseNotOwned
        }
        for peerId in connectionStatePeerIds(for: runtimePeerId) {
            connectionStatusByDeviceId[peerId] = .connected
        }
    }

    func testInstallRekeyStatus(
        fromSuite: String,
        toSuite: String,
        for runtimePeerId: String
    ) {
        setRekeyPresentationStatus(
            for: runtimePeerId,
            fromSuite: fromSuite,
            toSuite: toSuite
        )
    }

    func testResolveRuntimePeerId(forAnyPeerId peerId: String) -> String {
        runtimePeerId(forAnyPeerId: peerId)
    }

    func testResolveLatestConnectableDevice(for device: DiscoveredDevice) -> DiscoveredDevice {
        resolveLatestConnectableDevice(from: device)
    }

    func testResolveConnectableDeviceAwaitingControlRoute(
        for device: DiscoveredDevice
    ) async throws -> DiscoveredDevice {
        try await resolveConnectableDeviceAwaitingControlRoute(from: device)
    }

    func testMergeActiveConnectionMetadata(
        base: DiscoveredDevice,
        update: DiscoveredDevice
    ) -> DiscoveredDevice {
        mergeActiveConnectionMetadata(base: base, update: update)
    }

    func testMergePeerServiceMetadata(
        runtimePeerId: String,
        declaredDeviceId: String?,
        capabilities: [String]?,
        fileTransferPort: UInt16?,
        remoteControlPort: UInt16?
    ) {
        mergePeerServiceMetadata(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            capabilities: capabilities,
            fileTransferPort: fileTransferPort,
            remoteControlPort: remoteControlPort
        )
    }

    func testConnectionEndpointDescriptions(for device: DiscoveredDevice) -> [String] {
        connectionEndpointCandidates(for: device).map(\.debugDescription)
    }

    func testSimulateTerminalCleanup(
        runtimePeerId: String,
        terminalStatus: ConnectionStatus = .disconnected,
        error: String? = nil
    ) {
        if let lease = connections.lease(for: runtimePeerId) {
            _ = removeSessionKeysIfOwned(
                for: runtimePeerId,
                connectionGeneration: lease.generation
            )
            if let ownedConnection = connections.removeIfOwned(lease, for: runtimePeerId) {
                ownedConnection.cancel()
            }
        }
        let peerIds = connectionStatePeerIds(for: runtimePeerId)
        for peerId in peerIds {
            connectionStatusByDeviceId[peerId] = terminalStatus
            if let error {
                connectionErrorByDeviceId[peerId] = error
            } else {
                connectionErrorByDeviceId.removeValue(forKey: peerId)
            }
        }
        purgeTerminalConnectionPresentationState(for: runtimePeerId)
    }
}
#endif
