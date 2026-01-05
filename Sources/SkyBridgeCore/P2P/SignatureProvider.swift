//
// SignatureProvider.swift
// SkyBridgeCore
//
// Signature Mechanism Alignment - 1
// Requirements: 1.1, 1.2, 3.1, 3.2, 3.3, 5.1
//
// 独立的签名 Provider 协议和实现：
// - SignatureProvider 协议：专注于签名操作，独立于 CryptoProvider
// - ClassicSignatureProvider：Ed25519 签名（CryptoKit Curve25519.Signing）
// - PQCSignatureProvider：ML-DSA-65 签名（Apple PQC 或 OQS 后端）
// - P256SignatureProvider：P-256 ECDSA 签名（仅用于 legacy 验证和 SE PoP）
//
// **设计决策**：
// - 不复用 CryptoProvider，避免职责混淆
// - 每个 Provider 专注于单一签名算法
// - 支持 SigningKeyHandle 的多种形式（软件密钥、Secure Enclave、回调）
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - SignatureAlgorithm

/// 签名算法枚举（Wire 层，包含 P-256 用于 Codable 兼容）
public enum SignatureAlgorithm: String, Codable, Sendable, Equatable {
 /// Ed25519（Classic suite）
    case ed25519 = "Ed25519"
    
 /// ML-DSA-65（PQC suite）
    case mlDSA65 = "ML-DSA-65"
    
 /// P-256 ECDSA（Legacy / SE PoP）
    case p256ECDSA = "P-256-ECDSA"
    
 /// 根据 CryptoSuite 获取签名算法
 /// - Parameter suite: 加密套件
 /// - Returns: 对应的签名算法
    public static func forSuite(_ suite: CryptoSuite) -> SignatureAlgorithm {
 // isPQC 涵盖 PQC + Hybrid suites
        if suite.isPQC || suite.isHybrid {
            return .mlDSA65
        } else {
            return .ed25519
        }
    }
    
 /// Wire code for canonical transcript encoding
    public var wireCode: UInt16 {
        switch self {
        case .ed25519: return 0x0001
        case .mlDSA65: return 0x0002
        case .p256ECDSA: return 0x0003
        }
    }
}

// MARK: - ProtocolSigningAlgorithm

/// 协议签名算法（类型层面排除 P-256）
///
/// **设计原则**: 从类型系统层面保证 P-256 不能参与主协议签名 (sigA/sigB)
/// - 只有 ed25519 和 mlDSA65 两个 case
/// - 比 runtime precondition 强一万倍
/// - P-256 只能用于 seSig 和 legacy 验证
///
/// **Requirements: 1.1, 1.2, 3.4, 3.5**
public enum ProtocolSigningAlgorithm: String, Codable, Sendable, Hashable {
 /// Ed25519（Classic suite）
    case ed25519 = "Ed25519"
    
 /// ML-DSA-65（PQC suite）
    case mlDSA65 = "ML-DSA-65"
    
 /// 转换为通用 SignatureAlgorithm（用于 wire 层）
    public var wire: SignatureAlgorithm {
        switch self {
        case .ed25519: return .ed25519
        case .mlDSA65: return .mlDSA65
        }
    }
    
 /// 从通用 SignatureAlgorithm 转换（可能失败）
 /// - Returns: nil if algorithm is .p256ECDSA
    public init?(from wire: SignatureAlgorithm) {
        switch wire {
        case .ed25519: self = .ed25519
        case .mlDSA65: self = .mlDSA65
        case .p256ECDSA: return nil  // P-256 不允许用于协议签名
        }
    }
    
 /// Wire code for canonical transcript encoding
    public var wireCode: UInt16 {
        switch self {
        case .ed25519: return 0x0001
        case .mlDSA65: return 0x0002
        }
    }
    
 /// 根据 CryptoSuite 获取协议签名算法
 /// - Parameter suite: 加密套件
 /// - Returns: 对应的协议签名算法
    public static func forSuite(_ suite: CryptoSuite) -> ProtocolSigningAlgorithm {
 // isPQC 涵盖 PQC + Hybrid suites (isPQCGroup 将在 3 实现)
        if suite.isPQC || suite.isHybrid {
            return .mlDSA65
        } else {
            return .ed25519
        }
    }
}

