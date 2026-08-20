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

/// Versioned, forward-compatible protocol-identity authority binding.
///
/// The algorithm, source, and state are deliberately persisted as raw strings.
/// Older SkyBridge builds ignore this entire sidecar as an unknown JSON field,
/// while newer builds can preserve future values without asking a legacy enum
/// decoder to understand them. In particular, ML-DSA-87 must never be written
/// into `protocolSigningAlgorithm` or `protocolIdentityPins`, whose enum values
/// are part of the legacy record contract.
public struct ProtocolIdentityBindingV2: Codable, Sendable, Equatable, Hashable {
    public static let schemaVersion = 2
    public static let activeState = "active"

    public let version: Int
    public let algorithm: String
    public let publicKey: Data
    public let fingerprint: String
    public let source: String
    public let approvedAt: Date
    public let generation: UInt64
    public let state: String

    public init(
        algorithm: ProtocolSigningAlgorithm,
        publicKey: Data,
        fingerprint: String,
        source: ProtocolIdentityPinSource,
        approvedAt: Date = Date(),
        generation: UInt64,
        state: String = ProtocolIdentityBindingV2.activeState
    ) {
        self.version = Self.schemaVersion
        self.algorithm = algorithm.rawValue
        self.publicKey = publicKey
        self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.source = source.rawValue
        self.approvedAt = approvedAt
        self.generation = generation
        self.state = state
    }

    public var protocolSigningAlgorithm: ProtocolSigningAlgorithm? {
        ProtocolSigningAlgorithm(rawValue: algorithm)
    }

    public var pinSource: ProtocolIdentityPinSource? {
        ProtocolIdentityPinSource(rawValue: source)
    }
}

// MARK: - Trust Record

/// 信任记录
public struct TrustRecord: Codable, Sendable, Equatable, Identifiable {
    /// Version of the deterministic payload covered by `signature`.
    /// A nil value identifies a record written before the complete payload was
    /// introduced and is accepted only when every historically unsigned
    /// security field remains in its safe legacy state.
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
    public let protocolIdentityBindingsV2: [ProtocolIdentityBindingV2]?

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

