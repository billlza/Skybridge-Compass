//
// TrustSyncService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Trust Sync Service
// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8
//
// 设备信任记录的 iCloud 同步服务：
// 1. 支持 tombstone 防止幽灵复活
// 2. 冲突解决：revoke 优先 + LWW
// 3. iCloud Keychain 同步（kSecAttrSynchronizable）
//

import Foundation
import Combine
import CryptoKit
import Security
import LocalAuthentication

// MARK: - Trust Record Type

/// 信任记录类型
public enum TrustRecordType: String, Codable, Sendable {
 /// 添加信任
    case add = "add"
    
 /// 撤销信任（tombstone）
    case revoke = "revoke"
}

public enum TrustLifecycleState: String, Codable, Sendable {
    case active
    case reverificationRequired
    case quarantined
    case revoked
}

public enum ProtocolIdentityPinSource: String, Codable, Sendable, Equatable, Hashable {
    case legacyMigration = "legacy-migration"
    case authenticatedHandshake = "authenticated-handshake"
    case pib1OperatorApproval = "pib-1-operator-approval"
}

public struct ProtocolIdentityPin: Codable, Sendable, Equatable, Hashable {
    public let algorithm: ProtocolSigningAlgorithm
    public let fingerprint: String
    public let approvedAt: Date
    public let source: ProtocolIdentityPinSource

    public init(
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        approvedAt: Date = Date(),
        source: ProtocolIdentityPinSource
    ) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.approvedAt = approvedAt
        self.source = source
    }
}

// MARK: - Trust Record

/// 信任记录
public struct TrustRecord: Codable, Sendable, Equatable, Identifiable {
    /// Version of the deterministic payload covered by `signature`.
    /// `nil` identifies records written before the complete v2 payload was
    /// introduced and is accepted only under strict legacy-field constraints.
    public static let currentSignaturePayloadVersion = 2

 /// 记录 ID（deviceId 作为主键）
    public var id: String { deviceId }
    
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 公钥数据
    public let publicKey: Data

 /// Secure Enclave PoP 公钥（可选，用于握手阶段额外校验）
    public let secureEnclavePublicKey: Data?
    
 /// 协议签名公钥 (Ed25519/ML-DSA)（ 7.2）
 ///
 /// 新版本使用此字段存储协议签名公钥。
 /// 如果为 nil，回退到 `publicKey` 字段。
    public let protocolPublicKey: Data?
    public let protocolSigningAlgorithm: ProtocolSigningAlgorithm?
    public let protocolPublicKeyFingerprint: String?
    public let protocolIdentityPins: [ProtocolIdentityPin]?

 /// Legacy P-256 身份公钥（ 7.2）
 ///
 /// 迁移期保留，用于向后兼容验证。
 /// 当对端是旧版本时，允许 fallback 到 P-256 ECDSA 验证。
    public let legacyP256PublicKey: Data?
    
 /// 对端使用的签名算法（ 7.2）
    public let signatureAlgorithm: SignatureAlgorithm?
    
 /// KEM 身份公钥（可选）
    public let kemPublicKeys: [KEMPublicKeyInfo]?
    
 /// 证明等级
    public let attestationLevel: P2PAttestationLevel
    
 /// 证明数据
    public let attestationData: Data?
    
 /// 设备能力
    public let capabilities: [String]
    
 /// 创建时间
    public let createdAt: Date
    
 /// 更新时间
    public let updatedAt: Date
    
    /// 版本号
    public let version: Int

    /// Deterministic signature schema. Optional so historical records remain
    /// decodable and can be quarantined instead of making the store unreadable.
    public let signaturePayloadVersion: Int?

 /// 签名（由本机管理密钥签名）
    public let signature: Data
    
 /// 记录类型
    public let recordType: TrustRecordType
    
 /// 撤销时间（tombstone）
    public let revokedAt: Date?

 /// current-path 非权威 metadata
    public let currentDeviceIdMetadata: String?
    public let knownDeviceIdsMetadata: [String]?
    public let lifecycleStateMetadata: TrustLifecycleState?
    
 /// 设备名称（用于 UI 显示）
    public let deviceName: String?
    
 /// 短 ID（用于 UI 显示）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }

 /// 是否为 tombstone
    public var isTombstone: Bool {
        recordType == .revoke
    }
    
 /// 是否过期（tombstone 30 天后过期）
    public var isExpired: Bool {
        guard isTombstone else { return false }
        // `updatedAt` has always been covered by every signature schema. Never
        // let the historically-unbound `revokedAt` shorten tombstone retention.
        let expirationDate = updatedAt.addingTimeInterval(30 * 24 * 60 * 60) // 30 天
        return Date() > expirationDate
    }

    public var currentDeviceId: String {
        currentDeviceIdMetadata ?? deviceId
    }

    public var knownDeviceIds: [String] {
        let base = knownDeviceIdsMetadata ?? [currentDeviceId]
        return Array(Set(base + [currentDeviceId])).sorted()
    }

    public var lifecycleState: TrustLifecycleState {
        lifecycleStateMetadata ?? (isTombstone ? .revoked : .active)
    }

    /// A trust record may authorize a security decision only while it is live
    /// and explicitly active. Quarantined and reverification-required records
    /// remain visible to trust-management UI, but cannot authenticate peers.
    public var isAuthenticationEligible: Bool {
        !isTombstone && !isExpired && lifecycleState == .active
    }

    public var currentPathAuthorityFingerprint: String? {
        protocolPublicKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var currentPathAuthorityPins: [ProtocolIdentityPin] {
        Self.normalizedProtocolIdentityPins(
            protocolIdentityPins,
            legacyFingerprint: protocolPublicKeyFingerprint,
            legacyAlgorithm: protocolSigningAlgorithm,
            approvedAt: updatedAt
        ) ?? []
    }

    public var currentPathAuthorityFingerprints: Set<String> {
        Set(currentPathAuthorityPins.map(\.fingerprint))
    }
    
 /// 是否允许 legacy P-256 fallback（ 7.2）
 ///
 /// 只有仍可用于认证的 TrustRecord 明确记录了 legacy P-256 公钥时
 /// 才允许 fallback。首次连接、撤销、隔离和待复验记录均不允许。
    public var allowsLegacyFallback: Bool {
        isAuthenticationEligible && legacyP256PublicKey != nil
    }
    
 /// 获取用于验证的公钥（ 7.2）
 ///
 /// 根据预期算法返回对应的公钥。不可用于认证的记录永远不返回密钥。
 /// - Parameter algorithm: 预期的签名算法
 /// - Returns: 用于验证的公钥，如果没有对应算法的公钥则返回 nil
    public func getVerificationPublicKey(for algorithm: SignatureAlgorithm) -> Data? {
        guard isAuthenticationEligible else { return nil }
        switch algorithm {
        case .ed25519, .mlDSA65:
 // 优先使用新的协议公钥，回退到旧的 publicKey
            return protocolPublicKey ?? publicKey
        case .p256ECDSA:
 // P-256 用于 legacy 验证或 SE PoP
            return legacyP256PublicKey ?? secureEnclavePublicKey
        }
    }
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        publicKey: Data,
        secureEnclavePublicKey: Data? = nil,
        protocolPublicKey: Data? = nil,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm? = nil,
        protocolPublicKeyFingerprint: String? = nil,
        protocolIdentityPins: [ProtocolIdentityPin]? = nil,
        legacyP256PublicKey: Data? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        attestationLevel: P2PAttestationLevel = .none,
        attestationData: Data? = nil,
        capabilities: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        version: Int = 1,
        signaturePayloadVersion: Int? = nil,
        signature: Data,
        recordType: TrustRecordType = .add,
        revokedAt: Date? = nil,
        deviceName: String? = nil,
        currentDeviceId: String? = nil,
        knownDeviceIds: [String]? = nil,
        lifecycleState: TrustLifecycleState? = nil
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.publicKey = publicKey
        self.secureEnclavePublicKey = secureEnclavePublicKey
        self.protocolPublicKey = protocolPublicKey
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
        self.protocolIdentityPins = Self.normalizedProtocolIdentityPins(
            protocolIdentityPins,
            legacyFingerprint: nil,
            legacyAlgorithm: nil,
            approvedAt: updatedAt
        )
        self.legacyP256PublicKey = legacyP256PublicKey
        self.signatureAlgorithm = signatureAlgorithm
        self.kemPublicKeys = kemPublicKeys
        self.attestationLevel = attestationLevel
        self.attestationData = attestationData
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.signaturePayloadVersion = signaturePayloadVersion
        self.signature = signature
        self.recordType = recordType
        self.revokedAt = revokedAt
        self.deviceName = deviceName
        self.currentDeviceIdMetadata = currentDeviceId
        self.knownDeviceIdsMetadata = knownDeviceIds
        self.lifecycleStateMetadata = lifecycleState
    }
    
    /// 创建撤销记录（tombstone）
    public func revoked(signature: Data) -> TrustRecord {
        revoked(signature: signature, at: Date())
    }

    func revoked(signature: Data, at revocationDate: Date) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            publicKey: publicKey,
            secureEnclavePublicKey: secureEnclavePublicKey,
            protocolPublicKey: protocolPublicKey,
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            protocolIdentityPins: protocolIdentityPins,
            legacyP256PublicKey: legacyP256PublicKey,
            signatureAlgorithm: signatureAlgorithm,
            kemPublicKeys: kemPublicKeys,
            attestationLevel: attestationLevel,
            attestationData: attestationData,
            capabilities: capabilities,
            createdAt: createdAt,
            updatedAt: revocationDate,
            version: version + 1,
            signaturePayloadVersion: Self.currentSignaturePayloadVersion,
            signature: signature,
            recordType: .revoke,
            revokedAt: revocationDate,
            deviceName: deviceName,
            currentDeviceId: currentDeviceId,
            knownDeviceIds: knownDeviceIds,
            lifecycleState: .revoked
        )
    }

    public static func normalizedProtocolFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    public static func normalizedProtocolIdentityPins(
        _ pins: [ProtocolIdentityPin]?,
        legacyFingerprint: String?,
        legacyAlgorithm: ProtocolSigningAlgorithm?,
        approvedAt: Date
    ) -> [ProtocolIdentityPin]? {
        var pinsByAlgorithm: [ProtocolSigningAlgorithm: ProtocolIdentityPin] = [:]

        func upsert(_ pin: ProtocolIdentityPin) {
            guard let fingerprint = normalizedProtocolFingerprint(pin.fingerprint) else { return }
            let normalized = ProtocolIdentityPin(
                algorithm: pin.algorithm,
                fingerprint: fingerprint,
                approvedAt: pin.approvedAt,
                source: pin.source
            )
            if let existing = pinsByAlgorithm[pin.algorithm],
               existing.approvedAt > normalized.approvedAt {
                return
            }
            pinsByAlgorithm[pin.algorithm] = normalized
        }

        for pin in pins ?? [] {
            upsert(pin)
        }

        if let legacyAlgorithm,
           pinsByAlgorithm[legacyAlgorithm] == nil,
           let fingerprint = normalizedProtocolFingerprint(legacyFingerprint) {
            upsert(
                ProtocolIdentityPin(
                    algorithm: legacyAlgorithm,
                    fingerprint: fingerprint,
                    approvedAt: approvedAt,
                    source: .legacyMigration
                )
            )
        }

        let normalized = pinsByAlgorithm.values.sorted {
            if $0.algorithm.rawValue != $1.algorithm.rawValue {
                return $0.algorithm.rawValue < $1.algorithm.rawValue
            }
            return $0.fingerprint < $1.fingerprint
        }
        return normalized.isEmpty ? nil : normalized
    }

    public static func protocolIdentityPins(
        existing pins: [ProtocolIdentityPin]?,
        legacyFingerprint: String?,
        legacyAlgorithm: ProtocolSigningAlgorithm?,
        adding algorithm: ProtocolSigningAlgorithm,
        fingerprint: String,
        approvedAt: Date = Date(),
        source: ProtocolIdentityPinSource
    ) -> [ProtocolIdentityPin]? {
        var normalized = normalizedProtocolIdentityPins(
            pins,
            legacyFingerprint: legacyFingerprint,
            legacyAlgorithm: legacyAlgorithm,
            approvedAt: approvedAt
        ) ?? []
        normalized.removeAll { $0.algorithm == algorithm }
        guard let fingerprint = normalizedProtocolFingerprint(fingerprint) else {
            return normalized.isEmpty ? nil : normalized
        }
        normalized.append(
            ProtocolIdentityPin(
                algorithm: algorithm,
                fingerprint: fingerprint,
                approvedAt: approvedAt,
                source: source
            )
        )
        return normalizedProtocolIdentityPins(
            normalized,
            legacyFingerprint: nil,
            legacyAlgorithm: nil,
            approvedAt: approvedAt
        )
    }
}

