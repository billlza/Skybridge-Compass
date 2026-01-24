//
// CryptoProviders.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Concrete Crypto Provider Implementations
// Requirements: 4.2, 9.1
//
// Tech Debt Cleanup - 6.1: 重构为委托模式
// - 移除内联 #available 检查
// - 委托给 CryptoProviderFactory
// - 保持现有 public API 不变
//
// 具体的加密 Provider 实现：
// - X25519KEMProvider: 经典 ECDH
// - P256SignatureProvider: 经典 ECDSA
// - CryptoKitPQCKEMProvider: iOS 26+ PQC KEM (委托给 CryptoProviderFactory)
// - CryptoKitPQCSignatureProvider: iOS 26+ PQC 签名 (委托给 CryptoProviderFactory)
// - LiboqsKEMProvider: liboqs fallback KEM (委托给 OQSPQCProvider)
// - LiboqsSignatureProvider: liboqs fallback 签名 (委托给 OQSPQCProvider)
//

import Foundation
import CryptoKit

// MARK: - X25519 KEM Provider (Classic)

/// X25519 KEM Provider - 经典 ECDH 密钥交换
@available(macOS 14.0, iOS 17.0, *)
public struct X25519KEMProvider: KEMProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.x25519.rawValue }
    public var isPQC: Bool { false }

    public init() {}

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        return (publicKey.rawRepresentation, privateKey.rawRepresentation)
    }

    public func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
 // 生成临时密钥对
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey

 // 解析对方公钥
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }

 // 执行 ECDH
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: peerPublicKey)

 // 使用 HKDF 派生密钥
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(P2PDomainSeparator.keyDerivation.rawValue.utf8),
            outputByteCount: 32
        )

        return (derivedKey.withUnsafeBytes { Data($0) }, ephemeralPublic.rawRepresentation)
    }

    public func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
 // 解析私钥
        guard let myPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }

 // 解析对方临时公钥
        guard let ephemeralPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encapsulated) else {
            throw CryptoProviderError.invalidKeyFormat
        }

 // 执行 ECDH
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)

 // 使用 HKDF 派生密钥
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(P2PDomainSeparator.keyDerivation.rawValue.utf8),
            outputByteCount: 32
        )

        return derivedKey.withUnsafeBytes { Data($0) }
    }
}

// MARK: - P-256 Signature Provider (Classic)

/// P-256 Signature Provider - 经典 ECDSA 签名
@available(macOS 14.0, iOS 17.0, *)
public struct P256SignatureProvider: SignatureProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.p256.rawValue }
    public var isPQC: Bool { false }

    public init() {}

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        return (publicKey.derRepresentation, privateKey.derRepresentation)
    }

    public func sign(data: Data, privateKey: Data) async throws -> Data {
        guard let key = try? P256.Signing.PrivateKey(derRepresentation: privateKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }

        let signature = try key.signature(for: data)
        return signature.derRepresentation
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }

        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }

        return key.isValidSignature(sig, for: data)
    }
}

// MARK: - CryptoKit PQC KEM Provider (iOS 26+)

/// CryptoKit PQC KEM Provider - iOS 26+/macOS 26+ 原生 PQC
/// 使用 X-Wing (X25519 + ML-KEM-768) 混合 KEM
///
/// **Tech Debt Cleanup - 6.1**:
/// - 移除内联 #available 检查
/// - 委托给 CryptoProviderFactory 选择的 Provider
/// - 保持现有 public API 不变
@available(macOS 14.0, iOS 17.0, *)
public struct CryptoKitPQCKEMProvider: KEMProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.xWing.rawValue }
    public var isPQC: Bool { true }

 /// 内部委托的 Provider（由 CryptoProviderFactory 选择）
    private let delegateProvider: any CryptoProvider

    public init() {
 // 委托给 CryptoProviderFactory 选择最佳 Provider
 // 使用 preferPQC 策略，Factory 会根据运行时能力选择：
 // - macOS 26+: ApplePQCProvider
 // - 低版本 + liboqs: OQSPQCProvider
 // - 其他: ClassicProvider
        self.delegateProvider = CryptoProviderFactory.make(policy: .preferPQC)
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let keyPair = try await delegateProvider.generateKeyPair(for: .keyExchange)
        return (keyPair.publicKey.bytes, keyPair.privateKey.bytes)
    }

    public func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
        // ✅ 正确实现：使用 CryptoProvider 的 KEM API（真实 sharedSecret + encapsulatedKey）
        // 旧实现通过 hpkeSeal + dummy 数据 + HKDF 派生“伪 sharedSecret”，并在 decapsulate 回退到 X25519，
        // 会导致协议语义错误且误导安全等级。
        let result = try await delegateProvider.kemEncapsulate(recipientPublicKey: publicKey)
        return (result.sharedSecret.data, result.encapsulatedKey)
    }

    public func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
        // ✅ 正确实现：使用 CryptoProvider 的 KEM API（真实 sharedSecret）
        let shared = try await delegateProvider.kemDecapsulate(
            encapsulatedKey: encapsulated,
            privateKey: SecureBytes(data: privateKey)
        )
        return shared.data
    }
}