    /// Deterministic signature schema. Optional for decoding historical records.
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
        // updatedAt was covered by every historical signature schema. An old
        // record's unbound revokedAt must never shorten tombstone retention.
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
        guard Self.protocolIdentityBindingMapV2(protocolIdentityBindingsV2) != nil else {
            return []
        }
        let legacyPins = Self.normalizedProtocolIdentityPins(
            protocolIdentityPins,
            legacyFingerprint: protocolPublicKeyFingerprint,
            legacyAlgorithm: protocolSigningAlgorithm,
            approvedAt: updatedAt
        ) ?? []
        let v2Pins = Self.validProtocolIdentityBindingsV2(protocolIdentityBindingsV2).compactMap { binding -> ProtocolIdentityPin? in
            guard let algorithm = binding.protocolSigningAlgorithm,
                  let source = binding.pinSource else {
                return nil
            }
            return ProtocolIdentityPin(
                algorithm: algorithm,
                fingerprint: binding.fingerprint,
                approvedAt: binding.approvedAt,
                source: source
            )
        }
        return Self.normalizedProtocolIdentityPins(
            legacyPins + v2Pins,
            legacyFingerprint: nil,
            legacyAlgorithm: nil,
            approvedAt: updatedAt,
            includeMLDSA87: true
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
        guard Self.protocolIdentityBindingMapV2(protocolIdentityBindingsV2) != nil else {
            return nil
        }

        if let protocolAlgorithm = ProtocolSigningAlgorithm(from: algorithm),
           let binding = activeProtocolIdentityBindingV2(for: protocolAlgorithm) {
            return binding.publicKey
        }

        switch algorithm {
        case .ed25519, .mlDSA65:
            guard let expectedAlgorithm = ProtocolSigningAlgorithm(from: algorithm) else {
                return nil
            }
            return legacyVerificationPublicKey(for: expectedAlgorithm)
        case .mlDSA87:
            // ML-DSA-87 authority exists only in the v2 raw-string sidecar so an
            // older decoder never encounters an unknown legacy enum value.
            return nil
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
        protocolIdentityBindingsV2: [ProtocolIdentityBindingV2]? = nil,
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
        self.protocolIdentityBindingsV2 = protocolIdentityBindingsV2
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
            protocolIdentityBindingsV2: protocolIdentityBindingsV2,
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

    private static func expectedProtocolPublicKeyLength(
        for algorithm: ProtocolSigningAlgorithm
    ) -> Int {
        switch algorithm {
        case .ed25519:
            return 32
        case .mlDSA65:
            return 1_952
        case .mlDSA87:
            return 2_592
        }
    }

    private static func validatedProtocolPublicKey(
        _ publicKey: Data,
        algorithm: ProtocolSigningAlgorithm,
        fingerprint: String?
    ) -> Data? {
        guard publicKey.count == expectedProtocolPublicKeyLength(for: algorithm) else {
            return nil
        }
        guard let fingerprint else { return publicKey }
        guard let normalizedFingerprint = normalizedProtocolFingerprint(fingerprint) else {
            return nil
        }
        let computedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: algorithm,
            publicKeyBytes: publicKey
        )
        return computedFingerprint == normalizedFingerprint ? publicKey : nil
    }

    private static func validatedProtocolIdentityBindingV2(
        _ binding: ProtocolIdentityBindingV2
    ) -> ProtocolIdentityBindingV2? {
        guard binding.version == ProtocolIdentityBindingV2.schemaVersion,
              binding.state == ProtocolIdentityBindingV2.activeState,
              binding.generation > 0,
              binding.approvedAt.timeIntervalSinceReferenceDate.isFinite,
              let algorithm = binding.protocolSigningAlgorithm,
              binding.pinSource != nil,
              binding.fingerprint == binding.fingerprint.lowercased(),
              validatedProtocolPublicKey(
                binding.publicKey,
                algorithm: algorithm,
                fingerprint: binding.fingerprint
              ) != nil else {
            return nil
        }
        return binding
    }

    /// Returns unambiguous, fully validated active v2 authorities. Unknown
    /// versions, algorithms, and non-active states remain forward-compatible
    /// metadata. A malformed active binding or a same-algorithm key conflict
    /// rejects the whole authority map instead of partially authenticating it.
    private static func protocolIdentityBindingMapV2(
        _ bindings: [ProtocolIdentityBindingV2]?
    ) -> [ProtocolSigningAlgorithm: ProtocolIdentityBindingV2]? {
        var bindingByAlgorithm: [ProtocolSigningAlgorithm: ProtocolIdentityBindingV2] = [:]

        for candidate in bindings ?? [] {
            guard candidate.version == ProtocolIdentityBindingV2.schemaVersion,
                  candidate.state == ProtocolIdentityBindingV2.activeState,
                  let algorithm = candidate.protocolSigningAlgorithm else {
                continue
            }
            guard let binding = validatedProtocolIdentityBindingV2(candidate) else {
                return nil
            }
            if let existing = bindingByAlgorithm[algorithm] {
                guard existing.publicKey == binding.publicKey,
                      existing.fingerprint == binding.fingerprint else {
                    return nil
                }
                if binding.generation > existing.generation {
                    bindingByAlgorithm[algorithm] = binding
                }
            } else {
                bindingByAlgorithm[algorithm] = binding
            }
        }

        return bindingByAlgorithm
    }

    private static func validProtocolIdentityBindingsV2(
        _ bindings: [ProtocolIdentityBindingV2]?
    ) -> [ProtocolIdentityBindingV2] {
        guard let bindingMap = protocolIdentityBindingMapV2(bindings) else {
            return []
        }
        return bindingMap.values.sorted { lhs, rhs in
            lhs.algorithm < rhs.algorithm
        }
    }

    private func activeProtocolIdentityBindingV2(
        for algorithm: ProtocolSigningAlgorithm
    ) -> ProtocolIdentityBindingV2? {
        Self.validProtocolIdentityBindingsV2(protocolIdentityBindingsV2).first {
            $0.protocolSigningAlgorithm == algorithm
        }
    }

    /// Returns a raw-key authority only when this record can currently
    /// authenticate and the v2 sidecar contains one unambiguous active binding.
    public func authenticatedProtocolIdentityBinding(
        for algorithm: ProtocolSigningAlgorithm
    ) -> ProtocolIdentityBindingV2? {
        guard isAuthenticationEligible else { return nil }
        guard Self.protocolIdentityBindingMapV2(protocolIdentityBindingsV2) != nil else {
            return nil
        }
        return activeProtocolIdentityBindingV2(for: algorithm)
    }

    private func legacyVerificationPublicKey(
        for expectedAlgorithm: ProtocolSigningAlgorithm
    ) -> Data? {
        guard expectedAlgorithm != .mlDSA87 else { return nil }

        let declaredAlgorithm: ProtocolSigningAlgorithm?
        if let protocolSigningAlgorithm {
            declaredAlgorithm = protocolSigningAlgorithm
        } else if let signatureAlgorithm {
            declaredAlgorithm = ProtocolSigningAlgorithm(from: signatureAlgorithm)
        } else if expectedAlgorithm == .ed25519 {
            // Records predating the protocol-algorithm field used a 32-byte
            // Ed25519 `publicKey`. No equivalent untyped fallback is safe for
            // either ML-DSA parameter set.
            declaredAlgorithm = .ed25519
        } else {
            declaredAlgorithm = nil
        }

        guard declaredAlgorithm == expectedAlgorithm else { return nil }
        let candidate = protocolPublicKey ?? publicKey
        return Self.validatedProtocolPublicKey(
            candidate,
            algorithm: expectedAlgorithm,
            fingerprint: protocolPublicKeyFingerprint
        )
    }

    public static func normalizedProtocolIdentityPins(
        _ pins: [ProtocolIdentityPin]?,
        legacyFingerprint: String?,
        legacyAlgorithm: ProtocolSigningAlgorithm?,
        approvedAt: Date,
        includeMLDSA87: Bool = false
    ) -> [ProtocolIdentityPin]? {
        var pinsByAlgorithm: [ProtocolSigningAlgorithm: ProtocolIdentityPin] = [:]

        func upsert(_ pin: ProtocolIdentityPin) {
            guard includeMLDSA87 || pin.algorithm != .mlDSA87 else { return }
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
           (includeMLDSA87 || legacyAlgorithm != .mlDSA87),
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
        guard algorithm != .mlDSA87 else {
            return normalizedProtocolIdentityPins(
                pins,
                legacyFingerprint: legacyFingerprint,
                legacyAlgorithm: legacyAlgorithm,
                approvedAt: approvedAt
            )
        }
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

    private struct ProtocolAuthorityIdentity: Equatable {
        let publicKey: Data?
        let fingerprint: String
    }

    private static func insertingAuthorityIdentity(
        _ identity: ProtocolAuthorityIdentity,
        algorithm: ProtocolSigningAlgorithm,
        into identities: inout [ProtocolSigningAlgorithm: ProtocolAuthorityIdentity]
    ) -> Bool {
        guard let existing = identities[algorithm] else {
            identities[algorithm] = identity
            return true
        }
        guard existing.fingerprint == identity.fingerprint else { return false }
        if let existingKey = existing.publicKey,
           let incomingKey = identity.publicKey,
           existingKey != incomingKey {
            return false
        }
        if existing.publicKey == nil, identity.publicKey != nil {
            identities[algorithm] = identity
        }
        return true
    }

    private static func protocolAuthorityIdentityMap(
        for record: TrustRecord
    ) -> [ProtocolSigningAlgorithm: ProtocolAuthorityIdentity]? {
        guard let v2Bindings = protocolIdentityBindingMapV2(record.protocolIdentityBindingsV2) else {
            return nil
        }
        var identities: [ProtocolSigningAlgorithm: ProtocolAuthorityIdentity] = [:]

        for (algorithm, binding) in v2Bindings {
            guard insertingAuthorityIdentity(
                ProtocolAuthorityIdentity(
                    publicKey: binding.publicKey,
                    fingerprint: binding.fingerprint
                ),
                algorithm: algorithm,
                into: &identities
            ) else {
                return nil
            }
        }

        for pin in record.protocolIdentityPins ?? [] where pin.algorithm != .mlDSA87 {
            guard let fingerprint = normalizedProtocolFingerprint(pin.fingerprint) else { continue }
            guard insertingAuthorityIdentity(
                ProtocolAuthorityIdentity(publicKey: nil, fingerprint: fingerprint),
                algorithm: pin.algorithm,
                into: &identities
            ) else {
                return nil
            }
        }

        if let legacyAlgorithm = record.protocolSigningAlgorithm,
           legacyAlgorithm != .mlDSA87,
           let fingerprint = normalizedProtocolFingerprint(record.protocolPublicKeyFingerprint) {
            let candidate = record.protocolPublicKey ?? record.publicKey
            let validatedKey = validatedProtocolPublicKey(
                candidate,
                algorithm: legacyAlgorithm,
                fingerprint: fingerprint
            )
            guard insertingAuthorityIdentity(
                ProtocolAuthorityIdentity(publicKey: validatedKey, fingerprint: fingerprint),
                algorithm: legacyAlgorithm,
                into: &identities
            ) else {
                return nil
            }
        }

        return identities
    }

    fileprivate static func hasProtocolAuthorityConflict(
        _ lhs: TrustRecord,
        _ rhs: TrustRecord
    ) -> Bool {
        guard let lhsIdentities = protocolAuthorityIdentityMap(for: lhs),
              let rhsIdentities = protocolAuthorityIdentityMap(for: rhs) else {
            return true
        }
        for (algorithm, lhsIdentity) in lhsIdentities {
            guard let rhsIdentity = rhsIdentities[algorithm] else { continue }
            guard lhsIdentity.fingerprint == rhsIdentity.fingerprint else { return true }
            if let lhsKey = lhsIdentity.publicKey,
               let rhsKey = rhsIdentity.publicKey,
               lhsKey != rhsKey {
                return true
            }
        }
        return false
    }

    fileprivate static func canonicalProtocolIdentityBindingsV2(
        _ bindings: [ProtocolIdentityBindingV2]
    ) -> [ProtocolIdentityBindingV2]? {
        let sorted = bindings.sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            if lhs.algorithm != rhs.algorithm { return lhs.algorithm < rhs.algorithm }
            if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
            if lhs.fingerprint != rhs.fingerprint { return lhs.fingerprint < rhs.fingerprint }
            if lhs.state != rhs.state { return lhs.state < rhs.state }
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.approvedAt != rhs.approvedAt { return lhs.approvedAt < rhs.approvedAt }
            return lhs.publicKey.lexicographicallyPrecedes(rhs.publicKey)
        }
        return sorted.isEmpty ? nil : sorted
    }

    fileprivate static func protocolIdentityBindingsV2(
        existing record: TrustRecord?,
        adding algorithm: ProtocolSigningAlgorithm,
        publicKey: Data?,
        fingerprint: String,
        approvedAt: Date,
        source: ProtocolIdentityPinSource
    ) -> (accepted: Bool, bindings: [ProtocolIdentityBindingV2]?) {
        let existingBindings = record?.protocolIdentityBindingsV2 ?? []
        guard var existingMap = protocolIdentityBindingMapV2(existingBindings) else {
            return (false, nil)
        }
        var updatedBindings = existingBindings
        var nextGeneration = existingBindings.map(\.generation).max() ?? 0

        func appendBinding(
            algorithm: ProtocolSigningAlgorithm,
            publicKey: Data,
            fingerprint: String,
            source: ProtocolIdentityPinSource,
            approvedAt: Date
        ) -> ProtocolIdentityBindingV2? {
            guard nextGeneration < UInt64.max else { return nil }
            nextGeneration += 1
            let binding = ProtocolIdentityBindingV2(
                algorithm: algorithm,
                publicKey: publicKey,
                fingerprint: fingerprint,
                source: source,
                approvedAt: approvedAt,
                generation: nextGeneration
            )
            updatedBindings.append(binding)
            return binding
        }

        // Migrate a fully bound legacy Ed25519/ML-DSA-65 authority into the
        // sidecar before adding a second algorithm. Fingerprint-only legacy
        // pins remain legacy metadata because they do not contain raw authority.
        if let record,
           let legacyAlgorithm = record.protocolSigningAlgorithm,
           legacyAlgorithm != .mlDSA87,
           existingMap[legacyAlgorithm] == nil,
           let legacyFingerprint = normalizedProtocolFingerprint(record.protocolPublicKeyFingerprint) {
            let legacyCandidate = record.protocolPublicKey ?? record.publicKey
            if let legacyPublicKey = validatedProtocolPublicKey(
                legacyCandidate,
                algorithm: legacyAlgorithm,
                fingerprint: legacyFingerprint
            ) {
                guard let migratedBinding = appendBinding(
                    algorithm: legacyAlgorithm,
                    publicKey: legacyPublicKey,
                    fingerprint: legacyFingerprint,
                    source: .legacyMigration,
                    approvedAt: record.updatedAt
                ) else {
                    return (false, nil)
                }
                existingMap[legacyAlgorithm] = migratedBinding
            }
        }

        guard let normalizedFingerprint = normalizedProtocolFingerprint(fingerprint) else {
            return (false, nil)
        }

        if let existing = existingMap[algorithm] {
            guard existing.fingerprint == normalizedFingerprint else {
                return (false, nil)
            }
            if let publicKey, publicKey != existing.publicKey {
                return (false, nil)
            }
            return (true, canonicalProtocolIdentityBindingsV2(updatedBindings))
        }

        if let record {
            guard let legacyIdentities = protocolAuthorityIdentityMap(for: record) else {
                return (false, nil)
            }
            if let legacyIdentity = legacyIdentities[algorithm] {
                guard legacyIdentity.fingerprint == normalizedFingerprint else {
                    return (false, nil)
                }
                if let legacyKey = legacyIdentity.publicKey,
                   let publicKey,
                   legacyKey != publicKey {
                    return (false, nil)
                }
            }
        }

        guard let publicKey,
              validatedProtocolPublicKey(
                publicKey,
                algorithm: algorithm,
                fingerprint: normalizedFingerprint
              ) != nil else {
            // Fingerprint-only legacy updates remain representable for Ed25519
            // and ML-DSA-65, but never manufacture a v2 raw-key authority.
            return (algorithm != .mlDSA87, canonicalProtocolIdentityBindingsV2(updatedBindings))
        }

        guard appendBinding(
            algorithm: algorithm,
            publicKey: publicKey,
            fingerprint: normalizedFingerprint,
            source: source,
            approvedAt: approvedAt
        ) != nil else {
            return (false, nil)
        }
        return (true, canonicalProtocolIdentityBindingsV2(updatedBindings))
    }

    fileprivate static func mergedProtocolIdentityBindingsV2(
        existing: [ProtocolIdentityBindingV2]?,
        incoming: [ProtocolIdentityBindingV2]?
    ) -> (accepted: Bool, bindings: [ProtocolIdentityBindingV2]?) {
        guard let existingMap = protocolIdentityBindingMapV2(existing),
              let incomingMap = protocolIdentityBindingMapV2(incoming) else {
            return (false, nil)
        }
        for (algorithm, existingBinding) in existingMap {
            guard let incomingBinding = incomingMap[algorithm] else { continue }
            guard existingBinding.publicKey == incomingBinding.publicKey,
                  existingBinding.fingerprint == incomingBinding.fingerprint else {
                return (false, nil)
            }
        }

        var merged = incoming ?? []
        for binding in existing ?? [] where !merged.contains(binding) {
            if binding.version == ProtocolIdentityBindingV2.schemaVersion,
               binding.state == ProtocolIdentityBindingV2.activeState,
               let algorithm = binding.protocolSigningAlgorithm,
               incomingMap[algorithm] != nil {
                continue
            }
            merged.append(binding)
        }
        return (true, canonicalProtocolIdentityBindingsV2(merged))
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
    case aliasCleanupFailedAfterAuthoritativeCommit(String)
    case fallbackCleanupFailedAfterAuthoritativeCommit(String)
    case mutationWaiterLimitExceeded(maximum: Int)
    case mutationWaitDeadlineExceeded
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
        case .aliasCleanupFailedAfterAuthoritativeCommit(let reason):
            return "Authoritative trust commit succeeded, but stale alias cleanup failed: \(reason)"
        case .fallbackCleanupFailedAfterAuthoritativeCommit(let reason):
            return "Authoritative trust commit succeeded, but stale fallback cleanup failed: \(reason)"
        case .mutationWaiterLimitExceeded(let maximum):
            return "Trust mutation waiter limit exceeded: maximum=\(maximum)"
        case .mutationWaitDeadlineExceeded:
            return "Trust mutation wait deadline exceeded"
        case .pairingAuthorityCommitSuperseded:
            return "Pairing authority commit was superseded before durable persistence"
        }
    }
}

typealias PairingAuthorityCommitValidator = @MainActor @Sendable () async -> Bool

public enum CurrentPathTrustConflict: Sendable, Equatable {
    case identityConflict
    case deviceIdMigrationRequired
    case quarantinedIdentity
    case revokedIdentity
}

/// Exact authenticated protocol authority removed from the local trust graph.
/// Device aliases are retained for diagnostics and identity migration, but
/// session teardown is authorized only by an exact algorithm + fingerprint
/// match so a stale alias cannot cancel an unrelated replacement session.
struct TrustInvalidationAuthority: Sendable, Hashable {
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String