// MARK: - Trust Record Envelope

/// 信任记录信封（用于 iCloud 同步）
public struct TrustRecordEnvelope: Codable, Sendable {
 /// 信任记录
    public let record: TrustRecord
    
 /// 创建此记录的本机 ID
    public let localDeviceId: String
    
 /// 信封签名（由本机管理密钥签名）
    public let envelopeSignature: Data
    
 /// 创建时间
    public let createdAt: Date
    
    public init(
        record: TrustRecord,
        localDeviceId: String,
        envelopeSignature: Data,
        createdAt: Date = Date()
    ) {
        self.record = record
        self.localDeviceId = localDeviceId
        self.envelopeSignature = envelopeSignature
        self.createdAt = createdAt
    }
    
 /// 获取待签名数据
    public func dataToSign() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(record)
    }
}

// MARK: - Sync Status

/// 同步状态
public enum SyncStatus: String, Sendable {
    case idle = "idle"
    case syncing = "syncing"
    case synced = "synced"
    case failed = "failed"
    case unavailable = "unavailable"
}

// MARK: - Trust Sync Error

/// 信任同步错误
public enum TrustSyncError: Error, LocalizedError, Sendable {
    case recordNotFound
    case signatureFailed(String)
    case verificationFailed
    case keychainError(OSStatus)
    case syncUnavailable
    case conflictResolutionFailed
    case encodingError(String)
    case decodingError(String)
    case localTrustStoreUnavailable
    case fallbackCleanupFailedAfterAuthoritativeCommit(String)
    case aliasCleanupFailedAfterAuthoritativeCommit(String)
    case mutationWaiterLimitExceeded(maximum: Int)
    case mutationWaitDeadlineExceeded
    case forgetScopeChanged
    case pairingAuthorityCommitSuperseded
    
    public var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return "Trust record not found"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed:
            return "Signature verification failed"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .syncUnavailable:
            return "iCloud sync is not available"
        case .conflictResolutionFailed:
            return "Conflict resolution failed"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        case .decodingError(let reason):
            return "Decoding error: \(reason)"
        case .localTrustStoreUnavailable:
            return "Local trust store is unavailable"
        case .fallbackCleanupFailedAfterAuthoritativeCommit(let reason):
            return "Authoritative trust commit succeeded, but stale fallback cleanup failed: \(reason)"
        case .aliasCleanupFailedAfterAuthoritativeCommit(let reason):
            return "Authoritative trust commit succeeded, but stale alias cleanup failed: \(reason)"
        case .mutationWaiterLimitExceeded(let maximum):
            return "Trust mutation waiter limit exceeded: maximum=\(maximum)"
        case .mutationWaitDeadlineExceeded:
            return "Trust mutation wait deadline exceeded"
        case .forgetScopeChanged:
            return "Trust identity changed while forget was in progress; retry with a fresh scope"
        case .pairingAuthorityCommitSuperseded:
            return "Pairing authority commit was superseded before durable persistence"
        }
    }
}

public enum CurrentPathTrustConflict: Sendable, Equatable {
    case identityConflict
    case deviceIdMigrationRequired
    case quarantinedIdentity
    case revokedIdentity
}

typealias PairingAuthorityCommitValidator = @MainActor @Sendable () async -> Bool

struct TrustInvalidationEvent: Sendable, Equatable {
    let revision: UUID
    let deviceIds: Set<String>
    let protocolFingerprints: Set<String>