// MARK: - SignatureProvider Protocol

/// 协议签名 Provider 协议（只管 sigA/sigB）
/// 独立于 CryptoProvider，专注于握手协议签名操作
///
/// **设计决策**：
/// - 使用 `SigningKeyHandle` 而非原始 `Data`，支持 Secure Enclave 和回调
/// - 使用 `ProtocolSigningAlgorithm` 枚举（类型层面排除 P-256）
/// - P256SePoPProvider 不 conform 此协议
///
/// **Requirements: 1.1, 1.2, 3.4, 3.5**
public protocol ProtocolSignatureProvider: Sendable {
 /// 签名算法（只能是 ed25519 或 mlDSA65，类型层面排除 P-256）
    var signatureAlgorithm: ProtocolSigningAlgorithm { get }
    
 /// 签名数据
 /// - Parameters:
 /// - data: 待签名数据
 /// - key: 签名密钥句柄
 /// - Returns: 签名
 /// - Throws: 签名失败时抛出错误
    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data
    
 /// 验证签名
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 公钥
 /// - Returns: 是否验证通过
 /// - Throws: 验证过程中发生错误时抛出
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - SignatureProviderError

/// 签名 Provider 错误
public enum SignatureProviderError: Error, LocalizedError, Sendable {
 /// 无效的密钥类型
    case invalidKeyType(expected: String, actual: String)
    
 /// 签名失败
    case signatureFailed(String)
    
 /// 验证失败
    case verificationFailed(String)
    
 /// 无效的公钥格式
    case invalidPublicKeyFormat(String)
    
 /// 无效的签名格式
    case invalidSignatureFormat(String)
    
 /// 不支持的密钥句柄类型
    case unsupportedKeyHandle(String)
    
 /// PQC 后端不可用
    case pqcBackendUnavailable(String)

 /// 内部不变量被破坏（不应导致崩溃）
    case internalInvariantViolated(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidKeyType(let expected, let actual):
            return "Invalid key type: expected \(expected), got \(actual)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .invalidPublicKeyFormat(let reason):
            return "Invalid public key format: \(reason)"
        case .invalidSignatureFormat(let reason):
            return "Invalid signature format: \(reason)"
        case .unsupportedKeyHandle(let type):
            return "Unsupported key handle type: \(type)"
        case .pqcBackendUnavailable(let reason):
            return "PQC backend unavailable: \(reason)"
        case .internalInvariantViolated(let reason):
            return "Internal invariant violated: \(reason)"
        }
    }
}

// MARK: - ClassicSignatureProvider (Ed25519)

/// Classic 签名 Provider (Ed25519)
///
/// 使用 CryptoKit `Curve25519.Signing` 实现 Ed25519 签名。
///
/// **Requirements: 1.1**
public struct ClassicSignatureProvider: ProtocolSignatureProvider {
    public let signatureAlgorithm: ProtocolSigningAlgorithm = .ed25519
    
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
 // Ed25519 私钥长度：32 bytes (seed) 或 64 bytes (seed + public)
            let keyData: Data
            if privateKeyData.count == 64 {
 // 取前 32 bytes 作为 seed
                keyData = privateKeyData.prefix(32)
            } else if privateKeyData.count == 32 {
                keyData = privateKeyData
            } else {
                throw SignatureProviderError.invalidKeyType(
                    expected: "Ed25519 (32 or 64 bytes)",
                    actual: "\(privateKeyData.count) bytes"
                )
            }
            
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
            let signature = try privateKey.signature(for: data)
            return signature
            
        #if canImport(Security)
        case .secureEnclaveRef:
 // Ed25519 不支持 Secure Enclave（SE 只支持 P-256）
            throw SignatureProviderError.unsupportedKeyHandle(
                "Secure Enclave does not support Ed25519; use P256SignatureProvider for SE keys"
            )
        #endif
            
