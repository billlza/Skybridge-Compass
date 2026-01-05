//
// MultiAlgorithmSignatureVerifier.swift
// SkyBridgeCore
//
// 7.1: 向后兼容签名验证
// Requirements: 5.1, 5.3
//
// 签名验证器，支持多算法回退，带安全前置条件。
//
// **设计原则**: 不可误用的接口
// - 只接受 trustRecord，内部自己取 publicKey
// - 避免调用方传错 publicKey
//

import Foundation

// MARK: - SignatureAlignmentError

/// 签名对齐错误
///
/// **Requirements: 5.1, 5.3, 7.4, 7.5**
public enum SignatureAlignmentError: Error, LocalizedError, Sendable {
    case protocolKeyGenerationFailed(String)
    case protocolKeyNotFound
    case signatureAlgorithmMismatch(expected: SignatureAlgorithm, actual: SignatureAlgorithm)
    case suiteSignatureMismatch(selectedSuite: String, sigAAlgorithm: String)
    case legacySignatureRejected
    case migrationFailed(String)
    
 // Protocol Signature Invariants ( 3.4) - 新增 cases
 /// Provider 算法不匹配（provider 与 sigAAlgorithm 不一致）
    case providerAlgorithmMismatch(expected: ProtocolSigningAlgorithm, actual: ProtocolSigningAlgorithm)
 /// Wire 层算法与 sigAAlgorithm 不一致
    case wireAlgorithmMismatch(wireAlgorithm: SignatureAlgorithm, sigAAlgorithm: ProtocolSigningAlgorithm)
 /// offeredSuites 与 sigAAlgorithm 同质性违反
    case homogeneityViolation(sigAAlgorithm: ProtocolSigningAlgorithm, offeredSuites: [CryptoSuite])
 /// offeredSuites 为空
    case emptyOfferedSuites
 /// Legacy fallback 不允许（无安全前置条件）
    case legacyFallbackNotAllowed(reason: String)
 /// Transcript 不匹配
    case transcriptMismatch
 /// 算法不允许用于协议签名（P-256）
    case invalidAlgorithmForProtocolSigning(algorithm: SignatureAlgorithm)
 /// 无效的 Provider 类型（CryptoProvider 被当签名 provider）
    case invalidProviderType(message: String)
    
    public var errorDescription: String? {
        switch self {
        case .protocolKeyGenerationFailed(let reason):
            return "Protocol signing key generation failed: \(reason)"
        case .protocolKeyNotFound:
            return "Protocol signing key not found"
        case .signatureAlgorithmMismatch(let expected, let actual):
            return "Signature algorithm mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "Suite-signature mismatch: selectedSuite \(selectedSuite) incompatible with sigA algorithm \(sigAAlgorithm)"
        case .legacySignatureRejected:
            return "Legacy signature rejected (transition period ended)"
        case .migrationFailed(let reason):
            return "Key migration failed: \(reason)"
        case .providerAlgorithmMismatch(let expected, let actual):
            return "Provider algorithm mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .wireAlgorithmMismatch(let wireAlgorithm, let sigAAlgorithm):
            return "Wire algorithm \(wireAlgorithm.rawValue) does not match sigAAlgorithm \(sigAAlgorithm.rawValue)"
        case .homogeneityViolation(let sigAAlgorithm, let offeredSuites):
            return "Homogeneity violation: sigAAlgorithm=\(sigAAlgorithm.rawValue), offeredSuites count=\(offeredSuites.count)"
        case .emptyOfferedSuites:
            return "offeredSuites cannot be empty"
        case .legacyFallbackNotAllowed(let reason):
            return "Legacy fallback not allowed: \(reason)"
        case .transcriptMismatch:
            return "Transcript mismatch detected"
        case .invalidAlgorithmForProtocolSigning(let algorithm):
            return "Algorithm \(algorithm.rawValue) is not allowed for protocol signing (sigA/sigB)"
        case .invalidProviderType(let message):
            return "Invalid provider type: \(message)"
        }
    }
}

// MARK: - MultiAlgorithmSignatureVerifier

/// 签名验证器（支持多算法回退，带安全前置条件）
///
/// **设计原则**: 不可误用的接口
/// - 只接受 trustRecord，内部自己取 publicKey
/// - 避免调用方传错 publicKey
///
/// **Requirements: 5.1, 5.3**
public struct MultiAlgorithmSignatureVerifier: Sendable {
    