    func matches(deviceId: String?, protocolFingerprint: String? = nil) -> Bool {
        if let deviceId {
            let candidates = Set(
                PeerTrustLookup.lookupCandidates(for: deviceId)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            if !deviceIds.isDisjoint(with: candidates) {
                return true
            }
        }
        if let fingerprint = protocolFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !fingerprint.isEmpty,
           protocolFingerprints.contains(fingerprint) {
            return true
        }
        return false
    }
}

struct TrustForgetScope: Sendable, Equatable {
    let exactDeviceIds: [String]
    let deviceIds: [String]
    let autoConnectFingerprints: [String]
    fileprivate let verifiedRecords: [TrustRecord]
    fileprivate let rejectedRecords: [TrustRecord]
}

enum CurrentPathTrustAssessment: Sendable, Equatable {
    case conflict(CurrentPathTrustConflict)
    case trustedDevice
    case selfAsserted
}

/// Serializes trust-store transactions across actor reentrancy while bounding
/// queued work. Cancellation removes a queued waiter instead of leaving an
/// abandoned continuation behind.
actor TrustMutationAdmissionGate {
    private struct Permit {
        let token: UUID
        let deadline: ContinuousClock.Instant?
    }

    private struct Waiter {
        let token: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Permit, any Error>
        let deadlineTask: Task<Void, Never>
    }

    private let maximumWaiters: Int
    private let maximumWaitDuration: Duration
    private let sleepUntilDeadline: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var ownerToken: UUID?
    private var waiters: [Waiter] = []
#if DEBUG
    private var waiterCountObservers: [(expected: Int, continuation: CheckedContinuation<Void, Never>)] = []
#endif

    init(
        maximumWaiters: Int = 16,
        maximumWaitDuration: Duration = .seconds(30),
        sleepUntilDeadline: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        precondition(maximumWaiters >= 0)
        precondition(maximumWaitDuration > .zero)
        self.maximumWaiters = maximumWaiters
        self.maximumWaitDuration = maximumWaitDuration
        self.sleepUntilDeadline = sleepUntilDeadline
        self.now = now
    }

    var pendingWaiterCount: Int {
        waiters.count
    }

#if DEBUG
    func waitUntilPendingWaiterCountForTesting(_ expected: Int) async {
        if waiters.count == expected { return }
        await withCheckedContinuation { continuation in
            waiterCountObservers.append((expected: expected, continuation: continuation))
        }
    }
#endif

    func run<T: Sendable>(
        _ operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let permit = try await acquire()
        defer { release(token: permit.token) }
        try validate(permit: permit)
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws -> Permit {
        try Task.checkCancellation()
        let token = UUID()
        if ownerToken == nil {
            ownerToken = token
            return Permit(token: token, deadline: nil)
        }

        rejectElapsedWaiters()
        guard waiters.count < maximumWaiters else {
            throw TrustSyncError.mutationWaiterLimitExceeded(maximum: maximumWaiters)
        }

        let deadline = now().advanced(by: maximumWaitDuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [maximumWaitDuration, sleepUntilDeadline] in
                    do {
                        try await sleepUntilDeadline(maximumWaitDuration)
                    } catch {
                        return
                    }
                    self.expireWaiter(token: token)
                }
                waiters.append(
                    Waiter(
                        token: token,
                        deadline: deadline,
                        continuation: continuation,
                        deadlineTask: deadlineTask
                    )
                )
                notifyWaiterCountObserversForTesting()
                if Task.isCancelled {
                    cancelWaiter(token: token)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        notifyWaiterCountObserversForTesting()
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        guard now() >= waiters[index].deadline else { return }
        let waiter = waiters.remove(at: index)
        notifyWaiterCountObserversForTesting()
        waiter.continuation.resume(throwing: TrustSyncError.mutationWaitDeadlineExceeded)
    }

    private func validate(permit: Permit) throws {
        guard let deadline = permit.deadline else { return }
        guard now() < deadline else {
            throw TrustSyncError.mutationWaitDeadlineExceeded
        }
    }

    private func rejectElapsedWaiters() {
        let currentInstant = now()
        var activeWaiters: [Waiter] = []
        activeWaiters.reserveCapacity(waiters.count)
        for waiter in waiters {
            guard currentInstant >= waiter.deadline else {
                activeWaiters.append(waiter)
                continue
            }
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(throwing: TrustSyncError.mutationWaitDeadlineExceeded)
        }
        waiters = activeWaiters
        notifyWaiterCountObserversForTesting()
    }

    private func release(token: UUID) {
        precondition(ownerToken == token, "Only the active trust mutation owner may release it")
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            notifyWaiterCountObserversForTesting()
            next.deadlineTask.cancel()
            guard now() < next.deadline else {
                next.continuation.resume(throwing: TrustSyncError.mutationWaitDeadlineExceeded)
                continue
            }
            ownerToken = next.token
            next.continuation.resume(
                returning: Permit(token: next.token, deadline: next.deadline)
            )
            return
        }
        ownerToken = nil
    }


    private func notifyWaiterCountObserversForTesting() {
#if DEBUG
        var remaining: [(expected: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in waiterCountObservers {
            if observer.expected == waiters.count {
                observer.continuation.resume()
            } else {
                remaining.append(observer)
            }
        }
        waiterCountObservers = remaining
#endif
    }
}


// MARK: - Trust Sync Service

/// 信任同步服务 - iCloud Keychain 同步
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class TrustSyncService: ObservableObject {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = TrustSyncService()
    
 // MARK: - Constants
    
    private enum KeychainConstants {
        static let service = "com.skybridge.p2p.trust"
        static let recordPrefix = "trust_record_"
        static let syncEnabled = "sync_enabled"
    }

    private enum FallbackStorageConstants {
        static let recordsKey = "com.skybridge.p2p.trust.fallback.records.v1"
    }

    private static let protectedFallbackRecordStore: CodablePersistenceStore<[TrustRecord]> = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return CodablePersistenceStore(
            location: .protectedApplicationSupport(
                path: "P2PTrust/fallback-records.json",
                legacyUserDefaultsKey: FallbackStorageConstants.recordsKey
            ),
            encoder: encoder,
            decoder: decoder
        )
    }()

    private nonisolated static func forbidKeychainAuthenticationUI(_ query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
    
 // MARK: - Published Properties
    
 /// 同步状态
    @Published public var syncStatus: SyncStatus = .idle
    
    /// 活跃的信任记录
    @Published public private(set) var activeTrustRecords: [TrustRecord] = []

    /// Management-only projections for quarantined or unverifiable records.
    /// These never participate in authentication snapshots; they only make
    /// the explicit repair/forget action reachable from the UI.
    @Published public private(set) var trustRepairRecords: [TrustRecord] = []
    
 /// 最后同步时间
    @Published public var lastSyncTime: Date?

    private let trustInvalidationSubject = PassthroughSubject<TrustInvalidationEvent, Never>()
    var trustInvalidationPublisher: AnyPublisher<TrustInvalidationEvent, Never> {
        trustInvalidationSubject.eraseToAnyPublisher()
    }
    
 // MARK: - Properties
    
 /// 密钥管理器
    private let keyManager = DeviceIdentityKeyManager.shared
    
    /// 本地缓存
    private var localCache: [String: TrustRecord] = [:]

    /// Decodable records with invalid signatures are retained only as denial
    /// evidence. They never authorize a peer, but a matching legacy tombstone
    /// still prevents revoked trust from being silently resurrected.
    private var rejectedLocalCache: [String: TrustRecord] = [:]

    private let mutationGate = TrustMutationAdmissionGate()

#if DEBUG
    private var inMemoryPersistenceLeaseCountForTesting: Int = 0
    private var initialLoadTaskBeforeInMemoryTesting: Task<Result<Void, TrustSyncError>, Never>?
    /// Deterministic barrier placed after authority-record signing and before
    /// the final pairing lease validation/Keychain save. Tests can suspend here,
    /// reserve a replacement generation, then release the barrier.
    var pairingAuthorityPostSignBarrierForTesting: (@MainActor @Sendable () async -> Void)?

    private var usesInMemoryPersistenceForTesting: Bool {
        inMemoryPersistenceLeaseCountForTesting > 0
    }
#endif

    /// Startup persistence loading must complete before any asynchronous
    /// operation reads or mutates `localCache`. Without this barrier, the
    /// loader can resume after an add/revoke and replace newer in-memory trust
    /// state with its older persistence snapshot.
    private var initialLoadTask: Task<Result<Void, TrustSyncError>, Never>?
    
 // MARK: - Initialization
    
    private init() {
        initialLoadTask = Task { @MainActor [weak self] in
            guard let self else {
                return .failure(.localTrustStoreUnavailable)
            }
            do {
                try await self.loadLocalRecords()
                return .success(())
            } catch let error as TrustSyncError {
                return .failure(error)
            } catch {
                return .failure(.localTrustStoreUnavailable)
            }
        }
    }

#if DEBUG
    init(
        initialLoadOperationForTesting: @escaping @MainActor @Sendable () async throws -> Void,
        useInMemoryPersistenceForTesting: Bool = false
    ) {
        inMemoryPersistenceLeaseCountForTesting = useInMemoryPersistenceForTesting ? 1 : 0
        initialLoadTask = Task { @MainActor in
            do {
                try await initialLoadOperationForTesting()
                return .success(())
            } catch let error as TrustSyncError {
                return .failure(error)
            } catch {
                return .failure(.localTrustStoreUnavailable)
            }
        }
    }

    init(
        initialRecordsForTesting: [TrustRecord],
        rejectedRecordsForTesting: [TrustRecord] = []
    ) {
        inMemoryPersistenceLeaseCountForTesting = 1
        localCache = Dictionary(
            uniqueKeysWithValues: initialRecordsForTesting.map { ($0.deviceId, $0) }
        )
        rejectedLocalCache = Dictionary(
            uniqueKeysWithValues: rejectedRecordsForTesting.map { ($0.deviceId, $0) }
        )
        initialLoadTask = Task { @MainActor in .success(()) }
        updateActiveTrustRecordsFromCache()
    }
#endif

    private func awaitInitialLoadCompletion() async {
        guard let initialLoadTask else { return }
        _ = await initialLoadTask.value
    }

    private func requireInitialLoadSucceeded() async throws {
        try Task.checkCancellation()
        guard let initialLoadTask else {
            throw TrustSyncError.localTrustStoreUnavailable
        }
        let result = await initialLoadTask.value
        try Task.checkCancellation()
        try result.get()
    }
    
 // MARK: - Public Properties
    
 /// 同步前提条件检查
    public var isSyncAvailable: Bool {
 // 检查 iCloud 登录状态
        FileManager.default.ubiquityIdentityToken != nil
    }
    
 // MARK: - Public Methods
    
 /// 添加信任记录
 /// - Parameter record: 信任记录（不含签名）
 /// - Returns: 签名后的信任记录
    @discardableResult
    public func addTrustRecord(_ record: TrustRecord) async throws -> TrustRecord {
        try await requireInitialLoadSucceeded()
        return try await mutationGate.run { [self, record] in
            try await addTrustRecordWithinMutation(record)
        }
    }

    private func addTrustRecordWithinMutation(
        _ record: TrustRecord,
        pairingCommitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> TrustRecord {
        try await validatePairingAuthorityCommit(pairingCommitValidator)

        guard denialConflict(for: record) == nil else {
            throw TrustSyncError.verificationFailed
        }

 // 检查是否已存在
        if let existing = localCache[record.deviceId] {
 // 如果已存在且不是 tombstone，更新
            if !existing.isTombstone {
                return try await updateTrustRecordWithinMutation(
                    record,
                    pairingCommitValidator: pairingCommitValidator
                )
            }
 // 如果是 tombstone，不允许重新添加同一 deviceId
            throw TrustSyncError.conflictResolutionFailed
        }
        
        // 签名记录
        let signedRecord = try await signRecord(record)
        try await validatePairingAuthorityCommitAfterSigning(pairingCommitValidator)
        
 // 保存到本地
        let postCommitError: TrustSyncError?
#if DEBUG
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(
                signedRecord,
                synchronizable: isSyncAvailable
            )
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(
            signedRecord,
            synchronizable: isSyncAvailable
        )
#endif
        localCache[signedRecord.deviceId] = signedRecord
        
 // 更新 UI
        updateActiveTrustRecordsFromCache()

        if let postCommitError {
            throw postCommitError
        }
        
        SkyBridgeLogger.p2p.info("Added trust record: \(signedRecord.shortId)")
        return signedRecord
    }

    private func validatePairingAuthorityCommit(
        _ validator: PairingAuthorityCommitValidator?
    ) async throws {
        try Task.checkCancellation()
        guard let validator else { return }
        guard await validator() else {
            throw TrustSyncError.pairingAuthorityCommitSuperseded
        }
    }

    private func validatePairingAuthorityCommitAfterSigning(
        _ validator: PairingAuthorityCommitValidator?
    ) async throws {
#if DEBUG
        if validator != nil, let barrier = pairingAuthorityPostSignBarrierForTesting {
            await barrier()
        }
#endif
        try await validatePairingAuthorityCommit(validator)
    }

    /// Denial evidence wins across aliases and fingerprints. This combines
    /// verified local lifecycle records with invalid-signature records that
    /// are retained only to prevent a stale active alias from authorizing or
    /// resurrecting an identity.
    private func denialConflict(for record: TrustRecord) -> CurrentPathTrustConflict? {
        func matches(_ candidate: TrustRecord) -> Bool {
            PeerTrustLookup.recordsShareTrustIdentity(record, candidate)
        }

        let verifiedMatches = localCache.values.filter {
            !$0.isExpired && matches($0)
        }
        let rejectedMatches = rejectedLocalCache.values.filter(matches)
        guard !verifiedMatches.isEmpty || !rejectedMatches.isEmpty else { return nil }

        if (verifiedMatches + rejectedMatches).contains(where: {
            $0.isTombstone || $0.lifecycleState == .revoked
        }) {
            return .revokedIdentity
        }
        if !rejectedMatches.isEmpty || verifiedMatches.contains(where: {
            switch $0.lifecycleState {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        return nil
    }

    @discardableResult
    func upsertTrustRecordAtomically(
        deviceId: String,
        transform: @MainActor @Sendable (TrustRecord?) throws -> TrustRecord
    ) async throws -> TrustRecord {
        try await requireInitialLoadSucceeded()
        return try await mutationGate.run { [self, deviceId, transform] in
            let record = try transform(localCache[deviceId])
            guard record.deviceId == deviceId else {
                throw TrustSyncError.encodingError("atomic trust transform changed deviceId")
            }
            return try await addTrustRecordWithinMutation(record)
        }
    }
    
 /// 撤销信任记录（创建 tombstone）
    /// - Parameter deviceId: 设备 ID
    public func revokeTrustRecord(deviceId: String) async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self, deviceId] in
            guard try await revokeVerifiedIdentityWithinMutation(
                exactDeviceIds: [deviceId]
            ) else {
                throw TrustSyncError.recordNotFound
            }
        }
    }

    /// Revocation is an identity operation, not a storage-key operation.
    /// Expand only through locally verified aliases and cryptographic
    /// fingerprints, then publish the full scope with the first durable
    /// tombstone so every sibling session is torn down even if a later mirror
    /// cleanup error interrupts the remaining writes.
    @discardableResult
    private func revokeVerifiedIdentityWithinMutation(
        exactDeviceIds: Set<String>,
        additionalInvalidationDeviceIds: Set<String> = []
    ) async throws -> Bool {
        let resolution = verifiedForgetResolution(exactDeviceIds: exactDeviceIds)
        guard !resolution.verifiedKeys.isEmpty else { return false }
        let invalidationDeviceIds = resolution.expandedDeviceIds
            .union(additionalInvalidationDeviceIds)

        for key in resolution.verifiedKeys.sorted() {
            guard let record = localCache[key] else { continue }
            if record.isTombstone {
                publishTrustInvalidation(
                    records: [record],
                    additionalDeviceIds: invalidationDeviceIds
                )
            } else {
                _ = try await revokeTrustRecordWithinMutation(
                    deviceId: key,
                    additionalInvalidationDeviceIds: invalidationDeviceIds
                )
            }
        }
        return true
    }

    private func revokeTrustRecordWithinMutation(
        deviceId: String,
        additionalInvalidationDeviceIds: Set<String> = []
    ) async throws -> TrustRecord {
        try Task.checkCancellation()

        guard let existing = localCache[deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        
 // 先构造最终 tombstone，再签名其精确持久化载荷。
        let revocationDate = Date()
        let unsignedRevokedRecord = existing.revoked(signature: Data(), at: revocationDate)
        let dataToSign = try createDataToSign(for: unsignedRevokedRecord, revoked: true)
        let signature = try await keyManager.sign(data: dataToSign)
        try Task.checkCancellation()
        let revokedRecord = existing.revoked(signature: signature, at: revocationDate)
        
 // 保存到本地
        let postCommitError: TrustSyncError?
#if DEBUG
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(
                revokedRecord,
                synchronizable: isSyncAvailable
            )
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(
            revokedRecord,
            synchronizable: isSyncAvailable
        )
#endif
        localCache[deviceId] = revokedRecord
        
        // 更新 UI
        updateActiveTrustRecordsFromCache()

        // Publish synchronously with the durable tombstone commit. A caller
        // may fail later in the same mutation; that must not leave sessions for
        // this already-revoked identity alive.
        publishTrustInvalidation(
            records: [revokedRecord],
            additionalDeviceIds: additionalInvalidationDeviceIds
        )
        
        SkyBridgeLogger.p2p.info("Revoked trust record: \(revokedRecord.shortId)")
        if let postCommitError {
            throw postCommitError
        }
        return revokedRecord
    }

    /// Explicit user-confirmed removal path. Valid linked records become
    /// signed tombstones; only exact selected unverifiable records are deleted.
    /// This is a fail-closed forget operation, not an implicit re-pair bypass.
    public func revokeOrRemoveUnverifiableTrust(deviceIds rawDeviceIds: [String]) async throws {
        let expectedScope = try await verifiedForgetScopeForForget(
            exactDeviceIds: rawDeviceIds
        )
        try await revokeOrRemoveUnverifiableTrust(
            deviceIds: rawDeviceIds,
            expectedScope: expectedScope
        )
    }

    /// Applies a previously-authorized forget scope only if the signed trust
    /// identity graph is unchanged. Cross-store cleanup necessarily awaits
    /// between stores; recomputing under the mutation gate prevents that gap
    /// from turning a stale UI scope into a destructive alias/fingerprint race.
    func revokeOrRemoveUnverifiableTrust(
        deviceIds rawDeviceIds: [String],
        expectedScope: TrustForgetScope
    ) async throws {
        try await requireInitialLoadSucceeded()
        let deviceIds = Set(
            rawDeviceIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !deviceIds.isEmpty else { throw TrustSyncError.recordNotFound }

        try await mutationGate.run { [self, deviceIds, expectedScope] in
            // A rejected record has authenticated none of its embedded alias
            // metadata. It can select only its exact persisted key. Verified
            // records may expand revocation scope through signed identity
            // aliases and either current-path or legacy authority fingerprints.
            let currentScope = makeVerifiedForgetScope(exactDeviceIds: deviceIds)
            guard currentScope == expectedScope else {
                throw TrustSyncError.forgetScopeChanged
            }
            let verifiedKeys = Set(currentScope.verifiedRecords.map(\.deviceId))
            let rejectedKeys = Set(currentScope.rejectedRecords.map(\.deviceId))
            guard !verifiedKeys.isEmpty || !rejectedKeys.isEmpty else {
                throw TrustSyncError.recordNotFound
            }

            for key in verifiedKeys {
                guard let record = localCache[key] else { continue }
                if record.isTombstone {
                    publishTrustInvalidation(
                        records: [record],
                        additionalDeviceIds: Set(currentScope.deviceIds)
                    )
                } else {
                    _ = try await revokeTrustRecordWithinMutation(
                        deviceId: key,
                        additionalInvalidationDeviceIds: Set(currentScope.deviceIds)
                    )
                }
            }

            for key in rejectedKeys {
                guard let rejectedRecord = rejectedLocalCache[key] else { continue }
                if !verifiedKeys.contains(key) {
#if DEBUG
                    if !usesInMemoryPersistenceForTesting {
                        try deleteFromKeychain(deviceId: key)
                    }
#else
                    try deleteFromKeychain(deviceId: key)
#endif
                }
                rejectedLocalCache.removeValue(forKey: key)
                publishTrustInvalidation(
                    records: [rejectedRecord],
                    additionalDeviceIds: [key]
                )
            }
            updateActiveTrustRecordsFromCache()
            SkyBridgeLogger.p2p.info(
                "Completed explicit trust removal: verified=\(verifiedKeys.count, privacy: .public) quarantined=\(rejectedKeys.count, privacy: .public)"
            )
        }
    }
    
    /// 获取所有有效信任记录（排除 tombstone）
    public func getActiveTrustRecords() async -> [TrustRecord] {
        await awaitInitialLoadCompletion()
        return activeTrustRecordsSnapshot()
    }

    func trustedRecordsSnapshot() async throws -> [TrustRecord] {
        try await requireInitialLoadSucceeded()
        return activeTrustRecordsSnapshot()
    }

    func verifiedAutoConnectFingerprintsForForget(
        exactDeviceIds rawDeviceIds: [String]
    ) async throws -> [String] {
        let scope = try await verifiedForgetScopeForForget(exactDeviceIds: rawDeviceIds)
        return scope.autoConnectFingerprints
    }

    func verifiedForgetScopeForForget(
        exactDeviceIds rawDeviceIds: [String]
    ) async throws -> TrustForgetScope {
        try await requireInitialLoadSucceeded()
        let deviceIds = Set(
            rawDeviceIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !deviceIds.isEmpty else { throw TrustSyncError.recordNotFound }
        return makeVerifiedForgetScope(exactDeviceIds: deviceIds)
    }

    private func makeVerifiedForgetScope(
        exactDeviceIds deviceIds: Set<String>
    ) -> TrustForgetScope {
        let resolution = verifiedForgetResolution(exactDeviceIds: deviceIds)
        let fingerprints: Set<String> = Set(resolution.verifiedKeys.compactMap { key in
            guard let record = localCache[key] else { return nil }
            let fingerprint = record.pubKeyFP
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return fingerprint.isEmpty ? nil : fingerprint
        })
        return TrustForgetScope(
            exactDeviceIds: deviceIds.sorted(),
            deviceIds: resolution.expandedDeviceIds.sorted(),
            autoConnectFingerprints: fingerprints.sorted(),
            verifiedRecords: resolution.verifiedKeys
                .compactMap { localCache[$0] }
                .sorted { $0.deviceId < $1.deviceId },
            rejectedRecords: deviceIds
                .compactMap { rejectedLocalCache[$0] }
                .sorted { $0.deviceId < $1.deviceId }
        )
    }

    private struct VerifiedForgetResolution {
        var verifiedKeys: Set<String>
        var expandedDeviceIds: Set<String>
    }

    private func verifiedForgetResolution(
        exactDeviceIds: Set<String>
    ) -> VerifiedForgetResolution {
        var normalizedAliases = Set(
            exactDeviceIds.flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var verifiedKeys = Set<String>()
        var expandedDeviceIds = exactDeviceIds
        var authorityFingerprints = Set<String>()

        var discoveredNewRecord = true
        while discoveredNewRecord {
            discoveredNewRecord = false
            for (key, record) in localCache where !verifiedKeys.contains(key) {
                let recordCandidates = PeerTrustLookup.recordLookupCandidates(record)
                let normalizedRecordCandidates = Set(
                    recordCandidates
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                )
                var recordAuthorityFingerprints = record.currentPathAuthorityFingerprints
                let legacyFingerprint = record.pubKeyFP
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !legacyFingerprint.isEmpty {
                    recordAuthorityFingerprints.insert(legacyFingerprint)
                }
                guard exactDeviceIds.contains(key)
                        || !normalizedAliases.isDisjoint(with: normalizedRecordCandidates)
                        || !authorityFingerprints.isDisjoint(with: recordAuthorityFingerprints) else {
                    continue
                }
                verifiedKeys.insert(key)
                expandedDeviceIds.insert(key)
                expandedDeviceIds.formUnion(recordCandidates)
                normalizedAliases.formUnion(normalizedRecordCandidates)
                authorityFingerprints.formUnion(recordAuthorityFingerprints)
                discoveredNewRecord = true
            }
        }

        return VerifiedForgetResolution(
            verifiedKeys: verifiedKeys,
            expandedDeviceIds: expandedDeviceIds
        )
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        do {
            try await requireInitialLoadSucceeded()
        } catch {
            return true
        }
        if rejectedLocalCache.values.contains(where: {
            currentPathDeviceMatches($0, deviceId: deviceId)
        }) {
            return true
        }
        return localCache.values.contains {
            !$0.isExpired && currentPathDeviceMatches($0, deviceId: deviceId)
        }
    }
    
 /// 获取信任记录
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 信任记录（如果存在）
    public func getTrustRecord(deviceId: String) -> TrustRecord? {
        guard let record = localCache[deviceId] else { return nil }
        guard record.isAuthenticationEligible, denialConflict(for: record) == nil else {
            return nil
        }
        return record
    }
    
 /// 检查设备是否受信任
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 是否受信任
    public func isTrusted(deviceId: String) -> Bool {
        guard let record = localCache[deviceId] else { return false }
        return record.isAuthenticationEligible && denialConflict(for: record) == nil
    }
    
 /// 检查公钥指纹是否受信任
 /// - Parameter pubKeyFP: 公钥指纹
 /// - Returns: 是否受信任
    public func isTrusted(pubKeyFP: String) -> Bool {
        return localCache.values.contains {
            $0.pubKeyFP == pubKeyFP
                && $0.isAuthenticationEligible
                && denialConflict(for: $0) == nil
        }
    }

    public func getCurrentPathTrustRecord(fingerprint: String) -> TrustRecord? {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return localCache.values.first { record in
            guard record.isAuthenticationEligible else { return false }
            guard denialConflict(for: record) == nil else { return false }
            return record.currentPathAuthorityFingerprints.contains(normalized)
        }
    }

    func getCurrentPathTrustRecord(
        fingerprint: String,
        matchingDeviceId deviceId: String
    ) -> TrustRecord? {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return localCache.values.first { record in
            guard record.isAuthenticationEligible else { return false }
            guard denialConflict(for: record) == nil else { return false }
            guard record.currentPathAuthorityFingerprints.contains(normalized) else { return false }
            return currentPathDeviceMatches(record, deviceId: deviceId)
        }
    }

    public func evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        let normalizedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedFingerprint.isEmpty else { return nil }

        let fingerprintMatches = localCache.values.filter {
            !$0.isExpired &&
            $0.currentPathAuthorityFingerprints.contains(normalizedFingerprint)
        }
        let deviceMatches = localCache.values.filter {
            !$0.isExpired &&
            currentPathDeviceMatches($0, deviceId: deviceId)
        }
        let relevantRecords = fingerprintMatches + deviceMatches

        if relevantRecords.contains(where: {
            $0.isTombstone || $0.lifecycleState == .revoked
        }) {
            return .revokedIdentity
        }
        if relevantRecords.contains(where: {
            switch $0.lifecycleState {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = $0.currentPathAuthorityFingerprints
            guard !pinnedFingerprints.isEmpty else { return false }
            return !pinnedFingerprints.contains(normalizedFingerprint) && $0.lifecycleState == .active
        }) {
            return .identityConflict
        }
        if fingerprintMatches.contains(where: { $0.lifecycleState == .active }) {
            // A key-preserving deviceId migration is acceptable only when the
            // claimed deviceId has no incompatible active authority of its own.
            return nil
        }

        return nil
    }

    /// Produces one atomic security assessment after persistence is known to
    /// be readable. No actor suspension occurs between conflict and trusted
    /// record evaluation.
    func currentPathTrustAssessment(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) async throws -> CurrentPathTrustAssessment {
        try await requireInitialLoadSucceeded()
        if let rejectedConflict = rejectedCurrentPathTrustConflict(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            return .conflict(rejectedConflict)
        }
        if let conflict = evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            return .conflict(conflict)
        }
        if getCurrentPathTrustRecord(
            fingerprint: protocolPublicKeyFingerprint,
            matchingDeviceId: deviceId
        ) != nil {
            return .trustedDevice
        }
        return .selfAsserted
    }

    private func rejectedCurrentPathTrustConflict(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        let normalizedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedFingerprint.isEmpty else { return nil }

        let matches = rejectedLocalCache.values.filter { record in
            record.currentPathAuthorityFingerprints.contains(normalizedFingerprint)
                || currentPathDeviceMatches(record, deviceId: deviceId)
        }
        guard !matches.isEmpty else { return nil }
        if matches.contains(where: { $0.isTombstone || $0.lifecycleState == .revoked }) {
            return .revokedIdentity
        }
        return .quarantinedIdentity
    }

    private func currentPathDenialConflict(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        if let rejectedConflict = rejectedCurrentPathTrustConflict(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            return rejectedConflict
        }
        switch evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
        case .revokedIdentity:
            return .revokedIdentity
        case .quarantinedIdentity:
            return .quarantinedIdentity
        case .identityConflict, .deviceIdMigrationRequired, nil:
            return nil
        }
    }

    private func currentPathDeviceMatches(_ record: TrustRecord, deviceId: String) -> Bool {
        guard let lookup = currentPathLookupCandidates(for: deviceId) else { return false }
        return PeerTrustLookup.recordLookupCandidates(record).contains { candidate in
            lookup.candidates.contains(candidate)
                || lookup.candidateLowercased.contains(candidate.lowercased())
        }
    }

    private func currentPathLookupCandidates(
        for deviceId: String
    ) -> (candidates: Set<String>, candidateLowercased: Set<String>)? {
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceId.isEmpty else { return nil }

        let lookupCandidates = Set(
            PeerTrustLookup.lookupCandidates(
                primary: normalizedDeviceId,
                persistent: PeerTrustLookup.persistentDeviceId(from: normalizedDeviceId)
            )
        )
        guard !lookupCandidates.isEmpty else { return nil }
        return (lookupCandidates, Set(lookupCandidates.map { $0.lowercased() }))
    }

    nonisolated static func resolvedAuthenticatedRemoteAuthorityRecord(
        existingRecords: [TrustRecord],
        deviceId: String,
        displayName: String? = nil,
        preferredCurrentDeviceId: String? = nil,
        knownDeviceIds: [String] = [],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        authenticatedProtocolPublicKey: Data? = nil,
        pinSource: ProtocolIdentityPinSource = .authenticatedHandshake
    ) -> TrustRecord? {
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceId.isEmpty else { return nil }

        let normalizedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedFingerprint.count == 64,
              normalizedFingerprint.allSatisfy(\.isHexDigit) else {
            return nil
        }

        func validatedProtocolPublicKey(_ publicKey: Data?) -> Data? {
            guard let publicKey else { return nil }
            let expectedLength: Int
            switch protocolSigningAlgorithm {
            case .ed25519:
                expectedLength = 32
            case .mlDSA65:
                expectedLength = 1_952
            }
            guard publicKey.count == expectedLength else { return nil }
            let fingerprint = ProtocolIdentityBinding.computeFingerprint(
                algorithm: protocolSigningAlgorithm,
                publicKeyBytes: publicKey
            )
            return fingerprint == normalizedFingerprint ? publicKey : nil
        }

        if authenticatedProtocolPublicKey != nil,
           validatedProtocolPublicKey(authenticatedProtocolPublicKey) == nil {
            return nil
        }

        let normalizedDisplayName = LocalDevicePresentation.sanitizedDisplayNameCandidate(displayName)
        let stableCurrentDeviceId = PeerTrustLookup.persistentDeviceId(from: preferredCurrentDeviceId)
            ?? preferredCurrentDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)

        let authenticatedLookupCandidates = PeerTrustLookup.lookupCandidates(
            primary: normalizedDeviceId,
            persistent: stableCurrentDeviceId
        )
        let authenticatedCandidateSet = Set(authenticatedLookupCandidates)
        let authenticatedCandidateLowerSet = Set(authenticatedCandidateSet.map { $0.lowercased() })

        func directRecordMatchesAuthenticatedIdentity(_ record: TrustRecord) -> Bool {
            let directCandidates = Set(
                [record.deviceId, record.currentDeviceIdMetadata]
                    .compactMap { $0 }
                    .flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
            )
            return !directCandidates.isDisjoint(with: authenticatedCandidateSet)
                || directCandidates.contains {
                    authenticatedCandidateLowerSet.contains($0.lowercased())
                }
        }

        // Only identifiers authenticated by the current path may select an
        // existing authority record. `knownDeviceIds` are remote metadata: they
        // can be retained after conflict checks, but can never anchor a target
        // or lend another device's KEM, attestation, or legacy key material.
        let matchingRecords = existingRecords.filter { record in
            !record.isTombstone &&
            !record.isExpired &&
            directRecordMatchesAuthenticatedIdentity(record)
        }

        let targetRecord: TrustRecord?
        if matchingRecords.count <= 1 {
            targetRecord = matchingRecords.first
        } else if let stableCurrentDeviceId {
            let stableMatches = matchingRecords.filter { record in
                record.currentDeviceId == stableCurrentDeviceId || record.deviceId == stableCurrentDeviceId
            }
            targetRecord = stableMatches.count == 1 ? stableMatches[0] : nil
        } else {
            targetRecord = nil
        }
        guard matchingRecords.count <= 1 || targetRecord != nil else {
            return nil
        }

        let lookupCandidates = authenticatedLookupCandidates

        // Validate every prospective alias, including aliases already covered
        // by the selected record's signature. A claim that intersects any
        // other live or denial record is ambiguous and must fail closed before
        // material is copied or an alias record is deleted.
        var prospectiveAliasClaims = [normalizedDeviceId]
            + [stableCurrentDeviceId].compactMap { $0 }
        if let targetRecord {
            prospectiveAliasClaims.append(targetRecord.deviceId)
            prospectiveAliasClaims.append(targetRecord.currentDeviceId)
            prospectiveAliasClaims.append(contentsOf: targetRecord.knownDeviceIdsMetadata ?? [])
        }
        func conflictsWithAnotherRecord(_ claims: [String]) -> Bool {
            let claimedAliasCandidates = Set(
                claims.flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
            )
            guard !claimedAliasCandidates.isEmpty else { return false }
            let claimedAliasCandidatesLower = Set(claimedAliasCandidates.map { $0.lowercased() })
            let targetStorageKey = targetRecord?.deviceId
            return existingRecords.contains { record in
                guard !record.isExpired, record.deviceId != targetStorageKey else { return false }
                let directCandidates = [record.deviceId, record.currentDeviceIdMetadata]
                    .compactMap { $0 }
                    .flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
                return directCandidates.contains {
                    claimedAliasCandidates.contains($0)
                        || claimedAliasCandidatesLower.contains($0.lowercased())
                }
            }
        }
        guard !conflictsWithAnotherRecord(prospectiveAliasClaims) else { return nil }

        // `knownDeviceIds` arrive as remote metadata. Keep non-conflicting
        // aliases for local routing, but silently discard graft attempts that
        // point at another record's direct identity. They must never select a
        // target record or borrow its KEM/attestation material.
        let retainedKnownDeviceIds = knownDeviceIds.filter {
            !conflictsWithAnotherRecord([$0])
        }

        func mergeKnownDeviceIds(existing: [String?]) -> [String]? {
            let merged = Set(
                existing
                    .compactMap { $0 }
                    + lookupCandidates
                    + retainedKnownDeviceIds
                    + [stableCurrentDeviceId, normalizedDeviceId].compactMap { $0 }
            )
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !merged.isEmpty else { return nil }
            return Array(merged).sorted()
        }

        if let targetRecord {
            let canonicalDeviceId = stableCurrentDeviceId ?? targetRecord.deviceId
            let protocolPublicKey = validatedProtocolPublicKey(authenticatedProtocolPublicKey)
                ?? validatedProtocolPublicKey(targetRecord.protocolPublicKey)
            let updatedProtocolIdentityPins = TrustRecord.protocolIdentityPins(
                existing: targetRecord.currentPathAuthorityPins,
                legacyFingerprint: nil,
                legacyAlgorithm: nil,
                adding: protocolSigningAlgorithm,
                fingerprint: normalizedFingerprint,
                source: pinSource
            )
            return TrustRecord(
                deviceId: canonicalDeviceId,
                pubKeyFP: targetRecord.pubKeyFP,
                publicKey: targetRecord.publicKey,
                secureEnclavePublicKey: targetRecord.secureEnclavePublicKey,
                protocolPublicKey: protocolPublicKey,
                protocolSigningAlgorithm: protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: normalizedFingerprint,
                protocolIdentityPins: updatedProtocolIdentityPins,
                legacyP256PublicKey: targetRecord.legacyP256PublicKey,
                signatureAlgorithm: targetRecord.signatureAlgorithm,
                kemPublicKeys: targetRecord.kemPublicKeys,
                attestationLevel: targetRecord.attestationLevel,
                attestationData: targetRecord.attestationData,
                capabilities: targetRecord.capabilities,
                signature: Data(),
                deviceName: normalizedDisplayName ?? targetRecord.deviceName,
                currentDeviceId: canonicalDeviceId,
                knownDeviceIds: mergeKnownDeviceIds(
                    existing: [targetRecord.deviceId, targetRecord.currentDeviceIdMetadata]
                        + (targetRecord.knownDeviceIdsMetadata ?? [])
                        .map(Optional.some)
                ),
                lifecycleState: .active
            )
        }

        guard let stableCurrentDeviceId, !stableCurrentDeviceId.isEmpty else {
            return nil
        }

        return TrustRecord(
            deviceId: stableCurrentDeviceId,
            pubKeyFP: "",
            publicKey: Data(),
            protocolPublicKey: validatedProtocolPublicKey(authenticatedProtocolPublicKey),
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: normalizedFingerprint,
            protocolIdentityPins: TrustRecord.protocolIdentityPins(
                existing: nil,
                legacyFingerprint: nil,
                legacyAlgorithm: nil,
                adding: protocolSigningAlgorithm,
                fingerprint: normalizedFingerprint,
                source: pinSource
            ),
            signature: Data(),
            deviceName: normalizedDisplayName,
            currentDeviceId: stableCurrentDeviceId,
            knownDeviceIds: mergeKnownDeviceIds(existing: []),
            lifecycleState: .active
        )
    }

    @discardableResult
    public func recordAuthenticatedRemoteAuthority(
        deviceId: String,
        displayName: String? = nil,
        preferredCurrentDeviceId: String? = nil,
        knownDeviceIds: [String] = [],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        authenticatedProtocolPublicKey: Data? = nil,
        pinSource: ProtocolIdentityPinSource = .authenticatedHandshake
    ) async throws -> Bool {
        try await requireInitialLoadSucceeded()
        return try await mutationGate.run { [self] in
            try await recordAuthenticatedRemoteAuthorityWithinMutation(
                deviceId: deviceId,
                displayName: displayName,
                preferredCurrentDeviceId: preferredCurrentDeviceId,
                knownDeviceIds: knownDeviceIds,
                protocolSigningAlgorithm: protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
                authenticatedProtocolPublicKey: authenticatedProtocolPublicKey,
                pinSource: pinSource
            )
        }
    }

    /// Pairing-only authority commit. The validator is evaluated inside the
    /// mutation gate and again after record signing immediately before the
    /// synchronous durable save.
    @discardableResult
    func recordAuthenticatedRemoteAuthorityForPairing(
        deviceId: String,
        displayName: String? = nil,
        preferredCurrentDeviceId: String? = nil,
        knownDeviceIds: [String] = [],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        authenticatedProtocolPublicKey: Data? = nil,
        pinSource: ProtocolIdentityPinSource = .authenticatedHandshake,
        isCurrent: @escaping PairingAuthorityCommitValidator
    ) async throws -> Bool {
        try await requireInitialLoadSucceeded()
        return try await mutationGate.run { [self, isCurrent] in
            try await validatePairingAuthorityCommit(isCurrent)
            do {
                return try await recordAuthenticatedRemoteAuthorityWithinMutation(
                    deviceId: deviceId,
                    displayName: displayName,
                    preferredCurrentDeviceId: preferredCurrentDeviceId,
                    knownDeviceIds: knownDeviceIds,
                    protocolSigningAlgorithm: protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
                    authenticatedProtocolPublicKey: authenticatedProtocolPublicKey,
                    pinSource: pinSource,
                    pairingCommitValidator: isCurrent
                )
            } catch TrustSyncError.fallbackCleanupFailedAfterAuthoritativeCommit(let reason) {
                SkyBridgeLogger.p2p.warning(
                    "Pairing authority committed, but stale fallback cleanup failed: \(reason, privacy: .private)"
                )
                return true
            } catch TrustSyncError.aliasCleanupFailedAfterAuthoritativeCommit(let reason) {
                SkyBridgeLogger.p2p.warning(
                    "Pairing authority committed, but stale alias cleanup failed: \(reason, privacy: .private)"
                )
                return true
            }
        }
    }

    private func recordAuthenticatedRemoteAuthorityWithinMutation(
        deviceId: String,
        displayName: String?,
        preferredCurrentDeviceId: String?,
        knownDeviceIds: [String],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        authenticatedProtocolPublicKey: Data?,
        pinSource: ProtocolIdentityPinSource,
        pairingCommitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> Bool {
        try await validatePairingAuthorityCommit(pairingCommitValidator)

        let authorityClaims = [deviceId, preferredCurrentDeviceId]
            .compactMap { $0 }
            + knownDeviceIds
        for authorityClaim in authorityClaims where currentPathDenialConflict(
            deviceId: authorityClaim,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) != nil {
            throw TrustSyncError.verificationFailed
        }

        guard let record = Self.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: Array(localCache.values),
            deviceId: deviceId,
            displayName: displayName,
            preferredCurrentDeviceId: preferredCurrentDeviceId,
            knownDeviceIds: knownDeviceIds,
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            authenticatedProtocolPublicKey: authenticatedProtocolPublicKey,
            pinSource: pinSource
        ) else {
            return false
        }
        let signedRecord = try await addTrustRecordWithinMutation(
            record,
            pairingCommitValidator: pairingCommitValidator
        )
        let aliasesToRemove = Set(signedRecord.knownDeviceIdsMetadata ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != signedRecord.deviceId }
        var removedAliasRecord = false
        for alias in aliasesToRemove where localCache[alias] != nil {
            do {
                try deleteFromKeychain(deviceId: alias)
            } catch {
                throw TrustSyncError.aliasCleanupFailedAfterAuthoritativeCommit(
                    SkyBridgeDiagnosticRedaction.errorSummary(error)
                )
            }
            localCache.removeValue(forKey: alias)
            removedAliasRecord = true
        }
        if removedAliasRecord {
            updateActiveTrustRecordsFromCache()
        }
        return true
    }
    
    /// 同步信任记录
    public func sync() async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self] in
            try await syncWithinMutation()
        }
    }

    private func publishTrustInvalidation(
        records: [TrustRecord],
        additionalDeviceIds: Set<String> = []
    ) {
        var deviceIds = Set(
            additionalDeviceIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var protocolFingerprints = Set<String>()
        for record in records {
            deviceIds.formUnion(
                PeerTrustLookup.recordLookupCandidates(record)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            protocolFingerprints.formUnion(record.currentPathAuthorityFingerprints)
        }
        guard !deviceIds.isEmpty || !protocolFingerprints.isEmpty else { return }
        trustInvalidationSubject.send(
            TrustInvalidationEvent(
                revision: UUID(),
                deviceIds: deviceIds,
                protocolFingerprints: protocolFingerprints
            )
        )
    }

    private func syncWithinMutation() async throws {
        try Task.checkCancellation()

        guard isSyncAvailable else {
            syncStatus = .unavailable
            throw TrustSyncError.syncUnavailable
        }
        
        syncStatus = .syncing
        
        do {
 // 从 Keychain 加载所有记录（包括同步的）
            let allRecords = try loadAllFromKeychain()
            let verificationBatch = try await verifiedTrustRecordsForLocalLoad(
                allRecords,
                source: "Keychain sync"
            )
            try Task.checkCancellation()
            
 // 解决冲突
            for record in verificationBatch.accepted {
                if let existing = localCache[record.deviceId] {
                    let resolved = resolveConflict(local: existing, remote: record)
                    localCache[record.deviceId] = resolved
                } else {
                    localCache[record.deviceId] = record
                }
            }
            for record in verificationBatch.rejected {
                mergeRejectedLocalRecord(record)
            }

            let denialRecords = localCache.values.filter {
                $0.isTombstone || $0.lifecycleState != .active
            } + Array(rejectedLocalCache.values)
            if !denialRecords.isEmpty {
                publishTrustInvalidation(records: denialRecords)
            }
            
 // 清理过期 tombstone
            try cleanupExpiredTombstonesWithinMutation()
            
 // 更新 UI
            updateActiveTrustRecordsFromCache()
            
            syncStatus = .synced
            lastSyncTime = Date()
            
            SkyBridgeLogger.p2p.info("Trust sync completed, \(self.activeTrustRecords.count) active records")
        } catch {
            syncStatus = .failed
            throw error
        }
    }
    
    /// 清理过期 tombstone（30 天）
    public func cleanupExpiredTombstones() async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self] in
            try cleanupExpiredTombstonesWithinMutation()
        }
    }

    private func cleanupExpiredTombstonesWithinMutation() throws {

        let expiredIds = localCache.filter { $0.value.isExpired }.map { $0.key }
        
        for deviceId in expiredIds {
            try deleteFromKeychain(deviceId: deviceId)
            localCache.removeValue(forKey: deviceId)
        }
        
        if !expiredIds.isEmpty {
            SkyBridgeLogger.p2p.info("Cleaned up \(expiredIds.count) expired tombstones")
        }
    }

    
 /// Key Rotation 处理
 /// - Parameters:
 /// - oldDeviceId: 旧设备 ID
 /// - newDeviceId: 新设备 ID
 /// - newCertificate: 新证书
    public func handleKeyRotation(
        oldDeviceId: String,
        newDeviceId: String,
        newCertificate: P2PIdentityCertificate
    ) async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self, newCertificate, newDeviceId, oldDeviceId] in
            try await handleKeyRotationWithinMutation(
                oldDeviceId: oldDeviceId,
                newDeviceId: newDeviceId,
                newCertificate: newCertificate
            )
        }
    }

    private func handleKeyRotationWithinMutation(
        oldDeviceId: String,
        newDeviceId: String,
        newCertificate: P2PIdentityCertificate
    ) async throws {
        try Task.checkCancellation()

 // 撤销旧设备
        if localCache[oldDeviceId] != nil {
            _ = try await revokeVerifiedIdentityWithinMutation(
                exactDeviceIds: [oldDeviceId],
                additionalInvalidationDeviceIds: [newDeviceId]
            )
        }
        
 // 添加新设备
        let newRecord = TrustRecord(
            deviceId: newDeviceId,
            pubKeyFP: newCertificate.pubKeyFP,
            publicKey: newCertificate.publicKey,
            secureEnclavePublicKey: newCertificate.publicKey,
            kemPublicKeys: newCertificate.kemPublicKeys,
            attestationLevel: newCertificate.attestationLevel,
            attestationData: newCertificate.attestationData,
            capabilities: newCertificate.capabilities,
            signature: Data(), // 将在 addTrustRecord 中签名
            deviceName: nil
        )

        _ = try await addTrustRecordWithinMutation(newRecord)

        let oldDeviceDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(oldDeviceId)
        let newDeviceDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(newDeviceId)
        SkyBridgeLogger.p2p.info("Key rotation: \(oldDeviceDiagnosticLabel, privacy: .public) -> \(newDeviceDiagnosticLabel, privacy: .public)")
    }

    // MARK: - Conflict Resolution

    /// 解决冲突（revoke 优先 + LWW）
    public func resolveConflict(
        local: TrustRecord,
        remote: TrustRecord
    ) -> TrustRecord {
 // 1. revoke 永远优先于 add
        if local.recordType == .revoke || remote.recordType == .revoke {
            if local.recordType == .revoke && remote.recordType == .revoke {
                return local.updatedAt > remote.updatedAt ? local : remote
            }
            return local.recordType == .revoke ? local : remote
        }

 // 2. 同类型使用 LWW (Last Writer Wins)
        return local.updatedAt > remote.updatedAt ? local : remote
    }

    /// The protected mirror is a fallback, never a peer source to Keychain.
    /// A verified denial remains fail-closed, but two active copies always
    /// prefer the authoritative Keychain value even if a stale mirror carries
    /// a later timestamp.
    nonisolated static func resolveLocalPersistenceConflict(
        authoritativeKeychain: TrustRecord,
        fallback: TrustRecord
    ) -> TrustRecord {
        func isDenial(_ record: TrustRecord) -> Bool {
            record.isTombstone || record.lifecycleState != .active
        }

        let keychainDenial = isDenial(authoritativeKeychain)
        let fallbackDenial = isDenial(fallback)
        if keychainDenial != fallbackDenial {
            return keychainDenial ? authoritativeKeychain : fallback
        }
        guard keychainDenial else { return authoritativeKeychain }

        if authoritativeKeychain.isTombstone != fallback.isTombstone {
            return authoritativeKeychain.isTombstone ? authoritativeKeychain : fallback
        }
        return authoritativeKeychain.updatedAt >= fallback.updatedAt
            ? authoritativeKeychain
            : fallback
    }
    
 // MARK: - Private Methods
    
 /// 加载本地记录
    private func loadLocalRecords() async throws {
        var mergedCache: [String: TrustRecord] = [:]
        var authoritativeKeychainIds = Set<String>()
        var rejectedCache: [String: TrustRecord] = [:]
        var loadFailure: TrustSyncError?

        func mergeKeychain(_ record: TrustRecord) {
            if let existing = mergedCache[record.deviceId] {
                mergedCache[record.deviceId] = resolveConflict(local: existing, remote: record)
            } else {
                mergedCache[record.deviceId] = record
            }
            authoritativeKeychainIds.insert(record.deviceId)
        }

        func mergeFallback(_ record: TrustRecord) {
            guard let existing = mergedCache[record.deviceId] else {
                mergedCache[record.deviceId] = record
                return
            }
            if authoritativeKeychainIds.contains(record.deviceId) {
                mergedCache[record.deviceId] = Self.resolveLocalPersistenceConflict(
                    authoritativeKeychain: existing,
                    fallback: record
                )
            } else {
                mergedCache[record.deviceId] = resolveConflict(local: existing, remote: record)
            }
        }

        func reject(_ record: TrustRecord) {
            if let existing = rejectedCache[record.deviceId] {
                if existing.isTombstone {
                    return
                }
                if !record.isTombstone, existing.updatedAt >= record.updatedAt {
                    return
                }
            }
            rejectedCache[record.deviceId] = record
        }

        do {
            let records = try loadAllFromKeychain()
            let verificationBatch = try await verifiedTrustRecordsForLocalLoad(records, source: "Keychain")
            for record in verificationBatch.accepted { mergeKeychain(record) }
            for record in verificationBatch.rejected { reject(record) }
            SkyBridgeLogger.p2p.debug("Loaded \(verificationBatch.accepted.count) verified trust records from Keychain")
        } catch {
            if let trustError = error as? TrustSyncError,
               case .keychainError(let status) = trustError,
               shouldMirrorTrustRecordAfterKeychainFailure(status) {
                SkyBridgeLogger.p2p.warning("⚠️ Trust records keychain unavailable (\(status)); loading protected local trust mirror")
            } else {
                SkyBridgeLogger.p2p.error(
                    "Failed to load trust records: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
            }
            loadFailure = (error as? TrustSyncError) ?? .localTrustStoreUnavailable
        }

        do {
            let fallbackRecords = try loadFallbackRecords()
            let verificationBatch = try await verifiedTrustRecordsForLocalLoad(
                fallbackRecords,
                source: "protected local trust mirror"
            )
            for record in verificationBatch.accepted { mergeFallback(record) }
            for record in verificationBatch.rejected { reject(record) }
            if !verificationBatch.accepted.isEmpty {
                SkyBridgeLogger.p2p.debug("Loaded \(verificationBatch.accepted.count) verified trust records from fallback storage")
            }
        } catch {
            loadFailure = loadFailure ?? (error as? TrustSyncError) ?? .localTrustStoreUnavailable
            SkyBridgeLogger.p2p.error("Failed to load protected local trust mirror: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
        }

        if let loadFailure {
            syncStatus = .failed
            throw loadFailure
        }
        localCache = mergedCache
        rejectedLocalCache = rejectedCache
        updateActiveTrustRecordsFromCache()
    }

    private struct TrustRecordVerificationBatch {
        var accepted: [TrustRecord] = []
        var rejected: [TrustRecord] = []
    }

    private func verifiedTrustRecordsForLocalLoad(
        _ records: [TrustRecord],
        source: String
    ) async throws -> TrustRecordVerificationBatch {
        var batch = TrustRecordVerificationBatch()
        batch.accepted.reserveCapacity(records.count)
        batch.rejected.reserveCapacity(records.count)
        for record in records {
            try Task.checkCancellation()
            let isValid: Bool
            do {
                isValid = try await verifyRecordSignature(record)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                SkyBridgeLogger.p2p.warning(
                    "Rejected \(source, privacy: .public) trust record during local load: reason=verification_error error=\(error.localizedDescription, privacy: .private) device=redacted"
                )
                throw TrustSyncError.verificationFailed
            }
            guard isValid else {
                SkyBridgeLogger.p2p.warning(
                    "Rejected \(source, privacy: .public) trust record during local load: reason=invalid_signature device=redacted"
                )
                batch.rejected.append(record)
                continue
            }
            batch.accepted.append(record)
        }
        return batch
    }

    private func mergeRejectedLocalRecord(_ record: TrustRecord) {
        if let existing = rejectedLocalCache[record.deviceId] {
            if existing.isTombstone {
                return
            }
            if !record.isTombstone, existing.updatedAt >= record.updatedAt {
                return
            }
        }
        rejectedLocalCache[record.deviceId] = record
    }
    
    /// 更新活跃信任记录
    private func activeTrustRecordsSnapshot() -> [TrustRecord] {
        localCache.values.filter {
            $0.isAuthenticationEligible && denialConflict(for: $0) == nil
        }
    }

    private func updateActiveTrustRecordsFromCache() {
        activeTrustRecords = activeTrustRecordsSnapshot()
        var repairRecordsById: [String: TrustRecord] = [:]
        for record in localCache.values where !record.isExpired && !record.isTombstone {
            guard record.lifecycleState == .quarantined
                    || record.lifecycleState == .reverificationRequired else {
                continue
            }
            repairRecordsById[record.deviceId] = trustRepairPresentationRecord(record)
        }
        for record in rejectedLocalCache.values {
            repairRecordsById[record.deviceId] = trustRepairPresentationRecord(record)
        }
        trustRepairRecords = repairRecordsById.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.deviceId < $1.deviceId
        }
    }

    private func trustRepairPresentationRecord(_ record: TrustRecord) -> TrustRecord {
        // This is a management-only projection. Rejected records have not
        // authenticated any alias, key, capability, or attestation metadata,
        // so none of those fields may expand a destructive UI action.
        return TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: "",
            publicKey: Data(),
            capabilities: ["trust_repair_required"],
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signature: Data(),
            recordType: .add,
            revokedAt: nil,
            deviceName: nil,
            lifecycleState: .quarantined
        )
    }

    private func recordUsingCurrentSignaturePayload(_ record: TrustRecord) -> TrustRecord {
        TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            protocolSigningAlgorithm: record.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint,
            protocolIdentityPins: record.protocolIdentityPins,
            legacyP256PublicKey: record.legacyP256PublicKey,
            signatureAlgorithm: record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: record.attestationData,
            capabilities: record.capabilities,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signaturePayloadVersion: TrustRecord.currentSignaturePayloadVersion,
            signature: record.signature,
            recordType: record.recordType,
            revokedAt: record.revokedAt,
            deviceName: record.deviceName,
            currentDeviceId: record.currentDeviceIdMetadata,
            knownDeviceIds: record.knownDeviceIdsMetadata,
            lifecycleState: record.lifecycleStateMetadata
        )
    }
    
 /// 签名记录
    private func signRecord(_ record: TrustRecord) async throws -> TrustRecord {
        let signableRecord = recordUsingCurrentSignaturePayload(record)
#if DEBUG
        if usesInMemoryPersistenceForTesting {
            return TrustRecord(
                deviceId: signableRecord.deviceId,
                pubKeyFP: signableRecord.pubKeyFP,
                publicKey: signableRecord.publicKey,
                secureEnclavePublicKey: signableRecord.secureEnclavePublicKey,
                protocolPublicKey: signableRecord.protocolPublicKey,
                protocolSigningAlgorithm: signableRecord.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: signableRecord.protocolPublicKeyFingerprint,
                protocolIdentityPins: signableRecord.protocolIdentityPins,
                legacyP256PublicKey: signableRecord.legacyP256PublicKey,
                signatureAlgorithm: signableRecord.signatureAlgorithm,
                kemPublicKeys: signableRecord.kemPublicKeys,
                attestationLevel: signableRecord.attestationLevel,
                attestationData: signableRecord.attestationData,
                capabilities: signableRecord.capabilities,
                createdAt: signableRecord.createdAt,
                updatedAt: signableRecord.updatedAt,
                version: signableRecord.version,
                signaturePayloadVersion: signableRecord.signaturePayloadVersion,
                signature: signableRecord.signature.isEmpty ? Data(repeating: 0xAA, count: 64) : signableRecord.signature,
                recordType: signableRecord.recordType,
                revokedAt: signableRecord.revokedAt,
                deviceName: signableRecord.deviceName,
                currentDeviceId: signableRecord.currentDeviceIdMetadata,
                knownDeviceIds: signableRecord.knownDeviceIdsMetadata,
                lifecycleState: signableRecord.lifecycleStateMetadata
            )
        }
#endif

        let dataToSign = try createDataToSign(for: signableRecord, revoked: false)
        let signature = try await keyManager.sign(data: dataToSign)

        return TrustRecord(
            deviceId: signableRecord.deviceId,
            pubKeyFP: signableRecord.pubKeyFP,
            publicKey: signableRecord.publicKey,
            secureEnclavePublicKey: signableRecord.secureEnclavePublicKey,
            protocolPublicKey: signableRecord.protocolPublicKey,
            protocolSigningAlgorithm: signableRecord.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: signableRecord.protocolPublicKeyFingerprint,
            protocolIdentityPins: signableRecord.protocolIdentityPins,
            legacyP256PublicKey: signableRecord.legacyP256PublicKey,
            signatureAlgorithm: signableRecord.signatureAlgorithm,
            kemPublicKeys: signableRecord.kemPublicKeys,
            attestationLevel: signableRecord.attestationLevel,
            attestationData: signableRecord.attestationData,
            capabilities: signableRecord.capabilities,
            createdAt: signableRecord.createdAt,
            updatedAt: signableRecord.updatedAt,
            version: signableRecord.version,
            signaturePayloadVersion: signableRecord.signaturePayloadVersion,
            signature: signature,
            recordType: signableRecord.recordType,
            revokedAt: signableRecord.revokedAt,
            deviceName: signableRecord.deviceName,
            currentDeviceId: signableRecord.currentDeviceIdMetadata,
            knownDeviceIds: signableRecord.knownDeviceIdsMetadata,
            lifecycleState: signableRecord.lifecycleStateMetadata
        )
    }

 /// 更新信任记录
    private func updateTrustRecordWithinMutation(
        _ record: TrustRecord,
        pairingCommitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> TrustRecord {
        try await validatePairingAuthorityCommit(pairingCommitValidator)

        guard let existing = localCache[record.deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        
        let updatedRecord = TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            protocolSigningAlgorithm: record.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint,
            protocolIdentityPins: record.protocolIdentityPins,
            legacyP256PublicKey: record.legacyP256PublicKey,
            signatureAlgorithm: record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: record.attestationData,
            capabilities: record.capabilities,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            version: existing.version + 1,
            signature: Data(), // 将被签名
            recordType: .add,
            revokedAt: nil,
            deviceName: record.deviceName,
            currentDeviceId: record.currentDeviceIdMetadata,
            knownDeviceIds: record.knownDeviceIdsMetadata,
            lifecycleState: record.lifecycleStateMetadata
        )
        
        let signedRecord = try await signRecord(updatedRecord)
        try await validatePairingAuthorityCommitAfterSigning(pairingCommitValidator)
        let postCommitError: TrustSyncError?
#if DEBUG
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(
                signedRecord,
                synchronizable: isSyncAvailable
            )
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(
            signedRecord,
            synchronizable: isSyncAvailable
        )
#endif
        localCache[signedRecord.deviceId] = signedRecord
        
        updateActiveTrustRecordsFromCache()
        if let postCommitError {
            throw postCommitError
        }
        return signedRecord
    }
    
 /// 创建待签名数据
    private func createDataToSign(for record: TrustRecord, revoked: Bool) throws -> Data {
        if record.signaturePayloadVersion == TrustRecord.currentSignaturePayloadVersion {
            return try createCompleteDataToSign(for: record, revoked: revoked)
        }
        guard record.signaturePayloadVersion == nil else {
            throw TrustSyncError.encodingError("unsupported trust signature payload version")
        }
        return try createDataToSign(
            for: record,
            revoked: revoked,
            includeProtocolIdentityPins: true
        )
    }

    /// Complete v2 trust payload. Every persisted field that can affect
    /// authentication, revocation, expiry, migration, or trust presentation is
    /// covered, with explicit optional-value framing supplied by the encoder.
    private func createCompleteDataToSign(for record: TrustRecord, revoked: Bool) throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode("SKYBRIDGE-TRUST-RECORD")
        encoder.encode(Int64(TrustRecord.currentSignaturePayloadVersion))
        encoder.encode(record.deviceId)
        encoder.encode(record.pubKeyFP)
        encoder.encode(record.publicKey)
        encoder.encode(record.secureEnclavePublicKey) { enc, value in enc.encode(value) }
        encoder.encode(record.protocolPublicKey) { enc, value in enc.encode(value) }
        encoder.encode(record.protocolSigningAlgorithm?.rawValue) { enc, value in enc.encode(value) }
        encoder.encode(record.protocolPublicKeyFingerprint?.lowercased()) { enc, value in enc.encode(value) }
        encoder.encode(record.protocolIdentityPins) { enc, pins in
            let normalizedPins = TrustRecord.normalizedProtocolIdentityPins(
                pins,
                legacyFingerprint: nil,
                legacyAlgorithm: nil,
                approvedAt: record.updatedAt
            ) ?? []
            enc.encode(normalizedPins, encoder: { inner, pin in
                inner.encode(pin.algorithm.rawValue)
                inner.encode(pin.fingerprint)
                inner.encode(pin.approvedAt)
                inner.encode(pin.source.rawValue)
            })
        }
        encoder.encode(record.legacyP256PublicKey) { enc, value in enc.encode(value) }
        encoder.encode(record.signatureAlgorithm?.rawValue) { enc, value in enc.encode(value) }
        encoder.encode(record.kemPublicKeys, encoder: { enc, keys in
            let sorted = keys.sorted { $0.suiteWireId < $1.suiteWireId }
            enc.encode(sorted, encoder: { inner, key in
                inner.encode(key.suiteWireId)
                inner.encode(key.publicKey)
            })
        })
        encoder.encode(UInt8(record.attestationLevel.rawValue))
        encoder.encode(record.attestationData) { enc, value in enc.encode(value) }
        encoder.encode(record.capabilities)
        encoder.encode(record.createdAt)
        encoder.encode(record.updatedAt)
        encoder.encode(Int64(record.version))
        encoder.encode(record.recordType.rawValue)
        encoder.encode(record.revokedAt) { enc, value in enc.encode(value) }
        encoder.encode(record.deviceName) { enc, value in enc.encode(value) }
        encoder.encode(record.currentDeviceIdMetadata) { enc, value in enc.encode(value) }
        encoder.encode(canonicalKnownDeviceIds(for: record)) { enc, values in enc.encode(values) }
        encoder.encode(record.lifecycleStateMetadata?.rawValue) { enc, value in enc.encode(value) }
        encoder.encode(revoked ? "revoke" : "add")
        return encoder.finalize()
    }

    private func createDataToSign(
        for record: TrustRecord,
        revoked: Bool,
        includeProtocolIdentityPins: Bool
    ) throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(record.deviceId)
        encoder.encode(record.pubKeyFP)
        encoder.encode(record.publicKey)
        if let seKey = record.secureEnclavePublicKey {
            encoder.encode(seKey)
        }
        encoder.encode(record.protocolPublicKey) { enc, value in
            enc.encode(value)
        }
        encoder.encode(record.protocolSigningAlgorithm?.rawValue) { enc, value in
            enc.encode(value)
        }
        encoder.encode(record.protocolPublicKeyFingerprint?.lowercased()) { enc, value in
            enc.encode(value)
        }
        if includeProtocolIdentityPins {
            encoder.encode(record.protocolIdentityPins) { enc, pins in
                let normalizedPins = TrustRecord.normalizedProtocolIdentityPins(
                    pins,
                    legacyFingerprint: nil,
                    legacyAlgorithm: nil,
                    approvedAt: record.updatedAt
                ) ?? []
                enc.encode(normalizedPins, encoder: { inner, pin in
                    inner.encode(pin.algorithm.rawValue)
                    inner.encode(pin.fingerprint)
                    inner.encode(pin.approvedAt)
                    inner.encode(pin.source.rawValue)
                })
            }
        }
        encoder.encode(record.kemPublicKeys, encoder: { enc, keys in
            let sorted = keys.sorted { $0.suiteWireId < $1.suiteWireId }
            enc.encode(sorted, encoder: { inner, key in
                inner.encode(key.suiteWireId)
                inner.encode(key.publicKey)
            })
        })
        encoder.encode(UInt8(record.attestationLevel.rawValue))
        encoder.encode(record.capabilities)
        encoder.encode(record.currentDeviceIdMetadata) { enc, value in
            enc.encode(value)
        }
        encoder.encode(canonicalKnownDeviceIds(for: record)) { enc, values in
            enc.encode(values)
        }
        encoder.encode(record.lifecycleStateMetadata?.rawValue) { enc, value in
            enc.encode(value)
        }
        encoder.encode(record.createdAt)
        encoder.encode(record.updatedAt)
        encoder.encode(Int64(record.version))
        encoder.encode(revoked ? "revoke" : "add")
        return encoder.finalize()
    }

    private func createLegacyDataToSign(for record: TrustRecord, revoked: Bool) throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(record.deviceId)
        encoder.encode(record.pubKeyFP)
        encoder.encode(record.publicKey)
        if let seKey = record.secureEnclavePublicKey {
            encoder.encode(seKey)
        }
        encoder.encode(record.kemPublicKeys, encoder: { enc, keys in
            let sorted = keys.sorted { $0.suiteWireId < $1.suiteWireId }
            enc.encode(sorted, encoder: { inner, key in
                inner.encode(key.suiteWireId)
                inner.encode(key.publicKey)
            })
        })
        encoder.encode(UInt8(record.attestationLevel.rawValue))
        encoder.encode(record.capabilities)
        encoder.encode(record.createdAt)
        encoder.encode(record.updatedAt)
        encoder.encode(Int64(record.version))
        encoder.encode(revoked ? "revoke" : "add")
        return encoder.finalize()
    }

    private func canonicalKnownDeviceIds(for record: TrustRecord) -> [String]? {
        guard let knownDeviceIds = record.knownDeviceIdsMetadata, !knownDeviceIds.isEmpty else {
            return nil
        }
        return Array(Set(knownDeviceIds)).sorted()
    }
    
 // MARK: - Keychain Operations
    
 /// 保存到 Keychain
    private func saveToKeychain(
        _ record: TrustRecord,
        synchronizable: Bool
    ) throws -> TrustSyncError? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)

        var matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + record.deviceId,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        Self.forbidKeychainAuthenticationUI(&matchQuery)

        let updateStatus = SecItemUpdate(
            matchQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return fallbackCleanupErrorAfterAuthoritativeCommit(deviceId: record.deviceId)
        }

        if updateStatus != errSecItemNotFound {
            if shouldMirrorTrustRecordAfterKeychainFailure(updateStatus) {
                try upsertFallbackRecord(record)
                let recordDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(record.deviceId)
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Trust record keychain update unavailable (\(updateStatus)); persisted to protected local trust mirror: \(recordDiagnosticLabel, privacy: .public)"
                )
                return nil
            }
            throw TrustSyncError.keychainError(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + record.deviceId,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        Self.forbidKeychainAuthenticationUI(&addQuery)

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return fallbackCleanupErrorAfterAuthoritativeCommit(deviceId: record.deviceId)
        }

        if shouldMirrorTrustRecordAfterKeychainFailure(addStatus) {
            try upsertFallbackRecord(record)
            let recordDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(record.deviceId)
            SkyBridgeLogger.p2p.warning(
                "⚠️ Trust record keychain add unavailable (\(addStatus)); persisted to protected local trust mirror: \(recordDiagnosticLabel, privacy: .public)"
            )
            return nil
        }

        throw TrustSyncError.keychainError(addStatus)
    }

    private func fallbackCleanupErrorAfterAuthoritativeCommit(
        deviceId: String
    ) -> TrustSyncError? {
        do {
            try removeFallbackRecord(deviceId: deviceId)
            return nil
        } catch {
            syncStatus = .failed
            SkyBridgeLogger.p2p.error(
                "Authoritative trust record committed, but stale fallback cleanup failed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            return .fallbackCleanupFailedAfterAuthoritativeCommit(
                SkyBridgeDiagnosticRedaction.errorSummary(error)
            )
        }
    }
    
 /// 从 Keychain 加载所有记录
    private func loadAllFromKeychain() throws -> [TrustRecord] {
        func copyItems(_ inputQuery: [String: Any]) throws -> [[String: Any]] {
            var query = inputQuery
            Self.forbidKeychainAuthenticationUI(&query)
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            guard status == errSecSuccess else {
                throw TrustSyncError.keychainError(status)
            }
            guard let items = result as? [[String: Any]] else {
                throw TrustSyncError.decodingError("Keychain returned an unexpected item shape")
            }
            return items
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        // 首选：一次性拉取所有（含 synchronizable true/false）。
        // 在部分系统/环境下，kSecAttrSynchronizableAny 会返回
        // errSecParam(-50)，因此降级为分别查询同步和非同步项。每条查询
        // 始终保留 account attribute，防止 payload deviceId 与真实存储键错配。
        var items: [[String: Any]] = []
        do {
            var q = baseQuery
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            items = try copyItems(q)
        } catch let TrustSyncError.keychainError(status) where status == errSecParam {
            // 降级：分别拉取 non-sync 和 sync 项，再合并去重
            var nonSync = baseQuery
            nonSync[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            var sync = baseQuery
            sync[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
            let nonSynchronizableItems = try copyItems(nonSync)
            let synchronizableItems = try copyItems(sync)
            // Preserve both copies. Conflict resolution after authenticated
            // decoding must see a tombstone instead of dropping one by account.
            items = nonSynchronizableItems + synchronizableItems
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        return try items.enumerated().map { index, item in
            guard let data = item[kSecValueData as String] as? Data else {
                throw TrustSyncError.decodingError("Keychain item \(index) is missing value data")
            }
            guard let account = item[kSecAttrAccount as String] as? String else {
                throw TrustSyncError.decodingError("Keychain item \(index) is missing account identity")
            }
            let record: TrustRecord
            do {
                record = try decoder.decode(TrustRecord.self, from: data)
            } catch {
                throw TrustSyncError.decodingError("Keychain trust record \(index): \(error.localizedDescription)")
            }
            guard Self.keychainAccount(account, matchesRecordDeviceId: record.deviceId) else {
                throw TrustSyncError.decodingError("Keychain trust record account does not match payload identity")
            }
            return record
        }
    }

    nonisolated static func keychainAccount(_ account: String, matchesRecordDeviceId deviceId: String) -> Bool {
        account == KeychainConstants.recordPrefix + deviceId
    }
    
    private func decodeTrustRecords(from dataItems: [Data], decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }(), source: String = "unknown") throws -> [TrustRecord] {
        var records: [TrustRecord] = []
        records.reserveCapacity(dataItems.count)
        for (index, data) in dataItems.enumerated() {
            do {
                let record = try decoder.decode(TrustRecord.self, from: data)
                records.append(record)
            } catch {
                SkyBridgeLogger.p2p.warning(
                    "Rejected malformed \(source, privacy: .public) trust record during local load: index=\(index, privacy: .public) bytes=\(data.count, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                throw TrustSyncError.decodingError("trust record index \(index): \(error.localizedDescription)")
            }
        }
        return records
    }
    
    /// 从 Keychain 删除记录
    private func deleteFromKeychain(deviceId: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + deviceId,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        Self.forbidKeychainAuthenticationUI(&query)
        try Self.performMonotonicTrustDeletion(
            removeProtectedFallback: { [self] in
                try removeFallbackRecord(deviceId: deviceId)
            },
            deleteAuthoritativeKeychainRecord: {
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    /// Deletes the lower-authority mirror first. If that fallible operation
    /// fails, the authoritative Keychain item is left untouched. Once the
    /// mirror is gone, a Keychain failure can leave only the same or less
    /// authorization and is surfaced to the caller for retry.
    static func performMonotonicTrustDeletion(
        removeProtectedFallback: () throws -> Void,
        deleteAuthoritativeKeychainRecord: () -> OSStatus
    ) throws {
        try removeProtectedFallback()
        let status = deleteAuthoritativeKeychainRecord()
        guard isConfirmedKeychainDeletionStatus(status) else {
            throw TrustSyncError.keychainError(status)
        }
    }

    nonisolated static func isConfirmedKeychainDeletionStatus(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    private func isKeychainEntitlementUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == -34018
    }

    private func shouldMirrorTrustRecordAfterKeychainFailure(_ status: OSStatus) -> Bool {
        isKeychainEntitlementUnavailable(status) || status == errSecInteractionNotAllowed
    }

    private func loadFallbackRecords() throws -> [TrustRecord] {
        try Self.protectedFallbackRecordStore.loadOrThrow() ?? []
    }

    private func storeFallbackRecords(_ records: [TrustRecord]) throws {
        do {
            try Self.protectedFallbackRecordStore.save(records)
        } catch {
            SkyBridgeLogger.p2p.error(
                "Failed to persist protected local trust mirror: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            throw error
        }
    }

    private func upsertFallbackRecord(_ record: TrustRecord) throws {
        var records = try loadFallbackRecords()
        if let index = records.firstIndex(where: { $0.deviceId == record.deviceId }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try storeFallbackRecords(records)
    }

    private func removeFallbackRecord(deviceId: String) throws {
        var records = try loadFallbackRecords()
        let originalCount = records.count
        records.removeAll { $0.deviceId == deviceId }
        guard records.count != originalCount else { return }
        if records.isEmpty {
            try Self.protectedFallbackRecordStore.remove()
        } else {
            try storeFallbackRecords(records)
        }
    }

#if DEBUG
    func beginInMemoryPersistenceForTesting() async {
        if inMemoryPersistenceLeaseCountForTesting == 0 {
            await awaitInitialLoadCompletion()
            initialLoadTaskBeforeInMemoryTesting = initialLoadTask
            initialLoadTask = Task { @MainActor in .success(()) }
        }
        inMemoryPersistenceLeaseCountForTesting += 1
    }

    func endInMemoryPersistenceForTesting() {
        precondition(
            inMemoryPersistenceLeaseCountForTesting > 0,
            "in-memory trust persistence lease underflow"
        )
        inMemoryPersistenceLeaseCountForTesting -= 1
        if inMemoryPersistenceLeaseCountForTesting == 0 {
            initialLoadTask = initialLoadTaskBeforeInMemoryTesting
            initialLoadTaskBeforeInMemoryTesting = nil
        }
    }

    func removeRecordsForTesting(deviceIds: [String]) async {
        await awaitInitialLoadCompletion()

        let normalizedDeviceIds = Set(
            deviceIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard !normalizedDeviceIds.isEmpty else { return }

        do {
            try await mutationGate.run { [self, normalizedDeviceIds] in
                for deviceId in normalizedDeviceIds {
                    if !usesInMemoryPersistenceForTesting {
                        try deleteFromKeychain(deviceId: deviceId)
                    }
                    localCache.removeValue(forKey: deviceId)
                    rejectedLocalCache.removeValue(forKey: deviceId)
                }

                updateActiveTrustRecordsFromCache()
            }
        } catch {
            preconditionFailure("failed to remove trust record for testing: \(error)")
        }
    }

    func rawTrustRecordForTesting(deviceId: String) async -> TrustRecord? {
        await awaitInitialLoadCompletion()
        return localCache[deviceId]
    }
#endif
    
    private func hasSafeLegacyV1UnsignedFields(_ record: TrustRecord) -> Bool {
        guard record.signaturePayloadVersion == nil,
              record.legacyP256PublicKey == nil,
              record.signatureAlgorithm == nil,
              record.attestationData == nil else {
            return false
        }
        if record.isTombstone {
            guard let revokedAt = record.revokedAt,
                  abs(revokedAt.timeIntervalSince(record.updatedAt)) < 0.001,
                  record.lifecycleState == .revoked else {
                return false
            }
        } else if record.revokedAt != nil {
            return false
        }
        return true
    }

    private func hasSafePreMultiPinLegacyFields(_ record: TrustRecord) -> Bool {
        guard hasSafeLegacyV1UnsignedFields(record) else { return false }
        return record.protocolIdentityPins?.isEmpty != false
    }

    private func hasSafeOriginalLegacyFields(_ record: TrustRecord) -> Bool {
        guard hasSafePreMultiPinLegacyFields(record),
              record.protocolPublicKey == nil,
              record.protocolSigningAlgorithm == nil,
              record.protocolPublicKeyFingerprint == nil,
              record.currentDeviceIdMetadata == nil,
              record.knownDeviceIdsMetadata?.isEmpty != false,
              record.lifecycleStateMetadata == nil else {
            return false
        }
        return true
    }

    /// 验证记录签名
    public func verifyRecordSignature(_ record: TrustRecord) async throws -> Bool {
        guard let identityKey = try await keyManager.existingIdentityKeyInfoStrict() else {
            throw TrustSyncError.verificationFailed
        }
        let signerPublicKey = identityKey.publicKey
        if record.signaturePayloadVersion == TrustRecord.currentSignaturePayloadVersion {
            let completePayload = try createDataToSign(for: record, revoked: record.isTombstone)
            return try await keyManager.verify(
                data: completePayload,
                signature: record.signature,
                publicKey: signerPublicKey
            )
        }
        guard record.signaturePayloadVersion == nil,
              hasSafeLegacyV1UnsignedFields(record) else { return false }

        let currentPayload = try createDataToSign(for: record, revoked: record.isTombstone)
        if try await keyManager.verify(
            data: currentPayload,
            signature: record.signature,
            publicKey: signerPublicKey
        ) {
            return true
        }

        if hasSafePreMultiPinLegacyFields(record) {
            let preMultiPinPayload = try createDataToSign(
                for: record,
                revoked: record.isTombstone,
                includeProtocolIdentityPins: false
            )
            if try await keyManager.verify(
                data: preMultiPinPayload,
                signature: record.signature,
                publicKey: signerPublicKey
            ) {
                return true
            }
        }

        guard hasSafeOriginalLegacyFields(record) else { return false }
        let legacyPayload = try createLegacyDataToSign(for: record, revoked: record.isTombstone)
        return try await keyManager.verify(
            data: legacyPayload,
            signature: record.signature,
            publicKey: signerPublicKey
        )
    }
}