        case .callback(let signingCallback):
 // 使用回调签名（可能是远程签名服务）
            return try await signingCallback.sign(data: data)
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // Ed25519 公钥长度：32 bytes
        guard publicKey.count == 32 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "Ed25519 public key must be 32 bytes, got \(publicKey.count)"
            )
        }
        
 // Ed25519 签名长度：64 bytes
        guard signature.count == 64 else {
            throw SignatureProviderError.invalidSignatureFormat(
                "Ed25519 signature must be 64 bytes, got \(signature.count)"
            )
        }
        
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return pubKey.isValidSignature(signature, for: data)
    }
}


// MARK: - PQCSignatureBackend

/// PQC 签名后端选择
public enum PQCSignatureBackend: Sendable {
 /// Apple PQC (CryptoKit ML-DSA, macOS 26+/iOS 26+)
    case applePQC
    
 /// liboqs ML-DSA
    case oqs
    
 /// 自动选择（优先 Apple PQC，回退 OQS）
    case auto
}

// MARK: - PQCSignatureProvider (ML-DSA-65)

/// PQC 签名 Provider (ML-DSA-65)
///
/// 支持 Apple PQC 和 OQS 后端。
///
/// **Requirements: 1.2, 7.1, 7.2, 7.3**
public struct PQCSignatureProvider: ProtocolSignatureProvider {
    public let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65
    
 /// 底层实现后端
    private let backend: PQCSignatureBackend
    
    public init(backend: PQCSignatureBackend = .auto) {
        self.backend = backend
    }
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        let resolvedBackend = try resolveBackend()
        
        switch resolvedBackend {
        case .applePQC:
            return try await signWithApplePQC(data, key: key)
        case .oqs:
            return try await signWithOQS(data, key: key)
        case .auto:
            throw SignatureProviderError.internalInvariantViolated("Backend should be resolved before sign()")
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let resolvedBackend = try resolveBackend()
        
        switch resolvedBackend {
        case .applePQC:
            return try await verifyWithApplePQC(data, signature: signature, publicKey: publicKey)
        case .oqs:
            return try await verifyWithOQS(data, signature: signature, publicKey: publicKey)
        case .auto:
            throw SignatureProviderError.internalInvariantViolated("Backend should be resolved before verify()")
        }
    }
    
 // MARK: - Private Methods
    
    private func resolveBackend() throws -> PQCSignatureBackend {
        switch backend {
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(macOS 26.0, iOS 26.0, *) {
                return .applePQC
            }
            #endif
            throw SignatureProviderError.pqcBackendUnavailable("Apple PQC SDK not available")
            
        case .oqs:
 // OQS 总是可用（编译时链接）
            return .oqs
            
        case .auto:
            #if HAS_APPLE_PQC_SDK
            if #available(macOS 26.0, iOS 26.0, *) {
                return .applePQC
            }
            #endif
            return .oqs
        }
    }
    
 // MARK: - Apple PQC Implementation
    
    private func signWithApplePQC(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            switch key {
            case .softwareKey(let privateKeyData):
 // ML-DSA-65 私钥：64 bytes (seed format)
                let privateKey = try MLDSA65.PrivateKey(integrityCheckedRepresentation: privateKeyData)
                let signature = try privateKey.signature(for: data)
                return signature
                
            #if canImport(Security)
            case .secureEnclaveRef:
                throw SignatureProviderError.unsupportedKeyHandle(
                    "Secure Enclave does not support ML-DSA-65"
                )
            #endif
                
            case .callback(let signingCallback):
                return try await signingCallback.sign(data: data)
            }
        }
        #endif
        throw SignatureProviderError.pqcBackendUnavailable("Apple PQC SDK not available")
    }
    
    private func verifyWithApplePQC(
        _ data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
 // ML-DSA-65 公钥：1952 bytes
            guard publicKey.count == 1952 else {
                throw SignatureProviderError.invalidPublicKeyFormat(
                    "ML-DSA-65 public key must be 1952 bytes, got \(publicKey.count)"
                )
            }
            
            let pubKey = try MLDSA65.PublicKey(rawRepresentation: publicKey)
            return pubKey.isValidSignature(signature, for: data)
        }
        #endif
        throw SignatureProviderError.pqcBackendUnavailable("Apple PQC SDK not available")
    }
    
 // MARK: - OQS Implementation
    
    private func signWithOQS(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
 // 使用 OQS ML-DSA-65 签名
 // OQS 私钥格式：4032 bytes (full private key)
            return try await OQSMLDSAHelper.sign(data: data, privateKey: privateKeyData)
            
        #if canImport(Security)
        case .secureEnclaveRef:
            throw SignatureProviderError.unsupportedKeyHandle(
                "Secure Enclave does not support ML-DSA-65"
            )
        #endif
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
        }
    }
    
    private func verifyWithOQS(
        _ data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
 // ML-DSA-65 公钥：1952 bytes
        guard publicKey.count == 1952 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "ML-DSA-65 public key must be 1952 bytes, got \(publicKey.count)"
            )
        }
        
        return try await OQSMLDSAHelper.verify(data: data, signature: signature, publicKey: publicKey)
    }
}