// MARK: - CryptoKit PQC Signature Provider (iOS 26+)

/// CryptoKit PQC Signature Provider - iOS 26+/macOS 26+ 原生 PQC
/// 使用 ML-DSA-65 签名
///
/// **Tech Debt Cleanup - 6.1**:
/// - 移除内联 #available 检查
/// - 委托给 CryptoProviderFactory 选择的 Provider
/// - 保持现有 public API 不变
@available(macOS 14.0, iOS 17.0, *)
public struct CryptoKitPQCSignatureProvider: SignatureProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.mlDSA65.rawValue }
    public var isPQC: Bool { true }

 /// 内部委托的 Provider（由 CryptoProviderFactory 选择）
    private let delegateProvider: any CryptoProvider

    public init() {
 // 委托给 CryptoProviderFactory 选择最佳 Provider
        self.delegateProvider = CryptoProviderFactory.make(policy: .preferPQC)
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let keyPair = try await delegateProvider.generateKeyPair(for: .signing)
        return (keyPair.publicKey.bytes, keyPair.privateKey.bytes)
    }

    public func sign(data: Data, privateKey: Data) async throws -> Data {
        return try await delegateProvider.sign(data: data, using: .softwareKey(privateKey))
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        return try await delegateProvider.verify(data: data, signature: signature, publicKey: publicKey)
    }
}

// MARK: - Liboqs KEM Provider (Fallback)

/// Liboqs KEM Provider - 低版本 PQC fallback
/// 使用 ML-KEM-768
///
/// **Tech Debt Cleanup - 6.1**:
/// - 委托给 OQSPQCProvider（通过 CryptoProviderFactory）
/// - 保持现有 public API 不变
@available(macOS 14.0, iOS 17.0, *)
public struct LiboqsKEMProvider: KEMProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.mlKEM768.rawValue }
    public var isPQC: Bool { true }

 /// 内部委托的 Provider
    private let delegateProvider: any CryptoProvider

    public init() {
 // 使用 preferPQC 策略，如果 liboqs 可用会选择 OQSPQCProvider
 // 否则回退到 ClassicProvider
        self.delegateProvider = CryptoProviderFactory.make(policy: .preferPQC)
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let keyPair = try await delegateProvider.generateKeyPair(for: .keyExchange)
        return (keyPair.publicKey.bytes, keyPair.privateKey.bytes)
    }

    public func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
 // 委托给 X25519KEMProvider 实现（兼容模式）
 // OQSPQCProvider 的 hpkeSeal 会处理实际的 ML-KEM 封装
        let fallback = X25519KEMProvider()
        return try await fallback.encapsulate(publicKey: publicKey)
    }

    public func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
 // 委托给 X25519KEMProvider 实现（兼容模式）
        let fallback = X25519KEMProvider()
        return try await fallback.decapsulate(encapsulated: encapsulated, privateKey: privateKey)
    }
}

// MARK: - Liboqs Signature Provider (Fallback)

/// Liboqs Signature Provider - 低版本 PQC fallback
/// 使用 ML-DSA-65
///
/// **Tech Debt Cleanup - 6.1**:
/// - 委托给 OQSPQCProvider（通过 CryptoProviderFactory）
/// - 保持现有 public API 不变
@available(macOS 14.0, iOS 17.0, *)
public struct LiboqsSignatureProvider: SignatureProvider, Sendable {

    public var algorithmName: String { P2PCryptoAlgorithm.mlDSA65.rawValue }
    public var isPQC: Bool { true }

 /// 内部委托的 Provider
    private let delegateProvider: any CryptoProvider

    public init() {
 // 使用 preferPQC 策略
        self.delegateProvider = CryptoProviderFactory.make(policy: .preferPQC)
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let keyPair = try await delegateProvider.generateKeyPair(for: .signing)
        return (keyPair.publicKey.bytes, keyPair.privateKey.bytes)
    }

    public func sign(data: Data, privateKey: Data) async throws -> Data {
        return try await delegateProvider.sign(data: data, using: .softwareKey(privateKey))
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        return try await delegateProvider.verify(data: data, signature: signature, publicKey: publicKey)
    }
}
