import Foundation
import Network
import CryptoKit
import ActivityKit
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
        let protocolStoreFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: candidates)
        let trustedDeviceFingerprints = await TrustedDeviceStore.shared.currentPathFingerprints(forAny: candidates)
        return protocolStoreFingerprints.union(trustedDeviceFingerprints)
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
    
    @Published public private(set) var activeConnections: [Connection] = []
    @Published public private(set) var isListening: Bool = false
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
    
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var sessionKeys: [String: SessionKeys] = [:] // device.id -> SessionKeys
    private var previousSessionKeysBeforeRekey: [String: SessionKeys] = [:]
    /// 握手驱动器缓存（用于响应方角色）
    private var handshakeDrivers: [String: HandshakeDriver] = [:]
    /// 兼容旧逻辑：握手过程中/早期阶段可能缓存 shared secret（最终以 sessionKeys 为准）
    private var sharedSecrets: [String: SecureBytes] = [:] // device.id -> shared secret
    private let queue = DispatchQueue(label: "com.skybridge.p2p", qos: .userInitiated)
    private var connectingCount: Int = 0
    private var inFlightConnectAliasesByPeerId: [String: Set<String>] = [:]
    private var inFlightConnectWaitersByPeerId: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var userInitiatedDisconnects: Set<String> = []
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var lastActivityByDeviceId: [String: Date] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var pathRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var betterPathRecoveryDeferredSince: [String: Date] = [:]
    private let betterPathRecoveryDeferIntervalSeconds: TimeInterval = 5
    private let betterPathRecoveryMaxDeferralSeconds: TimeInterval = 30
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectSuppressedDeviceIds: Set<String> = []
    private var lastKnownDevices: [String: DiscoveredDevice] = [:]
    private var selectedEndpointDescriptionByDeviceId: [String: String] = [:]
    private var pairKeyByDeviceId: [String: Data] = [:]
    private var strictInboundStablePeerIdByRuntimePeerId: [String: String] = [:]
    private var peerAliasToCanonicalDeviceId: [String: String] = [:]
    private var peerPresentationIdByRuntimePeerId: [String: String] = [:]
    
    /// Prevent pairing identity exchange ping-pong loops.
    private var lastPairingIdentityExchangeSentAt: [String: Date] = [:]
    private var lastPairingIdentityExchangeReceivedAt: [String: Date] = [:]
    private var lastPairingIdentityBootstrapReadyAt: [String: Date] = [:]
    private var lastAcceptedPairingIdentityDeviceIdByPeerId: [String: String] = [:]
    
    /// Bootstrap rekey tasks (Classic -> PQC) keyed by peerId.
    private var bootstrapRekeyTasks: [String: Task<Void, Never>] = [:]

    /// In-band rekey flag (pause heartbeat / non-essential business sends to reduce ciphertext-handshake interleaving).
    private var rekeyInProgress: Set<String> = []

    private func smokeInboundTrace(_ line: String) {
        SkyBridgeSmokeTraceWriter.appendStatus(line)
        SkyBridgeSmokeTraceWriter.append(line)
    }

    private nonisolated static func smokeSanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static var protocolIdentityLogRedaction: String { "<redacted>" }

    private nonisolated static func diagnosticErrorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "error_domain=\(nsError.domain) code=\(nsError.code)"
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
    
    private enum PendingPairingContext: Sendable {
        case pairingIdentityExchange(peerId: String, payload: AppMessage.PairingIdentityExchangePayload)
        case protocolIdentityBinding(PendingProtocolIdentityBindingContext)
        case requesterProtocolIdentityBinding(PendingRequesterProtocolIdentityBindingContext)
    }

    private struct PendingProtocolIdentityBindingContext: Sendable {
        let peerId: String
        let candidates: [String]
        let payload: AppMessage.SignedProtocolIdentityBindingPayload
    }

    private struct PendingRequesterProtocolIdentityBindingContext: Sendable {
        let requesterDeviceIds: [String]
        let requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        let requesterProtocolIdentityPublicKey: Data
        let requesterProtocolIdentityFingerprint: String
        let verificationCode: String
        let displayName: String
    }
    private var pendingPairingContextByRequestId: [UUID: PendingPairingContext] = [:]
    private var pendingPairingDecisionContinuationByRequestId: [UUID: CheckedContinuation<PairingTrustDecision, Never>] = [:]
    private var uiTestPairingRequestIDs: Set<UUID> = []
    
    private static let pairingPolicyStore = CodablePersistenceStore<[String: String]>(
        location: .protectedApplicationSupport(
            path: "P2P/pairing-policy.json",
            legacyUserDefaultsKey: "pairing_policy.v1"
        )
    )
    /// peerId -> decisionRawValue (only persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var pairingPolicyByPeerId: [String: String] = [:]

    private let heartbeatIntervalSeconds: TimeInterval = 20
    private let maxReconnectAttempts: Int = 8

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
        pairingPolicyByPeerId = Self.pairingPolicyStore.load() ?? [:]

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

        for trustedRecord in TrustedDeviceStore.shared.trustedDevices {
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
            do {
                let reboundFingerprint = try await attemptOOBProtocolIdentityBinding(
                    for: device,
                    candidates: candidates
                )
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
                signedRefreshFailureReason = "PIB-1 protocol identity binding failed: \(Self.diagnosticErrorSummary(error))"
                let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-identity-binding reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>failed"
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
            reconnectTasks[peerId]?.cancel()
            reconnectTasks.removeValue(forKey: peerId)
        }

        SkyBridgeLogger.shared.warning("🔐 \(message)")
        throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: expectedSuite))
    }

    private func trustedProtocolFingerprints(forAny candidates: [String]) async -> Set<String> {
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
        let routeCandidates = connectionEndpointCandidates(for: device, preferDirectHostPort: true)
        guard !routeCandidates.isEmpty else {
            throw signedLANRefreshFailure("no LAN endpoint candidates")
        }
        let directEndpoints = routeCandidates.filter {
            Self.signedLANRefreshEndpointClass($0) == "direct-host"
        }
        let directHostCandidate = !directEndpoints.isEmpty
        guard directHostCandidate else {
            throw signedLANRefreshFailure("missing direct LAN endpoint candidate")
        }
        let serviceFallbackEndpoints = routeCandidates.filter {
            Self.signedLANRefreshEndpointClass($0) == "bonjour-service"
        }
        let endpoints = directEndpoints + serviceFallbackEndpoints
        guard !endpoints.isEmpty else {
            throw signedLANRefreshFailure("no signed LAN refresh bootstrap endpoint candidates")
        }

        let requestedSuites = signedLANRefreshRequestedSuites(preferredTargetSuite: preferredTargetSuite)
        let requesterProtocolIdentityFingerprint = try await localProtocolIdentityFingerprintForSignedLANRefresh()
        guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates) else {
            throw signedLANRefreshFailure("missing stable protocol identity target; refusing endpoint alias target")
        }
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: localStablePersistentDeviceIdentifier(),
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
        let serviceFallbackCandidateCount = serviceFallbackEndpoints.count
        let connectStartLine = "🔐 SKR-1 signed LAN KEM refresh connect-start: peer=\(Self.protocolIdentityLogRedaction) endpointCount=\(endpoints.count) serviceFallbackCandidates=\(serviceFallbackCandidateCount) classicFallbackSuppressed=1 pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>connect"
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
        defer { connection.cancel() }

        let requestLine = "🔐 SKR-1 signed LAN KEM refresh request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) selectedEndpointClass=\(selectedEndpointClass) selectedEndpointDirect=\(selectedEndpointDirect ? 1 : 0) selectedEndpointPeerToPeer=\(connectionResult.selectedEndpointPeerToPeer ? 1 : 0) directHostCandidate=\(directHostCandidate ? 1 : 0) requesterProtocolIdentity=\(Self.protocolIdentityLogRedaction) suites=\(requestedSuites.map(\.rawValue).joined(separator: ",")) suiteWireIds=\(requestedSuites.map { String(format: "0x%04X", $0.wireId) }.joined(separator: ",")) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>request"
        SkyBridgeLogger.shared.info(requestLine)
        SignedKEMRefreshSmokeStatusWriter.append(requestLine)
        let exchangeStartedAt = Date()
        try await sendPlainFramed(JSONEncoder().encode(AppMessage.kemRefreshRequest(request)), over: connection)
        let responseFrame = try await receivePlainFrame(over: connection, timeoutSeconds: 6.0)
        let responseLatencyMs = Date().timeIntervalSince(exchangeStartedAt) * 1_000.0
        let response = try JSONDecoder().decode(AppMessage.self, from: responseFrame)
        if case .kemRefreshFailure(let failure) = response {
            throw signedLANRefreshFailure(
                "remote rejected SKR-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode)"
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
        let endpoints = connectionEndpointCandidates(for: device, preferDirectHostPort: true)
        guard !endpoints.isEmpty else {
            throw protocolIdentityBindingFailure("no LAN endpoint candidates")
        }

        let requesterIdentity = try await localProtocolIdentityProofForProtocolBinding()
        guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates) else {
            throw protocolIdentityBindingFailure("missing stable protocol identity target; refusing endpoint alias target")
        }
        let unsignedRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: localStablePersistentDeviceIdentifier(),
            targetDeviceId: targetProtocolDeviceId,
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
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

        let responseTimeoutSeconds = Self.protocolIdentityBindingResponseTimeoutSeconds()
        let requestLine = "🔐 PIB-1 protocol identity binding request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) algorithms=\(request.requestedProtocolSigningAlgorithms.joined(separator: ",")) responseTimeoutSeconds=\(Int(responseTimeoutSeconds)) lifecycle=identity-oob>request"
        SkyBridgeLogger.shared.info(requestLine)
        SignedKEMRefreshSmokeStatusWriter.append(requestLine)
        try await sendPlainFramed(JSONEncoder().encode(AppMessage.protocolIdentityBindingRequest(request)), over: connection)
        let responseFrame = try await receivePlainFrame(
            over: connection,
            timeoutSeconds: responseTimeoutSeconds
        )
        let response = try JSONDecoder().decode(AppMessage.self, from: responseFrame)
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

        return validated.protocolIdentityFingerprint.lowercased()
    }

    @MainActor
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
        let trustedFingerprints = await ProtocolIdentityTrustStore.shared
            .trustedFingerprints(forAny: policyCandidates)
            .union(TrustedDeviceStore.shared.currentPathFingerprints(forAny: policyCandidates))
        if let storedPolicyAction = Self.protocolIdentityBindingStoredPolicyAction(
            pairingPolicyByPeerId: pairingPolicyByPeerId,
            policyCandidates: policyCandidates,
            trustedProtocolFingerprints: trustedFingerprints,
            payloadFingerprint: payload.protocolIdentityFingerprint
        ) {
            switch storedPolicyAction {
            case .approve(let operatorLabel):
                guard await installOOBProtocolIdentityBinding(.init(
                    peerId: device.id,
                    candidates: policyCandidates,
                    payload: payload
                ), clearExisting: false) else {
                    let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_pin_promotion_failed lifecycle=identity-oob>failed"
                    SkyBridgeLogger.shared.warning(line)
                    SignedKEMRefreshSmokeStatusWriter.append(line)
                    return .reject
                }
                let line = "🔐 PIB-1 protocol identity binding operator approved: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=\(operatorLabel) lifecycle=identity-oob>pinned"
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

        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            guard await installOOBProtocolIdentityBinding(.init(
                peerId: device.id,
                candidates: policyCandidates,
                payload: payload
            )) else {
                let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) reason=authority_pin_promotion_failed lifecycle=identity-oob>failed"
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
                return .reject
            }
            let line = "🔐 PIB-1 protocol identity binding operator approved: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=smoke-auto-approve lifecycle=identity-oob>pinned"
            SkyBridgeLogger.shared.info(line)
            SignedKEMRefreshSmokeStatusWriter.append(line)
            return .alwaysAllow
        }

        let requestId = UUID()
        let displayName = payload.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingPairingContextByRequestId[requestId] = .protocolIdentityBinding(.init(
            peerId: device.id,
            candidates: policyCandidates,
            payload: payload
        ))
        pendingPairingTrustRequest = PairingTrustRequest(
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
        SkyBridgeLogger.shared.info(awaitingLine)
        SignedKEMRefreshSmokeStatusWriter.append(awaitingLine)
        return await withCheckedContinuation { continuation in
            pendingPairingDecisionContinuationByRequestId[requestId] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(approvalTimeoutSeconds))
                guard let self,
                      let timedOut = self.pendingPairingDecisionContinuationByRequestId.removeValue(forKey: requestId) else {
                    return
                }
                self.pendingPairingContextByRequestId.removeValue(forKey: requestId)
                if self.pendingPairingTrustRequest?.id == requestId {
                    self.pendingPairingTrustRequest = nil
                }
                let line = "⏳ PIB-1 protocol identity binding approval timed out: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(approvalTimeoutSeconds) lifecycle=identity-oob>timeout"
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
                timedOut.resume(returning: .timedOut)
            }
        }
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
        guard TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
            peerId: context.peerId,
            deviceId: payload.deviceId,
            aliases: context.candidates + payload.aliases,
            displayName: payload.deviceName,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: payload.protocolIdentityFingerprint
        ) else {
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
        guard TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
            peerId: context.requesterDeviceIds.first ?? context.displayName,
            deviceId: context.requesterDeviceIds.first ?? context.displayName,
            aliases: context.requesterDeviceIds,
            displayName: context.displayName,
            protocolSigningAlgorithm: context.requesterProtocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: context.requesterProtocolIdentityFingerprint
        ) else {
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

    private func sendPlainFramed(_ data: Data, over connection: NWConnection) async throws {
        var framed = Data()
        var length = UInt32(data.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receivePlainFrame(over connection: NWConnection, timeoutSeconds: Double) async throws -> Data {
        let header = try await receiveExactly(4, from: connection, timeoutSeconds: timeoutSeconds)
        let length = Int(header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        })
        guard length > 0 && length <= 1_048_576 else {
            throw signedLANRefreshFailure("invalid response frame length \(length)")
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

    nonisolated static func signedLANRefreshFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.SignedLANRefresh",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private func signedLANRefreshFailure(_ reason: String) -> NSError {
        Self.signedLANRefreshFailure(reason)
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
    ) async throws {
        let peerId = canonicalPeerLookupKey(device.id)
        let targetSuite = preferredRekeyTargetSuite() ?? CryptoSuite.xwing.rawValue

        SkyBridgeLogger.shared.info(
            "🧩 P2P classic bootstrap start: peer=\(Self.protocolIdentityLogRedaction) targetSuite=\(targetSuite)"
        )
        currentHandshakeState = "经典 bootstrap 中..."

        try await performPQCHandshake(
            connection: connection,
            device: device,
            preferPQC: false,
            selectionPolicyOverride: .classicOnly
        )

        scheduleBootstrapRekeyIfNeeded(peerId: peerId, suiteRaw: targetSuite)
        let observedAt = Date()
        try await sendPairingIdentityExchange(to: peerId)
        SkyBridgeLogger.shared.info(
            "📤 已发送 pairingIdentityExchange 触发 PQC bootstrap: peer=\(Self.protocolIdentityLogRedaction)"
        )

        let observedReply = await waitForPairingIdentityExchangeActivity(
            with: peerId,
            since: observedAt,
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

        try await waitForBootstrapRekeyCompletion(peerId: peerId, targetSuite: targetSuite)
    }

    private func waitForBootstrapRekeyCompletion(
        peerId: String,
        targetSuite: String,
        timeout: Duration = .seconds(35)
    ) async throws {
        let runtimePeerId = canonicalPeerLookupKey(peerId)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if let suite = resolvedNegotiatedSuite(forAnyPeerId: runtimePeerId),
               suite.isPQCGroup {
                SkyBridgeLogger.shared.info(
                    "✅ bootstrap-assisted PQC rekey 完成: peer=\(Self.protocolIdentityLogRedaction) suite=\(suite.rawValue)"
                )
                return
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

            if connections[runtimePeerId] == nil || sessionKeys[runtimePeerId] == nil {
                throw P2PError.connectionFailed
            }

            try? await Task.sleep(for: .milliseconds(150))
        }

        bootstrapRekeyTasks[runtimePeerId]?.cancel()
        bootstrapRekeyTasks.removeValue(forKey: runtimePeerId)
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
    
    private func savePairingPolicy() {
        try? Self.pairingPolicyStore.save(pairingPolicyByPeerId)
    }
    
    /// Called by UI to resolve a pending pairing/trust request.
    @MainActor
    public func resolvePairingTrustRequest(_ request: PairingTrustRequest, decision: PairingTrustDecision) async {
        if uiTestPairingRequestIDs.remove(request.id) != nil {
            pendingPairingTrustRequest = nil
            switch decision {
            case .alwaysAllow:
                pairingPolicyByPeerId[request.peerId] = PairingTrustDecision.alwaysAllow.rawValue
                savePairingPolicy()
            case .reject:
                pairingPolicyByPeerId[request.peerId] = PairingTrustDecision.reject.rawValue
                savePairingPolicy()
            case .allowOnce, .timedOut:
                break
            }
            return
        }

        guard let ctx = pendingPairingContextByRequestId.removeValue(forKey: request.id) else {
            pendingPairingTrustRequest = nil
            return
        }

        pendingPairingTrustRequest = nil

        switch ctx {
        case .pairingIdentityExchange(let peerId, let payload):
            switch decision {
            case .alwaysAllow:
                pairingPolicyByPeerId[peerId] = PairingTrustDecision.alwaysAllow.rawValue
                savePairingPolicy()
                await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: true, persistTrust: true)
            case .allowOnce:
                await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: false, persistTrust: false)
            case .reject:
                pairingPolicyByPeerId[peerId] = PairingTrustDecision.reject.rawValue
                savePairingPolicy()
                SkyBridgeLogger.shared.warning("🛑 Pairing/trust request rejected: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
            case .timedOut:
                SkyBridgeLogger.shared.warning("⏳ Pairing/trust request timed out: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
            }
        case .protocolIdentityBinding(let context):
            var resolutionDecision = decision
            switch decision {
            case .alwaysAllow, .allowOnce:
                if !(await installOOBProtocolIdentityBinding(context)) {
                    resolutionDecision = .reject
                    let line = "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) reason=authority_pin_promotion_failed lifecycle=identity-oob>failed"
                    SkyBridgeLogger.shared.warning(line)
                    SignedKEMRefreshSmokeStatusWriter.append(line)
                }
            case .reject:
                SkyBridgeLogger.shared.warning(
                    "🛑 PIB-1 protocol identity binding rejected: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            case .timedOut:
                SkyBridgeLogger.shared.warning(
                    "⏳ PIB-1 protocol identity binding timed out: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            }
            pendingPairingDecisionContinuationByRequestId.removeValue(forKey: request.id)?.resume(returning: resolutionDecision)
        case .requesterProtocolIdentityBinding(let context):
            var resolutionDecision = decision
            switch decision {
            case .alwaysAllow, .allowOnce:
                if !(await installInboundRequesterProtocolIdentityBinding(context)) {
                    resolutionDecision = .reject
                    let line = "⛔️ PIB-1 requester protocol identity pin failed: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) reason=authority_pin_promotion_failed lifecycle=identity-oob>requester-pin-failed"
                    SkyBridgeLogger.shared.warning(line)
                    SignedKEMRefreshSmokeStatusWriter.append(line)
                }
            case .reject:
                SkyBridgeLogger.shared.warning(
                    "🛑 PIB-1 requester protocol identity binding rejected: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            case .timedOut:
                SkyBridgeLogger.shared.warning(
                    "⏳ PIB-1 requester protocol identity binding timed out: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
                )
            }
            pendingPairingDecisionContinuationByRequestId.removeValue(forKey: request.id)?.resume(returning: resolutionDecision)
        }
    }

    public func clearTrustMaterialForForgottenDevice(deviceIds rawDeviceIds: [String]) async {
        let candidates = Self.expandedTrustMaterialCandidates(for: rawDeviceIds)
        guard !candidates.isEmpty else { return }
        let candidateSet = Set(candidates)

        for candidate in candidates {
            await KEMTrustStore.shared.clear(deviceId: candidate)
            await ProtocolIdentityTrustStore.shared.clear(deviceId: candidate)
        }

        for key in stateKeysMatchingAliases(candidateSet, keys: connections.keys) {
            connections[key]?.cancel()
            connections.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: sessionKeys.keys) {
            sessionKeys.removeValue(forKey: key)
            previousSessionKeysBeforeRekey.removeValue(forKey: key)
            sharedSecrets.removeValue(forKey: key)
            handshakeDrivers.removeValue(forKey: key)
            await transport?.removeConnection(for: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: reconnectTasks.keys) {
            reconnectTasks[key]?.cancel()
            reconnectTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: pathRecoveryTasks.keys) {
            pathRecoveryTasks[key]?.cancel()
            pathRecoveryTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: heartbeatTasks.keys) {
            heartbeatTasks[key]?.cancel()
            heartbeatTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(candidateSet, keys: bootstrapRekeyTasks.keys) {
            bootstrapRekeyTasks[key]?.cancel()
            bootstrapRekeyTasks.removeValue(forKey: key)
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
        var pairingPolicyChanged = false
        for key in stateKeysMatchingAliases(candidateSet, keys: pairingPolicyByPeerId.keys) {
            pairingPolicyByPeerId.removeValue(forKey: key)
            pairingPolicyChanged = true
        }
        if pairingPolicyChanged {
            savePairingPolicy()
        }
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
    
    // MARK: - Public Methods
    
    /// 开始监听连接（使用 DeviceDiscoveryManager 的广播功能）
    public func startListening() async throws {
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
        
        // 使用 DeviceDiscoveryManager 的广播功能；必须看到真实 ready listener 证明，
        // 不能只信 isAdvertising 布尔值，否则 Bonjour 缓存可能被误认为 TCP 控制端口可达。
        let controlPort: UInt16 = 9527
        let beforeStart = discoveryManager.advertisingReadinessSnapshot
        if beforeStart.isReady(for: controlPort) {
            SkyBridgeLogger.shared.debug("📡 P2P Bonjour 广播已就绪，继续确认传输层")
        } else {
            try await discoveryManager.startAdvertising(port: controlPort)
        }
        let readiness = discoveryManager.advertisingReadinessSnapshot
        guard readiness.isReady(for: controlPort) else {
            isListening = false
            let message = "P2P 广播监听未进入可用状态: requestedPort=\(controlPort) actualPort=\(readiness.actualPort.map(String.init) ?? "-") handlerInstalled=\(readiness.handlerInstalled ? 1 : 0) generation=\(readiness.readyGeneration)"
            lastError = message
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
    
    /// 停止监听
    public func stopListening() {
        discoveryManager.stopAdvertising()
        listener?.cancel()
        listener = nil
        isListening = false
        
        SkyBridgeLogger.shared.info("⏹️ P2P 监听器已停止")
    }

    /// 握手验证码（6 位数字）——用于“配对/信任”阶段的人工可视比对（论文中的 OOB pairing ceremony）。
    ///
    /// - Important: Code is deterministically derived from the *handshake transcript hash* to bind user verification
    ///   to the negotiated suite + policy + key shares. Both peers compute the same value after a successful handshake.
    public func pairingVerificationCode(for deviceId: String) -> String? {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let keys = sessionKeys[deviceId] else { return nil }

        var material = Data("SkyBridge-Pairing-SAS|".utf8)
        material.append(keys.transcriptHash)

        let digest = SHA256.hash(data: material)
        let raw = digest.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
        let code = Int(raw % 1_000_000)
        return String(format: "%06d", code)
    }
    
    /// 连接到设备
    public func connect(to device: DiscoveredDevice) async throws {
        var resolvedTargetDevice = resolveLatestConnectableDevice(from: device)
        await repairLegacyTrustedIdentityIfNeeded(
            requestedDevice: device,
            resolvedDevice: resolvedTargetDevice
        )
        resolvedTargetDevice = resolveLatestConnectableDevice(from: device)
        let preferredTrustedPeerId = preferredTrustedPeerIdentifier(for: resolvedTargetDevice)
        let stableProtocolPeerId = stableProtocolIdentityCandidate(
            from: peerKEMLookupCandidates(for: resolvedTargetDevice)
        )
        let shouldTreatTargetAsTrusted = preferredTrustedPeerId != nil
        let canonicalTargetId = registerCanonicalPeerIdentity(
            candidate: resolvedTargetDevice,
            primaryPeerId: preferredTrustedPeerId ?? stableProtocolPeerId ?? resolvedTargetDevice.id
        )
        let targetDevice = canonicalizedDevice(
            resolvedTargetDevice,
            canonicalPeerId: canonicalTargetId,
            trustHint: shouldTreatTargetAsTrusted
        )
        if targetDevice.id != device.id {
            SkyBridgeLogger.shared.info("ℹ️ P2P 连接目标已补全: \(device.id) -> \(targetDevice.id)")
        }
        if let preferredTrustedPeerId, preferredTrustedPeerId == targetDevice.id {
            SkyBridgeLogger.shared.info("🔐 P2P 连接已命中受信任设备别名: \(resolvedTargetDevice.id) -> \(preferredTrustedPeerId)")
        }

        if isSelfConnectionTarget(targetDevice) {
            connectionStatusByDeviceId[targetDevice.id] = .failed
            connectionErrorByDeviceId[targetDevice.id] = "已阻止自连接"
            SkyBridgeLogger.shared.warning("⚠️ 已阻止可能的自连接目标: \(targetDevice.id)")
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
            await waitForInFlightConnect(inFlightKey)
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
            try await connect(to: device)
            return
        }

        // 并发限制（来自 Settings）
        let limit = max(1, SettingsManager.instance.maxConcurrentConnections)
        guard connectingCount < limit else {
            throw P2PError.tooManyConcurrentConnections
        }
        let inFlightConnectKey = registerInFlightConnect(for: targetDevice, runtimePeerId: runtimePeerId)
        defer { finishInFlightConnect(inFlightConnectKey) }
        if connections[targetDevice.id] != nil || connections[runtimePeerId] != nil || hasStoredSessionMaterial(for: targetDevice.id) {
            clearStaleInboundSessionState(
                for: targetDevice.id,
                reason: "connect_requires_authenticated_session"
            )
            let aliases = connectionAliasSet(for: runtimePeerId)
                .union(PeerIdentityAliasResolver.lookupCandidates(for: targetDevice.id))
                .union([targetDevice.id, runtimePeerId])
            for key in stateKeysMatchingAliases(aliases, keys: connections.keys) {
                connections[key]?.cancel()
                connections.removeValue(forKey: key)
                await transport?.removeConnection(for: key)
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
            throw P2PError.noConnectableEndpoint
        }

        // 更新状态（UI：连接中）
        connectionStatusByDeviceId[targetDevice.id] = .connecting
        connectionErrorByDeviceId.removeValue(forKey: targetDevice.id)
        lastKnownDevices[targetDevice.id] = targetDevice

        var didAttemptStaleKEMRefresh = false
        var establishedConnection: NWConnection?

        while true {
            try await ensureStrictPQCKEMTrustReady(for: targetDevice)

            let (connection, selectedEndpoint) = try await establishReadyConnection(
                to: endpoints,
                for: targetDevice
            )
            installConnectionObservers(connection, for: targetDevice)
            connections[targetDevice.id] = connection
            selectedEndpointDescriptionByDeviceId[targetDevice.id] = selectedEndpoint.debugDescription
            await handleConnectionStateChange(.ready, for: targetDevice)

            SkyBridgeLogger.shared.info("🔗 已连接候选端点：device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction)")

            // 发起方也必须开始接收（握手 MessageB 需要被路由到 HandshakeDriver）
            startReceiving(from: connection, peerId: targetDevice.id)

            do {
                if try await shouldUseClassicBootstrapForStrictPQC(device: targetDevice) {
                    try await performBootstrapAssistedPQCHandshake(
                        connection: connection,
                        device: targetDevice
                    )
                } else {
                    try await performPQCHandshake(
                        connection: connection,
                        device: targetDevice,
                        preferPQC: pqcManager.enforcePQCHandshake
                    )
                }
                establishedConnection = connection
                break
            } catch {
                // strictPQC is fail-closed: stale KEM may enter SKR-1 recovery;
                // it must not establish a Classic bootstrap channel or fake success.
                connection.cancel()
                connections.removeValue(forKey: targetDevice.id)
                sessionKeys.removeValue(forKey: targetDevice.id)
                previousSessionKeysBeforeRekey.removeValue(forKey: targetDevice.id)
                handshakeDrivers.removeValue(forKey: targetDevice.id)
                sharedSecrets.removeValue(forKey: targetDevice.id)
                await transport?.removeConnection(for: targetDevice.id)
                activeConnections.removeAll { $0.device.id == targetDevice.id }

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
                    reconnectTasks[targetDevice.id]?.cancel()
                    reconnectTasks.removeValue(forKey: targetDevice.id)
                } else if await handleStalePeerKEMFailureIfNeeded(error, for: targetDevice) {
                    reconnectTasks[targetDevice.id]?.cancel()
                    reconnectTasks.removeValue(forKey: targetDevice.id)
                } else {
                    scheduleReconnectIfNeeded(deviceId: targetDevice.id)
                }
                throw error
            }
        }

        if pqcManager.enforcePQCHandshake,
           let negotiated = sessionKeys[targetDevice.id]?.negotiatedSuite,
           !negotiated.isPQCGroup {
            let message = "严格 PQC 已启用，但会话竟然协商到了 Classic suite=\(negotiated.rawValue)；已拒绝保留该连接。"
            SkyBridgeLogger.shared.error("⛔️ \(message)")
            establishedConnection?.cancel()
            connections.removeValue(forKey: targetDevice.id)
            sessionKeys.removeValue(forKey: targetDevice.id)
            previousSessionKeysBeforeRekey.removeValue(forKey: targetDevice.id)
            handshakeDrivers.removeValue(forKey: targetDevice.id)
            sharedSecrets.removeValue(forKey: targetDevice.id)
            await transport?.removeConnection(for: targetDevice.id)
            activeConnections.removeAll { $0.device.id == targetDevice.id }
            connectionStatusByDeviceId[targetDevice.id] = .failed
            connectionErrorByDeviceId[targetDevice.id] = message
            throw P2PError.pqcRequiredUnavailable
        }
        
        // Paper-aligned contract:
        // connected == handshake finished && session keys ready (not just transport ready).
        SkyBridgeLogger.shared.info("✅ 已连接到 \(targetDevice.name)")
        connectionStatusByDeviceId[targetDevice.id] = .connected
        connectionErrorByDeviceId.removeValue(forKey: targetDevice.id)
        upsertActiveConnection(device: targetDevice, status: .connected)
        discoveryManager.setConnectionLiveness(for: targetDevice, isConnected: true)
        startHeartbeatIfNeeded(deviceId: targetDevice.id)

        // 更新灵动岛状态（iOS 17+）
        let suite = sessionKeys[targetDevice.id]?.negotiatedSuite.rawValue ?? "已连接"
        Task {
            await LiveActivityManager.shared.setConnected(deviceName: targetDevice.name, cryptoSuite: suite)
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
                await sendPeerDisconnectingNotice(to: runtimePeerId, device: targetDevice)
                for peerId in peerIds {
                    connectionStatusByDeviceId[peerId] = .disconnecting
                }
                userInitiatedDisconnects.insert(runtimePeerId)
                heartbeatTasks[runtimePeerId]?.cancel()
                heartbeatTasks.removeValue(forKey: runtimePeerId)
                reconnectTasks[runtimePeerId]?.cancel()
                reconnectTasks.removeValue(forKey: runtimePeerId)
                reconnectAttempts.removeValue(forKey: runtimePeerId)
                cancelPeerProtectionRoots(for: runtimePeerId)
                connections[runtimePeerId]?.cancel()
                connections.removeValue(forKey: runtimePeerId)
                sharedSecrets.removeValue(forKey: runtimePeerId)
                sessionKeys.removeValue(forKey: runtimePeerId)
                previousSessionKeysBeforeRekey.removeValue(forKey: runtimePeerId)
                negotiatedSuiteByDeviceId.removeValue(forKey: runtimePeerId)
                handshakeDrivers.removeValue(forKey: runtimePeerId)
                await transport?.removeConnection(for: runtimePeerId)
                await releaseArbiterState(for: runtimePeerId)

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
                guard bodyLen > 0, bodyLen <= 2_000_000 else {
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
                        if let payload, !payload.isEmpty {
                            self.smokeInboundTrace(
                                "p2p-inbound rx-body peer=\(Self.protocolIdentityLogRedaction) bytes=\(payload.count)"
                            )
                            if let promoteInboundDevice {
                                let unwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
                                if await self.handlePreHandshakeBootstrapControlMessage(
                                    unwrapped,
                                    from: peerId,
                                    over: connection
                                ) {
                                    self.smokeInboundTrace(
                                        "p2p-inbound provisional-bootstrap-control-consumed peer=\(Self.protocolIdentityLogRedaction)"
                                    )
                                    connection.cancel()
                                    return
                                }

                                guard await self.prepareProvisionalInboundHandshakeDriver(
                                    for: peerId,
                                    firstFrame: unwrapped
                                ) else {
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
                            }

                            await self.handleReceivedMessage(payload, from: peerId)
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
        if let existing = connections[canonicalPeerId], existing !== connection {
            smokeInboundTrace(
                "p2p-inbound replacing-active-connection peer=\(Self.protocolIdentityLogRedaction)"
            )
            existing.cancel()
        }

        lastKnownDevices[canonicalPeerId] = canonicalDevice
        connectionStatusByDeviceId[canonicalPeerId] = .connecting
        connectionErrorByDeviceId.removeValue(forKey: canonicalPeerId)
        connections[canonicalPeerId] = connection
        installConnectionObservers(connection, for: canonicalDevice)
        await handleConnectionStateChange(.ready, for: canonicalDevice, connection: connection)

        await transport.setConnection(connection, for: canonicalPeerId)
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
        firstFrame: Data
    ) async -> Bool {
        let handshakeFrame = HandshakePadding.unwrapIfNeeded(firstFrame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame),
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
            driver = await ensureInboundRekeyDriverIfNeeded(for: canonicalPeerId, frame: handshakeFrame)
        } else {
            driver = await ensureInboundHandshakeDriverIfNeeded(for: canonicalPeerId, frame: handshakeFrame)
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
        let peerId = canonicalPeerLookupKey(peerId)
        smokeInboundTrace(
            "p2p-inbound cleanup-broken peer=\(Self.protocolIdentityLogRedaction) reason=\(Self.smokeSanitize(reason))"
        )
        connection.cancel()

        let isTrackedConnection = connections[peerId].map { $0 === connection } ?? false
        guard isTrackedConnection else { return }

        connections.removeValue(forKey: peerId)
        handshakeDrivers.removeValue(forKey: peerId)
        sharedSecrets.removeValue(forKey: peerId)
        sessionKeys.removeValue(forKey: peerId)
        previousSessionKeysBeforeRekey.removeValue(forKey: peerId)
        negotiatedSuiteByDeviceId.removeValue(forKey: peerId)
        heartbeatTasks[peerId]?.cancel()
        heartbeatTasks.removeValue(forKey: peerId)
        reconnectTasks[peerId]?.cancel()
        reconnectTasks.removeValue(forKey: peerId)
        reconnectAttempts.removeValue(forKey: peerId)
        connectionStatusByDeviceId[peerId] = .failed
        connectionErrorByDeviceId[peerId] = reason
        discoveryManager.setConnectionLiveness(
            for: makeActiveConnectionDevice(peerId: peerId, connection: connection),
            isConnected: false
        )
        Task { @MainActor in
            await self.releaseArbiterState(for: peerId)
        }
    }

    /// 处理收到的消息
    private func handleReceivedMessage(_ data: Data, from peerId: String) async {
        let peerId = canonicalPeerLookupKey(peerId)
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
            smokeInboundTrace(
                "p2p-inbound dispatch existing-driver peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: driver)
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
        if let freshInboundDriver = await ensureInboundHandshakeDriverIfNeeded(for: peerId, frame: unwrapped) {
            smokeInboundTrace(
                "p2p-inbound dispatch fresh-handshake peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: freshInboundDriver)
            return
        }

        // 支持“已建立会话上的入站 rekey”：
        // 若当前无 driver 但已存在 sessionKeys，且收到的是 MessageA，则切换回握手模式而不是误当业务密文。
        if let rekeyDriver = await ensureInboundRekeyDriverIfNeeded(for: peerId, frame: unwrapped) {
            smokeInboundTrace(
                "p2p-inbound dispatch rekey peer=\(Self.protocolIdentityLogRedaction)"
            )
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: rekeyDriver)
            return
        }

        // 握手完成后的业务消息（加密通道）
        if handshakeDrivers[peerId] == nil, sessionKeys[peerId] != nil {
            // 兼容：避免把握手控制包（尤其是 Finished 38 bytes）当作业务消息去解密，导致 CryptoKitError 3 日志
            if isLikelyHandshakeControlPacket(unwrapped) {
                SkyBridgeLogger.shared.debug("ℹ️ 收到握手控制包（忽略）：\(unwrapped.count) bytes")
                return
            }
            do {
                let plaintext = try decryptFromDevice(unwrapped, deviceId: peerId)
                let msg = try JSONDecoder().decode(AppMessage.self, from: plaintext)
                await handleAppMessage(msg, from: peerId)
            } catch {
                // 如果不是业务消息（比如对端还在发旧格式），忽略即可
                SkyBridgeLogger.shared.debug("ℹ️ 无法解析业务消息（忽略）：\(Self.diagnosticErrorSummary(error))")
                smokeInboundTrace(
                    "p2p-inbound app-message-ignored peer=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
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

    private func handlePreHandshakeBootstrapControlMessage(
        _ data: Data,
        from peerId: String,
        over provisionalConnection: NWConnection? = nil
    ) async -> Bool {
        guard handshakeDrivers[peerId] == nil else { return false }
        if provisionalConnection == nil, sessionKeys[peerId] != nil { return false }
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx")
        guard let message = try? JSONDecoder().decode(AppMessage.self, from: frame) else {
            return false
        }
        switch message {
        case .kemRefreshRequest, .protocolIdentityBindingRequest:
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
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "kem_refresh",
                    reasonCode: Self.signedKEMRefreshFailureCode(for: error),
                    reason: error.localizedDescription,
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
                let failure = AppMessage.KEMRefreshFailurePayload(
                    requesterDeviceId: request.requesterDeviceId,
                    targetDeviceId: request.targetDeviceId,
                    stage: "identity_binding",
                    reasonCode: Self.protocolIdentityBindingFailureCode(for: error),
                    reason: error.localizedDescription,
                    requestHashHex: request.canonicalRequestHashHex
                )
                let line = "⛔️ PIB-1 protocol identity binding rejected: requester=\(Self.protocolIdentityLogRedaction) target=\(Self.protocolIdentityLogRedaction) reasonCode=\(failure.reasonCode) reason=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>rejected"
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

        let admission = await SignedKEMRefreshRequestAdmissionGate.shared.admit(
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

        let localId = localStablePersistentDeviceIdentifier()
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
        return AppMessage.SignedKEMRefreshPayload(
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

        let requestedAlgorithms = request.requestedProtocolSigningAlgorithms.compactMap { raw in
            ProtocolSigningAlgorithm(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let candidateAlgorithms = [ProtocolSigningAlgorithm.mlDSA65, .ed25519].filter { algorithm in
            requestedAlgorithms.isEmpty || requestedAlgorithms.contains(algorithm)
        }
        guard !candidateAlgorithms.isEmpty else {
            throw protocolIdentityBindingFailure("no requested protocol identity algorithm available")
        }
        let selectedIdentity = try await localProtocolIdentityProofForProtocolBinding(
            candidateAlgorithms: candidateAlgorithms
        )
        let localId = localStablePersistentDeviceIdentifier()
        let now = Date()
        let unsigned = AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: localId,
            aliases: PeerIdentityAliasResolver.lookupCandidates(for: localId),
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
        let code = signed.shortAuthenticationCode(request: request)
        let decision = await stageInboundRequesterProtocolIdentityApproval(
            request: request,
            peerId: peerId,
            requesterAlgorithm: requesterAlgorithm,
            requesterPublicKey: requesterIdentity.publicKey,
            requesterFingerprint: requesterFingerprint,
            verificationCode: code
        )
        guard decision != .reject, decision != .timedOut else {
            throw protocolIdentityBindingFailure("operator rejected requester protocol identity")
        }
        return signed
    }

    private func stageInboundRequesterProtocolIdentityApproval(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        peerId: String,
        requesterAlgorithm: ProtocolSigningAlgorithm,
        requesterPublicKey: Data,
        requesterFingerprint: String,
        verificationCode: String
    ) async -> PairingTrustDecision {
        let requesterIds = Self.inboundBootstrapDeviceIdCandidates(request.requesterDeviceId)
        guard !requesterIds.isEmpty else { return .reject }
        let stableRequesterId = requesterIds.first ?? request.requesterDeviceId
        let policyKey = "PIB-1-requester|\(stableRequesterId)|\(requesterAlgorithm.rawValue)|\(requesterFingerprint)"
        let context = PendingRequesterProtocolIdentityBindingContext(
            requesterDeviceIds: requesterIds,
            requesterProtocolSigningAlgorithm: requesterAlgorithm,
            requesterProtocolIdentityPublicKey: requesterPublicKey,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            verificationCode: verificationCode,
            displayName: request.requesterDeviceId
        )

        if let raw = pairingPolicyByPeerId[policyKey] ?? pairingPolicyByPeerId[stableRequesterId],
           let stored = PairingTrustDecision(rawValue: raw) {
            switch stored {
            case .alwaysAllow:
                return await installInboundRequesterProtocolIdentityBinding(context) ? .alwaysAllow : .reject
            case .reject:
                return .reject
            case .allowOnce, .timedOut:
                break
            }
        }

        // Symmetry fix (Mac→iOS): if this requester's protocol identity is ALREADY pinned in our
        // trust stores (i.e. a prior successful iOS→Mac pairing recorded this Mac's authority), it is
        // a known, previously-approved device — not a cold/stranger peer. Auto-approve WITHOUT raising
        // the 180s operator-approval prompt, so the operator does not have to be physically at the iPad.
        //
        // Security invariant: `requesterFingerprint` here is the signature-VERIFIED protocol identity
        // fingerprint (the requester's PIB-1 signature over `request.canonicalPreimage` was already
        // checked in `makeInboundSignedProtocolIdentityBindingPayload`). We only auto-approve when that
        // verified fingerprint is present in the pinned set for the requester's device-id candidates.
        // This is the EXACT same revocation-aware pin check the strict-PQC KEM-refresh responder uses
        // (see `makeInboundSignedKEMRefreshPayload`, "requester protocol identity fingerprint not pinned"):
        // `trustedProtocolFingerprints(forAny:)` unions only ACTIVE (non-revoked) records from both the
        // ProtocolIdentityTrustStore and the TrustedDeviceStore current-path authority. Unpinned or
        // revoked devices fall through to the operator prompt below — never auto-approved.
        let trustedRequesterPins = await trustedProtocolFingerprints(forAny: requesterIds)
        if trustedRequesterPins.contains(requesterFingerprint) {
            let approvedLine = "🔓 PIB-1 requester protocol identity auto-approved via existing pin (no prompt): requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>auto-approved-pinned"
            SkyBridgeLogger.shared.info(approvedLine)
            SignedKEMRefreshSmokeStatusWriter.append(approvedLine)
            return await installInboundRequesterProtocolIdentityBinding(context) ? .alwaysAllow : .reject
        }

        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"] == "1" {
            return await installInboundRequesterProtocolIdentityBinding(context) ? .alwaysAllow : .reject
        }

        let requestId = UUID()
        pendingPairingContextByRequestId[requestId] = .requesterProtocolIdentityBinding(context)
        pendingPairingTrustRequest = PairingTrustRequest(
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
        SkyBridgeLogger.shared.info(awaitingLine)
        SignedKEMRefreshSmokeStatusWriter.append(awaitingLine)
        return await withCheckedContinuation { continuation in
            pendingPairingDecisionContinuationByRequestId[requestId] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let self,
                      let timedOut = self.pendingPairingDecisionContinuationByRequestId.removeValue(forKey: requestId) else {
                    return
                }
                self.pendingPairingContextByRequestId.removeValue(forKey: requestId)
                if self.pendingPairingTrustRequest?.id == requestId {
                    self.pendingPairingTrustRequest = nil
                }
                let line = "⏳ PIB-1 requester protocol identity approval timed out: requester=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) timeoutSeconds=\(timeoutSeconds) lifecycle=identity-oob>timeout"
                SkyBridgeLogger.shared.warning(line)
                SignedKEMRefreshSmokeStatusWriter.append(line)
                timedOut.resume(returning: .timedOut)
            }
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

    private func ensureInboundHandshakeDriverIfNeeded(for peerId: String, frame: Data) async -> HandshakeDriver? {
        guard handshakeDrivers[peerId] == nil else { return handshakeDrivers[peerId] }

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
                clearStaleInboundSessionState(
                    for: peerId,
                    reason: "message_a_without_authenticated_session"
                )
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
            strictTrustContext = context
            strictInboundStablePeerIdByRuntimePeerId[peerId] = context.stablePeerId
            smokeInboundTrace(
                "p2p-inbound strict-trust-ready peer=\(Self.protocolIdentityLogRedaction) stable=\(Self.protocolIdentityLogRedaction) stage=inbound-handshake"
            )
        } else {
            strictTrustContext = nil
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
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
                guard let transport else { throw P2PError.connectionFailed }
                let driver = try skyBridgeCore.createHandshakeDriver(
                    transport: transport,
                    peerSupportedSuites: messageA.supportedSuites,
                    localSOAPeerId: localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId),
                    trustProvider: strictTrustContext?.provider,
                    authenticatedIncomingEstablishedPolicy: strictTrustContext == nil
                        ? .rejectDuplicate
                        : .replaceAuthenticated
                )
                handshakeDrivers[peerId] = driver
            }
        } catch {
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

    private func processHandshakeFrame(_ frame: Data, from peerId: String, initialDriver: HandshakeDriver) async {
        let activeDriver = handshakeDrivers[peerId] ?? initialDriver
        let peer = PeerIdentifier(deviceId: peerId)
        await activeDriver.handleMessage(frame, from: peer)

        let state = await activeDriver.getCurrentState()
        switch state {
        case .established(let keys):
            await persistAuthenticatedRemoteAuthority(from: activeDriver, for: peerId)
            let strictStablePeerId = strictInboundStablePeerIdByRuntimePeerId[peerId]
            if let strictStablePeerId, strictStablePeerId != peerId {
                await replaceStrictInboundStableSession(
                    stablePeerId: strictStablePeerId,
                    currentRuntimePeerId: peerId
                )
            }
            setSessionKeys(keys, for: peerId)
            previousSessionKeysBeforeRekey.removeValue(forKey: peerId)
            let pairKeySourcePeerId = strictStablePeerId ?? peerId
            if let remotePeerId = soaPeerIdBytes(for: pairKeySourcePeerId) {
                let pairKey = PeerSessionArbiter.pairKey(
                    localPeerId: localSOAPeerIdBytes(),
                    remotePeerId: remotePeerId
                )
                pairKeyByDeviceId[peerId] = pairKey
                if pairKeySourcePeerId != peerId {
                    pairKeyByDeviceId[pairKeySourcePeerId] = pairKey
                }
            } else {
                pairKeyByDeviceId.removeValue(forKey: peerId)
            }
            handshakeDrivers.removeValue(forKey: peerId)
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
                connection: connections[peerId]
            )
            upsertActiveConnection(device: activeDevice, status: .connected)
            syncPresentationState(for: peerId)

        case .failed(let reason):
            if let previousKeys = previousSessionKeysBeforeRekey.removeValue(forKey: peerId) {
                await restoreActiveSessionAfterRekeyFailure(
                    for: peerId,
                    previousKeys: previousKeys,
                    reason: reason
                )
                return
            }
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
            handshakeDrivers.removeValue(forKey: peerId)
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

        default:
            break
        }
    }

    private func ensureInboundRekeyDriverIfNeeded(for peerId: String, frame: Data) async -> HandshakeDriver? {
        guard handshakeDrivers[peerId] == nil else { return handshakeDrivers[peerId] }
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
            strictTrustContext = context
            strictInboundStablePeerIdByRuntimePeerId[peerId] = context.stablePeerId
            smokeInboundTrace(
                "p2p-inbound strict-trust-ready peer=\(Self.protocolIdentityLogRedaction) stable=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey"
            )
        } else {
            strictTrustContext = nil
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: peerId)
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
                guard let transport else { throw P2PError.connectionFailed }
                let driver = try skyBridgeCore.createHandshakeDriver(
                    transport: transport,
                    peerSupportedSuites: messageA.supportedSuites,
                    localSOAPeerId: localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId),
                    trustProvider: strictTrustContext?.provider,
                    authenticatedIncomingEstablishedPolicy: strictTrustContext == nil
                        ? .rejectDuplicate
                        : .replaceAuthenticated
                )
                handshakeDrivers[peerId] = driver
            }
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 入站 rekey driver 初始化失败: \(Self.diagnosticErrorSummary(error))")
            smokeInboundTrace(
                "p2p-inbound driver-create-failed peer=\(Self.protocolIdentityLogRedaction) stage=inbound-rekey error=\(Self.diagnosticErrorSummary(error))"
            )
            return nil
        }

        let currentSuite = sessionKeys[peerId]?.negotiatedSuite.rawValue
            ?? resolvedNegotiatedSuite(forAnyPeerId: peerId)?.rawValue
            ?? "Classic"
        let targetSuite = preferredRekeyTargetSuite(offeredSuites: messageA.supportedSuites) ?? currentSuite
        if let existingKeys = sessionKeys[peerId] {
            previousSessionKeysBeforeRekey[peerId] = existingKeys
        }
        await releaseArbiterState(for: peerId)
        sessionKeys.removeValue(forKey: peerId)
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

    private func handleAppMessage(_ message: AppMessage, from peerId: String) async {
        switch message {
        case .clipboard(let payload):
            guard let data = payload.decodedData else { return }
            ClipboardManager.shared.setRemoteClipboard(data: data, mimeType: payload.mimeType, fromDeviceId: peerId)
            ClipboardManager.shared.recordDeviceSync(deviceId: peerId, mimeType: payload.mimeType, bytes: data.count)
            SkyBridgeLogger.shared.info("📋 已接收远端剪贴板：\(Self.protocolIdentityLogRedaction)")
        case .textMessage(let payload):
            do {
                try DeviceMessagingService.shared.handleIncoming(
                    payload,
                    fromPeerIds: textMessageConversationLookupCandidates(for: peerId)
                )
                SkyBridgeLogger.shared.info(
                    "📨 已接收设备文本消息：peer=\(Self.protocolIdentityLogRedaction) messageId=\(payload.id.uuidString)"
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ 设备文本消息未落库：peer=\(Self.protocolIdentityLogRedaction) messageId=\(payload.id.uuidString) reason=\(DeviceMessagingService.logSafeErrorSummary(error))"
                )
            }
        case .pairingIdentityExchange(let payload):
            await handlePairingIdentityExchangeRequest(from: peerId, payload: payload)
        case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding:
            break
        case .heartbeat(let payload):
            let runtimePeerId = promotePeerPresentationIdentityIfNeeded(
                runtimePeerId: peerId,
                declaredDeviceId: payload.deviceId,
                deviceName: payload.deviceName,
                modelName: payload.modelName,
                platform: payload.platform,
                osVersion: payload.osVersion
            )
            mergePeerServiceMetadata(
                runtimePeerId: runtimePeerId,
                declaredDeviceId: payload.deviceId,
                capabilities: payload.capabilities,
                fileTransferPort: payload.fileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
        case .authenticatedRouteBinding:
            break
        case .peerDisconnecting(let payload):
            let runtimePeerId = promotePeerPresentationIdentityIfNeeded(
                runtimePeerId: peerId,
                declaredDeviceId: payload.deviceId,
                deviceName: payload.deviceName,
                modelName: nil,
                platform: nil,
                osVersion: nil
            )
            if let device = lastKnownDevices[runtimePeerId] ?? lastKnownDevices[presentationPeerId(for: runtimePeerId)] {
                _ = purgeStalePresentationState(for: device)
            }
            cancelPeerProtectionRoots(for: runtimePeerId)
            connections[runtimePeerId]?.cancel()
        case .ping(let payload):
            await replyPong(to: peerId, pingId: payload.id)
        case .pong:
            break
        }
    }

    private func hasStoredSessionMaterial(for peerId: String) -> Bool {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
            .union([peerId, runtimePeerId, presentationPeerId])

        let matchingSessionKeys = stateKeysMatchingAliases(aliases, keys: sessionKeys.keys)
        return !matchingSessionKeys.isEmpty
    }

    private func hasActiveAuthenticatedSession(for peerId: String) -> Bool {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
            .union([peerId, runtimePeerId, presentationPeerId])

        let matchingSessionKeys = stateKeysMatchingAliases(aliases, keys: sessionKeys.keys)
        guard !matchingSessionKeys.isEmpty else { return false }

        let matchingConnectionKeys = stateKeysMatchingAliases(aliases, keys: connections.keys)
        guard !matchingConnectionKeys.isEmpty else { return false }

        let matchingStatusKeys = stateKeysMatchingAliases(aliases, keys: connectionStatusByDeviceId.keys)
        return matchingStatusKeys.contains { key in
            connectionStatusByDeviceId[key] == .connected
        }
    }

    private func clearStaleInboundSessionState(for peerId: String, reason: String) {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let aliases = connectionAliasSet(for: runtimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: peerId))
            .union([peerId, runtimePeerId, presentationPeerId])

        for key in stateKeysMatchingAliases(aliases, keys: sessionKeys.keys) {
            sessionKeys.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: previousSessionKeysBeforeRekey.keys) {
            previousSessionKeysBeforeRekey.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: sharedSecrets.keys) {
            sharedSecrets.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: negotiatedSuiteByDeviceId.keys) {
            negotiatedSuiteByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: rekeyStatusByDeviceId.keys) {
            rekeyStatusByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: handshakeDrivers.keys) {
            handshakeDrivers.removeValue(forKey: key)
            rekeyInProgress.remove(key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: pairKeyByDeviceId.keys) {
            pairKeyByDeviceId.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: strictInboundStablePeerIdByRuntimePeerId.keys) {
            strictInboundStablePeerIdByRuntimePeerId.removeValue(forKey: key)
        }

        SkyBridgeLogger.shared.debug(
            "🧹 已清理陈旧入站会话材料: peer=\(peerId) reason=\(reason)"
        )
    }

    private func replaceStrictInboundStableSession(
        stablePeerId: String,
        currentRuntimePeerId: String
    ) async {
        let currentRuntimePeerId = canonicalPeerLookupKey(currentRuntimePeerId)
        let stableRuntimePeerId = runtimePeerId(forAnyPeerId: stablePeerId)
        let presentationPeerId = presentationPeerId(for: stableRuntimePeerId)
        let aliases = connectionAliasSet(for: stableRuntimePeerId)
            .union(PeerIdentityAliasResolver.lookupCandidates(for: stablePeerId))
            .union([stablePeerId, stableRuntimePeerId, presentationPeerId])

        for key in stateKeysMatchingAliases(aliases, keys: connections.keys) where key != currentRuntimePeerId {
            connections[key]?.cancel()
            connections.removeValue(forKey: key)
            await transport?.removeConnection(for: key)
        }
        clearStaleInboundSessionState(
            for: stablePeerId,
            reason: "strict_authenticated_inbound_reconnect_replaced_stable_session"
        )
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
        let capabilities = ["clipboard_sync", "file_transfer", "remote_desktop"]
        return (capabilities, FileTransferConstants.defaultPort, nil)
    }

    private func replyPong(to peerId: String, pingId: UInt64) async {
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(peerId) { return }
        guard let connection = connections[peerId] else { return }
        guard sessionKeys[peerId] != nil else { return }

        do {
            let message = AppMessage.pong(.init(id: pingId))
            let payload = try JSONEncoder().encode(message)
            let ciphertext = try encryptForDevice(payload, deviceId: peerId)
            try await send(data: ciphertext, over: connection)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ pong reply failed (ignored): \(Self.diagnosticErrorSummary(error))")
        }
    }

    private func sendPeerDisconnectingNotice(to peerId: String, device: DiscoveredDevice) async {
        let peerId = canonicalPeerLookupKey(peerId)
        guard let connection = connections[peerId] else { return }
        guard sessionKeys[peerId] != nil else { return }

        do {
            let message = AppMessage.peerDisconnecting(
                .init(
                    deviceId: PeerIdentityAliasResolver.persistentDeviceId(from: device.id),
                    deviceName: device.name
                )
            )
            let payload = try JSONEncoder().encode(message)
            let ciphertext = try encryptForDevice(payload, deviceId: peerId)
            try await send(data: ciphertext, over: connection)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ peerDisconnecting 发送失败（忽略）: \(Self.diagnosticErrorSummary(error))")
        }
    }
    
    private func handlePairingIdentityExchangeRequest(from peerId: String, payload: AppMessage.PairingIdentityExchangePayload) async {
        let peerId = promotePeerPresentationIdentityIfNeeded(
            runtimePeerId: peerId,
            declaredDeviceId: payload.deviceId,
            deviceName: payload.deviceName,
            modelName: payload.modelName,
            platform: payload.platform,
            osVersion: payload.osVersion
        )

        // Policy: auto-accept / auto-reject if a decision exists; otherwise raise a UI prompt.
        if let raw = pairingPolicyByPeerId[peerId],
           let policy = PairingTrustDecision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: true, persistTrust: true)
                return
            case .reject:
                SkyBridgeLogger.shared.warning("🛑 Pairing/trust request auto-rejected: peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction)")
                return
            case .allowOnce, .timedOut:
                // Should not be persisted; fall through to prompt.
                break
            }
        }
        
        // If the peer is already trusted OR we are currently bootstrapping Classic->PQC for this peer,
        // auto-accept to avoid the bootstrap being blocked by an extra prompt on the initiator side.
        if TrustedDeviceStore.shared.isTrusted(deviceId: peerId) || bootstrapRekeyTasks[peerId] != nil {
            await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: true, persistTrust: false)
            return
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
        pendingPairingContextByRequestId[requestId] = .pairingIdentityExchange(peerId: peerId, payload: payload)
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
        
        SkyBridgeLogger.shared.info("🔔 收到配对/受信任申请：device=\(Self.protocolIdentityLogRedaction) platform=\(device.platform.displayName) os=\(device.osVersion) peerId=\(Self.protocolIdentityLogRedaction)")
    }
    
    private func scheduleBootstrapRekeyIfNeeded(peerId: String, suiteRaw: String) {
        guard bootstrapRekeyTasks[peerId] == nil else { return }
        let peerIds = connectionStatePeerIds(for: peerId)
        let fromSuite = resolvedNegotiatedSuite(forAnyPeerId: peerId)?.rawValue ?? "Classic"
        setRekeyPresentationStatus(for: peerId, fromSuite: fromSuite, toSuite: suiteRaw)
        
        // Surface a stable "pending approval/keys" state to prevent reconnect storms.
        for effectivePeerId in peerIds {
            connectionErrorByDeviceId[effectivePeerId] = "等待对端批准配对/受信任申请以完成 PQC 切换（suite=\(suiteRaw)）"
        }
        currentHandshakeState = "等待对端批准以完成 PQC 切换..."
        
        bootstrapRekeyTasks[peerId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.bootstrapRekeyTasks.removeValue(forKey: peerId) }
            
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !Task.isCancelled {
                let keys = await self.kemPublicKeysForBootstrapRekey(peerId: peerId)
                if let targetSuite = CryptoSuite(rawValue: suiteRaw),
                   keys.keys.contains(where: { Self.suiteSupportsTargetKEM($0, target: targetSuite) }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            let keysNow = await self.kemPublicKeysForBootstrapRekey(peerId: peerId)
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
                    for: peerId,
                    message: message + "。请在 macOS 弹窗选择允许后重试，或稍后手动点击“重新握手”。"
                )
                return
            }
            
            do {
                // Give the responder a brief settle window to finish post-auth
                // pairingIdentityExchange handling before the in-band rekey starts.
                // On LAN bootstrap paths the remote side can still be transitioning
                // from `waitingFinished` to steady-state app-message handling.
                try? await Task.sleep(for: .seconds(2))
                SkyBridgeLogger.shared.info("🔁 已获得对端 KEM 公钥，开始 rekey 到 PQC… peer=\(Self.protocolIdentityLogRedaction)")
                try await self.rekeyToPreferPQC(deviceId: peerId, allowSOA: false)
                for effectivePeerId in self.connectionStatePeerIds(for: peerId) {
                    self.connectionErrorByDeviceId.removeValue(forKey: effectivePeerId)
                }
                self.currentHandshakeState = "已切换到 PQC"
            } catch {
                for effectivePeerId in self.connectionStatePeerIds(for: peerId) {
                    self.connectionErrorByDeviceId[effectivePeerId] = "PQC 切换失败：\(self.userVisibleConnectionError(error))"
                }
                self.clearRekeyPresentationStatus(for: peerId)
                SkyBridgeLogger.shared.error("❌ rekeyToPreferPQC failed: \(Self.diagnosticErrorSummary(error))")
            }
        }
    }

    private func publishBootstrapRekeyFailure(for runtimePeerId: String, message: String) {
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
        var lastError: Error?
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519] {
            do {
                let publicKey = try await skyBridgeCore.getProtocolSigningPublicKey(for: algorithm)
                let keyInfo = AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                )
                if let fingerprint = keyInfo.authoritativeFingerprint?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                   fingerprint.count == 64,
                   fingerprint.allSatisfy(\.isHexDigit) {
                    return fingerprint
                }
            } catch {
                lastError = error
                SkyBridgeLogger.shared.debug(
                    "ℹ️ SKR-1 signed LAN KEM refresh skipped local protocol identity key alg=\(algorithm.rawValue): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }

        if let lastError {
            throw signedLANRefreshFailure("missing local protocol identity fingerprint: \(lastError.localizedDescription)")
        }
        throw signedLANRefreshFailure("missing local protocol identity fingerprint")
    }

    private struct LocalProtocolIdentityProof: Sendable {
        let algorithm: ProtocolSigningAlgorithm
        let publicKey: Data
        let keyHandle: SigningKeyHandle
        let fingerprint: String
    }

    private func localProtocolIdentityProofForProtocolBinding(
        candidateAlgorithms: [ProtocolSigningAlgorithm] = [.mlDSA65, .ed25519],
        targetFingerprint: String? = nil
    ) async throws -> LocalProtocolIdentityProof {
        let normalizedTargetFingerprint = Self.normalizedProtocolIdentityFingerprint(targetFingerprint)
        var lastError: Error?
        for algorithm in candidateAlgorithms {
            do {
                let publicKey = try await skyBridgeCore.getProtocolSigningPublicKey(for: algorithm)
                let keyHandle = try await skyBridgeCore.getProtocolSigningKeyHandle(for: algorithm)
                let keyInfo = AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                )
                if let fingerprint = keyInfo.authoritativeFingerprint?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                   fingerprint.count == 64,
                   fingerprint.allSatisfy(\.isHexDigit) {
                    guard normalizedTargetFingerprint == nil || normalizedTargetFingerprint == fingerprint else {
                        continue
                    }
                    return LocalProtocolIdentityProof(
                        algorithm: algorithm,
                        publicKey: publicKey,
                        keyHandle: keyHandle,
                        fingerprint: fingerprint
                    )
                }
            } catch {
                lastError = error
                SkyBridgeLogger.shared.debug(
                    "ℹ️ PIB-1 requester proof skipped local protocol identity key alg=\(algorithm.rawValue): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }

        if let lastError {
            throw protocolIdentityBindingFailure("missing local protocol identity proof: \(lastError.localizedDescription)")
        }
        throw protocolIdentityBindingFailure("missing local protocol identity proof")
    }

    private func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await skyBridgeCore.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ P2P pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }
        return AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
    }
    
    private func acceptPairingIdentityExchange(
        from peerId: String,
        payload: AppMessage.PairingIdentityExchangePayload,
        trustPeer: Bool,
        persistTrust: Bool
    ) async {
        guard let payload = payload.normalizedBootstrapPayload else {
            SkyBridgeLogger.shared.warning(
                "⚠️ 忽略无效 pairingIdentityExchange: peer=\(Self.protocolIdentityLogRedaction) keys=\(payload.kemPublicKeys.count)"
            )
            return
        }
        let declaredDeviceId = payload.deviceId

        let peerId = promotePeerPresentationIdentityIfNeeded(
            runtimePeerId: peerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: payload.deviceName,
            modelName: payload.modelName,
            platform: payload.platform,
            osVersion: payload.osVersion
        )
        let previousDeclaredDeviceId = lastAcceptedPairingIdentityDeviceIdByPeerId[peerId]
        lastAcceptedPairingIdentityDeviceIdByPeerId[peerId] = declaredDeviceId
        let shouldForceIdentityReply = previousDeclaredDeviceId.map {
            $0.caseInsensitiveCompare(declaredDeviceId) != .orderedSame
        } ?? true
        let observedAt = Date()
        lastPairingIdentityExchangeReceivedAt[peerId] = observedAt
        let presentationPeerId = presentationPeerId(for: peerId)
        lastPairingIdentityExchangeReceivedAt[presentationPeerId] = observedAt
        mergePeerServiceMetadata(
            runtimePeerId: peerId,
            declaredDeviceId: declaredDeviceId,
            capabilities: payload.capabilities,
            fileTransferPort: payload.fileTransferPort,
            remoteControlPort: payload.remoteControlPort
        )

        // Store under both the "declared" deviceId and the current peerId key.
        // Reason: in discovery/bonjour flows the runtime peerId can be "bonjour:<name>@local." while the
        // pairing identity exchange uses a stable deviceId. If we only store one, PQC lookup may miss.
        await KEMTrustStore.shared.upsert(deviceId: declaredDeviceId, kemPublicKeys: payload.kemPublicKeys)
        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: payload.kemPublicKeys)
        await ProtocolIdentityTrustStore.shared.upsert(
            deviceId: declaredDeviceId,
            protocolIdentityPublicKeys: payload.protocolIdentityPublicKeys
        )
        await ProtocolIdentityTrustStore.shared.upsert(
            deviceId: peerId,
            protocolIdentityPublicKeys: payload.protocolIdentityPublicKeys
        )
        let protocolFingerprints = Set(
            (AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? [])
                .compactMap(\.authoritativeFingerprint)
        )
        for candidate in bootstrapKEMLookupCandidates(for: peerId) + [declaredDeviceId] where !protocolFingerprints.isEmpty {
            await ProtocolIdentityTrustStore.shared.upsert(deviceId: candidate, fingerprints: protocolFingerprints)
        }
        SkyBridgeLogger.shared.info("🔑 已保存对端 KEM 公钥：peer=\(Self.protocolIdentityLogRedaction) declaredDeviceId=\(Self.protocolIdentityLogRedaction) keys=\(payload.kemPublicKeys.count)")
        lastPairingIdentityBootstrapReadyAt[peerId] = observedAt
        lastPairingIdentityBootstrapReadyAt[presentationPeerId] = observedAt
        
        if trustPeer {
            // Persist a "trusted" record so strict-PQC bootstrap can be gated by an explicit trust decision.
            let device = lastKnownDevices[peerId]
                ?? discoveryManager.discoveredDevices.first(where: { $0.id == peerId })
                ?? DiscoveredDevice(id: peerId, name: peerId, modelName: "", platform: .unknown, osVersion: "Unknown")
            TrustedDeviceStore.shared.trustResolvedPeer(device, declaredDeviceId: declaredDeviceId)
            if let canonicalDeclaredDeviceId = PeerIdentityAliasResolver.persistentDeviceId(from: declaredDeviceId) {
                let canonicalDevice = canonicalizedDevice(
                    device,
                    canonicalPeerId: canonicalDeclaredDeviceId,
                    trustHint: true
                )
                await repairLegacyTrustedIdentityIfNeeded(
                    requestedDevice: device,
                    resolvedDevice: canonicalDevice
                )
            }
            if persistTrust {
                SkyBridgeLogger.shared.info("✅ 已加入受信任设备：\(Self.protocolIdentityLogRedaction) peerId=\(Self.protocolIdentityLogRedaction)")
            }
        }

        if pqcManager.enforcePQCHandshake,
           let negotiatedSuite = resolvedNegotiatedSuite(forAnyPeerId: peerId),
           !negotiatedSuite.isPQCGroup,
           let targetSuite = preferredRekeyTargetSuite() {
            scheduleBootstrapRekeyIfNeeded(peerId: peerId, suiteRaw: targetSuite)
        }
        
        // Reply once (rate-limited) so both sides learn each other's KEM identity keys.
        // The first accepted identity on a session is not rate-limited; file transfer uses
        // the reply as proof that the receiver has bound the stable device id to the session.
        if !shouldForceIdentityReply,
           let last = lastPairingIdentityExchangeSentAt[peerId],
           Date().timeIntervalSince(last) < 10 {
            return
        }
        lastPairingIdentityExchangeSentAt[peerId] = Date()
        do {
            try await sendPairingIdentityExchange(to: peerId)
            SkyBridgeLogger.shared.info("🔁 pairingIdentityExchange replied to peer=\(Self.protocolIdentityLogRedaction)")
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ pairingIdentityExchange reply failed (ignored): \(Self.diagnosticErrorSummary(error))")
        }
    }

    /// 向对端发送本机 KEM identity 公钥，用于 bootstrap PQC suite 协商（首次可用 classic，收到后即可 rekey 到 PQC）。
    public func sendPairingIdentityExchange(to deviceId: String) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
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
                return
            }
        }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        guard sessionKeys[deviceId] != nil else { throw P2PError.noSessionKey }

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        guard !kemKeys.isEmpty else {
            SkyBridgeLogger.shared.warning("⚠️ 跳过 pairingIdentityExchange：本机 KEM 公钥为空")
            return
        }

        // 设备 ID：用于对端把我们写入 trust store 的 key（尽量与 discovery 的 deviceId 对齐）
        let snapshot = AppleMobileDeviceIdentity.currentSnapshot()
        let localId = localStableDeviceIdentifier().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localId.isEmpty else {
            SkyBridgeLogger.shared.warning("⚠️ 跳过 pairingIdentityExchange：本机 stable deviceId 为空")
            return
        }
        let serviceHints = localPeerServiceHints()
        let identity = AuthenticationManager.instance.remoteControlSecurityIdentityMetadata
        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: await localProtocolIdentityPublicKeysForPairing(),
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
        let ciphertext = try encryptForDevice(payload, deviceId: deviceId)
        try await send(data: ciphertext, over: connection)
        lastPairingIdentityExchangeSentAt[deviceId] = Date()
        SkyBridgeLogger.shared.info("📤 pairingIdentityExchange sent: peer=\(Self.protocolIdentityLogRedaction) keys=\(kemKeys.count)")
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
            try? await Task.sleep(for: .milliseconds(100))
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
            try? await Task.sleep(for: .milliseconds(100))
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
        in observations: [String: Date],
        matching aliases: Set<String>,
        since: Date
    ) -> Bool {
        for key in stateKeysMatchingAliases(aliases, keys: observations.keys) {
            if let observedAt = observations[key], observedAt >= since {
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
        let protocolFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(
            forAny: expandedCandidates
        )
        let trustedFingerprints = TrustedDeviceStore.shared.currentPathFingerprints(
            forAny: expandedCandidates
        )
        return !protocolFingerprints.union(trustedFingerprints).isEmpty
    }

    /// 发送剪贴板内容到指定设备（走已建立的会话密钥加密通道）
    public func sendClipboard(to deviceId: String, data: Data, mimeType: String) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(deviceId) { return }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        guard sessionKeys[deviceId] != nil else { throw P2PError.noSessionKey }

        let message = AppMessage.clipboard(.init(mimeType: mimeType, dataBase64: data.base64EncodedString()))
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encryptForDevice(payload, deviceId: deviceId)
        try await send(data: ciphertext, over: connection)

        ClipboardManager.shared.recordDeviceSync(deviceId: deviceId, mimeType: mimeType, bytes: data.count)
    }

    public func sendTextMessage(
        to deviceId: String,
        payload: AppMessage.TextMessagePayload
    ) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard !rekeyInProgress.contains(deviceId) else { throw P2PError.noSessionKey }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        guard sessionKeys[deviceId] != nil else { throw P2PError.noSessionKey }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(AppMessage.textMessage(payload))
        } catch {
            SkyBridgeLogger.shared.error("⛔️ 设备文本消息编码失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.encryptionFailed
        }

        let ciphertext: Data
        do {
            ciphertext = try encryptForDevice(encoded, deviceId: deviceId)
        } catch {
            SkyBridgeLogger.shared.error("⛔️ 设备文本消息加密失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.encryptionFailed
        }

        do {
            try await send(data: ciphertext, over: connection)
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 设备文本消息发送失败: \(Self.diagnosticErrorSummary(error))")
            throw P2PError.connectionFailed
        }
    }

    /// 广播剪贴板到所有已建立会话的连接
    public func broadcastClipboard(data: Data, mimeType: String) async {
        for deviceId in connections.keys {
            guard sessionKeys[deviceId] != nil else { continue }
            try? await sendClipboard(to: deviceId, data: data, mimeType: mimeType)
        }
    }
    
    private func handleConnectionStateChange(
        _ state: NWConnection.State,
        for device: DiscoveredDevice,
        connection: NWConnection? = nil
    ) async {
        let runtimePeerId = canonicalPeerLookupKey(device.id)
        let effectiveDevice = canonicalizedDevice(device, canonicalPeerId: runtimePeerId)
        let peerIds = connectionStatePeerIds(for: runtimePeerId)

        if let connection, !isTrackedConnection(connection) {
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
            connections.removeValue(forKey: runtimePeerId)
            selectedEndpointDescriptionByDeviceId.removeValue(forKey: runtimePeerId)
            sessionKeys.removeValue(forKey: runtimePeerId)
            previousSessionKeysBeforeRekey.removeValue(forKey: runtimePeerId)
            handshakeDrivers.removeValue(forKey: runtimePeerId)
            sharedSecrets.removeValue(forKey: runtimePeerId)
            await transport?.removeConnection(for: runtimePeerId)
            if isPathRecoverySocketFailure {
                upsertActiveConnection(device: effectiveDevice, status: .connecting)
            } else {
                purgeTerminalConnectionPresentationState(for: runtimePeerId)
            }
            discoveryManager.setConnectionLiveness(for: effectiveDevice, isConnected: false)
            heartbeatTasks[runtimePeerId]?.cancel()
            heartbeatTasks.removeValue(forKey: runtimePeerId)
            pathRecoveryTasks[runtimePeerId]?.cancel()
            pathRecoveryTasks.removeValue(forKey: runtimePeerId)
            if !isPathRecoverySocketFailure {
                cancelPeerProtectionRoots(for: runtimePeerId)
            }
            await releaseArbiterState(for: runtimePeerId)
            scheduleReconnectIfNeeded(deviceId: runtimePeerId)
            
        case .cancelled:
            connections.removeValue(forKey: runtimePeerId)
            selectedEndpointDescriptionByDeviceId.removeValue(forKey: runtimePeerId)
            sessionKeys.removeValue(forKey: runtimePeerId)
            previousSessionKeysBeforeRekey.removeValue(forKey: runtimePeerId)
            handshakeDrivers.removeValue(forKey: runtimePeerId)
            sharedSecrets.removeValue(forKey: runtimePeerId)
            await transport?.removeConnection(for: runtimePeerId)
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
            heartbeatTasks[runtimePeerId]?.cancel()
            heartbeatTasks.removeValue(forKey: runtimePeerId)
            pathRecoveryTasks[runtimePeerId]?.cancel()
            pathRecoveryTasks.removeValue(forKey: runtimePeerId)
            cancelPeerProtectionRoots(for: runtimePeerId)
            await releaseArbiterState(for: runtimePeerId)
            if !wasUser {
                scheduleReconnectIfNeeded(deviceId: runtimePeerId)
            }
            
        default:
            break
        }
    }

    private func startHeartbeatIfNeeded(deviceId: String) {
        guard heartbeatTasks[deviceId] == nil else { return }
        guard connections[deviceId] != nil, sessionKeys[deviceId] != nil else { return }

        heartbeatTasks[deviceId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.heartbeatIntervalSeconds ?? 20))
                guard let self else { return }
                guard self.connections[deviceId] != nil, self.sessionKeys[deviceId] != nil else { return }
                
                // Pause heartbeat during in-band rekey to reduce ciphertext/handshake interleaving.
                if self.rekeyInProgress.contains(deviceId) { continue }

                let now = Date()
                let last = self.lastActivityByDeviceId[deviceId] ?? .distantPast
                if now.timeIntervalSince(last) < self.heartbeatIntervalSeconds { continue }
                let serviceHints = self.localPeerServiceHints()

                do {
                    let snapshot = AppleMobileDeviceIdentity.currentSnapshot()
                    let localId = self.localStableDeviceIdentifier()
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
                    let ciphertext = try self.encryptForDevice(payload, deviceId: deviceId)
                    if let connection = self.connections[deviceId] {
                        try await self.send(data: ciphertext, over: connection)
                        self.lastActivityByDeviceId[deviceId] = now
                    }
                } catch {
                    self.connectionErrorByDeviceId[deviceId] = self.userVisibleConnectionError(error)
                }
            }
        }
    }

    private enum PathRecoveryReason: String {
        case viabilityLost = "viability_lost"
        case betterPath = "better_path"
    }

    private func schedulePathRecoveryIfNeeded(deviceId: String, reason: PathRecoveryReason) {
        guard !userInitiatedDisconnects.contains(deviceId) else { return }
        guard pathRecoveryTasks[deviceId] == nil else { return }
        guard connections[deviceId] != nil else { return }

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
            pathRecoveryTasks[deviceId] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.betterPathRecoveryDeferIntervalSeconds ?? 5))
                guard let self else { return }
                self.pathRecoveryTasks.removeValue(forKey: deviceId)
                self.schedulePathRecoveryIfNeeded(deviceId: deviceId, reason: reason)
            }
            return
        }

        betterPathRecoveryDeferredSince.removeValue(forKey: deviceId)
        pathRecoveryTasks[deviceId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            defer {
                self.pathRecoveryTasks.removeValue(forKey: deviceId)
            }
            guard self.connections[deviceId] != nil else { return }
            guard let lastKnown = self.lastKnownDevices[deviceId] else { return }

            let refreshed = self.resolveLatestConnectableDevice(from: lastKnown)
            self.lastKnownDevices[deviceId] = refreshed
            self.connectionErrorByDeviceId[deviceId] = Self.pathRecoveryInProgressMessage
            SkyBridgeLogger.shared.info(
                "🔄 触发路径恢复: peer=\(deviceId) reason=\(reason.rawValue) target=\(refreshed.id)"
            )
            self.connections[deviceId]?.cancel()
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
        reconnectTasks[deviceId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.reconnectTasks.removeValue(forKey: deviceId)
            if self.connections[deviceId] != nil { return }
            do {
                try await self.connect(to: device)
                self.reconnectAttempts.removeValue(forKey: deviceId)
            } catch {
                self.connectionErrorByDeviceId[deviceId] = self.userVisibleConnectionError(error)
                self.scheduleReconnectIfNeeded(deviceId: deviceId)
            }
        }
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

    private func textMessageConversationLookupCandidates(for peerId: String) -> [String] {
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else {
                return
            }
            ordered.append(value)
        }

        append(peerId)
        append(runtimePeerId)
        append(presentationPeerId)
        append(lastAcceptedPairingIdentityDeviceIdByPeerId[peerId])
        append(lastAcceptedPairingIdentityDeviceIdByPeerId[runtimePeerId])

        for candidate in connectionStatePeerIds(for: runtimePeerId) {
            append(candidate)
        }
        return ordered
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

    private func waitForInFlightConnect(_ key: String) async {
        await withCheckedContinuation { continuation in
            inFlightConnectWaitersByPeerId[key, default: []].append(continuation)
        }
    }

    private func finishInFlightConnect(_ key: String) {
        inFlightConnectAliasesByPeerId.removeValue(forKey: key)
        let waiters = inFlightConnectWaitersByPeerId.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelPeerProtectionRoots(for runtimePeerId: String) {
        let aliases = connectionAliasSet(for: runtimePeerId)

        for key in stateKeysMatchingAliases(aliases, keys: reconnectTasks.keys) {
            reconnectTasks[key]?.cancel()
            reconnectTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: pathRecoveryTasks.keys) {
            pathRecoveryTasks[key]?.cancel()
            pathRecoveryTasks.removeValue(forKey: key)
        }
        for key in stateKeysMatchingAliases(aliases, keys: heartbeatTasks.keys) {
            heartbeatTasks[key]?.cancel()
            heartbeatTasks.removeValue(forKey: key)
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
        if merged.bonjourServiceName == nil || merged.bonjourServiceName?.isEmpty == true {
            merged.bonjourServiceName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(update.bonjourServiceName)
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
        if merged.bonjourServiceType == nil
            || (merged.bonjourServiceType == DiscoveryServiceType.skybridge.rawValue
                && update.bonjourServiceType != nil
                && update.bonjourServiceType != DiscoveryServiceType.skybridge.rawValue) {
            merged.bonjourServiceType = update.bonjourServiceType
        }
        if merged.bonjourServiceDomain == nil {
            merged.bonjourServiceDomain = update.bonjourServiceDomain
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
        let runtimePeerId = runtimePeerId(forAnyPeerId: peerId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let directCandidates = [peerId, runtimePeerId, presentationPeerId]

        for candidate in directCandidates {
            if let suite = negotiatedSuiteByDeviceId[candidate] {
                return suite
            }
        }

        let aliases = connectionAliasSet(for: runtimePeerId)
        for candidate in stateKeysMatchingAliases(aliases, keys: negotiatedSuiteByDeviceId.keys) {
            if let suite = negotiatedSuiteByDeviceId[candidate] {
                return suite
            }
        }

        return sessionKeys[runtimePeerId]?.negotiatedSuite
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
            isTrusted: baseDevice.isTrusted || TrustedDeviceStore.shared.isTrusted(deviceId: presentationPeerId),
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
        TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: device)
    }

    private func canonicalizedDevice(
        _ device: DiscoveredDevice,
        canonicalPeerId: String,
        trustHint: Bool = false
    ) -> DiscoveredDevice {
        // Preserve trust across runtime/bonjour aliases so UI state and policy decisions
        // remain aligned with the persisted trusted identity.
        let effectiveIsTrusted = trustHint
            || device.isTrusted
            || TrustedDeviceStore.shared.isTrusted(deviceId: device.id)
            || TrustedDeviceStore.shared.isTrusted(deviceId: canonicalPeerId)

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

    private func connectionEndpointCandidates(
        for device: DiscoveredDevice,
        preferDirectHostPort: Bool = false
    ) -> [NWEndpoint] {
        P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: device,
            preferDirectHostPort: preferDirectHostPort
        )
    }

    private static func signedLANRefreshEndpointClass(_ endpoint: NWEndpoint) -> String {
        P2PConnectionEndpointPolicy.signedLANRefreshEndpointClass(endpoint)
    }

    private func makeConnectionParameters(for endpoint: NWEndpoint) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
        parameters.allowLocalEndpointReuse = true
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

        for (index, endpoint) in endpoints.enumerated() {
            let peerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
            let connection = NWConnection(to: endpoint, using: makeConnectionParameters(for: endpoint))
            let readyGate = ConnectionReadyGate()

            connection.stateUpdateHandler = { state in
                readyGate.onState(state)
                if case .waiting(let error) = state {
                    SkyBridgeLogger.shared.debug(
                        "⏳ 候选端点等待网络[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                    )
                }
            }

            SkyBridgeLogger.shared.info(
                "🔗 尝试连接候选端点[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) peerToPeer=\(peerToPeer)"
            )
            connection.start(queue: queue)

            let attemptStartedAt = Date()
            do {
                try await readyGate.waitReady(timeoutSeconds: 8.0)
                let connectLatencyMs = Date().timeIntervalSince(attemptStartedAt) * 1_000.0
                attemptDurationsMs.append(connectLatencyMs)
                connection.stateUpdateHandler = nil
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
                let connectLatencyMs = Date().timeIntervalSince(attemptStartedAt) * 1_000.0
                attemptDurationsMs.append(connectLatencyMs)
                failedAttemptCount += 1
                lastError = error
                connection.cancel()
                SkyBridgeLogger.shared.warning(
                    "⚠️ 候选端点连接失败[\(index + 1)/\(endpoints.count)]: device=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) error=\(Self.diagnosticErrorSummary(error))"
                )
            }
        }

        throw lastError
    }

    private static func attemptDurationJitterMs(_ samples: [Double]) -> Double {
        guard let minValue = samples.min(), let maxValue = samples.max(), samples.count > 1 else {
            return 0.0
        }
        return maxValue - minValue
    }

    private func installConnectionObservers(_ connection: NWConnection, for device: DiscoveredDevice) {
        connection.viabilityUpdateHandler = { [weak self] viable in
            Task { @MainActor in
                guard let self else { return }
                SkyBridgeLogger.shared.debug("🌐 连接可用性变化：device=\(Self.protocolIdentityLogRedaction) viable=\(viable)")
                if !viable {
                    self.connectionStatusByDeviceId[device.id] = .connecting
                    self.schedulePathRecoveryIfNeeded(
                        deviceId: self.canonicalPeerLookupKey(device.id),
                        reason: .viabilityLost
                    )
                }
            }
        }

        connection.betterPathUpdateHandler = { [weak self] betterPath in
            Task { @MainActor in
                SkyBridgeLogger.shared.debug("🌐 更优路径可用：device=\(Self.protocolIdentityLogRedaction) betterPath=\(betterPath)")
                guard let self, betterPath else { return }
                self.schedulePathRecoveryIfNeeded(
                    deviceId: self.canonicalPeerLookupKey(device.id),
                    reason: .betterPath
                )
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleConnectionStateChange(state, for: device, connection: connection)
            }
        }
    }

    private func isTrackedConnection(_ connection: NWConnection) -> Bool {
        connections.values.contains { $0 === connection }
    }

    private func normalizedStrongDeviceId(for device: DiscoveredDevice) -> String? {
        P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: device)
    }

    private func repairLegacyTrustedIdentityIfNeeded(
        requestedDevice: DiscoveredDevice,
        resolvedDevice: DiscoveredDevice
    ) async {
        guard let canonicalStableId = PeerIdentityAliasResolver.persistentDeviceId(from: resolvedDevice.id),
              canonicalStableId == resolvedDevice.id else {
            return
        }

        let legacyIdentifiers = TrustedDeviceStore.shared.repairLegacyTrustedDeviceIdentity(
            requestedDevice: requestedDevice,
            liveDiscoveredDevice: resolvedDevice
        )
        guard !legacyIdentifiers.isEmpty else { return }

        await KEMTrustStore.shared.rebindCanonicalDeviceId(
            canonicalStableId,
            legacyIdentifiers: legacyIdentifiers
        )
        SkyBridgeLogger.shared.info(
            "🔧 已修复受信任设备主键与 KEM 映射: \(Self.protocolIdentityLogRedaction) -> \(Self.protocolIdentityLogRedaction)"
        )
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

    private func isSelfConnectionTarget(_ device: DiscoveredDevice) -> Bool {
        let localId = localStableDeviceIdentifier().lowercased()
        let persistentLocalId = localStablePersistentDeviceIdentifier().lowercased()
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

    private func setSessionKeys(_ keys: SessionKeys, for deviceId: String, deviceNameHint: String? = nil) {
        sessionKeys[deviceId] = keys
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
        Task {
            await LiveActivityManager.shared.setConnected(deviceName: name, cryptoSuite: keys.negotiatedSuite.rawValue)
        }
    }

    private func persistAuthenticatedRemoteAuthority(
        from driver: HandshakeDriver,
        for peerId: String,
        deviceNameHint: String? = nil
    ) async {
        guard let authority = await driver.getAuthenticatedRemoteAuthority() else {
            return
        }

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
        let preferredCurrentDeviceId =
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: resolvedDevice)
            ?? PeerIdentityAliasResolver.persistentDeviceId(from: resolvedDevice.id)

        let persisted = TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: resolvedDevice,
            preferredCurrentDeviceId: preferredCurrentDeviceId,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        )

        if persisted {
            SkyBridgeLogger.shared.info(
                "🔐 已持久化对端协议身份 authority: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction)"
            )
        } else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ 对端协议身份 authority 未持久化（缺少稳定 peer 映射）: peer=\(Self.protocolIdentityLogRedaction)"
            )
        }
    }

    private func restoreActiveSessionAfterRekeyFailure(
        for peerId: String,
        previousKeys: SessionKeys,
        reason: HandshakeFailureReason
    ) async {
        setSessionKeys(previousKeys, for: peerId)
        handshakeDrivers.removeValue(forKey: peerId)
        rekeyInProgress.remove(peerId)
        clearRekeyPresentationStatus(for: peerId)
        if let pairKey = activeSOAPairKey(for: peerId) {
            pairKeyByDeviceId[peerId] = pairKey
            await PeerSessionArbiter.shared.markEstablished(pairKey: pairKey)
        }

        currentHandshakeState = "rekey失败，保留原会话 (Suite: \(previousKeys.negotiatedSuite.rawValue))"
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
            "⚠️ rekey失败，已恢复原会话: \(peerId) - \(reason)"
        )
    }

    private func shouldUseSOA(for device: DiscoveredDevice) -> Bool {
        device.capabilities.contains("hs_soa") || device.advertisedCapabilities.contains("hs_soa")
    }

    private func localStableDeviceIdentifier() -> String {
        ProtocolDeviceIdentity.stableDeviceId()
    }

    private func localStablePersistentDeviceIdentifier() -> String {
        let raw = localStableDeviceIdentifier()
        return PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    private func localSOAPeerIdBytes() -> Data {
        var persistent = localStablePersistentDeviceIdentifier()
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

    private func activeSOAPairKey(for deviceId: String) -> Data? {
        if let pairKey = pairKeyByDeviceId[deviceId] {
            return pairKey
        }
        guard let remotePeerId = soaPeerIdBytes(for: deviceId) else {
            return nil
        }
        return PeerSessionArbiter.pairKey(
            localPeerId: localSOAPeerIdBytes(),
            remotePeerId: remotePeerId
        )
    }

    private func clearArbiterEstablishedStateForRekey(for deviceId: String) async -> Data? {
        guard let pairKey = activeSOAPairKey(for: deviceId) else {
            return nil
        }
        SkyBridgeLogger.shared.info("🧩 rekey: releasing SOA established guard for \(deviceId)")
        await PeerSessionArbiter.shared.clearEstablished(pairKey: pairKey)
        await PeerSessionArbiter.shared.clearOutgoing(pairKey: pairKey, attemptId: nil)
        return pairKey
    }

    private func restoreArbiterEstablishedStateAfterFailedRekey(
        pairKey: Data?,
        deviceId: String
    ) async {
        guard let pairKey, sessionKeys[deviceId] != nil else {
            return
        }
        SkyBridgeLogger.shared.info("🧩 rekey: restoring SOA established guard after failed rekey for \(deviceId)")
        await PeerSessionArbiter.shared.markEstablished(pairKey: pairKey)
    }

    private func releaseArbiterState(for deviceId: String) async {
        guard let pairKey = pairKeyByDeviceId.removeValue(forKey: deviceId) else { return }
        for key in Array(pairKeyByDeviceId.keys) where pairKeyByDeviceId[key] == pairKey {
            pairKeyByDeviceId.removeValue(forKey: key)
        }
        await PeerSessionArbiter.shared.clearEstablished(pairKey: pairKey)
        await PeerSessionArbiter.shared.clearOutgoing(pairKey: pairKey, attemptId: nil)
    }
    
    /// 执行 PQC 握手（使用完整的 HandshakeDriver 协议）
    private func performPQCHandshake(
        connection: NWConnection,
        device: DiscoveredDevice,
        preferPQC: Bool,
        selectionPolicyOverride: CryptoProviderFactory.SelectionPolicy? = nil,
        allowSOA: Bool = true
    ) async throws {
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
        
        // 创建传输层
        if transport == nil {
            transport = NWConnectionTransport()
        }
        await transport!.setConnection(connection, for: device.id)

        do {
            let peerId = device.id
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
            let outboundSOATargetPeerId = strictTrustContext?.stablePeerId ?? peerId
            let canBindSOATarget = soaPeerIdBytes(for: outboundSOATargetPeerId) != nil
            let shouldAdvertiseSOA = allowSOA && (shouldUseSOA(for: device) || canBindSOATarget)
            let localPeerId = shouldAdvertiseSOA ? localSOAPeerIdBytes() : nil
            let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: outboundSOATargetPeerId) : nil
            if let localPeerId, let remotePeerId {
                pairKeyByDeviceId[peerId] = PeerSessionArbiter.pairKey(
                    localPeerId: localPeerId,
                    remotePeerId: remotePeerId
                )
            } else {
                pairKeyByDeviceId.removeValue(forKey: peerId)
            }
            let outboundSOA: HandshakeSOAMetadata? = {
                guard let localPeerId, let remotePeerId else { return nil }
                return try? HandshakeSOAMetadata(
                    initiatorPeerId: localPeerId,
                    targetPeerId: remotePeerId,
                    attemptId: randomAttemptIdBytes()
                )
            }()

            // 让握手驱动器可接收来自 startReceiving 的消息
            let keys = try await skyBridgeCore.performHandshake(
                deviceId: peerId,
                transport: transport!,
                preferPQC: preferPQC,
                soaMetadata: outboundSOA,
                localSOAPeerId: localPeerId,
                expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId) ?? remotePeerId,
                trustProvider: strictTrustContext?.provider,
                onDriverCreated: { driver in
                    // Swift 6 并发：避免在并发回调里捕获/引用 `self`（即使是 weak self）
                    await MainActor.run {
                        P2PConnectionManager.instance.handshakeDrivers[peerId] = driver
                    }
                }
            )
            if let activeDriver = handshakeDrivers[peerId] {
                await persistAuthenticatedRemoteAuthority(
                    from: activeDriver,
                    for: peerId,
                    deviceNameHint: device.name
                )
            }
            
            // 保存会话密钥 + 清理握手 driver
            setSessionKeys(keys, for: device.id, deviceNameHint: device.name)
            handshakeDrivers.removeValue(forKey: device.id)
            
            currentHandshakeState = "握手成功 (Suite: \(keys.negotiatedSuite.rawValue))"
            SkyBridgeLogger.shared.info("✅ PQC 握手完成 (Suite: \(keys.negotiatedSuite.rawValue))")
            
        } catch {
            handshakeDrivers.removeValue(forKey: device.id)
            let message = userVisibleConnectionError(error)
            currentHandshakeState = "握手失败: \(message)"
            lastError = message
            SkyBridgeLogger.shared.error("❌ PQC 握手失败: \(String(reflecting: error))")
            throw error
        }
    }

    /// 强制用 preferPQC=true 重新握手（用于完成 KEM 公钥交换后的“立刻切换到 PQC suite”）
    public func rekeyToPreferPQC(deviceId: String, allowSOA: Bool = false) async throws {
        let deviceId = canonicalPeerLookupKey(deviceId)
        let fromSuite = resolvedNegotiatedSuite(forAnyPeerId: deviceId)?.rawValue ?? "Classic"
        let targetSuite = preferredRekeyTargetSuite() ?? fromSuite
        let rekeyPairKey = allowSOA ? await clearArbiterEstablishedStateForRekey(for: deviceId) : nil
        setRekeyPresentationStatus(for: deviceId, fromSuite: fromSuite, toSuite: targetSuite)
        rekeyInProgress.insert(deviceId)
        defer {
            rekeyInProgress.remove(deviceId)
            clearRekeyPresentationStatus(for: deviceId)
        }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        let device = discoveryManager.discoveredDevices.first(where: { $0.id == deviceId })
            ?? DiscoveredDevice(id: deviceId, name: deviceId, modelName: "", platform: .unknown, osVersion: "Unknown")
        do {
            try await performPQCHandshake(
                connection: connection,
                device: device,
                preferPQC: true,
                selectionPolicyOverride: pqcManager.enforcePQCHandshake ? .requirePQC : nil,
                allowSOA: allowSOA
            )
        } catch {
            await restoreArbiterEstablishedStateAfterFailedRekey(pairKey: rekeyPairKey, deviceId: deviceId)
            throw error
        }
    }

    /// 使用会话密钥加密数据
    public func encryptForDevice(_ data: Data, deviceId: String) throws -> Data {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let keys = sessionKeys[deviceId] else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.encrypt(data, sessionKey: keys.sendKey)
    }
    
    /// 使用会话密钥解密数据
    public func decryptFromDevice(_ data: Data, deviceId: String) throws -> Data {
        let deviceId = canonicalPeerLookupKey(deviceId)
        guard let keys = sessionKeys[deviceId] else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.decrypt(data, sessionKey: keys.receiveKey)
    }

    func realtimeMediaKeySnapshot(for deviceId: String) -> RemoteRealtimeMediaKeySnapshot? {
        let canonicalDeviceId = canonicalPeerLookupKey(deviceId)
        let runtimePeerId = runtimePeerId(forAnyPeerId: canonicalDeviceId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let directCandidates = [runtimePeerId, canonicalDeviceId, presentationPeerId, deviceId]
        for candidate in directCandidates {
            if let keys = sessionKeys[candidate] {
                return RemoteRealtimeMediaKeySnapshot(
                    sessionId: "lan-\(candidate)",
                    sendKey: keys.sendKey,
                    receiveKey: keys.receiveKey,
                    localRole: keys.role,
                    transcriptHash: keys.transcriptHash,
                    mediaAdmissionToken: nil
                )
            }
        }

        let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: canonicalDeviceId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
        for candidate in stateKeysMatchingAliases(aliases, keys: sessionKeys.keys) {
            if let keys = sessionKeys[candidate] {
                return RemoteRealtimeMediaKeySnapshot(
                    sessionId: "lan-\(candidate)",
                    sendKey: keys.sendKey,
                    receiveKey: keys.receiveKey,
                    localRole: keys.role,
                    transcriptHash: keys.transcriptHash,
                    mediaAdmissionToken: nil
                )
            }
        }
        return nil
    }

    /// Derive the authenticated LAN file-transfer key from the established session keys.
    /// This mirrors the macOS derivation so local file-transfer metadata/chunks/receipts
    /// stay cryptographically bound to the already authenticated P2P session.
    public func deriveClassicFileTransferKey(transferId: String, deviceId: String) throws -> SymmetricKey {
        let canonicalDeviceId = canonicalPeerLookupKey(deviceId)
        let runtimePeerId = runtimePeerId(forAnyPeerId: canonicalDeviceId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)

        for candidate in [runtimePeerId, canonicalDeviceId, presentationPeerId] {
            if let keys = sessionKeys[candidate] {
                return deriveClassicFileTransferKey(from: keys, transferId: transferId)
            }
        }

        let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: canonicalDeviceId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))

        for candidate in stateKeysMatchingAliases(aliases, keys: sessionKeys.keys) {
            if let keys = sessionKeys[candidate] {
                return deriveClassicFileTransferKey(from: keys, transferId: transferId)
            }
        }

        throw P2PError.noSessionKey
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

        let liveTransportKeys = Set(connections.keys).union(
            connectionStatusByDeviceId.compactMap { key, value in
                value == .connected ? key : nil
            }
        )

        for key in sessionKeys.keys {
            let canonical = canonicalPeerLookupKey(key)
            let runtimePeerId = runtimePeerId(forAnyPeerId: canonical)
            let presentationPeerId = presentationPeerId(for: runtimePeerId)
            let aliases = connectionAliasSet(for: runtimePeerId)
                .union(PeerIdentityAliasResolver.lookupCandidates(for: key))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: canonical))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
                .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
                .union([key, canonical, runtimePeerId, presentationPeerId].filter { !$0.isEmpty })

            guard !stateKeysMatchingAliases(aliases, keys: liveTransportKeys).isEmpty else {
                continue
            }

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
        let canonicalDeviceId = canonicalPeerLookupKey(deviceId)
        if let suite = sessionKeys[canonicalDeviceId]?.negotiatedSuite {
            return suite
        }
        if let suite = negotiatedSuiteByDeviceId[deviceId] {
            return suite
        }

        let runtimePeerId = runtimePeerId(forAnyPeerId: deviceId)
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        let directCandidates = [canonicalDeviceId, runtimePeerId, presentationPeerId]
        for candidate in directCandidates {
            if let suite = negotiatedSuiteByDeviceId[candidate] {
                return suite
            }
        }

        let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: runtimePeerId))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: presentationPeerId))
        for candidate in stateKeysMatchingAliases(aliases, keys: negotiatedSuiteByDeviceId.keys) {
            if let suite = negotiatedSuiteByDeviceId[candidate] {
                return suite
            }
        }

        return nil
    }
    
    private func send(data: Data, over connection: NWConnection) async throws {
        // Phase C2: optional padding for post-handshake business traffic (SBP2)
        let padded = TrafficPadding.wrapIfEnabled(data, label: "tx")

        // 与 macOS 端一致：4-byte big-endian length framing
        var framed = Data()
        var length = UInt32(padded.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(padded)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framed,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
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

    func testInstallNegotiatedSuite(_ suite: CryptoSuite, for runtimePeerId: String) {
        negotiatedSuiteByDeviceId[runtimePeerId] = suite
        let presentationPeerId = presentationPeerId(for: runtimePeerId)
        if presentationPeerId != runtimePeerId {
            negotiatedSuiteByDeviceId[presentationPeerId] = suite
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
