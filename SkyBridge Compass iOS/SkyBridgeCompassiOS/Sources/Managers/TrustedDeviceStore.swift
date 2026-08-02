import Foundation
import Combine

/// 受信任设备存储（持久化）
/// - 目的：让 iOS 端的“受信任设备”不再是占位 UI，并能和握手/验证流程挂钩
@MainActor
public final class TrustedDeviceStore: ObservableObject {
    public static let shared = TrustedDeviceStore()

    public enum PersistenceError: LocalizedError, Equatable {
        case unavailable(String)
        case writeFailed(operation: String, reason: String)
        case concurrentModification(operation: String)
        case authorityTransactionQuarantined

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "受信任设备存储不可用：\(reason)"
            case .writeFailed(let operation, let reason):
                return "无法持久化\(operation)：\(reason)"
            case .concurrentModification(let operation):
                return "无法完成\(operation)：本地信任状态在合并期间持续变化"
            case .authorityTransactionQuarantined:
                return "配对接受事务尚未完成恢复，受信任设备 authority 已隔离"
            }
        }
    }

    public enum AuthorityUpdateError: LocalizedError, Equatable {
        case invalidProtocolSigningAlgorithm
        case invalidProtocolPublicKeyFingerprint
        case invalidProtocolPublicKey
        case protocolPublicKeyFingerprintMismatch
        case conflictingProtocolIdentityKey(algorithm: String)
        case missingStableDeviceIdentifier
        case ambiguousStableDeviceIdentifier
        case missingAuthenticatedRemoteAuthority

        public var errorDescription: String? {
            switch self {
            case .invalidProtocolSigningAlgorithm:
                return "协议身份签名算法无效"
            case .invalidProtocolPublicKeyFingerprint:
                return "协议身份公钥指纹无效"
            case .invalidProtocolPublicKey:
                return "协议身份公钥编码或长度无效"
            case .protocolPublicKeyFingerprintMismatch:
                return "协议身份公钥与认证指纹不匹配"
            case .conflictingProtocolIdentityKey(let algorithm):
                return "\(algorithm) 协议身份公钥与已持久化 authority 冲突，必须重新验证"
            case .missingStableDeviceIdentifier:
                return "无法将认证 authority 绑定到稳定设备标识"
            case .ambiguousStableDeviceIdentifier:
                return "同一稳定设备标识对应多条信任记录，记录已隔离并要求重新验证"
            case .missingAuthenticatedRemoteAuthority:
                return "握手完成但没有可提交的对端认证 authority"
            }
        }
    }

    public enum AuthenticatedAuthorityObservationResult: Sendable, Equatable {
        /// The exact authenticated raw key was already present, so its existing
        /// durable record could be refreshed without widening trust.
        case refreshedExistingAuthority
        /// A self-authenticated key is session evidence only until the operator
        /// explicitly approves its device binding.
        case pendingOperatorApproval
    }

    public struct TrustMutationReceipt: Codable, Sendable, Equatable {
        fileprivate let stableDeviceId: String
        fileprivate let previousRecord: TrustedDevice?
        fileprivate let committedRecord: TrustedDevice
        fileprivate let committedRevision: UInt64
        let beforeSnapshot: PairingAcceptanceSnapshot
        let afterSnapshot: PairingAcceptanceSnapshot
    }

    struct PairingAcceptanceSnapshot: Codable, Sendable, Equatable {
        let devices: [TrustedDevice]
    }

    struct PreparedTrustMutation: Sendable {
        let before: PairingAcceptanceSnapshot
        let after: PairingAcceptanceSnapshot
        fileprivate let stableDeviceId: String
        fileprivate let previousRecord: TrustedDevice?
        fileprivate let committedRecord: TrustedDevice
    }

    public enum CurrentPathLifecycleState: String, Codable, Sendable, Equatable {
        case active
        case reverificationRequired
        case quarantined
        case revoked
    }

    public enum CurrentPathTrustConflict: Sendable, Equatable {
        case identityConflict
        case deviceIdMigrationRequired
        case quarantinedIdentity
        case revokedIdentity
    }

    public struct TrustedDevice: Codable, Identifiable, Sendable, Equatable {
        public struct ConnectableContext: Codable, Sendable, Equatable {
            static let currentBonjourRouteSchemaVersion = 1

            public var bonjourServiceName: String?
            public var bonjourServiceType: String?
            public var bonjourServiceDomain: String?
            public var services: [String]
            public var portMap: [String: UInt16]
            public var lastResolvedIPAddress: String?
            /// `nil` identifies legacy records whose three route fields were persisted
            /// independently. Such a record is accepted only when its service evidence proves
            /// that exactly one service type could own the tuple.
            var bonjourRouteSchemaVersion: Int?

            public init(
                bonjourServiceName: String? = nil,
                bonjourServiceType: String? = nil,
                bonjourServiceDomain: String? = nil,
                services: [String] = [],
                portMap: [String: UInt16] = [:],
                lastResolvedIPAddress: String? = nil
            ) {
                self.bonjourServiceName = bonjourServiceName
                self.bonjourServiceType = bonjourServiceType
                self.bonjourServiceDomain = bonjourServiceDomain
                self.services = services
                self.portMap = portMap
                self.lastResolvedIPAddress = lastResolvedIPAddress
                self.bonjourRouteSchemaVersion = nil
            }

            init(
                bonjourRoute: BonjourRouteTuple?,
                services: [String],
                portMap: [String: UInt16],
                lastResolvedIPAddress: String?
            ) {
                bonjourServiceName = bonjourRoute?.name
                bonjourServiceType = bonjourRoute?.type
                bonjourServiceDomain = bonjourRoute?.domain
                self.services = services
                self.portMap = portMap
                self.lastResolvedIPAddress = lastResolvedIPAddress
                bonjourRouteSchemaVersion = bonjourRoute == nil
                    ? nil
                    : Self.currentBonjourRouteSchemaVersion
            }

            var verifiedBonjourRoute: BonjourRouteTuple? {
                guard let candidate = BonjourRouteTuple(
                    name: bonjourServiceName,
                    type: bonjourServiceType,
                    domain: bonjourServiceDomain
                ) else {
                    return nil
                }

                if bonjourRouteSchemaVersion == Self.currentBonjourRouteSchemaVersion {
                    return candidate
                }
                guard bonjourRouteSchemaVersion == nil else {
                    return nil
                }

                // Before route schema v1, fields were merged separately. A legacy route can be
                // migrated only when all service/port evidence names the same single owner.
                // Multi-service records cannot prove which name/domain belongs to which type and
                // must be rehydrated from live Bonjour instead of guessing.
                let evidencedServiceTypes = Set(
                    (services + Array(portMap.keys)).compactMap { raw -> String? in
                        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return value.isEmpty ? nil : value
                    }
                )
                guard evidencedServiceTypes == [candidate.type] else {
                    return nil
                }
                return candidate
            }
        }

        public struct ProtocolIdentityPin: Codable, Sendable, Equatable, Hashable {
            public var algorithm: String
            public var fingerprint: String
            public var approvedAt: Date
            public var source: String

            public init(
                algorithm: String,
                fingerprint: String,
                approvedAt: Date = Date(),
                source: String
            ) {
                self.algorithm = algorithm.trimmingCharacters(in: .whitespacesAndNewlines)
                self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                self.approvedAt = approvedAt
                self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        /// Versioned proof-to-byte binding for a protocol identity key. The
        /// legacy scalar fields and `ProtocolIdentityPin` remain decodable so
        /// existing ML-DSA-65 records are not destroyed during migration.
        public struct ProtocolIdentityKeyBinding: Codable, Sendable, Equatable, Hashable {
            public static let currentSchemaVersion = 1

            public var schemaVersion: Int
            public var algorithm: String
            public var fingerprint: String
            public var publicKeyBase64: String
            public var approvedAt: Date
            public var source: String

            public init(
                schemaVersion: Int = Self.currentSchemaVersion,
                algorithm: String,
                fingerprint: String,
                publicKeyBytes: Data,
                approvedAt: Date = Date(),
                source: String
            ) {
                self.schemaVersion = schemaVersion
                self.algorithm = algorithm.trimmingCharacters(in: .whitespacesAndNewlines)
                self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                self.publicKeyBase64 = publicKeyBytes.base64EncodedString()
                self.approvedAt = approvedAt
                self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            public var publicKeyBytes: Data? {
                guard let decoded = Data(base64Encoded: publicKeyBase64),
                      decoded.base64EncodedString() == publicKeyBase64 else {
                    return nil
                }
                return decoded
            }
        }

        public let id: String // 建议使用 discovery TXT 的 uuid / 或配对 deviceId
        public var name: String
        public var platform: DevicePlatform
        public var ipAddress: String?
        public var addedAt: Date
        public var protocolSigningAlgorithm: String?
        public var protocolPublicKeyFingerprint: String?
        public var protocolIdentityPins: [ProtocolIdentityPin]?
        public var protocolIdentityKeyBindings: [ProtocolIdentityKeyBinding]?
        public var currentDeviceId: String?
        public var knownDeviceIds: [String]?
        public var currentPathLifecycleState: CurrentPathLifecycleState?
        public var currentPathLifecycleGeneration: Int64?
        public var connectableContext: ConnectableContext?

        public init(
            id: String,
            name: String,
            platform: DevicePlatform,
            ipAddress: String?,
            addedAt: Date = Date(),
            protocolSigningAlgorithm: String? = nil,
            protocolPublicKeyFingerprint: String? = nil,
            protocolIdentityPins: [ProtocolIdentityPin]? = nil,
            protocolIdentityKeyBindings: [ProtocolIdentityKeyBinding]? = nil,
            currentDeviceId: String? = nil,
            knownDeviceIds: [String]? = nil,
            currentPathLifecycleState: CurrentPathLifecycleState? = nil,
            currentPathLifecycleGeneration: Int64? = nil,
            connectableContext: ConnectableContext? = nil
        ) {
            self.id = id
            self.name = name
            self.platform = platform
            self.ipAddress = ipAddress
            self.addedAt = addedAt
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint?.lowercased()
            self.protocolIdentityPins = protocolIdentityPins
            self.protocolIdentityKeyBindings = protocolIdentityKeyBindings
            self.currentDeviceId = currentDeviceId
            self.knownDeviceIds = knownDeviceIds
            self.currentPathLifecycleState = currentPathLifecycleState
            self.currentPathLifecycleGeneration = currentPathLifecycleGeneration
            self.connectableContext = connectableContext
        }
    }

    /// Revocation records are durable authority tombstones, not connection
    /// hints. Endpoint identities can be reassigned, so they must never survive
    /// on a tombstone. A tombstone without a stable device identifier is not
    /// durable authority and is dropped instead of revoking a future endpoint
    /// occupant.
    nonisolated static func sanitizedRevokedTombstone(
        _ device: TrustedDevice
    ) -> TrustedDevice? {
        guard (device.currentPathLifecycleState ?? .active) == .revoked else {
            return device
        }

        let rawStableCandidates = [device.currentDeviceId, device.id]
            + (device.knownDeviceIds ?? [])
        let stableIdentifiers = rawStableCandidates.compactMap {
            PeerIdentityAliasResolver.persistentDeviceId(from: $0)
        }
        guard let stableDeviceId = stableIdentifiers.first else {
            return nil
        }

        let trimmedRecordId = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordId = PeerIdentityAliasResolver.persistentDeviceId(from: trimmedRecordId) == nil
            ? stableDeviceId
            : trimmedRecordId
        let stableKnownDeviceIds = Array(Set((device.knownDeviceIds ?? []).compactMap {
            PeerIdentityAliasResolver.persistentDeviceId(from: $0)
        })).sorted()

        return TrustedDevice(
            id: recordId,
            name: device.name,
            platform: device.platform,
            ipAddress: nil,
            addedAt: device.addedAt,
            protocolSigningAlgorithm: device.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: device.protocolPublicKeyFingerprint,
            protocolIdentityPins: device.protocolIdentityPins,
            protocolIdentityKeyBindings: device.protocolIdentityKeyBindings,
            currentDeviceId: stableDeviceId,
            knownDeviceIds: stableKnownDeviceIds.isEmpty ? nil : stableKnownDeviceIds,
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: max(
                device.currentPathLifecycleGeneration ?? 0,
                0
            ),
            connectableContext: nil
        )
    }

    @Published public private(set) var trustedDevices: [TrustedDevice] = []
    @Published public private(set) var persistenceErrorMessage: String?
    private var trustMutationRevisionByStableDeviceId: [String: UInt64] = [:]
    private var lastPersistedTrustedDevices: [TrustedDevice] = []
    private let pairingAcceptanceJournalExists: @Sendable () -> Bool

    /// Stored authority is usable only after a strict load and while every
    /// subsequent write in this process has remained observable and durable.
    public var isAuthorityPersistenceAvailable: Bool {
        persistenceErrorMessage == nil && !pairingAcceptanceJournalExists()
    }

    func activeAuthoritySnapshot() throws -> [TrustedDevice] {
        try requireAuthorityPersistenceAvailable(outerPermit: nil)
        return trustedDevices.filter { isActive($0) }
    }

    func authorityRecordsSnapshot() throws -> [TrustedDevice] {
        try requireAuthorityPersistenceAvailable(outerPermit: nil)
        return trustedDevices
    }

    private static let trustedDevicesStore = CodablePersistenceStore<[TrustedDevice]>(
        location: .protectedApplicationSupport(
            path: "Trust/trusted-devices.json",
            legacyUserDefaultsKey: "trusted_devices.v1"
        )
    )
    private final class EphemeralPersistence {
        var devices: [TrustedDevice]?
    }
    private let loadPersistedDevices: () throws -> [TrustedDevice]?
    private let savePersistedDevices: ([TrustedDevice]) throws -> Void

    private init() {
        pairingAcceptanceJournalExists = {
            PairingAcceptanceJournalStore.defaultJournalExists()
        }
        #if DEBUG || SKYBRIDGE_TESTING
        if Self.usesEphemeralPersistenceForSmoke() {
            let persistence = EphemeralPersistence()
            loadPersistedDevices = { persistence.devices }
            savePersistedDevices = { persistence.devices = $0 }
        } else {
            loadPersistedDevices = { try Self.trustedDevicesStore.loadOrThrow() }
            savePersistedDevices = { try Self.trustedDevicesStore.save($0) }
        }
        #else
        loadPersistedDevices = { try Self.trustedDevicesStore.loadOrThrow() }
        savePersistedDevices = { try Self.trustedDevicesStore.save($0) }
        #endif
        load()
    }

    nonisolated static func usesEphemeralPersistenceForSmoke(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        return environment["SKYBRIDGE_SMOKE_ROLE"] != nil
            && environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1"
        #else
        return false
        #endif
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        testingLoad: @escaping () throws -> [TrustedDevice]?,
        testingSave: @escaping ([TrustedDevice]) throws -> Void,
        pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = {
            PairingAcceptanceJournalStore.defaultJournalExists()
        }
    ) {
        loadPersistedDevices = testingLoad
        savePersistedDevices = testingSave
        self.pairingAcceptanceJournalExists = pairingAcceptanceJournalExists
        load()
    }

    func replaceTrustedDevicesForTesting(_ devices: [TrustedDevice]) throws {
        let touchedStableDeviceIds = Set(
            (trustedDevices + devices).flatMap { Array(stableDeviceIdentifiers(for: $0)) }
        )
        try persist(devices, operation: "重置测试受信任设备")
        trustedDevices = devices
        for stableDeviceId in touchedStableDeviceIds {
            _ = advanceTrustMutationRevision(for: stableDeviceId)
        }
    }
#endif

    public func hasActiveDurableTrust(forAny deviceIds: [String]) -> Bool {
        guard isAuthorityPersistenceAvailable else { return false }
        let candidates = Set(deviceIds.flatMap { PeerIdentityAliasResolver.lookupCandidates(for: $0) })
        guard !candidates.isEmpty else { return false }
        return trustedDevices.contains { isActive($0) && matches($0, candidates: candidates) }
    }

    public func isTrusted(deviceId: String) -> Bool {
        guard isAuthorityPersistenceAvailable else { return false }
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return false }
        return trustedDevices.contains(where: { isActive($0) && matches($0, candidates: candidates) })
    }

    public func canonicalTrustedDeviceId(for deviceId: String) -> String? {
        guard isAuthorityPersistenceAvailable else { return nil }
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return nil }
        guard let matched = trustedDevices.first(where: { isActive($0) && matches($0, candidates: candidates) }) else {
            return nil
        }
        return resolvedCurrentDeviceId(for: matched)
    }

    public func uniqueCanonicalTrustedDeviceId(for deviceId: String) -> String? {
        guard isAuthorityPersistenceAvailable else { return nil }
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return nil }

        let stableMatches = Set(trustedDevices.compactMap { device -> String? in
            guard isActive(device), matches(device, candidates: candidates) else { return nil }
            return canonicalStoredTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: device))
        })
        guard stableMatches.count == 1 else { return nil }
        return stableMatches.first
    }

    public func canonicalTrustedDeviceId(for device: DiscoveredDevice) -> String? {
        guard isAuthorityPersistenceAvailable else { return nil }
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        if let matched = trustedDevices.first(where: { isActive($0) && matches($0, candidates: candidates) }) {
            return resolvedCurrentDeviceId(for: matched)
        }
        return nil
    }

    /// Authority-sensitive callers may use only an exact stable identifier.
    /// Bonjour names, host aliases and IP routes remain discovery hints and are
    /// deliberately excluded from this lookup.
    func stableIdentifierMatchedTrustedDeviceId(for device: DiscoveredDevice) -> String? {
        guard isAuthorityPersistenceAvailable,
              let stableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(from: device.id)
        else {
            return nil
        }
        let matches = trustedDevices.filter { trusted in
            isActive(trusted) && stableDeviceIdentifiers(for: trusted).contains(stableDeviceId)
        }
        guard matches.count == 1 else { return nil }
        return resolvedCurrentDeviceId(for: matches[0])
    }

    public func resolvedConnectableDevice(for device: DiscoveredDevice) -> DiscoveredDevice? {
        guard isAuthorityPersistenceAvailable else { return nil }
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        guard let matched = trustedDevices.first(where: { isActive($0) && matches($0, candidates: candidates) }) else {
            return nil
        }

        let fallbackContext = connectableContext(from: matched)
        let mergedContext = mergedConnectableContext(
            fallbackContext,
            with: connectableContext(from: device)
        )

        guard let mergedContext else { return nil }
        let bonjourRoute = mergedContext.verifiedBonjourRoute
        guard bonjourRoute != nil
                || mergedContext.lastResolvedIPAddress?.isEmpty == false
                || !mergedContext.services.isEmpty
                || !mergedContext.portMap.isEmpty else {
            return nil
        }

        let mergedServices = Array(Set(device.services).union(mergedContext.services)).sorted()
        let mergedPortMap = mergedContext.portMap.merging(device.portMap) { _, latest in latest }

        return DiscoveredDevice(
            id: device.id,
            name: device.name,
            bonjourServiceName: bonjourRoute?.name,
            modelName: device.modelName,
            platform: device.platform,
            osVersion: device.osVersion,
            ipAddress: device.ipAddress ?? mergedContext.lastResolvedIPAddress ?? matched.ipAddress,
            bonjourServiceType: bonjourRoute?.type,
            bonjourServiceDomain: bonjourRoute?.domain,
            services: mergedServices,
            portMap: mergedPortMap,
            signalStrength: device.signalStrength,
            lastSeen: device.lastSeen,
            isConnected: device.isConnected,
            isTrusted: true,
            publicKey: device.publicKey,
            advertisedCapabilities: device.advertisedCapabilities,
            capabilities: device.capabilities
        )
    }

    public func currentPathTrustRecord(fingerprint: String) -> TrustedDevice? {
        guard isAuthorityPersistenceAvailable else { return nil }
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        return trustedDevices.first { device in
            authorityFingerprints(for: device).contains(normalized) && isActive(device)
        }
    }

    public func currentPathTrustRecord(
        fingerprint: String,
        matchingDeviceId deviceId: String
    ) -> TrustedDevice? {
        guard isAuthorityPersistenceAvailable else { return nil }
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        return trustedDevices.first { device in
            guard authorityFingerprints(for: device).contains(normalized) else { return false }
            guard isActive(device) else { return false }
            return currentPathDeviceMatches(device, deviceId: deviceId)
        }
    }

    public func currentPathFingerprints(forAny deviceIds: [String]) -> Set<String> {
        guard isAuthorityPersistenceAvailable else { return [] }
        let candidates = Set(deviceIds.flatMap { PeerIdentityAliasResolver.lookupCandidates(for: $0) })
        guard !candidates.isEmpty else { return [] }
        var fingerprints = Set<String>()
        for device in trustedDevices where isActive(device) {
            guard matches(device, candidates: candidates) else { continue }
            fingerprints.formUnion(authorityFingerprints(for: device))
        }
        return fingerprints
    }

    func hasCurrentPathAuthorityFingerprint(
        _ fingerprint: String,
        lifecycleStates: [CurrentPathLifecycleState]
    ) -> Bool {
        guard isAuthorityPersistenceAvailable else { return false }
        guard let normalized = normalizedFingerprint(fingerprint) else { return false }
        return trustedDevices.contains { device in
            guard authorityFingerprints(for: device).contains(normalized) else { return false }
            let state = device.currentPathLifecycleState ?? .active
            return lifecycleStates.contains(state)
        }
    }

    func hasCurrentPathAuthorityDevice(
        _ deviceId: String,
        lifecycleStates: [CurrentPathLifecycleState]
    ) -> Bool {
        guard isAuthorityPersistenceAvailable else { return false }
        return trustedDevices.contains { device in
            guard currentPathDeviceMatches(device, deviceId: deviceId) else { return false }
            let state = device.currentPathLifecycleState ?? .active
            return lifecycleStates.contains(state)
        }
    }

    public func evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        guard isAuthorityPersistenceAvailable else { return .quarantinedIdentity }
        guard let normalized = normalizedFingerprint(protocolPublicKeyFingerprint) else { return nil }

        let fingerprintMatches = trustedDevices.filter { authorityFingerprints(for: $0).contains(normalized) }
        if fingerprintMatches.contains(where: { ($0.currentPathLifecycleState ?? .active) == .revoked }) {
            return .revokedIdentity
        }
        if fingerprintMatches.contains(where: {
            switch $0.currentPathLifecycleState ?? .active {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if fingerprintMatches.contains(where: { ($0.currentPathLifecycleState ?? .active) == .active }) {
            // The authoritative signing key is the stronger identity anchor.
            // If the same key now advertises a new deviceId, allow the session
            // to proceed and heal the stored deviceId/aliases after success.
            return nil
        }

        let deviceMatches = trustedDevices.filter { currentPathDeviceMatches($0, deviceId: deviceId) }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = authorityFingerprints(for: $0)
            guard !pinnedFingerprints.isEmpty else { return false }
            return !pinnedFingerprints.contains(normalized) && ($0.currentPathLifecycleState ?? .active) == .revoked
        }) {
            return .revokedIdentity
        }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = authorityFingerprints(for: $0)
            guard !pinnedFingerprints.isEmpty else { return false }
            guard !pinnedFingerprints.contains(normalized) else { return false }
            switch $0.currentPathLifecycleState ?? .active {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = authorityFingerprints(for: $0)
            guard !pinnedFingerprints.isEmpty else { return false }
            return !pinnedFingerprints.contains(normalized) && ($0.currentPathLifecycleState ?? .active) == .active
        }) {
            return .identityConflict
        }

        return nil
    }

    @discardableResult
    public func markReverificationRequired(deviceId: String) -> Bool {
        guard isAuthorityPersistenceAvailable else { return false }
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return false }

        var changed = false
        for index in trustedDevices.indices where matches(trustedDevices[index], candidates: candidates) {
            if trustedDevices[index].currentPathLifecycleState != .reverificationRequired {
                transitionLifecycle(
                    of: &trustedDevices[index],
                    to: .reverificationRequired
                )
                changed = true
            }
        }

        if changed {
            save()
        }
        return changed
    }

    public func trust(_ device: DiscoveredDevice) {
        guard isAuthorityPersistenceAvailable else { return }
        let id = device.id
        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        guard !candidates.isEmpty else { return }
        let latestConnectableContext = connectableContext(from: device)

        if let idx = trustedDevices.firstIndex(where: { matches($0, candidates: candidates) }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
            transitionLifecycle(of: &trustedDevices[idx], to: .active)
            trustedDevices[idx].connectableContext = mergedConnectableContext(
                trustedDevices[idx].connectableContext,
                with: latestConnectableContext
            )
            trustedDevices[idx].knownDeviceIds = mergedKnownDeviceIds(
                existing: trustedDevices[idx].knownDeviceIds,
                adding: Array(candidates)
            )
            if let persistent = PeerIdentityAliasResolver.persistentDeviceId(from: id) {
                trustedDevices[idx].currentDeviceId = persistent
            }
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: id,
                    name: device.name,
                    platform: device.platform,
                    ipAddress: device.ipAddress,
                    currentDeviceId: PeerIdentityAliasResolver.persistentDeviceId(from: id),
                    knownDeviceIds: Array(candidates).sorted(),
                    currentPathLifecycleState: .active,
                    connectableContext: latestConnectableContext
                )
            )
        }
        save()
    }

    @discardableResult
    public func trustResolvedPeer(
        _ device: DiscoveredDevice,
        declaredDeviceId: String,
        protocolSigningAlgorithm: String? = nil,
        protocolPublicKeyFingerprint: String? = nil
    ) throws -> TrustMutationReceipt {
        do {
            let prepared = try prepareTrustResolvedPeer(
                device,
                declaredDeviceId: declaredDeviceId,
                protocolSigningAlgorithm: protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
                outerPermit: nil
            )
            return try applyPreparedTrustMutation(prepared, outerPermit: nil)
        } catch AuthorityUpdateError.ambiguousStableDeviceIdentifier {
            if let stableDeviceId = normalizedTrustedDeviceIdentifier(declaredDeviceId) {
                try quarantineStableAuthorityRows(
                    stableDeviceId: stableDeviceId,
                    operation: "隔离重复的稳定设备 authority"
                )
            }
            throw AuthorityUpdateError.ambiguousStableDeviceIdentifier
        }
    }

    func prepareTrustResolvedPeer(
        _ device: DiscoveredDevice,
        declaredDeviceId: String,
        protocolSigningAlgorithm: String? = nil,
        protocolPublicKeyFingerprint: String? = nil,
        outerPermit: PairingIdentityAuthorityMutationPermit?
    ) throws -> PreparedTrustMutation {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        guard let normalizedDeclaredDeviceId = normalizedTrustedDeviceIdentifier(
            declaredDeviceId
        ) else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }
        let normalizedAlgorithm = protocolSigningAlgorithm?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint)

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: normalizedDeclaredDeviceId))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        guard !candidates.isEmpty else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }
        let latestConnectableContext = connectableContext(from: device)
        let beforeSnapshot = PairingAcceptanceSnapshot(devices: trustedDevices)
        var candidateTrustedDevices = trustedDevices
        let exactStableIdentityIndices = candidateTrustedDevices.indices.filter { index in
            stableDeviceIdentifiers(for: candidateTrustedDevices[index]).contains(
                normalizedDeclaredDeviceId
            )
        }
        guard exactStableIdentityIndices.count <= 1 else {
            throw AuthorityUpdateError.ambiguousStableDeviceIdentifier
        }
        let exactStableIdentityIndex = exactStableIdentityIndices.first
        let previousRecord = exactStableIdentityIndex.map { candidateTrustedDevices[$0] }

        if let idx = exactStableIdentityIndex {
            candidateTrustedDevices[idx].name = device.name
            candidateTrustedDevices[idx].platform = device.platform
            candidateTrustedDevices[idx].ipAddress = device.ipAddress
            candidateTrustedDevices[idx].currentDeviceId = normalizedDeclaredDeviceId
            transitionLifecycle(of: &candidateTrustedDevices[idx], to: .active)
            candidateTrustedDevices[idx].connectableContext = mergedConnectableContext(
                candidateTrustedDevices[idx].connectableContext,
                with: latestConnectableContext
            )
            let previousAlgorithm = candidateTrustedDevices[idx].protocolSigningAlgorithm
            let previousFingerprint = candidateTrustedDevices[idx].protocolPublicKeyFingerprint
            if let normalizedAlgorithm, !normalizedAlgorithm.isEmpty {
                candidateTrustedDevices[idx].protocolSigningAlgorithm = normalizedAlgorithm
            }
            if let normalizedFingerprint {
                if let normalizedAlgorithm, !normalizedAlgorithm.isEmpty {
                    candidateTrustedDevices[idx].protocolIdentityPins = protocolIdentityPinsByReplacingAlgorithm(
                        existing: candidateTrustedDevices[idx].protocolIdentityPins,
                        legacyAlgorithm: previousAlgorithm,
                        legacyFingerprint: previousFingerprint,
                        addingAlgorithm: normalizedAlgorithm,
                        addingFingerprint: normalizedFingerprint,
                        source: Self.authenticatedHandshakePinSource
                    )
                }
                candidateTrustedDevices[idx].protocolPublicKeyFingerprint = normalizedFingerprint
            }
            candidateTrustedDevices[idx].knownDeviceIds = mergedKnownDeviceIds(
                existing: candidateTrustedDevices[idx].knownDeviceIds,
                adding: Array(candidates)
            )
        } else {
            candidateTrustedDevices.append(
                TrustedDevice(
                    id: device.id,
                    name: device.name,
                    platform: device.platform,
                    ipAddress: device.ipAddress,
                    protocolSigningAlgorithm: normalizedAlgorithm,
                    protocolPublicKeyFingerprint: normalizedFingerprint,
                    protocolIdentityPins: {
                        guard let normalizedAlgorithm,
                              let normalizedFingerprint else { return nil }
                        return [
                            TrustedDevice.ProtocolIdentityPin(
                                algorithm: normalizedAlgorithm,
                                fingerprint: normalizedFingerprint,
                                source: Self.authenticatedHandshakePinSource
                            )
                        ]
                    }(),
                    currentDeviceId: normalizedDeclaredDeviceId,
                    knownDeviceIds: Array(candidates).sorted(),
                    currentPathLifecycleState: .active,
                    connectableContext: latestConnectableContext
                )
            )
        }
        guard let committedRecord = candidateTrustedDevices.first(where: { record in
            stableDeviceIdentifiers(for: record).contains(normalizedDeclaredDeviceId)
        }) else {
            throw PersistenceError.writeFailed(
                operation: "受信任设备",
                reason: "候选缺少待提交的稳定设备记录"
            )
        }
        return PreparedTrustMutation(
            before: beforeSnapshot,
            after: PairingAcceptanceSnapshot(devices: candidateTrustedDevices),
            stableDeviceId: normalizedDeclaredDeviceId,
            previousRecord: previousRecord,
            committedRecord: committedRecord
        )
    }

    func applyPreparedTrustMutation(
        _ prepared: PreparedTrustMutation,
        outerPermit: PairingIdentityAuthorityMutationPermit?
    ) throws -> TrustMutationReceipt {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        guard trustedDevices == prepared.before.devices else {
            throw PersistenceError.concurrentModification(operation: "配对接受事务")
        }
        try persist(
            prepared.after.devices,
            operation: "受信任设备",
            outerPermit: outerPermit
        )
        let committedRevision = advanceTrustMutationRevision(for: prepared.stableDeviceId)
        trustedDevices = prepared.after.devices
        return TrustMutationReceipt(
            stableDeviceId: prepared.stableDeviceId,
            previousRecord: prepared.previousRecord,
            committedRecord: prepared.committedRecord,
            committedRevision: committedRevision,
            beforeSnapshot: prepared.before,
            afterSnapshot: prepared.after
        )
    }

    func pairingAcceptanceSnapshot(
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> PairingAcceptanceSnapshot {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        return PairingAcceptanceSnapshot(devices: trustedDevices)
    }

    func restorePairingAcceptanceSnapshot(
        _ snapshot: PairingAcceptanceSnapshot,
        expectedCurrent: [PairingAcceptanceSnapshot],
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        guard expectedCurrent.contains(where: { $0.devices == trustedDevices }) else {
            throw PersistenceError.concurrentModification(operation: "配对接受事务恢复")
        }
        let previous = trustedDevices
        try persist(
            snapshot.devices,
            operation: "恢复配对接受事务",
            outerPermit: outerPermit
        )
        trustedDevices = snapshot.devices
        let touchedStableDeviceIds = Set(
            (previous + snapshot.devices).flatMap { Array(stableDeviceIdentifiers(for: $0)) }
        )
        for stableDeviceId in touchedStableDeviceIds {
            _ = advanceTrustMutationRevision(for: stableDeviceId)
        }
    }

    func pairingAcceptanceSnapshotMatches(
        _ snapshot: PairingAcceptanceSnapshot,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> Bool {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        return trustedDevices == snapshot.devices
    }

    public func rollbackTrustMutation(_ receipt: TrustMutationReceipt) throws {
        let stableIdentityIndices = trustedDevices.indices.filter {
            stableDeviceIdentifiers(for: trustedDevices[$0]).contains(
                receipt.stableDeviceId
            )
        }
        let committedIndices = stableIdentityIndices.filter {
            trustedDevices[$0] == receipt.committedRecord
        }
        guard stableIdentityIndices.count == 1,
              committedIndices.count == 1,
              let committedIndex = committedIndices.first,
              trustMutationRevisionByStableDeviceId[receipt.stableDeviceId]
                == receipt.committedRevision else {
            // A same-authority concurrent mutation makes exact compensation
            // impossible. Quarantine every matching stable record so the
            // residue cannot authorize a later automatic pairing.
            var quarantined = trustedDevices
            var didQuarantine = false
            for index in quarantined.indices where stableDeviceIdentifiers(
                for: quarantined[index]
            ).contains(receipt.stableDeviceId) {
                switch quarantined[index].currentPathLifecycleState ?? .active {
                case .active, .reverificationRequired:
                    transitionLifecycle(of: &quarantined[index], to: .quarantined)
                    didQuarantine = true
                case .quarantined, .revoked:
                    break
                }
            }
            if didQuarantine, quarantined != trustedDevices {
                try persist(quarantined, operation: "隔离并发修改的受信任设备")
                trustedDevices = quarantined
                _ = advanceTrustMutationRevision(for: receipt.stableDeviceId)
            }
            throw PersistenceError.concurrentModification(operation: "受信任设备回滚")
        }

        var candidate = trustedDevices
        if let previousRecord = receipt.previousRecord {
            candidate[committedIndex] = previousRecord
        } else {
            candidate.remove(at: committedIndex)
        }
        try persist(candidate, operation: "受信任设备回滚")
        trustedDevices = candidate
        _ = advanceTrustMutationRevision(for: receipt.stableDeviceId)
    }

    @discardableResult
    public func recordAuthenticatedRemoteAuthority(
        for device: DiscoveredDevice,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        protocolPublicKeyBytes: Data
    ) throws -> AuthenticatedAuthorityObservationResult {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else {
            throw AuthorityUpdateError.invalidProtocolPublicKeyFingerprint
        }
        let normalizedAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlgorithm.isEmpty else {
            throw AuthorityUpdateError.invalidProtocolSigningAlgorithm
        }

        let authenticatedKeyBinding = try validatedProtocolIdentityKeyBinding(
            algorithm: normalizedAlgorithm,
            fingerprint: normalizedFingerprint,
            publicKeyBytes: protocolPublicKeyBytes,
            source: Self.authenticatedHandshakePinSource
        )
        guard let authenticatedAlgorithm = ProtocolSigningAlgorithm(
            rawValue: authenticatedKeyBinding.algorithm
        ), uniqueExactActiveProtocolIdentityAuthorityDeviceId(
            algorithm: authenticatedAlgorithm,
            fingerprint: authenticatedKeyBinding.fingerprint,
            publicKey: protocolPublicKeyBytes
        ) != nil else {
            // Unknown self-authenticated keys remain bound to the live session.
            // Persisting one row per key would create an attacker-controlled,
            // unbounded durable store before any operator approval.
            return .pendingOperatorApproval
        }

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        candidates.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        if let ipAddress = device.ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        guard !candidates.isEmpty else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }

        _ = try upsertAuthoritativeTrustedDevice(
            preferredRecordId: device.id,
            candidateAliases: candidates,
            name: device.name,
            platform: device.platform,
            ipAddress: device.ipAddress,
            protocolSigningAlgorithm: normalizedAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolPublicKeyBytes: protocolPublicKeyBytes,
            preferredCurrentDeviceId: nil,
            connectableContext: connectableContext(from: device),
            pinSource: Self.authenticatedHandshakePinSource,
            activation: .preserveExistingAuthorization,
            recordMatchPolicy: .authenticatedAuthorityOnly
        )
        return .refreshedExistingAuthority
    }

    @discardableResult
    public func recordApprovedProtocolIdentityBinding(
        peerId: String,
        deviceId: String,
        aliases: [String],
        displayName: String?,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        protocolPublicKeyBytes: Data
    ) throws -> Bool {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else {
            throw AuthorityUpdateError.invalidProtocolPublicKeyFingerprint
        }
        guard let normalizedAlgorithm = normalizedAlgorithm(protocolSigningAlgorithm) else {
            throw AuthorityUpdateError.invalidProtocolSigningAlgorithm
        }
        guard let stableCurrentDeviceId = normalizedTrustedDeviceIdentifier(deviceId) else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }

        var candidates = Set<String>()
        for rawId in [peerId, deviceId] + aliases {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: rawId))
        }
        candidates.insert(stableCurrentDeviceId)
        guard !candidates.isEmpty else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }

        return try upsertAuthoritativeTrustedDevice(
            preferredRecordId: stableCurrentDeviceId,
            candidateAliases: candidates,
            name: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
                : stableCurrentDeviceId,
            platform: .unknown,
            ipAddress: nil,
            protocolSigningAlgorithm: normalizedAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolPublicKeyBytes: protocolPublicKeyBytes,
            preferredCurrentDeviceId: stableCurrentDeviceId,
            pinSource: Self.pibOperatorApprovalPinSource,
            activation: .operatorApproved,
            recordMatchPolicy: .operatorApprovedStableIdentifierOrAuthority
        )
    }

    public func upsertCurrentPathAuthority(
        deviceId: String,
        name: String,
        platform: DevicePlatform = .unknown,
        ipAddress: String? = nil,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        protocolPublicKeyBytes: Data,
        connectableContext: TrustedDevice.ConnectableContext? = nil
    ) throws {
        guard let normalizedFingerprint = normalizedFingerprint(protocolPublicKeyFingerprint) else {
            throw AuthorityUpdateError.invalidProtocolPublicKeyFingerprint
        }
        let normalizedAlgorithm = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlgorithm.isEmpty else {
            throw AuthorityUpdateError.invalidProtocolSigningAlgorithm
        }
        guard let stableCurrentDeviceId = normalizedTrustedDeviceIdentifier(deviceId) else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }

        var candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: stableCurrentDeviceId))
        if let ipAddress {
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        if candidates.isEmpty {
            candidates.insert(stableCurrentDeviceId.lowercased())
        }

        _ = try upsertAuthoritativeTrustedDevice(
            preferredRecordId: stableCurrentDeviceId,
            candidateAliases: candidates,
            name: name,
            platform: platform,
            ipAddress: ipAddress,
            protocolSigningAlgorithm: normalizedAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolPublicKeyBytes: protocolPublicKeyBytes,
            preferredCurrentDeviceId: stableCurrentDeviceId,
            connectableContext: connectableContext,
            pinSource: Self.authenticatedHandshakePinSource,
            activation: .operatorApproved,
            recordMatchPolicy: .operatorApprovedStableIdentifierOrAuthority
        )
    }

    /// 合并 CloudKit 同步的可信设备。撤销是单调的安全状态：远端旧的
    /// positive record 不能覆盖本地 tombstone；只有显式重新配对可以恢复。
    public func mergeFromCloud(_ devices: [TrustedDevice]) throws {
        if let candidateTrustedDevices = cloudMergeCandidate(
            localDevices: trustedDevices,
            remoteDevices: devices
        ) {
            try persist(candidateTrustedDevices, operation: "合并云端受信任设备")
            trustedDevices = candidateTrustedDevices
        }
    }

    /// Cloud pages can contain hundreds of records and alias matching is
    /// intentionally more expensive than a dictionary lookup. Compute the
    /// candidate away from MainActor, then compare-and-commit on MainActor so
    /// an operator revocation or re-pair that happens while planning is never
    /// overwritten by a stale cloud candidate.
    func mergeFromCloudWithoutBlockingMainActor(
        _ devices: [TrustedDevice]
    ) async throws {
        guard !devices.isEmpty else { return }

        let maximumPlanningAttempts = 3
        for _ in 0..<maximumPlanningAttempts {
            let baseline = trustedDevices
            let candidate = await Task.detached(priority: .utility) { [self, baseline, devices] in
                cloudMergeCandidate(
                    localDevices: baseline,
                    remoteDevices: devices
                )
            }.value

            guard trustedDevices == baseline else {
                // No persistence has happened yet; recompute from the newer
                // authoritative snapshot instead of committing stale state.
                continue
            }
            guard let candidate else { return }

            try persist(candidate, operation: "合并云端受信任设备")
            trustedDevices = candidate
            return
        }

        throw PersistenceError.concurrentModification(operation: "合并云端受信任设备")
    }

    /// A CloudKit compare-and-swap conflict whose server identity cannot be
    /// bound to the record being saved is not safe to treat as an ordinary
    /// retry. Persistently quarantine the affected local authorities before
    /// the sync error escapes so a malformed or ambiguous conflict cannot
    /// leave stale positive trust usable by connection code.
    func quarantineCloudConflictAuthorities(deviceIds: [String]) throws {
        let requestedIds = Set(deviceIds.compactMap { rawValue -> String? in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
        guard !requestedIds.isEmpty else { return }

        var requestedAliases = requestedIds
        for deviceId in requestedIds {
            requestedAliases.formUnion(
                PeerIdentityAliasResolver.lookupCandidates(for: deviceId)
            )
        }

        var candidateTrustedDevices = trustedDevices
        var changed = false
        for index in candidateTrustedDevices.indices {
            let record = candidateTrustedDevices[index]
            let matchesRequestedAuthority = requestedIds.contains(record.id)
                || !trustedAliasCandidates(for: record).isDisjoint(with: requestedAliases)
            guard matchesRequestedAuthority else { continue }

            switch record.currentPathLifecycleState ?? .active {
            case .active, .reverificationRequired:
                transitionLifecycle(
                    of: &candidateTrustedDevices[index],
                    to: .quarantined
                )
                changed = true
            case .quarantined, .revoked:
                // Never advance or downgrade an already fail-closed state.
                continue
            }
        }

        guard changed else { return }
        try persist(
            candidateTrustedDevices,
            operation: "隔离 CloudKit 冲突受信任设备"
        )
        trustedDevices = candidateTrustedDevices
    }

    private nonisolated func cloudMergeCandidate(
        localDevices: [TrustedDevice],
        remoteDevices: [TrustedDevice]
    ) -> [TrustedDevice]? {
        guard !remoteDevices.isEmpty else { return nil }

        var candidateTrustedDevices = localDevices
        var changed = false

        for rawRemote in remoteDevices {
            guard let remote = migratedTrustedDeviceRecord(rawRemote) else {
                continue
            }
            guard !remote.id.isEmpty else { continue }
            let remoteAliases = stableTrustedAliasCandidates(for: remote)
            let remoteFingerprints = authorityFingerprints(for: remote)
            let matchingIndices = candidateTrustedDevices.indices.filter { index in
                let current = candidateTrustedDevices[index]
                if current.id == remote.id { return true }
                if !stableTrustedAliasCandidates(for: current).isDisjoint(with: remoteAliases) {
                    return true
                }
                return !remoteFingerprints.isEmpty
                    && !authorityFingerprints(for: current).isDisjoint(with: remoteFingerprints)
            }

            guard let primaryIndex = matchingIndices.first else {
                candidateTrustedDevices.append(remote)
                changed = true
                continue
            }

            let localWinner = matchingIndices
                .map { candidateTrustedDevices[$0] }
                .max { lhs, rhs in
                    lifecycleOrderingKey(for: lhs) < lifecycleOrderingKey(for: rhs)
                }
            guard let localWinner else { continue }
            let remoteOrderingKey = lifecycleOrderingKey(for: remote)
            let localOrderingKey = lifecycleOrderingKey(for: localWinner)

            // A later explicit lifecycle transition wins. Legacy/equal
            // generations remain revoked-dominant, so an old cloud active row
            // can never resurrect a tombstone.
            guard remoteOrderingKey >= localOrderingKey else { continue }

            var merged = candidateTrustedDevices[primaryIndex]
            for index in matchingIndices where index != primaryIndex {
                merged = mergedTrustedDeviceRecord(
                    merged,
                    with: candidateTrustedDevices[index]
                )
            }
            merged = mergedTrustedDeviceRecord(merged, with: remote)
            merged.currentPathLifecycleState = remote.currentPathLifecycleState ?? .active
            merged.currentPathLifecycleGeneration = lifecycleGeneration(of: remote)
            merged = sanitizedProtocolIdentityKeyBindings(in: merged)
            if merged.currentPathLifecycleState == .revoked,
               let tombstone = Self.sanitizedRevokedTombstone(merged) {
                merged = tombstone
            }

            if merged != candidateTrustedDevices[primaryIndex] || matchingIndices.count > 1 {
                candidateTrustedDevices[primaryIndex] = merged
                changed = true
            }
            for index in matchingIndices.sorted(by: >) where index != primaryIndex {
                candidateTrustedDevices.remove(at: index)
            }
        }

        let sanitizedCandidates = candidateTrustedDevices.compactMap(migratedTrustedDeviceRecord)
        if sanitizedCandidates != candidateTrustedDevices {
            candidateTrustedDevices = sanitizedCandidates
            changed = true
        }

        return changed ? candidateTrustedDevices : nil
    }

    @discardableResult
    public func untrust(deviceId: String) throws -> [String] {
        var removalCandidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        let trimmedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDeviceId.isEmpty {
            removalCandidates.insert(trimmedDeviceId)
        }

        let directlyMatchedRecords = trustedDevices.filter { record in
            record.id == deviceId || matches(record, candidates: removalCandidates)
        }
        let selectedStableDeviceIds: Set<String>
        if let requestedStableDeviceId = normalizedTrustedDeviceIdentifier(trimmedDeviceId) {
            selectedStableDeviceIds = [requestedStableDeviceId]
        } else {
            let activeStableMatches = Set(
                directlyMatchedRecords
                    .filter(isActive)
                    .flatMap { stableDeviceIdentifiers(for: $0) }
            )
            guard activeStableMatches.count <= 1 else {
                throw AuthorityUpdateError.ambiguousStableDeviceIdentifier
            }
            guard let uniqueStableDeviceId = activeStableMatches.first else {
                return Array(removalCandidates).sorted()
            }
            selectedStableDeviceIds = [uniqueStableDeviceId]
        }

        let matchedRecords = trustedDevices.filter { record in
            !stableDeviceIdentifiers(for: record).isDisjoint(
                with: selectedStableDeviceIds
            )
        }
        for record in matchedRecords {
            removalCandidates.formUnion(trustedAliasCandidates(for: record))
            removalCandidates.insert(record.id)
            if let currentDeviceId = record.currentDeviceId {
                removalCandidates.insert(currentDeviceId)
            }
            for knownDeviceId in record.knownDeviceIds ?? [] {
                removalCandidates.insert(knownDeviceId)
            }
        }

        var candidateTrustedDevices = trustedDevices
        var changed = false
        for index in candidateTrustedDevices.indices {
            let record = candidateTrustedDevices[index]
            guard !stableDeviceIdentifiers(for: record).isDisjoint(
                with: selectedStableDeviceIds
            ) else {
                continue
            }
            let needsTombstoneSanitization = record.currentPathLifecycleState == .revoked
                && Self.sanitizedRevokedTombstone(record) != record
            if candidateTrustedDevices[index].currentPathLifecycleState != .revoked
                || candidateTrustedDevices[index].ipAddress != nil
                || candidateTrustedDevices[index].connectableContext != nil
                || needsTombstoneSanitization {
                transitionLifecycle(of: &candidateTrustedDevices[index], to: .revoked)
                candidateTrustedDevices[index].ipAddress = nil
                candidateTrustedDevices[index].connectableContext = nil
                changed = true
            }
        }

        if matchedRecords.isEmpty,
           let stableId = selectedStableDeviceIds.first {
            candidateTrustedDevices.append(
                TrustedDevice(
                    id: stableId,
                    name: "已撤销设备",
                    platform: .unknown,
                    ipAddress: nil,
                    currentDeviceId: stableId,
                    knownDeviceIds: [stableId],
                    currentPathLifecycleState: .revoked,
                    currentPathLifecycleGeneration: 1
                )
            )
            changed = true
        }

        if changed {
            candidateTrustedDevices = candidateTrustedDevices.compactMap(
                migratedTrustedDeviceRecord
            )
            try persist(candidateTrustedDevices, operation: "撤销受信任设备")
            trustedDevices = candidateTrustedDevices
        }
        return Array(removalCandidates).sorted()
    }

    public func clearAll() throws {
        var candidateTrustedDevices = trustedDevices
        var changed = false
        for index in candidateTrustedDevices.indices {
            let record = candidateTrustedDevices[index]
            let needsTombstoneSanitization = record.currentPathLifecycleState == .revoked
                && Self.sanitizedRevokedTombstone(record) != record
            if candidateTrustedDevices[index].currentPathLifecycleState != .revoked
                || candidateTrustedDevices[index].ipAddress != nil
                || candidateTrustedDevices[index].connectableContext != nil
                || needsTombstoneSanitization {
                transitionLifecycle(of: &candidateTrustedDevices[index], to: .revoked)
                candidateTrustedDevices[index].ipAddress = nil
                candidateTrustedDevices[index].connectableContext = nil
                changed = true
            }
        }
        guard changed else { return }
        candidateTrustedDevices = candidateTrustedDevices.compactMap(
            migratedTrustedDeviceRecord
        )
        try persist(candidateTrustedDevices, operation: "撤销全部受信任设备")
        trustedDevices = candidateTrustedDevices
    }

    private func load() {
        do {
            trustedDevices = (try loadPersistedDevices() ?? [])
                .compactMap(migratedTrustedDeviceRecord)
            lastPersistedTrustedDevices = trustedDevices
        } catch {
            trustedDevices = []
            lastPersistedTrustedDevices = []
            markPersistenceUnavailable(error, operation: "读取受信任设备")
        }
    }

    private func save() {
        do {
            try persist(trustedDevices, operation: "更新受信任设备")
        } catch {
            // `persist` records a durable, user-visible fail-closed state. The
            // legacy nonthrowing mutators remain source-compatible, but their
            // in-memory values are never accepted as authority after failure.
        }
    }

    private func persist(
        _ candidate: [TrustedDevice],
        operation: String,
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws {
        try requireAuthorityPersistenceAvailable(outerPermit: outerPermit)
        do {
            try savePersistedDevices(candidate)
            let changedStableDeviceIds = changedStableDeviceIdentifiers(
                from: lastPersistedTrustedDevices,
                to: candidate
            )
            lastPersistedTrustedDevices = candidate
            for stableDeviceId in changedStableDeviceIds {
                _ = advanceTrustMutationRevision(for: stableDeviceId)
            }
        } catch {
            markPersistenceUnavailable(error, operation: operation)
            throw PersistenceError.writeFailed(operation: operation, reason: error.localizedDescription)
        }
    }

    private func requireAuthorityPersistenceAvailable(
        outerPermit: PairingIdentityAuthorityMutationPermit?
    ) throws {
        guard persistenceErrorMessage == nil else {
            throw PersistenceError.unavailable(persistenceErrorMessage ?? "未知错误")
        }
        if pairingAcceptanceJournalExists() {
            guard let outerPermit,
                  PairingAcceptanceJournalStore.permitOwnsActiveJournal(outerPermit) else {
                throw PersistenceError.authorityTransactionQuarantined
            }
        }
    }

    private func markPersistenceUnavailable(_ error: Error, operation: String) {
        let message = "\(operation)失败：\(error.localizedDescription)"
        persistenceErrorMessage = message
        SkyBridgeLogger.shared.error("⛔️ 受信任设备持久化不可用，自动信任已禁用：\(message)")
    }

    private nonisolated static let authenticatedHandshakePinSource = "authenticated-handshake"
    private nonisolated static let legacyMigrationPinSource = "legacy-migration"
    private static let pibOperatorApprovalPinSource = "pib-1-operator-approval"

    private nonisolated func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private nonisolated func normalizedAlgorithm(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private nonisolated func normalizedProtocolIdentityPins(
        _ pins: [TrustedDevice.ProtocolIdentityPin]?,
        legacyAlgorithm: String?,
        legacyFingerprint: String?,
        approvedAt: Date
    ) -> [TrustedDevice.ProtocolIdentityPin] {
        var pinsByAlgorithm: [String: TrustedDevice.ProtocolIdentityPin] = [:]

        func upsert(_ pin: TrustedDevice.ProtocolIdentityPin) {
            guard let algorithm = normalizedAlgorithm(pin.algorithm),
                  let fingerprint = normalizedFingerprint(pin.fingerprint) else {
                return
            }
            let normalizedPin = TrustedDevice.ProtocolIdentityPin(
                algorithm: algorithm,
                fingerprint: fingerprint,
                approvedAt: pin.approvedAt,
                source: pin.source.isEmpty ? Self.authenticatedHandshakePinSource : pin.source
            )
            if let existing = pinsByAlgorithm[algorithm],
               existing.approvedAt > normalizedPin.approvedAt {
                return
            }
            pinsByAlgorithm[algorithm] = normalizedPin
        }

        for pin in pins ?? [] {
            upsert(pin)
        }

        if let algorithm = normalizedAlgorithm(legacyAlgorithm),
           pinsByAlgorithm[algorithm] == nil,
           let fingerprint = normalizedFingerprint(legacyFingerprint) {
            upsert(
                TrustedDevice.ProtocolIdentityPin(
                    algorithm: algorithm,
                    fingerprint: fingerprint,
                    approvedAt: approvedAt,
                    source: Self.legacyMigrationPinSource
                )
            )
        }

        return pinsByAlgorithm.values.sorted {
            if $0.algorithm != $1.algorithm {
                return $0.algorithm < $1.algorithm
            }
            return $0.fingerprint < $1.fingerprint
        }
    }

    private nonisolated func protocolIdentityPins(
        for device: TrustedDevice
    ) -> [TrustedDevice.ProtocolIdentityPin] {
        normalizedProtocolIdentityPins(
            device.protocolIdentityPins,
            legacyAlgorithm: device.protocolSigningAlgorithm,
            legacyFingerprint: device.protocolPublicKeyFingerprint,
            approvedAt: device.addedAt
        )
    }

    private nonisolated func authorityFingerprints(for device: TrustedDevice) -> Set<String> {
        Set(protocolIdentityPins(for: device).map(\.fingerprint))
    }

    private nonisolated func validatedProtocolIdentityKeyBinding(
        algorithm rawAlgorithm: String,
        fingerprint rawFingerprint: String,
        publicKeyBytes: Data,
        approvedAt: Date = Date(),
        source: String
    ) throws -> TrustedDevice.ProtocolIdentityKeyBinding {
        guard let algorithm = ProtocolSigningAlgorithm(
            rawValue: rawAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw AuthorityUpdateError.invalidProtocolSigningAlgorithm
        }
        guard let fingerprint = normalizedFingerprint(rawFingerprint) else {
            throw AuthorityUpdateError.invalidProtocolPublicKeyFingerprint
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(
                bytes: publicKeyBytes,
                algorithm: algorithm
            )
        } catch {
            throw AuthorityUpdateError.invalidProtocolPublicKey
        }
        let computedFingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: algorithm,
            publicKeyBytes: publicKeyBytes
        )
        guard computedFingerprint == fingerprint else {
            throw AuthorityUpdateError.protocolPublicKeyFingerprintMismatch
        }
        return TrustedDevice.ProtocolIdentityKeyBinding(
            algorithm: algorithm.rawValue,
            fingerprint: fingerprint,
            publicKeyBytes: publicKeyBytes,
            approvedAt: approvedAt,
            source: source.isEmpty ? Self.authenticatedHandshakePinSource : source
        )
    }

    private nonisolated func normalizedProtocolIdentityKeyBinding(
        _ binding: TrustedDevice.ProtocolIdentityKeyBinding
    ) -> TrustedDevice.ProtocolIdentityKeyBinding? {
        guard binding.schemaVersion == TrustedDevice.ProtocolIdentityKeyBinding.currentSchemaVersion,
              let publicKeyBytes = binding.publicKeyBytes,
              let validated = try? validatedProtocolIdentityKeyBinding(
                algorithm: binding.algorithm,
                fingerprint: binding.fingerprint,
                publicKeyBytes: publicKeyBytes,
                approvedAt: binding.approvedAt,
                source: binding.source
              ) else {
            return nil
        }
        return validated
    }

    private nonisolated func normalizedProtocolIdentityKeyBindings(
        _ bindings: [TrustedDevice.ProtocolIdentityKeyBinding]?
    ) -> [TrustedDevice.ProtocolIdentityKeyBinding] {
        var unique: [String: TrustedDevice.ProtocolIdentityKeyBinding] = [:]
        for binding in bindings ?? [] {
            guard let normalized = normalizedProtocolIdentityKeyBinding(binding) else { continue }
            let identity = [
                normalized.algorithm,
                normalized.fingerprint,
                normalized.publicKeyBase64
            ].joined(separator: "\u{0}")
            if let existing = unique[identity], existing.approvedAt > normalized.approvedAt {
                continue
            }
            unique[identity] = normalized
        }
        return unique.values.sorted {
            if $0.algorithm != $1.algorithm { return $0.algorithm < $1.algorithm }
            if $0.fingerprint != $1.fingerprint { return $0.fingerprint < $1.fingerprint }
            return $0.publicKeyBase64 < $1.publicKeyBase64
        }
    }

    private nonisolated func protocolIdentityKeyBindings(
        for device: TrustedDevice
    ) -> [TrustedDevice.ProtocolIdentityKeyBinding] {
        normalizedProtocolIdentityKeyBindings(device.protocolIdentityKeyBindings)
    }

    private nonisolated func hasConflictingProtocolIdentityKeyBindings(
        _ bindings: [TrustedDevice.ProtocolIdentityKeyBinding]
    ) -> Bool {
        var identityByAlgorithm: [String: (fingerprint: String, publicKeyBase64: String)] = [:]
        for binding in bindings {
            let identity = (binding.fingerprint, binding.publicKeyBase64)
            if let existing = identityByAlgorithm[binding.algorithm],
               (existing.fingerprint != identity.0
                    || existing.publicKeyBase64 != identity.1) {
                return true
            }
            identityByAlgorithm[binding.algorithm] = identity
        }
        return false
    }

    public func currentPathProtocolIdentityKeyBinding(
        for deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) -> TrustedDevice.ProtocolIdentityKeyBinding? {
        guard isAuthorityPersistenceAvailable else { return nil }
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return nil }

        let matchingBindings = trustedDevices
            .filter { isActive($0) && matches($0, candidates: candidates) }
            .flatMap(protocolIdentityKeyBindings(for:))
            .filter { $0.algorithm == algorithm.rawValue }
        guard matchingBindings.count == 1 else { return nil }
        return matchingBindings[0]
    }

    /// Returns true only when the exact raw-key authority was already active
    /// before the current handshake observation is persisted. A fresh
    /// self-authenticated handshake must never manufacture its own automatic
    /// pairing authorization.
    func uniqueExactActiveProtocolIdentityAuthorityDeviceId(
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        publicKey: Data
    ) -> String? {
        guard isAuthorityPersistenceAvailable,
            let normalizedFingerprint = normalizedFingerprint(fingerprint)
        else {
            return nil
        }
        let matchingRecords = trustedDevices.filter { record in
            isActive(record) && protocolIdentityKeyBindings(for: record).contains { binding in
                binding.algorithm == algorithm.rawValue
                    && binding.fingerprint == normalizedFingerprint
                    && binding.publicKeyBytes == publicKey
            }
        }
        guard matchingRecords.count == 1 else { return nil }
        return normalizedTrustedDeviceIdentifier(
            resolvedCurrentDeviceId(for: matchingRecords[0])
        )
    }

    /// Returns only an active PIB-1 operator approval whose current stable
    /// device identifier exactly equals the declared pairing identity. Alias
    /// matches and handshake-derived pins are deliberately excluded: this is
    /// the sole non-SOA admission source for pairing-identity persistence.
    func exactActivePIBOperatorApproval(
        forDeclaredDeviceId deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) -> PIBOperatorApprovalReceipt? {
        guard isAuthorityPersistenceAvailable else { return nil }
        let declaredDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !declaredDeviceId.isEmpty else { return nil }

        let matchingBindings = trustedDevices.compactMap { device -> TrustedDevice.ProtocolIdentityKeyBinding? in
            guard isActive(device),
                resolvedCurrentDeviceId(for: device) == declaredDeviceId
            else {
                return nil
            }
            let exact = protocolIdentityKeyBindings(for: device).filter {
                $0.algorithm == algorithm.rawValue
                    && $0.source == Self.pibOperatorApprovalPinSource
            }
            guard exact.count == 1 else { return nil }
            return exact[0]
        }
        guard matchingBindings.count == 1,
            let publicKey = matchingBindings[0].publicKeyBytes
        else {
            return nil
        }
        let binding = matchingBindings[0]
        return PIBOperatorApprovalReceipt(
            declaredDeviceId: declaredDeviceId,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyFingerprint: binding.fingerprint,
            protocolPublicKey: publicKey,
            pinSource: binding.source
        )
    }

    private func protocolIdentityPinsByReplacingAlgorithm(
        existing pins: [TrustedDevice.ProtocolIdentityPin]?,
        legacyAlgorithm: String?,
        legacyFingerprint: String?,
        addingAlgorithm: String,
        addingFingerprint: String,
        approvedAt: Date = Date(),
        source: String
    ) -> [TrustedDevice.ProtocolIdentityPin] {
        guard let algorithm = normalizedAlgorithm(addingAlgorithm),
              let fingerprint = normalizedFingerprint(addingFingerprint) else {
            return normalizedProtocolIdentityPins(
                pins,
                legacyAlgorithm: legacyAlgorithm,
                legacyFingerprint: legacyFingerprint,
                approvedAt: approvedAt
            )
        }

        var normalized = normalizedProtocolIdentityPins(
            pins,
            legacyAlgorithm: legacyAlgorithm,
            legacyFingerprint: legacyFingerprint,
            approvedAt: approvedAt
        )
        normalized.removeAll { $0.algorithm == algorithm }
        normalized.append(
            TrustedDevice.ProtocolIdentityPin(
                algorithm: algorithm,
                fingerprint: fingerprint,
                approvedAt: approvedAt,
                source: source
            )
        )
        return normalizedProtocolIdentityPins(
            normalized,
            legacyAlgorithm: nil,
            legacyFingerprint: nil,
            approvedAt: approvedAt
        )
    }

    private enum AuthorityActivation: Equatable {
        case preserveExistingAuthorization
        case operatorApproved
    }

    private enum AuthorityRecordMatchPolicy: Equatable {
        case authenticatedAuthorityOnly
        case operatorApprovedStableIdentifierOrAuthority
    }

    private func upsertAuthoritativeTrustedDevice(
        preferredRecordId: String,
        candidateAliases: Set<String>,
        name: String,
        platform: DevicePlatform,
        ipAddress: String?,
        protocolSigningAlgorithm: String,
        protocolPublicKeyFingerprint: String,
        protocolPublicKeyBytes: Data,
        preferredCurrentDeviceId: String?,
        connectableContext: TrustedDevice.ConnectableContext? = nil,
        pinSource: String,
        activation: AuthorityActivation,
        recordMatchPolicy: AuthorityRecordMatchPolicy
    ) throws -> Bool {
        let authenticatedKeyBinding = try validatedProtocolIdentityKeyBinding(
            algorithm: protocolSigningAlgorithm,
            fingerprint: protocolPublicKeyFingerprint,
            publicKeyBytes: protocolPublicKeyBytes,
            source: pinSource
        )
        var candidateTrustedDevices = trustedDevices
        let matchingIndices = candidateTrustedDevices.indices.filter { index in
            let record = candidateTrustedDevices[index]
            let matchesExactAuthority = protocolIdentityKeyBindings(for: record).contains {
                $0.algorithm == authenticatedKeyBinding.algorithm
                    && $0.fingerprint == authenticatedKeyBinding.fingerprint
                    && $0.publicKeyBase64 == authenticatedKeyBinding.publicKeyBase64
            }
            switch recordMatchPolicy {
            case .authenticatedAuthorityOnly:
                // A route, display name, or peer-claimed stable identifier is
                // not authority. Automatic handshake persistence may merge an
                // existing record only when the authenticated raw key is
                // already bound to that record.
                return isActive(record) && matchesExactAuthority
            case .operatorApprovedStableIdentifierOrAuthority:
                return matchesExactAuthority
                    || (preferredCurrentDeviceId.map {
                        stableDeviceIdentifiers(for: record).contains($0)
                    } ?? false)
            }
        }

        let primaryIndex = preferredPrimaryAuthorityIndex(
            matchingIndices: matchingIndices,
            preferredCurrentDeviceId: preferredCurrentDeviceId,
            preferredFingerprint: protocolPublicKeyFingerprint,
            devices: candidateTrustedDevices
        )

        let canonicalCurrentDeviceId: String?
        switch recordMatchPolicy {
        case .authenticatedAuthorityOnly:
            canonicalCurrentDeviceId =
                primaryIndex.flatMap {
                    normalizedTrustedDeviceIdentifier(
                        resolvedCurrentDeviceId(for: candidateTrustedDevices[$0])
                    )
                }
        case .operatorApprovedStableIdentifierOrAuthority:
            canonicalCurrentDeviceId =
                preferredCurrentDeviceId
                ?? primaryIndex.flatMap {
                    normalizedTrustedDeviceIdentifier(
                        resolvedCurrentDeviceId(for: candidateTrustedDevices[$0])
                    )
                }
                ?? normalizedTrustedDeviceIdentifier(preferredRecordId)
        }

        guard let canonicalCurrentDeviceId else {
            throw AuthorityUpdateError.missingStableDeviceIdentifier
        }
        let knownDeviceIds: [String]
        switch recordMatchPolicy {
        case .authenticatedAuthorityOnly:
            // Discovery aliases are routing observations, not authenticated
            // device identity. Persisting them as known stable identifiers
            // would let an attacker poison later canonical lookups.
            knownDeviceIds = [canonicalCurrentDeviceId]
        case .operatorApprovedStableIdentifierOrAuthority:
            knownDeviceIds = [canonicalCurrentDeviceId]
        }

        let matchingRecords = matchingIndices.map { candidateTrustedDevices[$0] }
        let sameAlgorithmPins = matchingRecords
            .flatMap(protocolIdentityPins(for:))
            .filter { $0.algorithm == authenticatedKeyBinding.algorithm }
        let sameAlgorithmBindings = matchingRecords
            .flatMap(protocolIdentityKeyBindings(for:))
            .filter { $0.algorithm == authenticatedKeyBinding.algorithm }
        let hasSameAlgorithmConflict = sameAlgorithmPins.contains {
            $0.fingerprint != authenticatedKeyBinding.fingerprint
        } || sameAlgorithmBindings.contains {
            $0.fingerprint != authenticatedKeyBinding.fingerprint
                || $0.publicKeyBase64 != authenticatedKeyBinding.publicKeyBase64
        }

        if hasSameAlgorithmConflict {
            var lifecycleChanged = false
            for index in matchingIndices {
                switch candidateTrustedDevices[index].currentPathLifecycleState ?? .active {
                case .active:
                    transitionLifecycle(
                        of: &candidateTrustedDevices[index],
                        to: .reverificationRequired
                    )
                    lifecycleChanged = true
                case .reverificationRequired, .quarantined, .revoked:
                    // A conflict can only tighten authority. Never use it to
                    // downgrade quarantine or resurrect a revocation.
                    continue
                }
            }
            if lifecycleChanged {
                try persist(
                    candidateTrustedDevices,
                    operation: "隔离冲突的协议身份 authority"
                )
                trustedDevices = candidateTrustedDevices
            }
            throw AuthorityUpdateError.conflictingProtocolIdentityKey(
                algorithm: authenticatedKeyBinding.algorithm
            )
        }

        if let primaryIndex {
            var mergedRecord = candidateTrustedDevices[primaryIndex]
            for index in matchingIndices where index != primaryIndex {
                mergedRecord = mergedTrustedDeviceRecord(mergedRecord, with: candidateTrustedDevices[index])
            }
            if !name.isEmpty {
                mergedRecord.name = name
            }
            if platform != .unknown {
                mergedRecord.platform = platform
            }
            if let ipAddress, !ipAddress.isEmpty {
                mergedRecord.ipAddress = ipAddress
            }
            mergedRecord.connectableContext = mergedConnectableContext(
                mergedRecord.connectableContext,
                with: connectableContext
            )
            mergedRecord.protocolIdentityPins = protocolIdentityPinsByReplacingAlgorithm(
                existing: mergedRecord.protocolIdentityPins,
                legacyAlgorithm: mergedRecord.protocolSigningAlgorithm,
                legacyFingerprint: mergedRecord.protocolPublicKeyFingerprint,
                addingAlgorithm: protocolSigningAlgorithm,
                addingFingerprint: protocolPublicKeyFingerprint,
                source: pinSource
            )
            var keyBindings = protocolIdentityKeyBindings(for: mergedRecord)
            keyBindings.removeAll { $0.algorithm == authenticatedKeyBinding.algorithm }
            keyBindings.append(authenticatedKeyBinding)
            mergedRecord.protocolIdentityKeyBindings = normalizedProtocolIdentityKeyBindings(keyBindings)
            mergedRecord.protocolSigningAlgorithm = protocolSigningAlgorithm
            mergedRecord.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            mergedRecord.currentDeviceId = canonicalCurrentDeviceId
            mergedRecord.knownDeviceIds = mergedKnownDeviceIds(
                existing: mergedRecord.knownDeviceIds,
                adding: knownDeviceIds
            )
            if activation == .operatorApproved {
                transitionLifecycle(of: &mergedRecord, to: .active)
            }
            candidateTrustedDevices[primaryIndex] = mergedRecord

            for index in matchingIndices.sorted(by: >) where index != primaryIndex {
                candidateTrustedDevices.remove(at: index)
            }
        } else {
            candidateTrustedDevices.append(
                TrustedDevice(
                    id: canonicalCurrentDeviceId,
                    name: name,
                    platform: platform,
                    ipAddress: ipAddress,
                    protocolSigningAlgorithm: protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
                    protocolIdentityPins: [
                        TrustedDevice.ProtocolIdentityPin(
                            algorithm: protocolSigningAlgorithm,
                            fingerprint: protocolPublicKeyFingerprint,
                            source: pinSource
                        )
                    ],
                    protocolIdentityKeyBindings: [authenticatedKeyBinding],
                    currentDeviceId: canonicalCurrentDeviceId,
                    knownDeviceIds: knownDeviceIds,
                    currentPathLifecycleState: activation == .operatorApproved
                        ? .active
                        : .reverificationRequired,
                    connectableContext: connectableContext
                )
            )
        }

        guard candidateTrustedDevices != trustedDevices else {
            return true
        }
        try persist(candidateTrustedDevices, operation: "更新认证 authority")
        trustedDevices = candidateTrustedDevices
        return true
    }

    private func preferredPrimaryAuthorityIndex(
        matchingIndices: [Int],
        preferredCurrentDeviceId: String?,
        preferredFingerprint: String,
        devices: [TrustedDevice]
    ) -> Int? {
        matchingIndices.sorted { lhs, rhs in
            let lhsRecord = devices[lhs]
            let rhsRecord = devices[rhs]

            let lhsIdMatchesPreferred = normalizedTrustedDeviceIdentifier(lhsRecord.id) == preferredCurrentDeviceId
            let rhsIdMatchesPreferred = normalizedTrustedDeviceIdentifier(rhsRecord.id) == preferredCurrentDeviceId
            if lhsIdMatchesPreferred != rhsIdMatchesPreferred {
                return lhsIdMatchesPreferred && !rhsIdMatchesPreferred
            }

            let lhsCurrentMatchesPreferred =
                normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: lhsRecord)) == preferredCurrentDeviceId
            let rhsCurrentMatchesPreferred =
                normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: rhsRecord)) == preferredCurrentDeviceId
            if lhsCurrentMatchesPreferred != rhsCurrentMatchesPreferred {
                return lhsCurrentMatchesPreferred && !rhsCurrentMatchesPreferred
            }

            let lhsFingerprintMatches = authorityFingerprints(for: lhsRecord).contains(preferredFingerprint)
            let rhsFingerprintMatches = authorityFingerprints(for: rhsRecord).contains(preferredFingerprint)
            if lhsFingerprintMatches != rhsFingerprintMatches {
                return lhsFingerprintMatches && !rhsFingerprintMatches
            }

            let lhsHasAuthority = !(lhsRecord.protocolSigningAlgorithm?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            let rhsHasAuthority = !(rhsRecord.protocolSigningAlgorithm?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            if lhsHasAuthority != rhsHasAuthority {
                return lhsHasAuthority && !rhsHasAuthority
            }

            if lhsRecord.addedAt != rhsRecord.addedAt {
                return lhsRecord.addedAt < rhsRecord.addedAt
            }
            return lhsRecord.id < rhsRecord.id
        }.first
    }

    private nonisolated func mergedTrustedDeviceRecord(
        _ primary: TrustedDevice,
        with duplicate: TrustedDevice
    ) -> TrustedDevice {
        var merged = primary

        if merged.name.isEmpty, !duplicate.name.isEmpty {
            merged.name = duplicate.name
        }
        if merged.platform == .unknown, duplicate.platform != .unknown {
            merged.platform = duplicate.platform
        }
        if (merged.ipAddress?.isEmpty ?? true), let duplicateIPAddress = duplicate.ipAddress, !duplicateIPAddress.isEmpty {
            merged.ipAddress = duplicateIPAddress
        }
        if merged.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let duplicateAlgorithm = duplicate.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines),
           !duplicateAlgorithm.isEmpty {
            merged.protocolSigningAlgorithm = duplicateAlgorithm
        }
        if merged.protocolPublicKeyFingerprint == nil,
           let duplicateFingerprint = normalizedFingerprint(duplicate.protocolPublicKeyFingerprint) {
            merged.protocolPublicKeyFingerprint = duplicateFingerprint
        }
        let mergedPins = normalizedProtocolIdentityPins(
            protocolIdentityPins(for: merged) + protocolIdentityPins(for: duplicate),
            legacyAlgorithm: nil,
            legacyFingerprint: nil,
            approvedAt: Date()
        )
        merged.protocolIdentityPins = mergedPins.isEmpty ? nil : mergedPins
        let mergedKeyBindings = normalizedProtocolIdentityKeyBindings(
            protocolIdentityKeyBindings(for: merged) + protocolIdentityKeyBindings(for: duplicate)
        )
        merged.protocolIdentityKeyBindings = mergedKeyBindings.isEmpty ? nil : mergedKeyBindings
        if merged.currentDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let duplicateCurrentDeviceId = normalizedTrustedDeviceIdentifier(resolvedCurrentDeviceId(for: duplicate)) {
            merged.currentDeviceId = duplicateCurrentDeviceId
        }
        if duplicate.addedAt < merged.addedAt {
            merged.addedAt = duplicate.addedAt
        }
        merged.connectableContext = mergedConnectableContext(
            merged.connectableContext,
            with: duplicate.connectableContext
        )
        if lifecycleOrderingKey(for: duplicate) > lifecycleOrderingKey(for: merged) {
            merged.currentPathLifecycleState = duplicate.currentPathLifecycleState ?? .active
            merged.currentPathLifecycleGeneration = lifecycleGeneration(of: duplicate)
        }

        var combinedKnownDeviceIds = mergedKnownDeviceIds(existing: merged.knownDeviceIds, adding: duplicate.id)
        if let duplicateCurrentDeviceId = duplicate.currentDeviceId {
            combinedKnownDeviceIds = mergedKnownDeviceIds(existing: combinedKnownDeviceIds, adding: duplicateCurrentDeviceId)
        }
        if let duplicateKnownDeviceIds = duplicate.knownDeviceIds {
            combinedKnownDeviceIds = mergedKnownDeviceIds(existing: combinedKnownDeviceIds, adding: duplicateKnownDeviceIds)
        }
        merged.knownDeviceIds = combinedKnownDeviceIds

        merged = sanitizedProtocolIdentityKeyBindings(in: merged)
        if merged.currentPathLifecycleState == .revoked {
            return Self.sanitizedRevokedTombstone(merged) ?? merged
        }
        return merged
    }

    private nonisolated func normalizedTrustedDeviceIdentifier(_ raw: String?) -> String? {
        canonicalPersistentTrustedDeviceIdentifier(raw)
    }

    private nonisolated func mergedKnownDeviceIds(existing: [String]?, adding newValue: String) -> [String] {
        mergedKnownDeviceIds(existing: existing, adding: [newValue])
    }

    private nonisolated func mergedKnownDeviceIds(existing: [String]?, adding newValues: [String]) -> [String] {
        Array(Set((existing ?? []) + newValues.filter { !$0.isEmpty })).sorted()
    }

    private nonisolated func lifecycleGeneration(of device: TrustedDevice) -> Int64 {
        max(device.currentPathLifecycleGeneration ?? 0, 0)
    }

    private nonisolated func lifecyclePrecedence(of device: TrustedDevice) -> Int {
        switch device.currentPathLifecycleState ?? .active {
        case .active:
            return 0
        case .reverificationRequired:
            return 1
        case .quarantined:
            return 2
        case .revoked:
            return 3
        }
    }

    private nonisolated func lifecycleOrderingKey(for device: TrustedDevice) -> (Int64, Int) {
        (lifecycleGeneration(of: device), lifecyclePrecedence(of: device))
    }

    private func transitionLifecycle(
        of device: inout TrustedDevice,
        to state: CurrentPathLifecycleState
    ) {
        let previousState = device.currentPathLifecycleState ?? .active
        if previousState != state {
            let currentGeneration = lifecycleGeneration(of: device)
            device.currentPathLifecycleGeneration = currentGeneration == Int64.max
                ? Int64.max
                : currentGeneration + 1
        }
        device.currentPathLifecycleState = state
    }

    private func isActive(_ device: TrustedDevice) -> Bool {
        guard isAuthorityPersistenceAvailable,
              (device.currentPathLifecycleState ?? .active) == .active else {
            return false
        }

        let deviceOrderingKey = lifecycleOrderingKey(for: device)
        let stableAliases = stableTrustedAliasCandidates(for: device)
        let fingerprints = authorityFingerprints(for: device)

        // Legacy or partially-synced stores can contain duplicate authority
        // rows. Never authorize an older positive row when an equivalent row
        // carries a later lifecycle transition (including a revocation).
        return !trustedDevices.contains { candidate in
            let representsSameAuthority = candidate.id == device.id
                || (!stableAliases.isEmpty
                    && !stableTrustedAliasCandidates(for: candidate).isDisjoint(with: stableAliases))
                || (!fingerprints.isEmpty
                    && !authorityFingerprints(for: candidate).isDisjoint(with: fingerprints))
            guard representsSameAuthority else { return false }
            return lifecycleOrderingKey(for: candidate) > deviceOrderingKey
        }
    }

    private func matches(_ device: TrustedDevice, candidates: Set<String>) -> Bool {
        !trustedAliasCandidates(for: device).isDisjoint(with: candidates)
    }

    private func currentPathDeviceMatches(_ device: TrustedDevice, deviceId: String) -> Bool {
        let candidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !candidates.isEmpty else { return false }
        return !trustedAliasCandidates(for: device).isDisjoint(with: candidates)
    }

    private nonisolated func resolvedCurrentDeviceId(for device: TrustedDevice) -> String {
        bestPersistentTrustedDeviceIdentifier(for: device) ?? device.id
    }

    private nonisolated func trustedAliasCandidates(for device: TrustedDevice) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: device.currentDeviceId))

        if let knownDeviceIds = device.knownDeviceIds {
            for knownDeviceId in knownDeviceIds {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: knownDeviceId))
            }
        }

        if let ipAddress = device.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }

        if let context = device.connectableContext {
            if let ipAddress = context.lastResolvedIPAddress {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
            }
            if let bonjourAlias = bonjourAlias(from: context) {
                aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: bonjourAlias))
            }
        }

        return aliases
    }

    /// Endpoint aliases (IP/Bonjour socket identities) are intentionally not
    /// durable revocation keys because they may later be reassigned to another
    /// physical device.
    private nonisolated func stableTrustedAliasCandidates(for device: TrustedDevice) -> Set<String> {
        Set(trustedAliasCandidates(for: device).filter { alias in
            !PeerIdentityAliasResolver.isEndpointAlias(alias)
        })
    }

    /// Stable authority identifiers only. Routing aliases such as IP and
    /// Bonjour endpoints are intentionally excluded because they can be
    /// reassigned to a different physical device.
    private nonisolated func stableDeviceIdentifiers(
        for device: TrustedDevice
    ) -> Set<String> {
        let rawIdentifiers: [String?] = [device.id, device.currentDeviceId]
            + (device.knownDeviceIds ?? []).map(Optional.some)
        return Set(rawIdentifiers.compactMap(normalizedTrustedDeviceIdentifier))
    }

    private nonisolated func changedStableDeviceIdentifiers(
        from previous: [TrustedDevice],
        to current: [TrustedDevice]
    ) -> Set<String> {
        let identifiers = Set(
            (previous + current).flatMap { Array(stableDeviceIdentifiers(for: $0)) }
        )
        return Set(identifiers.filter { stableDeviceId in
            let previousRecords = previous.filter {
                stableDeviceIdentifiers(for: $0).contains(stableDeviceId)
            }
            let currentRecords = current.filter {
                stableDeviceIdentifiers(for: $0).contains(stableDeviceId)
            }
            return previousRecords != currentRecords
        })
    }

    private func quarantineStableAuthorityRows(
        stableDeviceId: String,
        operation: String
    ) throws {
        var candidate = trustedDevices
        for index in candidate.indices where stableDeviceIdentifiers(
            for: candidate[index]
        ).contains(stableDeviceId) {
            switch candidate[index].currentPathLifecycleState ?? .active {
            case .active, .reverificationRequired:
                transitionLifecycle(of: &candidate[index], to: .quarantined)
            case .quarantined, .revoked:
                break
            }
        }
        guard candidate != trustedDevices else { return }
        try persist(candidate, operation: operation)
        trustedDevices = candidate
    }

    @discardableResult
    private func advanceTrustMutationRevision(for stableDeviceId: String) -> UInt64 {
        let current = trustMutationRevisionByStableDeviceId[stableDeviceId] ?? 0
        let increment = current.addingReportingOverflow(1)
        precondition(!increment.overflow, "Trusted device mutation revision exhausted")
        trustMutationRevisionByStableDeviceId[stableDeviceId] = increment.partialValue
        return increment.partialValue
    }

    private func connectableContext(from device: DiscoveredDevice) -> TrustedDevice.ConnectableContext? {
        let bonjourRoute = BonjourRouteTuple(device)
        let services = Array(Set(device.services.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        let portMap = device.portMap.filter { !$0.key.isEmpty && $0.value > 0 }
        let ipAddress = device.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard bonjourRoute != nil
                || !services.isEmpty
                || !portMap.isEmpty
                || ipAddress?.isEmpty == false else {
            return nil
        }

        return TrustedDevice.ConnectableContext(
            bonjourRoute: bonjourRoute,
            services: services,
            portMap: portMap,
            lastResolvedIPAddress: ipAddress
        )
    }

    private func connectableContext(from trustedDevice: TrustedDevice) -> TrustedDevice.ConnectableContext? {
        mergedConnectableContext(
            trustedDevice.connectableContext,
            with: TrustedDevice.ConnectableContext(lastResolvedIPAddress: trustedDevice.ipAddress)
        )
    }

    private nonisolated func mergedConnectableContext(
        _ existing: TrustedDevice.ConnectableContext?,
        with update: TrustedDevice.ConnectableContext?
    ) -> TrustedDevice.ConnectableContext? {
        guard existing != nil || update != nil else { return nil }

        let selectedRoute = BonjourRouteTuple.preferred(
            existing: existing?.verifiedBonjourRoute,
            update: update?.verifiedBonjourRoute
        )
        let services = Array(
            Set(existing?.services ?? []).union(update?.services ?? [])
        ).sorted()
        let portMap = (existing?.portMap ?? [:]).merging(update?.portMap ?? [:]) {
            _, latest in latest
        }
        let lastResolvedIPAddress = existing?.lastResolvedIPAddress
            ?? update?.lastResolvedIPAddress
        guard selectedRoute != nil
                || !services.isEmpty
                || !portMap.isEmpty
                || lastResolvedIPAddress?.isEmpty == false else {
            return nil
        }

        return TrustedDevice.ConnectableContext(
            bonjourRoute: selectedRoute,
            services: services,
            portMap: portMap,
            lastResolvedIPAddress: lastResolvedIPAddress
        )
    }

    private nonisolated func bonjourAlias(from context: TrustedDevice.ConnectableContext) -> String? {
        guard let route = context.verifiedBonjourRoute else { return nil }
        return "bonjour:\(route.name)@\(route.domain)"
    }

    private nonisolated func canonicalPersistentTrustedDeviceIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PeerIdentityAliasResolver.persistentDeviceId(from: trimmed)
    }

    private nonisolated func canonicalStoredTrustedDeviceIdentifier(_ raw: String?) -> String? {
        guard let normalized = PeerIdentityAliasResolver.normalizedIdentifier(raw),
              !normalized.isEmpty else {
            return nil
        }

        if let persistent = canonicalPersistentTrustedDeviceIdentifier(normalized) {
            return persistent
        }

        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            guard !payload.isEmpty,
                  !payload.contains(where: \.isWhitespace),
                  payload.allSatisfy({ character in
                      character.isASCII
                          && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
                  }),
                  !PeerIdentityAliasResolver.isEndpointAlias(normalized) else {
                return nil
            }
            return normalized
        }
        return nil
    }

    private nonisolated func bestPersistentTrustedDeviceIdentifier(for device: TrustedDevice) -> String? {
        if let current = canonicalStoredTrustedDeviceIdentifier(device.currentDeviceId) {
            return current
        }
        if let recordID = canonicalStoredTrustedDeviceIdentifier(device.id) {
            return recordID
        }
        for knownDeviceId in device.knownDeviceIds ?? [] {
            if let known = canonicalStoredTrustedDeviceIdentifier(knownDeviceId) {
                return known
            }
        }
        return nil
    }

    private nonisolated func migratedTrustedDeviceRecord(_ device: TrustedDevice) -> TrustedDevice? {
        var migrated = device
        migrated.currentDeviceId = bestPersistentTrustedDeviceIdentifier(for: device)
        if let generation = migrated.currentPathLifecycleGeneration, generation < 0 {
            migrated.currentPathLifecycleGeneration = 0
        }
        let pins = protocolIdentityPins(for: migrated)
        migrated.protocolIdentityPins = pins.isEmpty ? nil : pins
        migrated = sanitizedProtocolIdentityKeyBindings(in: migrated)
        return Self.sanitizedRevokedTombstone(migrated)
    }

    private nonisolated func sanitizedProtocolIdentityKeyBindings(
        in device: TrustedDevice
    ) -> TrustedDevice {
        var sanitized = device
        let rawBindings = device.protocolIdentityKeyBindings ?? []
        let normalizedBindings = normalizedProtocolIdentityKeyBindings(rawBindings)
        sanitized.protocolIdentityKeyBindings = normalizedBindings.isEmpty ? nil : normalizedBindings

        let containsInvalidBinding = rawBindings.contains {
            normalizedProtocolIdentityKeyBinding($0) == nil
        }
        let containsConflict = hasConflictingProtocolIdentityKeyBindings(normalizedBindings)
        guard containsInvalidBinding || containsConflict else { return sanitized }

        switch sanitized.currentPathLifecycleState ?? .active {
        case .revoked, .quarantined:
            break
        case .active, .reverificationRequired:
            let generation = max(sanitized.currentPathLifecycleGeneration ?? 0, 0)
            sanitized.currentPathLifecycleGeneration = generation == Int64.max
                ? Int64.max
                : generation + 1
            sanitized.currentPathLifecycleState = .quarantined
        }
        return sanitized
    }
}