// MARK: - OQSMLDSAHelper

/// OQS ML-DSA-65 辅助类
///
/// 封装 liboqs ML-DSA-65 操作，复用 OQSPQCCryptoProvider 的实现。
@available(macOS 14.0, iOS 17.0, *)
internal enum OQSMLDSAHelper {
 /// ML-DSA-65 签名
 /// - Parameters:
 /// - data: 待签名数据
 /// - privateKey: ML-DSA-65 私钥
 /// - Returns: 签名
    static func sign(data: Data, privateKey: Data) async throws -> Data {
 // 复用 OQSPQCCryptoProvider 的签名实现
        let provider = OQSPQCCryptoProvider()
        let keyHandle = SigningKeyHandle.softwareKey(privateKey)
        return try await provider.sign(data: data, using: keyHandle)
    }
    
 /// ML-DSA-65 验证
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: ML-DSA-65 公钥
 /// - Returns: 是否验证通过
    static func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let provider = OQSPQCCryptoProvider()
        return try await provider.verify(data: data, signature: signature, publicKey: publicKey)
    }
}


// MARK: - SePoPSignatureProvider Protocol

/// SE PoP 签名 Provider 协议（独立于 ProtocolSignatureProvider）
///
/// **设计原则**:
/// - 不 conform ProtocolSignatureProvider
/// - 只用于 seSigA/seSigB
/// - 算法固定为 P-256 ECDSA
///
/// **Requirements: 3.3, 11.1, 11.2**
public protocol SePoPSignatureProvider: Sendable {
 /// 签名数据
    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data
    
 /// 验证签名
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - LegacySignatureVerifier Protocol

/// Legacy 签名验证器协议（只能验证，不能签名）
///
/// **设计原则**:
/// - 只用于首次接触的 legacy 验证
/// - 没有 sign 方法，防止误用
/// - P-256 verify only
///
/// **Requirements: 3.3, 11.1, 11.2**
public protocol LegacySignatureVerifier: Sendable {
 /// 验证签名（只能验证，不能签名）
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - P256SePoPProvider (P-256 ECDSA for SE PoP)

/// P-256 SE PoP 签名 Provider
///
/// **重要**: 不 conform ProtocolSignatureProvider，无法被当成协议签名器使用
/// 仅用于 seSigA/seSigB（Secure Enclave Proof-of-Possession）
///
/// **Requirements: 3.3, 5.1**
public struct P256SePoPProvider: SePoPSignatureProvider {
    
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
 // P-256 私钥：32 bytes
            guard privateKeyData.count == 32 else {
                throw SignatureProviderError.invalidKeyType(
                    expected: "P-256 (32 bytes)",
                    actual: "\(privateKeyData.count) bytes"
                )
            }
            
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: data)
            return signature.derRepresentation
            