    init?(
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String
    ) {
        guard let fingerprint = TrustRecord.normalizedProtocolFingerprint(
            protocolPublicKeyFingerprint
        ) else {
            return nil
        }
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyFingerprint = fingerprint
    }
}

struct TrustInvalidationIdentity: Sendable, Hashable {
    let deviceIds: Set<String>
    let authorities: Set<TrustInvalidationAuthority>

    init?(record: TrustRecord, additionalDeviceIds: Set<String> = []) {
        let normalizedDeviceIds = Set(
            (PeerTrustLookup.recordLookupCandidates(record) + Array(additionalDeviceIds))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let normalizedAuthorities = Set(record.currentPathAuthorityPins.compactMap { pin in
            TrustInvalidationAuthority(
                protocolSigningAlgorithm: pin.algorithm,
                protocolPublicKeyFingerprint: pin.fingerprint
            )
        })
        guard !normalizedAuthorities.isEmpty else { return nil }
        self.deviceIds = normalizedDeviceIds
        self.authorities = normalizedAuthorities
    }
}

struct TrustInvalidationEvent: Sendable, Equatable {
    let revision: UUID
    let identities: Set<TrustInvalidationIdentity>

    init(revision: UUID = UUID(), identities: Set<TrustInvalidationIdentity>) {
        self.revision = revision
        self.identities = identities
    }

    func matches(authority: AuthenticatedRemoteAuthority) -> Bool {
        guard let exactAuthority = TrustInvalidationAuthority(
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        ) else {
            return false
        }
        return identities.contains { $0.authorities.contains(exactAuthority) }
    }

