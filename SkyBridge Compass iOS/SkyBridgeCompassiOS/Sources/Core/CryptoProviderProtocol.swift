//
// CryptoProviderProtocol.swift
// SkyBridgeCompassiOS
//
// 与 macOS SkyBridgeCore 完全兼容的加密 Provider 协议
// 确保 iOS 与 macOS 之间的量子安全通信互操作性
//
// 注意：基础类型（CryptoSuite, CryptoTier, SecureBytes 等）定义在 CoreTypes.swift 中
//

import Foundation

// MARK: - CryptoProvider Protocol

/// 统一的加密 Provider 协议
public protocol CryptoProvider: Sendable {
    /// Provider 标识
    var providerName: String { get }
    
    /// Provider 层级
    var tier: CryptoTier { get }
    
    /// 当前使用的算法套件
    var activeSuite: CryptoSuite { get }
    
    /// 支持的所有算法套件
    var supportedSuites: [CryptoSuite] { get }

    /// 是否支持指定算法套件
    func supportsSuite(_ suite: CryptoSuite) -> Bool
    
    /// HPKE 封装（KEM）
    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

    /// KEM-DEM 封装
    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

    /// KEM-DEM 封装（导出共享密钥）
    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes)
    
    /// HPKE 解封装
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data
    
    /// HPKE 解封装（SecureBytes 版本）
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

    /// KEM-DEM 解封装
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

    /// KEM-DEM 解封装（导出共享密钥）
    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes)
    
    /// KEM 封装
    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes)
    
    /// KEM 解封装
    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes
    
    /// 数字签名
    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data
    
    /// 签名验证
    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool
    
    /// 生成密钥对
    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair
}

// MARK: - Default Implementations

public extension CryptoProvider {
    var supportedSuites: [CryptoSuite] {
        [activeSuite]
    }
    
    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }
    
    func kemDemSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
    }
    
    func kemDemOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }
}

// MARK: - CryptoProviderError

/// 加密 Provider 错误
public enum CryptoProviderError: Error, LocalizedError, Sendable {
    case unsupportedOperation(String)
    case invalidKeySize(expected: Int, actual: Int)
    case invalidKeyLength(expected: Int, actual: Int, suite: String, usage: KeyUsage)
    case invalidKeyFormat
    case invalidPublicKey(String)
    case invalidPrivateKey(String)
    case encapsulationFailed(String)
    case decapsulationFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case keyGenerationFailed(String)
    case pqcNotAvailable
    case invalidCiphertext(String)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let op): return "Unsupported operation: \(op)"
        case .invalidKeySize(let expected, let actual): return "Invalid key size: expected \(expected), got \(actual)"
        case .invalidKeyLength(let expected, let actual, let suite, let usage): return "Invalid key length for \(suite) \(usage.rawValue): expected \(expected), got \(actual)"
        case .invalidKeyFormat: return "Invalid key format"
        case .invalidPublicKey(let reason): return "Invalid public key: \(reason)"
        case .invalidPrivateKey(let reason): return "Invalid private key: \(reason)"
        case .encapsulationFailed(let reason): return "Encapsulation failed: \(reason)"
        case .decapsulationFailed(let reason): return "Decapsulation failed: \(reason)"
        case .signatureFailed(let reason): return "Signature failed: \(reason)"
        case .verificationFailed(let reason): return "Verification failed: \(reason)"
        case .keyGenerationFailed(let reason): return "Key generation failed: \(reason)"
        case .pqcNotAvailable: return "PQC not available on this platform"
        case .invalidCiphertext(let reason): return "Invalid ciphertext: \(reason)"
        }
    }
}