        #if canImport(Security)
        case .secureEnclaveRef(let secKey):
 // 使用 Secure Enclave 签名
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                secKey,
                .ecdsaSignatureMessageX962SHA256,
                data as CFData,
                &error
            ) else {
                let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
                throw SignatureProviderError.signatureFailed(errorDesc)
            }
            return signature as Data
        #endif
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // P-256 公钥：65 bytes (uncompressed) 或 33 bytes (compressed)
        guard publicKey.count == 65 || publicKey.count == 33 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "P-256 public key must be 65 (uncompressed) or 33 (compressed) bytes, got \(publicKey.count)"
            )
        }
        
        do {
            let pubKey: P256.Signing.PublicKey
            if publicKey.count == 65 {
                pubKey = try P256.Signing.PublicKey(x963Representation: publicKey)
            } else {
                pubKey = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
            }
            
 // 尝试 DER 格式签名
            if let derSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                return pubKey.isValidSignature(derSignature, for: SHA256.hash(data: data))
            }
            
 // 尝试 raw 格式签名 (r || s, 64 bytes)
            if signature.count == 64,
               let rawSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
                return pubKey.isValidSignature(rawSignature, for: SHA256.hash(data: data))
            }
            
            throw SignatureProviderError.invalidSignatureFormat(
                "P-256 signature must be DER or raw (64 bytes) format"
            )
        } catch let error as SignatureProviderError {
            throw error
        } catch {
            throw SignatureProviderError.verificationFailed(error.localizedDescription)
        }
    }
}

// MARK: - P256LegacyVerifier (verify-only)

/// P-256 Legacy 验证器
///
/// **重要**: 只能验证，不能签名，防止误用
/// 仅用于首次接触的 legacy 验证
///
/// **Requirements: 3.3, 11.1, 11.2**
public struct P256LegacyVerifier: LegacySignatureVerifier {
    
    public init() {}
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // P-256 公钥：65 bytes (uncompressed) 或 33 bytes (compressed)
        guard publicKey.count == 65 || publicKey.count == 33 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "P-256 public key must be 65 (uncompressed) or 33 (compressed) bytes, got \(publicKey.count)"
            )
        }
        
        do {
            let pubKey: P256.Signing.PublicKey
            if publicKey.count == 65 {
                pubKey = try P256.Signing.PublicKey(x963Representation: publicKey)
            } else {
                pubKey = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
            }
            
 // 尝试 DER 格式签名
            if let derSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                return pubKey.isValidSignature(derSignature, for: SHA256.hash(data: data))
            }
            
 // 尝试 raw 格式签名 (r || s, 64 bytes)
            if signature.count == 64,
               let rawSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
                return pubKey.isValidSignature(rawSignature, for: SHA256.hash(data: data))
            }
            
            throw SignatureProviderError.invalidSignatureFormat(
                "P-256 signature must be DER or raw (64 bytes) format"
            )
        } catch let error as SignatureProviderError {
            throw error
        } catch {
            throw SignatureProviderError.verificationFailed(error.localizedDescription)
        }
    }
}

// MARK: - P256ProtocolSignatureProvider (Legacy, deprecated)