 /// 验证签名，支持 Ed25519 和 P-256 ECDSA 回退
 ///
 /// **安全前置条件**:
 /// - Legacy fallback 只允许在 TrustRecord 已明确记录该 peer 的 legacy P-256 身份公钥时
 /// - 首次连接/未 pin 的情况下禁止 fallback
 /// - 每次 legacy fallback 都发射 downgrade event
 ///
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - expectedAlgorithm: 预期算法（基于 suite）
 /// - trustRecord: 对端的 TrustRecord（用于获取公钥和判断是否允许 fallback）
 /// - Returns: 验证结果
 /// - Throws: SignatureAlignmentError 如果 trustRecord 为 nil
    public static func verify(
        data: Data,
        signature: Data,
        expectedAlgorithm: SignatureAlgorithm,
        trustRecord: TrustRecord
    ) async throws -> Bool {
 // 1. 从 trustRecord 获取公钥（不可误用的接口设计）
        guard let publicKey = trustRecord.getVerificationPublicKey(for: expectedAlgorithm) else {
 // 没有对应算法的公钥
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .signatureVerificationFailed,
                severity: .warning,
                message: "No public key found for expected algorithm",
                context: [
                    "expectedAlgorithm": expectedAlgorithm.rawValue,
                    "deviceId": trustRecord.deviceId
                ]
            ))
            return false
        }
        
 // 2. 尝试预期算法
        if try await verifyWith(algorithm: expectedAlgorithm, data: data, signature: signature, publicKey: publicKey) {
            return true
        }

        
 // 3. 安全检查: 是否允许 legacy fallback
        guard trustRecord.allowsLegacyFallback,
              let legacyPublicKey = trustRecord.legacyP256PublicKey else {
 // 不允许 fallback
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .signatureVerificationFailed,
                severity: .warning,
                message: "Signature verification failed, legacy fallback not allowed",
                context: [
                    "expectedAlgorithm": expectedAlgorithm.rawValue,
                    "reason": "no_legacy_trust_record",
                    "deviceId": trustRecord.deviceId
                ]
            ))
            return false
        }
        
 // 4. 向后兼容: 尝试 P-256 ECDSA (legacy peers)
        if expectedAlgorithm == .ed25519 {
            if try await verifyWith(algorithm: .p256ECDSA, data: data, signature: signature, publicKey: legacyPublicKey) {
 // 发射 downgrade event
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .legacySignatureAccepted,
                    severity: .warning,
                    message: "Accepted legacy P-256 signature for Ed25519 suite (downgrade)",
                    context: [
                        "expectedAlgorithm": expectedAlgorithm.rawValue,
                        "actualAlgorithm": SignatureAlgorithm.p256ECDSA.rawValue,
                        "deviceId": trustRecord.deviceId
                    ]
                ))
                return true
            }
        }
        
        return false
    }
    
 /// 验证首次接触的签名（从 MessageA/MessageB 中获取公钥）
 ///
 /// **安全设计**: 首次接触不允许 fallback，必须使用预期算法
 ///
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 从消息中提取的公钥
 /// - expectedAlgorithm: 预期算法
 /// - Returns: 验证结果
    public static func verifyFirstContact(
        data: Data,
        signature: Data,
        publicKey: Data,
        expectedAlgorithm: SignatureAlgorithm
    ) async throws -> Bool {
 // 首次接触不允许 fallback，必须使用预期算法
        return try await verifyWith(algorithm: expectedAlgorithm, data: data, signature: signature, publicKey: publicKey)
    }
    
 /// 使用指定算法验证签名
    private static func verifyWith(
        algorithm: SignatureAlgorithm,
        data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        switch algorithm {
        case .ed25519:
            let provider = ClassicSignatureProvider()
            return try await provider.verify(data, signature: signature, publicKey: publicKey)
        case .mlDSA65:
            let provider = PQCSignatureProvider(backend: .auto)
            return try await provider.verify(data, signature: signature, publicKey: publicKey)
        case .p256ECDSA:
 // P-256 只用于 legacy 验证，使用 LegacySignatureVerifier
            let verifier = P256LegacyVerifier()
            return try await verifier.verify(data, signature: signature, publicKey: publicKey)
        }
    }
    
 // MARK: - Key Upgrade ( 13.1)
    
 /// 验证密钥升级请求（双签名绑定）
 ///
 /// **安全设计**: 用于迁移期安全升级公钥
 /// - 老 peer 发送升级请求，包含新的 Ed25519 公钥
 /// - 用老 P-256 密钥对新公钥的签名（证明控制老密钥）
 /// - 用新 Ed25519 密钥对老公钥的签名（证明控制新密钥）
 ///
 /// **Property 8: Key Upgrade Security (Dual-Signature Binding)**
 /// **Validates: Requirements 5.4**
 ///
 /// - Parameters:
 /// - oldP256PublicKey: 已 pin 的老公钥 (P-256)
 /// - newEd25519PublicKey: 新公钥 (Ed25519)
 /// - oldKeySignature: P-256 签名 over newEd25519PublicKey
 /// - newKeySignature: Ed25519 签名 over oldP256PublicKey
 /// - Returns: 是否验证通过
 /// - Throws: SignatureAlignmentError 如果验证失败
    public static func verifyKeyUpgrade(
        oldP256PublicKey: Data,
        newEd25519PublicKey: Data,
        oldKeySignature: Data,
        newKeySignature: Data
    ) async throws -> Bool {
 // 1. 验证老密钥签名（P-256 签名 over newEd25519PublicKey）
        let oldKeyValid = try await verifyWith(
            algorithm: .p256ECDSA,
            data: newEd25519PublicKey,
            signature: oldKeySignature,
            publicKey: oldP256PublicKey
        )
        
        guard oldKeyValid else {
            throw SignatureAlignmentError.migrationFailed("Old key signature invalid")
        }
        
 // 2. 验证新密钥签名（Ed25519 签名 over oldP256PublicKey）
        let newKeyValid = try await verifyWith(
            algorithm: .ed25519,
            data: oldP256PublicKey,
            signature: newKeySignature,
            publicKey: newEd25519PublicKey
        )
        
        guard newKeyValid else {
            throw SignatureAlignmentError.migrationFailed("New key signature invalid")
        }
        
 // 3. 发射密钥升级成功事件
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .keyMigrationCompleted,
            severity: .info,
            message: "Key upgrade verified successfully (dual-signature binding)",
            context: [
                "oldKeyAlgorithm": SignatureAlgorithm.p256ECDSA.rawValue,
                "newKeyAlgorithm": SignatureAlgorithm.ed25519.rawValue
            ]
        ))
        
        return true
    }
}