    func matches(
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String
    ) -> Bool {
        guard let exactAuthority = TrustInvalidationAuthority(
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) else {
            return false
        }
        return identities.contains { $0.authorities.contains(exactAuthority) }
    }
}

/// Serializes trust persistence transactions across MainActor reentrancy while
/// bounding queued work. Cancellation and deadline expiry remove a queued
/// waiter instead of leaving an abandoned continuation behind.
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
#if DEBUG || SKYBRIDGE_TESTING
    private var waiterCountObservers: [
        (expected: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
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

#if DEBUG || SKYBRIDGE_TESTING
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
#if DEBUG || SKYBRIDGE_TESTING
        var remaining: [
            (expected: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
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
    @Published public var activeTrustRecords: [TrustRecord] = []
    
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
    private let mutationGate = TrustMutationAdmissionGate()
    private var initialLoadTask: Task<Result<Void, TrustSyncError>, Never>?
    /// 单调递增的加载尝试代号。MainActor 串行化下用于判断“当前 initialLoadTask
    /// 是否已被其他调用方替换”，防止并发调用方重复补发重试。
    private var loadAttemptGeneration: UInt64 = 0
    /// 本地信任存储可用性门（对齐 iOS TrustedDeviceStore.isAuthorityPersistenceAvailable）：
    /// 加载以硬失败收场时置 false，所有同步准入读取 fail closed；
    /// “空 store 但可读”仍视为可用（允许首次接触）。
    private(set) var isLocalStoreAvailable = true

#if DEBUG || SKYBRIDGE_TESTING
    private var usesInMemoryPersistenceForTesting: Bool = false
    private var initialLoadTaskBeforeInMemoryTesting: Task<Result<Void, TrustSyncError>, Never>?
    private var isLocalStoreAvailableBeforeInMemoryTesting: Bool?
    private var initialLoadOperationForTesting: (@MainActor @Sendable () async throws -> Void)?
    var aliasRecordDeletionForTesting: (@MainActor @Sendable (String) throws -> Void)?
    var mutationPostSignBarrierForTesting: (@MainActor @Sendable () async -> Void)?
#endif
    
 // MARK: - Initialization
    
    private init() {
        initialLoadTask = makeInitialLoadAttemptTask()
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        initialLoadOperationForTesting: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        usesInMemoryPersistenceForTesting = true
        self.initialLoadOperationForTesting = initialLoadOperationForTesting
        initialLoadTask = makeInitialLoadAttemptTask()
    }

    init(initialRecordsForTesting: [TrustRecord]) {
        usesInMemoryPersistenceForTesting = true
        localCache = Dictionary(
            uniqueKeysWithValues: initialRecordsForTesting.map { ($0.deviceId, $0) }
        )
        loadAttemptGeneration &+= 1
        initialLoadTask = Task { @MainActor in .success(()) }
        updateActiveTrustRecordsFromCache()
    }

    func requireInitialLoadForTesting() async throws {
        try await requireInitialLoadSucceeded()
    }
#endif

    /// 与 init 完全相同的加载操作；重试路径必须复用它（含测试注入的 op），
    /// 保证生产与测试的自愈语义一致。
    private func performInitialLoadOperation() async throws {
#if DEBUG || SKYBRIDGE_TESTING
        if let initialLoadOperationForTesting {
            try await initialLoadOperationForTesting()
            return
        }
#endif
        try await loadLocalRecords()
    }

    private func makeInitialLoadAttemptTask() -> Task<Result<Void, TrustSyncError>, Never> {
        loadAttemptGeneration &+= 1
        return Task { @MainActor [weak self] in
            guard let self else {
                return .failure(.localTrustStoreUnavailable)
            }
            do {
                try await self.performInitialLoadOperation()
                self.isLocalStoreAvailable = true
                return .success(())
            } catch {
                self.isLocalStoreAvailable = false
                return .failure((error as? TrustSyncError) ?? .localTrustStoreUnavailable)
            }
        }
    }

    private func awaitInitialLoadCompletion() async {
        guard let initialLoadTask else { return }
        _ = await initialLoadTask.value
    }

    private func requireInitialLoadSucceeded() async throws {
        try Task.checkCancellation()
        guard let initialLoadTask else {
            throw TrustSyncError.localTrustStoreUnavailable
        }
        // 在 await 之前采样 generation：await 期间若有其他调用方已补发重试，
        // generation 必然改变，本调用只需搭乘那次重试而不再补发。
        let observedGeneration = loadAttemptGeneration
        let result = await initialLoadTask.value
        try Task.checkCancellation()
        if case .success = result { return }

        // 硬失败可在进程内自愈：每个调用方最多补发一次全新加载（不循环重试），
        // 持续失败仍对每个调用方保持 fail closed；原因消除后下一次调用即恢复。
        if loadAttemptGeneration == observedGeneration {
            self.initialLoadTask = makeInitialLoadAttemptTask()
        }
        guard let retryTask = self.initialLoadTask else {
            throw TrustSyncError.localTrustStoreUnavailable
        }
        let retryResult = await retryTask.value
        try Task.checkCancellation()
        try retryResult.get()
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

    /// Performs read-modify-write inside the mutation admission gate. Callers
    /// that merge KEM keys, capabilities, or authority metadata must use this
    /// path instead of reading `getTrustRecord` before a later async write.
    @discardableResult
    func upsertTrustRecordAtomically(
        deviceId: String,
        transform: @escaping @MainActor @Sendable (TrustRecord?) throws -> TrustRecord
    ) async throws -> TrustRecord {
        try await requireInitialLoadSucceeded()
        return try await mutationGate.run { [self, deviceId, transform] in
            let record = try transform(localCache[deviceId])
            guard record.deviceId == deviceId else {
                throw TrustSyncError.verificationFailed
            }
            return try await addTrustRecordWithinMutation(record)
        }
    }

    private func addTrustRecordWithinMutation(
        _ record: TrustRecord,
        commitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> TrustRecord {
        guard denialConflict(for: record) == nil else {
            throw TrustSyncError.verificationFailed
        }

 // 检查是否已存在
        if let existing = localCache[record.deviceId] {
 // 如果已存在且不是 tombstone，更新
            if !existing.isTombstone {
                return try await updateTrustRecordWithinMutation(
                    record,
                    commitValidator: commitValidator
                )
            }
 // 如果是 tombstone，不允许重新添加同一 deviceId
            throw TrustSyncError.conflictResolutionFailed
        }
        
 // 签名记录
        let signedRecord = try await signRecord(record)
        try await validateMutationStillCurrentAfterSigning(
            commitValidator: commitValidator
        )
        
 // 保存到本地
        let postCommitError: TrustSyncError?
#if DEBUG || SKYBRIDGE_TESTING
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
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

    private func denialConflict(for incoming: TrustRecord) -> CurrentPathTrustConflict? {
        // 不可用的 store 无法证明 incoming 未被撤销：一律 fail closed。
        guard isLocalStoreAvailable else { return .quarantinedIdentity }
        let incomingDirectCandidates = Set(
            [incoming.deviceId, incoming.currentDeviceIdMetadata]
                .compactMap { $0 }
                .flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
                .map { $0.lowercased() }
        )
        let incomingAuthorityFingerprints = incoming.currentPathAuthorityFingerprints
        let incomingLegacyFingerprint = incoming.pubKeyFP
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for existing in localCache.values where !existing.isExpired {
            let conflict: CurrentPathTrustConflict
            if existing.isTombstone || existing.lifecycleState == .revoked {
                conflict = .revokedIdentity
            } else if existing.lifecycleState == .quarantined
                        || existing.lifecycleState == .reverificationRequired {
                conflict = .quarantinedIdentity
            } else {
                continue
            }

            let existingDirectCandidates = Set(
                [existing.deviceId, existing.currentDeviceIdMetadata]
                    .compactMap { $0 }
                    .flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
                    .map { $0.lowercased() }
            )
            if !incomingDirectCandidates.isDisjoint(with: existingDirectCandidates) {
                return conflict
            }
            if !incomingAuthorityFingerprints.isDisjoint(
                with: existing.currentPathAuthorityFingerprints
            ) {
                return conflict
            }
            let existingLegacyFingerprint = existing.pubKeyFP
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !incomingLegacyFingerprint.isEmpty,
               incomingLegacyFingerprint == existingLegacyFingerprint {
                return conflict
            }
        }
        return nil
    }
    
 /// 撤销信任记录（创建 tombstone）
 /// - Parameter deviceId: 设备 ID
    public func revokeTrustRecord(deviceId: String) async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self, deviceId] in
            try await revokeTrustRecordWithinMutation(deviceId: deviceId)
        }
    }

    private func revokeTrustRecordWithinMutation(deviceId: String) async throws {
        guard let existing = localCache[deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        
 // 先构造最终 tombstone，再签名其精确持久化载荷。
        let revocationDate = Date()
        let unsignedRevokedRecord = existing.revoked(signature: Data(), at: revocationDate)
        let dataToSign = try createCompleteDataToSign(for: unsignedRevokedRecord, revoked: true)
        let signature = try await keyManager.sign(data: dataToSign)
        try await validateMutationStillCurrentAfterSigning()
        let revokedRecord = existing.revoked(signature: signature, at: revocationDate)
        
 // 保存到本地
        let postCommitError: TrustSyncError?
#if DEBUG || SKYBRIDGE_TESTING
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(revokedRecord, synchronizable: isSyncAvailable)
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(revokedRecord, synchronizable: isSyncAvailable)
#endif
        localCache[deviceId] = revokedRecord
        
 // 更新 UI
        updateActiveTrustRecordsFromCache()

        // The durable tombstone is the commit point. Notify synchronously
        // before reporting any post-commit mirror-cleanup error so no active
        // session can outlive authority revocation merely because cleanup of a
        // stale copy failed.
        publishTrustInvalidation(records: [revokedRecord])

        if let postCommitError {
            throw postCommitError
        }
        
        SkyBridgeLogger.p2p.info("Revoked trust record: \(revokedRecord.shortId)")
    }
    
 /// 获取所有可用于认证的信任记录。
 /// 隔离、待重新验证、撤销和过期记录仍可留在管理面，但绝不能进入认证面。
    public func getActiveTrustRecords() async -> [TrustRecord] {
        await awaitInitialLoadCompletion()
        return activeTrustRecordsSnapshot()
    }
    
 /// 获取信任记录
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 信任记录（如果存在）
    public func getTrustRecord(deviceId: String) -> TrustRecord? {
        guard isLocalStoreAvailable else { return nil }
        guard let record = localCache[deviceId] else { return nil }
        return record.isTombstone ? nil : record
    }

 /// 检查设备是否受信任
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 是否受信任
    public func isTrusted(deviceId: String) -> Bool {
        guard isLocalStoreAvailable else { return false }
        guard let record = localCache[deviceId] else { return false }
        return record.isAuthenticationEligible
    }

 /// 检查公钥指纹是否受信任
 /// - Parameter pubKeyFP: 公钥指纹
 /// - Returns: 是否受信任
    public func isTrusted(pubKeyFP: String) -> Bool {
        guard isLocalStoreAvailable else { return false }
        return localCache.values.contains {
            $0.pubKeyFP == pubKeyFP && $0.isAuthenticationEligible
        }
    }

    public func getCurrentPathTrustRecord(fingerprint: String) -> TrustRecord? {
        guard isLocalStoreAvailable else { return nil }
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return localCache.values.first { record in
            guard record.isAuthenticationEligible else { return false }
            return record.currentPathAuthorityFingerprints.contains(normalized)
        }
    }

    /// Read-only peer-pinning lookup used by handshake policy. It deliberately
    /// ignores fingerprint-only legacy pins and returns nil on alias ambiguity
    /// or any same-algorithm raw-key disagreement.
    public func authenticatedProtocolIdentityBinding(
        deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) -> ProtocolIdentityBindingV2? {
        guard isLocalStoreAvailable else { return nil }
        let matchingBindings = localCache.values.compactMap { record -> ProtocolIdentityBindingV2? in
            guard record.isAuthenticationEligible,
                  currentPathDeviceMatches(record, deviceId: deviceId) else {
                return nil
            }
            return record.authenticatedProtocolIdentityBinding(for: algorithm)
        }
        guard let first = matchingBindings.first else { return nil }
        guard matchingBindings.dropFirst().allSatisfy({ binding in
            binding.publicKey == first.publicKey && binding.fingerprint == first.fingerprint
        }) else {
            return nil
        }
        return matchingBindings.max { lhs, rhs in
            lhs.generation < rhs.generation
        }
    }

    public func hasAuthenticatedProtocolIdentity(
        deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) -> Bool {
        authenticatedProtocolIdentityBinding(deviceId: deviceId, algorithm: algorithm) != nil
    }

    /// Endpoint-based responders may not know the peer's stable device id yet.
    /// This lookup treats possession of an already authenticated exact raw key
    /// as the identity and never consults fingerprint-only legacy pins.
    public func authenticatedProtocolIdentityBinding(
        publicKey: Data,
        algorithm: ProtocolSigningAlgorithm
    ) -> ProtocolIdentityBindingV2? {
        guard isLocalStoreAvailable else { return nil }
        let matches = localCache.values.compactMap { record -> ProtocolIdentityBindingV2? in
            guard let binding = record.authenticatedProtocolIdentityBinding(for: algorithm),
                  binding.publicKey == publicKey else {
                return nil
            }
            return binding
        }
        return matches.max { lhs, rhs in
            lhs.generation < rhs.generation
        }
    }

    /// Resolves the outbound PQC signature algorithm for one peer. ML-DSA-87
    /// is opt-in on both sides: local settings must request it and the peer must
    /// already have an authentication-eligible exact raw-key 87 authority.
    /// Every unpinned or legacy peer remains on the established ML-DSA-65 path.
    public func outboundPQCSignatureAlgorithm(
        deviceId: String,
        requestedAlgorithm: ProtocolSigningAlgorithm
    ) -> ProtocolSigningAlgorithm {
        guard requestedAlgorithm == .mlDSA87,
              hasAuthenticatedProtocolIdentity(
                deviceId: deviceId,
                algorithm: .mlDSA87
              ) else {
            return .mlDSA65
        }
        return .mlDSA87
    }

    func getCurrentPathTrustRecord(
        fingerprint: String,
        matchingDeviceId deviceId: String
    ) -> TrustRecord? {
        guard isLocalStoreAvailable else { return nil }
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return localCache.values.first { record in
            guard record.isAuthenticationEligible else { return false }
            guard record.currentPathAuthorityFingerprints.contains(normalized) else { return false }
            return currentPathDeviceMatches(record, deviceId: deviceId)
        }
    }

    public func evaluateCurrentPathBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) -> CurrentPathTrustConflict? {
        // Store 不可用时无法证明该身份未被撤销/隔离，准入判定必须 fail closed
        //（对齐 iOS TrustedDeviceStore.evaluateCurrentPathBinding）。
        guard isLocalStoreAvailable else { return .quarantinedIdentity }
        let normalizedFingerprint = protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedFingerprint.isEmpty else { return nil }

        let fingerprintMatches = localCache.values.filter {
            !$0.isTombstone &&
            !$0.isExpired &&
            $0.currentPathAuthorityFingerprints.contains(normalizedFingerprint)
        }
        if fingerprintMatches.contains(where: { $0.lifecycleState == .revoked }) {
            return .revokedIdentity
        }
        if fingerprintMatches.contains(where: {
            switch $0.lifecycleState {
            case .reverificationRequired, .quarantined:
                return true
            case .active, .revoked:
                return false
            }
        }) {
            return .quarantinedIdentity
        }
        if fingerprintMatches.contains(where: { $0.lifecycleState == .active }) {
            // The authoritative signing key remains the stronger trust anchor.
            // A deviceId rotation under the same key should heal metadata after
            // the session succeeds instead of being treated as a hard conflict.
            return nil
        }

        let deviceMatches = localCache.values.filter {
            !$0.isTombstone &&
            !$0.isExpired &&
            currentPathDeviceMatches($0, deviceId: deviceId)
        }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = $0.currentPathAuthorityFingerprints
            guard !pinnedFingerprints.isEmpty else { return false }
            return !pinnedFingerprints.contains(normalizedFingerprint) && $0.lifecycleState == .revoked
        }) {
            return .revokedIdentity
        }
        if deviceMatches.contains(where: {
            let pinnedFingerprints = $0.currentPathAuthorityFingerprints
            guard !pinnedFingerprints.isEmpty else { return false }
            guard !pinnedFingerprints.contains(normalizedFingerprint) else { return false }
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

        return nil
    }

    private func currentPathDeviceMatches(_ record: TrustRecord, deviceId: String) -> Bool {
        guard let lookup = currentPathLookupCandidates(for: deviceId) else { return false }
        return PeerTrustLookup.recordMatches(
            record,
            candidates: lookup.candidates,
            candidateLowercased: lookup.candidateLowercased
        )
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
            case .mlDSA87:
                expectedLength = 2_592
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
        let authenticatedCandidateLowerSet = Set(
            authenticatedCandidateSet.map { $0.lowercased() }
        )

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
        // existing authority. Remote aliases and display names are metadata;
        // they must never lend another record's KEM, attestation, or legacy key.
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
        guard matchingRecords.count <= 1 || targetRecord != nil else { return nil }

        func conflictsWithAnotherRecord(_ claims: [String]) -> Bool {
            let claimedCandidates = Set(
                claims.flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
            )
            guard !claimedCandidates.isEmpty else { return false }
            let claimedCandidatesLower = Set(claimedCandidates.map { $0.lowercased() })
            let targetStorageKey = targetRecord?.deviceId
            return existingRecords.contains { record in
                guard !record.isExpired, record.deviceId != targetStorageKey else { return false }
                let directCandidates = [record.deviceId, record.currentDeviceIdMetadata]
                    .compactMap { $0 }
                    .flatMap { PeerTrustLookup.lookupCandidates(for: $0) }
                return directCandidates.contains {
                    claimedCandidates.contains($0)
                        || claimedCandidatesLower.contains($0.lowercased())
                }
            }
        }

        var existingIdentityClaims = [normalizedDeviceId]
            + [stableCurrentDeviceId].compactMap { $0 }
        if let targetRecord {
            existingIdentityClaims.append(targetRecord.deviceId)
            existingIdentityClaims.append(targetRecord.currentDeviceId)
            existingIdentityClaims.append(contentsOf: targetRecord.knownDeviceIdsMetadata ?? [])
        }
        guard !conflictsWithAnotherRecord(existingIdentityClaims) else { return nil }

        // Retain only non-conflicting remote aliases. Alias claims cannot select
        // an authority record or cause another record's durable alias deletion.
        let retainedKnownDeviceIds = knownDeviceIds.filter {
            !conflictsWithAnotherRecord([$0])
        }

        func mergeKnownDeviceIds(existing: [String?]) -> [String]? {
            let merged = Set(
                existing.compactMap { $0 }
                    + authenticatedLookupCandidates
                    + retainedKnownDeviceIds
                    + [stableCurrentDeviceId, normalizedDeviceId].compactMap { $0 }
            )
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return merged.isEmpty ? nil : Array(merged).sorted()
        }

        if let targetRecord {
            let canonicalDeviceId = stableCurrentDeviceId ?? targetRecord.deviceId
            let approvedAt = Date()
            let v2Update = TrustRecord.protocolIdentityBindingsV2(
                existing: targetRecord,
                adding: protocolSigningAlgorithm,
                publicKey: validatedProtocolPublicKey(authenticatedProtocolPublicKey),
                fingerprint: normalizedFingerprint,
                approvedAt: approvedAt,
                source: pinSource
            )
            guard v2Update.accepted else { return nil }

            let preservesLegacyMLDSA65 = targetRecord.protocolSigningAlgorithm == .mlDSA65
                && protocolSigningAlgorithm != .mlDSA65
            let writesLegacyAuthority = protocolSigningAlgorithm != .mlDSA87
                && !preservesLegacyMLDSA65
            let legacyProtocolPublicKey: Data?
            if writesLegacyAuthority {
                legacyProtocolPublicKey = validatedProtocolPublicKey(authenticatedProtocolPublicKey)
                    ?? (targetRecord.protocolSigningAlgorithm == protocolSigningAlgorithm
                        ? validatedProtocolPublicKey(targetRecord.protocolPublicKey)
                        : nil)
            } else {
                legacyProtocolPublicKey = targetRecord.protocolPublicKey
            }
            let legacyProtocolSigningAlgorithm = writesLegacyAuthority
                ? protocolSigningAlgorithm
                : targetRecord.protocolSigningAlgorithm
            let legacyProtocolFingerprint = writesLegacyAuthority
                ? normalizedFingerprint
                : targetRecord.protocolPublicKeyFingerprint
            let updatedProtocolIdentityPins = protocolSigningAlgorithm == .mlDSA87
                ? targetRecord.protocolIdentityPins
                : TrustRecord.protocolIdentityPins(
                    existing: targetRecord.protocolIdentityPins,
                    legacyFingerprint: targetRecord.protocolPublicKeyFingerprint,
                    legacyAlgorithm: targetRecord.protocolSigningAlgorithm,
                    adding: protocolSigningAlgorithm,
                    fingerprint: normalizedFingerprint,
                    approvedAt: approvedAt,
                    source: pinSource
                )
            return TrustRecord(
                deviceId: canonicalDeviceId,
                pubKeyFP: targetRecord.pubKeyFP,
                publicKey: targetRecord.publicKey,
                secureEnclavePublicKey: targetRecord.secureEnclavePublicKey,
                protocolPublicKey: legacyProtocolPublicKey,
                protocolSigningAlgorithm: legacyProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: legacyProtocolFingerprint,
                protocolIdentityPins: updatedProtocolIdentityPins,
                protocolIdentityBindingsV2: v2Update.bindings,
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

        let approvedAt = Date()
        let v2Update = TrustRecord.protocolIdentityBindingsV2(
            existing: nil,
            adding: protocolSigningAlgorithm,
            publicKey: validatedProtocolPublicKey(authenticatedProtocolPublicKey),
            fingerprint: normalizedFingerprint,
            approvedAt: approvedAt,
            source: pinSource
        )
        guard v2Update.accepted else { return nil }
        let writesLegacyAuthority = protocolSigningAlgorithm != .mlDSA87

        return TrustRecord(
            deviceId: stableCurrentDeviceId,
            pubKeyFP: "",
            publicKey: Data(),
            protocolPublicKey: writesLegacyAuthority
                ? validatedProtocolPublicKey(authenticatedProtocolPublicKey)
                : nil,
            protocolSigningAlgorithm: writesLegacyAuthority ? protocolSigningAlgorithm : nil,
            protocolPublicKeyFingerprint: writesLegacyAuthority ? normalizedFingerprint : nil,
            protocolIdentityPins: writesLegacyAuthority
                ? TrustRecord.protocolIdentityPins(
                    existing: nil,
                    legacyFingerprint: nil,
                    legacyAlgorithm: nil,
                    adding: protocolSigningAlgorithm,
                    fingerprint: normalizedFingerprint,
                    approvedAt: approvedAt,
                    source: pinSource
                )
                : nil,
            protocolIdentityBindingsV2: v2Update.bindings,
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

    /// Pairing-only authority commit. The transport/generation validator is
    /// rechecked after signing and immediately before persistence, which keeps
    /// a suspended old pairing operation from becoming durable after a newer
    /// operation has replaced it.
    @discardableResult
    func recordAuthenticatedRemoteAuthorityForPairing(
        deviceId: String,
        displayName: String? = nil,
        preferredCurrentDeviceId: String? = nil,
        knownDeviceIds: [String] = [],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyFingerprint: String,
        authenticatedProtocolPublicKey: Data? = nil,
        isCurrent: @escaping PairingAuthorityCommitValidator
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
                pinSource: .authenticatedHandshake,
                commitValidator: isCurrent
            )
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
        commitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> Bool {
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
            commitValidator: commitValidator
        )
        let aliasesToRemove = Set(signedRecord.knownDeviceIdsMetadata ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != signedRecord.deviceId }
        var removedAliasRecord = false
        for alias in aliasesToRemove where localCache[alias] != nil {
            do {
                try deleteAliasRecordFromPersistence(deviceId: alias)
                localCache.removeValue(forKey: alias)
                removedAliasRecord = true
            } catch {
                if removedAliasRecord {
                    updateActiveTrustRecordsFromCache()
                }
                SkyBridgeLogger.p2p.error(
                    "Authoritative protocol identity committed but alias cleanup failed. error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                throw TrustSyncError.aliasCleanupFailedAfterAuthoritativeCommit(
                    SkyBridgeDiagnosticRedaction.errorSummary(error)
                )
            }
        }
        if removedAliasRecord {
            updateActiveTrustRecordsFromCache()
        }
        return true
    }

    private func publishTrustInvalidation(
        records: [TrustRecord],
        additionalDeviceIds: Set<String> = []
    ) {
        let identities = Set(records.compactMap { record in
            TrustInvalidationIdentity(
                record: record,
                additionalDeviceIds: additionalDeviceIds
            )
        })
        guard !identities.isEmpty else { return }
        trustInvalidationSubject.send(
            TrustInvalidationEvent(identities: identities)
        )
    }
    
 /// 同步信任记录
    public func sync() async throws {
        try await requireInitialLoadSucceeded()
        try await mutationGate.run { [self] in
            try await syncWithinMutation()
        }
    }

    private func syncWithinMutation() async throws {
        guard isSyncAvailable else {
            syncStatus = .unavailable
            throw TrustSyncError.syncUnavailable
        }
        
        syncStatus = .syncing
        
        do {
 // 从 Keychain 加载所有记录（包括同步的）
            let allRecords = try loadAllFromKeychain()
            let verification = await verifiedTrustRecordsForLocalLoad(
                allRecords,
                source: "Keychain sync"
            )

 // 解决冲突（deny-only tombstone 走同一条 revoke 优先合并路径）
            for record in verification.verifiedRecords + verification.denyOnlyTombstones {
                if let existing = localCache[record.deviceId] {
                    let resolved = try resolveConflict(local: existing, remote: record)
                    localCache[record.deviceId] = resolved
                } else {
                    localCache[record.deviceId] = record
                }
            }

            let denialRecords = localCache.values.filter {
                !$0.isExpired && ($0.isTombstone || $0.lifecycleState != .active)
            }
            publishTrustInvalidation(records: denialRecords)
            
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
        try await mutationGate.run { [self] in
 // 撤销旧设备
            if localCache[oldDeviceId] != nil {
                do {
                    try await revokeTrustRecordWithinMutation(deviceId: oldDeviceId)
                } catch TrustSyncError.aliasCleanupFailedAfterAuthoritativeCommit(let cleanupResidue),
                        TrustSyncError.fallbackCleanupFailedAfterAuthoritativeCommit(let cleanupResidue) {
                    // 旧设备 tombstone 已权威提交且失效已发布；清理残留不得中止新设备记录的写入。
                    SkyBridgeLogger.p2p.warning("Key rotation: old-device revocation committed with post-commit cleanup residue: \(cleanupResidue)")
                }
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
    }

    // MARK: - Conflict Resolution

    /// 解决冲突（revoke 优先；无 authority 冲突时才允许 LWW）
    public func resolveConflict(
        local: TrustRecord,
        remote: TrustRecord
    ) throws -> TrustRecord {
 // 1. revoke 永远优先于 add
        if local.recordType == .revoke || remote.recordType == .revoke {
            if local.recordType == .revoke && remote.recordType == .revoke {
                return local.updatedAt > remote.updatedAt ? local : remote
            }
            return local.recordType == .revoke ? local : remote
        }

        // A timestamp must never select between two different raw authorities
        // for the same signing algorithm. Such a change requires an explicit,
        // authenticated key-rotation protocol outside ordinary trust sync.
        guard !TrustRecord.hasProtocolAuthorityConflict(local, remote) else {
            throw TrustSyncError.conflictResolutionFailed
        }

 // 2. 同类型且 authority 一致时使用 LWW (Last Writer Wins)
        return local.updatedAt > remote.updatedAt ? local : remote
    }
    
 // MARK: - Private Methods
    
 /// 加载本地记录
    private func loadLocalRecords() async throws {
        try await loadLocalRecords(
            keychainRecords: { [self] in try loadAllFromKeychain() },
            fallbackRecords: { [self] in try loadFallbackRecords() }
        )
    }

    private func loadLocalRecords(
        keychainRecords: @MainActor () throws -> [TrustRecord],
        fallbackRecords: @MainActor () throws -> [TrustRecord]
    ) async throws {
        // 验签环境预检：身份密钥存储的环境性失败（如首次解锁前的
        // errSecInteractionNotAllowed）必须让整库进入不可用（fail closed），
        // 而不是让每条记录都以"验签失败"被逐条跳过后返回"空但可用"的
        // 首次接触语义。密钥尚不存在（返回 nil）不是环境失败。
        do {
            _ = try await keyManager.existingIdentityKeyInfoStrict()
        } catch {
            isLocalStoreAvailable = false
            syncStatus = .failed
            throw (error as? TrustSyncError) ?? .localTrustStoreUnavailable
        }

        var mergedCache: [String: TrustRecord] = [:]
        var conflictedDeviceIds: Set<String> = []
        var loadFailure: TrustSyncError?

        func merge(_ record: TrustRecord) {
            // tombstone 不受冲突隔离拦截：resolveConflict 对 tombstone 走 revoke
            // 优先、不会抛错；若被隔离拦下，同 deviceId 先冲突后到的吊销会被静默
            // 丢弃，破坏单调吊销并允许后续 re-pair 持久覆盖墓碑。
            guard record.isTombstone || !conflictedDeviceIds.contains(record.deviceId) else { return }
            if let existing = mergedCache[record.deviceId] {
                do {
                    mergedCache[record.deviceId] = try resolveConflict(local: existing, remote: record)
                } catch {
                    // Fail closed at startup: neither conflicting authority is
                    // exposed to authentication until an explicit recovery.
                    // 只隔离这一个 deviceId，绝不升级为整库加载失败。
                    mergedCache.removeValue(forKey: record.deviceId)
                    conflictedDeviceIds.insert(record.deviceId)
                    syncStatus = .failed
                    SkyBridgeLogger.p2p.error(
                        "Rejected conflicting protocol authority during local trust load: device=redacted"
                    )
                }
            } else {
                mergedCache[record.deviceId] = record
            }
        }

        do {
            let records = try keychainRecords()
            let verification = await verifiedTrustRecordsForLocalLoad(
                records,
                source: "Keychain"
            )
            for record in verification.verifiedRecords { merge(record) }
            // deny-only tombstone 与已验证记录走同一条 revoke 优先的合并路径。
            for tombstone in verification.denyOnlyTombstones { merge(tombstone) }
            SkyBridgeLogger.p2p.debug("Loaded \(verification.verifiedRecords.count) verified trust records from Keychain")
        } catch {
            // errSecParam(-50) 在部分系统/环境下会出现在 synchronizable 查询中；
            // 对于启动期加载而言，视作“暂无可用 trust records”更合理，避免刷错误日志。
            if let e = error as? TrustSyncError, case .keychainError(let status) = e, status == errSecParam {
                SkyBridgeLogger.p2p.debug("Trust records load skipped (errSecParam=-50)")
            } else if let e = error as? TrustSyncError,
                      case .keychainError(let status) = e,
                      shouldMirrorTrustRecordAfterKeychainFailure(status) {
                SkyBridgeLogger.p2p.warning("⚠️ Trust records keychain unavailable (\(status)); loading protected local trust mirror")
            } else {
                SkyBridgeLogger.p2p.error("Failed to load trust records: \(error.localizedDescription)")
                // loadFailure 只保留给真正不可读的 store（整库查询硬失败）；
                // 单条坏记录已在上面按条跳过，不会走到这里。
                loadFailure = (error as? TrustSyncError) ?? .localTrustStoreUnavailable
            }
        }

        do {
            let records = try fallbackRecords()
            let verification = await verifiedTrustRecordsForLocalLoad(
                records,
                source: "protected local trust mirror"
            )
            for record in verification.verifiedRecords { merge(record) }
            for tombstone in verification.denyOnlyTombstones { merge(tombstone) }
            if !verification.verifiedRecords.isEmpty {
                SkyBridgeLogger.p2p.debug("Loaded \(verification.verifiedRecords.count) verified trust records from fallback storage")
            }
        } catch {
            syncStatus = .failed
            SkyBridgeLogger.p2p.error("Failed to load protected local trust mirror: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
            loadFailure = loadFailure
                ?? (error as? TrustSyncError)
                ?? .localTrustStoreUnavailable
        }

        if let loadFailure {
            // 硬失败：store 不可读，所有同步准入读取自此 fail closed，
            // 直到一次成功加载恢复可用性。
            isLocalStoreAvailable = false
            syncStatus = .failed
            throw loadFailure
        }
        localCache = mergedCache
        isLocalStoreAvailable = true
        updateActiveTrustRecordsFromCache()
    }

    /// 单次加载的验证聚合结果。
    private struct LocalLoadVerification {
        /// 本机身份密钥验签通过、可参与认证决策的记录。
        var verifiedRecords: [TrustRecord] = []
        /// 本机无法验证签名、但按 monotonic revocation 保留为仅拒绝语义的
        /// tombstone（isAuthenticationEligible 恒为 false，绝不进入认证面）。
        var denyOnlyTombstones: [TrustRecord] = []
    }

    /// 逐条验签，单条坏记录只跳过，绝不让整库加载失败：iCloud 同步来的记录由
    /// 对端设备的本地身份密钥签名，本机永远无法验证，这种良性 fan-out 不允许
    /// 把整个 trust store 打成不可用（那会让撤销检查 fail open）。
    private func verifiedTrustRecordsForLocalLoad(
        _ records: [TrustRecord],
        source: String
    ) async -> LocalLoadVerification {
        var verification = LocalLoadVerification()
        verification.verifiedRecords.reserveCapacity(records.count)
        for record in records {
            let isValid: Bool
            do {
                isValid = try await verifyRecordSignature(record)
            } catch {
                SkyBridgeLogger.p2p.warning(
                    "Rejected \(source, privacy: .public) trust record during local load: reason=verification_error error=\(error.localizedDescription, privacy: .private) device=redacted"
                )
                retainDenyOnlyTombstoneIfNeeded(record, in: &verification, source: source)
                continue
            }
            guard isValid else {
                SkyBridgeLogger.p2p.warning(
                    "Rejected \(source, privacy: .public) trust record during local load: reason=invalid_signature device=redacted"
                )
                retainDenyOnlyTombstoneIfNeeded(record, in: &verification, source: source)
                continue
            }
            verification.verifiedRecords.append(record)
        }
        return verification
    }

    /// 异设备撤销必须继续生效：无法验证的 tombstone 保留为仅拒绝记录，
    /// 走与已验证记录相同的合并机制，保证 revoke 单调优先。
    private func retainDenyOnlyTombstoneIfNeeded(
        _ record: TrustRecord,
        in verification: inout LocalLoadVerification,
        source: String
    ) {
        guard record.isTombstone else { return }
        verification.denyOnlyTombstones.append(record)
        SkyBridgeLogger.p2p.warning(
            "Retained unverifiable \(source, privacy: .public) tombstone as deny-only during local load: device=redacted"
        )
    }
    
 /// 更新活跃信任记录
    private func activeTrustRecordsSnapshot() -> [TrustRecord] {
        guard isLocalStoreAvailable else { return [] }
        return localCache.values.filter(\.isAuthenticationEligible)
    }

    private func updateActiveTrustRecordsFromCache() {
        activeTrustRecords = activeTrustRecordsSnapshot()
    }
    
 /// 签名记录
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
            protocolIdentityBindingsV2: record.protocolIdentityBindingsV2,
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

    private func validateMutationStillCurrentAfterSigning(
        commitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws {
#if DEBUG || SKYBRIDGE_TESTING
        if let mutationPostSignBarrierForTesting {
            await mutationPostSignBarrierForTesting()
        }
#endif
        try Task.checkCancellation()
        if let commitValidator, !(await commitValidator()) {
            throw TrustSyncError.pairingAuthorityCommitSuperseded
        }
    }

    private func signRecord(_ record: TrustRecord) async throws -> TrustRecord {
        let signableRecord = recordUsingCurrentSignaturePayload(record)
#if DEBUG || SKYBRIDGE_TESTING
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
                protocolIdentityBindingsV2: signableRecord.protocolIdentityBindingsV2,
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

        let dataToSign = try createCompleteDataToSign(for: signableRecord, revoked: false)
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
            protocolIdentityBindingsV2: signableRecord.protocolIdentityBindingsV2,
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
        commitValidator: PairingAuthorityCommitValidator? = nil
    ) async throws -> TrustRecord {
        guard let existing = localCache[record.deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        guard !TrustRecord.hasProtocolAuthorityConflict(existing, record) else {
            throw TrustSyncError.conflictResolutionFailed
        }
        let v2Merge = TrustRecord.mergedProtocolIdentityBindingsV2(
            existing: existing.protocolIdentityBindingsV2,
            incoming: record.protocolIdentityBindingsV2
        )
        guard v2Merge.accepted else {
            throw TrustSyncError.conflictResolutionFailed
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
            protocolIdentityBindingsV2: v2Merge.bindings,
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
        try await validateMutationStillCurrentAfterSigning(
            commitValidator: commitValidator
        )
        let postCommitError: TrustSyncError?
#if DEBUG || SKYBRIDGE_TESTING
        if !usesInMemoryPersistenceForTesting {
            postCommitError = try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
        } else {
            postCommitError = nil
        }
#else
        postCommitError = try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
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
            includeProtocolIdentityPins: true,
            includeProtocolIdentityBindingsV2: true
        )
    }

    /// Complete trust payload. Every persisted field that can affect
    /// authentication, revocation, expiry, migration, or trust presentation is
    /// covered, including the raw-key v2 authority sidecar.
    private func createCompleteDataToSign(
        for record: TrustRecord,
        revoked: Bool
    ) throws -> Data {
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
        encoder.encode(record.protocolIdentityBindingsV2) { enc, bindings in
            let canonicalBindings = TrustRecord.canonicalProtocolIdentityBindingsV2(bindings) ?? []
            enc.encode(canonicalBindings, encoder: { inner, binding in
                inner.encode(Int64(binding.version))
                inner.encode(binding.algorithm)
                inner.encode(binding.publicKey)
                inner.encode(binding.fingerprint)
                inner.encode(binding.source)
                inner.encode(binding.approvedAt)
                inner.encode(binding.generation)
                inner.encode(binding.state)
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
        includeProtocolIdentityPins: Bool,
        includeProtocolIdentityBindingsV2: Bool
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
        if includeProtocolIdentityBindingsV2 {
            encoder.encode(record.protocolIdentityBindingsV2) { enc, bindings in
                let canonicalBindings = TrustRecord.canonicalProtocolIdentityBindingsV2(bindings) ?? []
                enc.encode(canonicalBindings, encoder: { inner, binding in
                    inner.encode(Int64(binding.version))
                    inner.encode(binding.algorithm)
                    inner.encode(binding.publicKey)
                    inner.encode(binding.fingerprint)
                    inner.encode(binding.source)
                    inner.encode(binding.approvedAt)
                    inner.encode(binding.generation)
                    inner.encode(binding.state)
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

        if shouldMirrorTrustRecordAfterKeychainFailure(addStatus) || addStatus == errSecDuplicateItem {
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
                "Authoritative trust record committed, but stale fallback cleanup failed. error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
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
            // 降级：分别拉取 non-sync 和 sync 项，并保留两份记录供冲突解析。
            var nonSync = baseQuery
            nonSync[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            var sync = baseQuery
            sync[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
            let a: [[String: Any]]
            do {
                a = try copyItems(nonSync)
            } catch let TrustSyncError.keychainError(status) where status == errSecParam {
                a = []
            }
            let b: [[String: Any]]
            do {
                b = try copyItems(sync)
            } catch let TrustSyncError.keychainError(status) where status == errSecParam {
                // 某些环境下 “synchronizable=true” 会返回 errSecParam（例如未启用 iCloud Keychain），视作无同步项即可
                b = []
            }

            // Preserve both copies. Conflict resolution must see a tombstone
            // rather than nondeterministically dropping one by account.
            items = a + b
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        // 单条损坏/错位的 item 只跳过：整库查询失败（copyItems 抛出）才是硬错误。
        return items.enumerated().compactMap { index, item in
            guard let data = item[kSecValueData as String] as? Data else {
                SkyBridgeLogger.p2p.warning(
                    "Skipped keychain trust item during local load: index=\(index, privacy: .public) reason=missing_value_data"
                )
                return nil
            }
            guard let account = item[kSecAttrAccount as String] as? String else {
                SkyBridgeLogger.p2p.warning(
                    "Skipped keychain trust item during local load: index=\(index, privacy: .public) reason=missing_account_identity"
                )
                return nil
            }
            let record: TrustRecord
            do {
                record = try decoder.decode(TrustRecord.self, from: data)
            } catch {
                SkyBridgeLogger.p2p.warning(
                    "Skipped keychain trust item during local load: index=\(index, privacy: .public) reason=decoding_error error=\(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
            guard Self.keychainAccount(account, matchesRecordDeviceId: record.deviceId) else {
                SkyBridgeLogger.p2p.warning(
                    "Skipped keychain trust item during local load: index=\(index, privacy: .public) reason=account_identity_mismatch"
                )
                return nil
            }
            return record
        }
    }

    nonisolated static func keychainAccount(
        _ account: String,
        matchesRecordDeviceId deviceId: String
    ) -> Bool {
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
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess
            || status == errSecItemNotFound
            || shouldMirrorTrustRecordAfterKeychainFailure(status) else {
            throw TrustSyncError.keychainError(status)
        }
        try removeFallbackRecord(deviceId: deviceId)
    }

    private func deleteAliasRecordFromPersistence(deviceId: String) throws {
#if DEBUG || SKYBRIDGE_TESTING
        if let aliasRecordDeletionForTesting {
            try aliasRecordDeletionForTesting(deviceId)
            return
        }
        guard !usesInMemoryPersistenceForTesting else { return }
#endif
        try deleteFromKeychain(deviceId: deviceId)
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

#if DEBUG || SKYBRIDGE_TESTING
    func recordSignaturePayloadForTesting(
        _ record: TrustRecord,
        includeProtocolIdentityPins: Bool,
        includeProtocolIdentityBindingsV2: Bool
    ) throws -> Data {
        try createDataToSign(
            for: record,
            revoked: record.isTombstone,
            includeProtocolIdentityPins: includeProtocolIdentityPins,
            includeProtocolIdentityBindingsV2: includeProtocolIdentityBindingsV2
        )
    }

    func setInMemoryPersistenceForTesting(_ enabled: Bool) {
        if enabled, !usesInMemoryPersistenceForTesting {
            initialLoadTaskBeforeInMemoryTesting = initialLoadTask
            isLocalStoreAvailableBeforeInMemoryTesting = isLocalStoreAvailable
            loadAttemptGeneration &+= 1
            initialLoadTask = Task { @MainActor in .success(()) }
            isLocalStoreAvailable = true
        } else if !enabled, usesInMemoryPersistenceForTesting {
            loadAttemptGeneration &+= 1
            initialLoadTask = initialLoadTaskBeforeInMemoryTesting
            initialLoadTaskBeforeInMemoryTesting = nil
            isLocalStoreAvailable = isLocalStoreAvailableBeforeInMemoryTesting ?? true
            isLocalStoreAvailableBeforeInMemoryTesting = nil
        }
        usesInMemoryPersistenceForTesting = enabled
    }

    /// 以注入的记录源跑一遍真实的加载管线（验签、合并、可用性门）。
    func loadLocalRecordsForTesting(
        keychainRecords: @MainActor () throws -> [TrustRecord],
        fallbackRecords: @MainActor () throws -> [TrustRecord] = { [] }
    ) async throws {
        try await loadLocalRecords(
            keychainRecords: keychainRecords,
            fallbackRecords: fallbackRecords
        )
    }

    func removeRecordsForTesting(deviceIds: [String]) async throws {
        try await requireInitialLoadSucceeded()
        let normalizedDeviceIds = Set(
            deviceIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard !normalizedDeviceIds.isEmpty else { return }

        try await mutationGate.run { [self, normalizedDeviceIds] in
            for deviceId in normalizedDeviceIds {
                if !usesInMemoryPersistenceForTesting {
                    try deleteFromKeychain(deviceId: deviceId)
                }
                localCache.removeValue(forKey: deviceId)
            }
            updateActiveTrustRecordsFromCache()
        }
    }

    func rawTrustRecordForTesting(deviceId: String) async -> TrustRecord? {
        await awaitInitialLoadCompletion()
        return localCache[deviceId]
    }
#endif
    
    private func hasSafeLegacyUnsignedFields(_ record: TrustRecord) -> Bool {
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
        guard hasSafeLegacyUnsignedFields(record) else { return false }
        return record.protocolIdentityPins?.isEmpty != false
    }

    private func hasSafeOriginalLegacyFields(_ record: TrustRecord) -> Bool {
        guard hasSafePreMultiPinLegacyFields(record),
              record.protocolIdentityBindingsV2?.isEmpty != false,
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
              hasSafeLegacyUnsignedFields(record) else {
            return false
        }

        let currentPayload = try createDataToSign(for: record, revoked: record.isTombstone)
        if try await keyManager.verify(
            data: currentPayload,
            signature: record.signature,
            publicKey: signerPublicKey
        ) {
            return true
        }

        // A sidecar-bearing record must verify the payload that covers every
        // raw binding. Otherwise an attacker could attach unsigned authority to
        // a legitimately signed legacy record.
        guard record.protocolIdentityBindingsV2?.isEmpty != false else {
            return false
        }

        let preV2Payload = try createDataToSign(
            for: record,
            revoked: record.isTombstone,
            includeProtocolIdentityPins: true,
            includeProtocolIdentityBindingsV2: false
        )
        if try await keyManager.verify(
            data: preV2Payload,
            signature: record.signature,
            publicKey: signerPublicKey
        ) {
            return true
        }

        if hasSafePreMultiPinLegacyFields(record) {
            let preMultiPinPayload = try createDataToSign(
                for: record,
                revoked: record.isTombstone,
                includeProtocolIdentityPins: false,
                includeProtocolIdentityBindingsV2: false
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