/// P-256 ECDSA 签名 Provider
///
/// **已废弃**: 请使用 P256SePoPProvider 或 P256LegacyVerifier
///
/// 仅用于：
/// 1. Legacy 签名验证（向后兼容）
/// 2. Secure Enclave PoP 签名（seSigA/seSigB）
///
/// **Requirements: 5.1**
@available(*, deprecated, message: "Use P256SePoPProvider for SE PoP or P256LegacyVerifier for legacy verification")
public struct P256ProtocolSignatureProvider {
    public let signatureAlgorithm: SignatureAlgorithm = .p256ECDSA
    
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
 // P-256 私钥：32 bytes
            guard privateKeyData.count == 32 else {
                throw SignatureProviderError.invalidKeyType(
                    expected: "P-256 (32 bytes)",
                    actual: "\(privateKeyData.count) bytes"
                )
            }
            
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: data)
 // 返回 DER 编码的签名
            return signature.derRepresentation
            
        #if canImport(Security)
        case .secureEnclaveRef(let secKey):
 // 使用 Secure Enclave 签名
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                secKey,
                .ecdsaSignatureMessageX962SHA256,
                data as CFData,
                &error
            ) else {
                let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
                throw SignatureProviderError.signatureFailed(errorDesc)
            }
            return signature as Data
        #endif
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // P-256 公钥：65 bytes (uncompressed) 或 33 bytes (compressed)
        guard publicKey.count == 65 || publicKey.count == 33 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "P-256 public key must be 65 (uncompressed) or 33 (compressed) bytes, got \(publicKey.count)"
            )
        }
        
 // 尝试使用 CryptoKit 验证
        do {
            let pubKey: P256.Signing.PublicKey
            if publicKey.count == 65 {
                pubKey = try P256.Signing.PublicKey(x963Representation: publicKey)
            } else {
                pubKey = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
            }
            
 // 尝试 DER 格式签名
            if let derSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                return pubKey.isValidSignature(derSignature, for: SHA256.hash(data: data))
            }
            
 // 尝试 raw 格式签名 (r || s, 64 bytes)
            if signature.count == 64,
               let rawSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
                return pubKey.isValidSignature(rawSignature, for: SHA256.hash(data: data))
            }
            
            throw SignatureProviderError.invalidSignatureFormat(
                "P-256 signature must be DER or raw (64 bytes) format"
            )
        } catch let error as SignatureProviderError {
            throw error
        } catch {
 // 回退到 Security framework 验证
            #if canImport(Security)
            return try verifyWithSecurityFramework(data: data, signature: signature, publicKey: publicKey)
            #else
            throw SignatureProviderError.verificationFailed(error.localizedDescription)
            #endif
        }
    }
    
    #if canImport(Security)
    private func verifyWithSecurityFramework(
        data: Data,
        signature: Data,
        publicKey: Data
    ) throws -> Bool {
 // 从 DER 数据创建公钥
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        
        var error: Unmanaged<CFError>?
        guard let publicKeyRef = SecKeyCreateWithData(
            publicKey as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Invalid key data"
            throw SignatureProviderError.invalidPublicKeyFormat(errorDesc)
        }
        
 // 验证签名
        let isValid = SecKeyVerifySignature(
            publicKeyRef,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            signature as CFData,
            &error
        )
        
        return isValid
    }
    #endif
}

// MARK: - ProtocolSignatureProviderSelector

/// 协议签名 Provider 选择器
///
/// 根据 CryptoProviderTier 或 ProtocolSigningAlgorithm 选择合适的签名 Provider。
///
/// **Requirements: 3.1, 3.2, 3.3**
public struct ProtocolSignatureProviderSelector {
    
 /// 根据 CryptoProvider tier 选择签名 Provider
 /// - Parameter tier: CryptoProvider tier
 /// - Returns: 用于 sigA/sigB 的签名 Provider
    public static func select(for tier: CryptoTier) -> any ProtocolSignatureProvider {
        switch tier {
        case .nativePQC:
            return PQCSignatureProvider(backend: .applePQC)
        case .liboqsPQC:
            return PQCSignatureProvider(backend: .oqs)
        case .classic:
            return ClassicSignatureProvider()
        }
    }
    
 /// 根据协议签名算法选择签名 Provider
 /// - Parameter algorithm: 协议签名算法（类型层面排除 P-256）
 /// - Returns: 签名 Provider
    public static func select(for algorithm: ProtocolSigningAlgorithm) -> any ProtocolSignatureProvider {
        switch algorithm {
        case .ed25519:
            return ClassicSignatureProvider()
        case .mlDSA65:
 // 优先使用 Apple PQC，回退到 OQS
            return PQCSignatureProvider(backend: .auto)
        }
    }
    
 /// 根据通用签名算法选择签名 Provider（兼容旧代码）
 /// - Parameter algorithm: 签名算法
 /// - Returns: 签名 Provider（P-256 返回 nil）
    public static func selectProtocolProvider(for algorithm: SignatureAlgorithm) -> (any ProtocolSignatureProvider)? {
        guard let protocolAlg = ProtocolSigningAlgorithm(from: algorithm) else {
            return nil  // P-256 不能用于协议签名
        }
        return select(for: protocolAlg)
    }
}
