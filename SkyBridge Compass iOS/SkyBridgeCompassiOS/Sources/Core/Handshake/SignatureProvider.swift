//
// SignatureProvider.swift
// SkyBridgeCompassiOS
//
// 签名 Provider 协议和实现 - 与 macOS SkyBridgeCore 完全兼容
// 注意：基础类型（SigningKeyHandle, SigningCallback）定义在 CoreTypes.swift 中
// 注意：SignatureAlgorithm, ProtocolSigningAlgorithm 定义在 HandshakeMessages.swift 中
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - SignatureProviderError

/// 签名 Provider 错误
public enum SignatureProviderError: Error, LocalizedError, Sendable {
    case invalidKeyType(expected: String, actual: String)
    case signatureFailed(String)
    case verificationFailed(String)
    case invalidPublicKeyFormat(String)
    case invalidSignatureFormat(String)
    case unsupportedKeyHandle(String)
    case pqcBackendUnavailable(String)
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

// MARK: - ProtocolSignatureProvider Protocol

/// 协议签名 Provider 协议（只管 sigA/sigB）
public protocol ProtocolSignatureProvider: Sendable {
    /// 签名算法
    var signatureAlgorithm: ProtocolSigningAlgorithm { get }
    
    /// 签名数据
    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data
    
    /// 验证签名
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - SePoPSignatureProvider Protocol

/// SE PoP 签名 Provider 协议
public protocol SePoPSignatureProvider: Sendable {
    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data
    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - ClassicSignatureProvider (Ed25519)

/// Classic 签名 Provider (Ed25519)
public struct ClassicSignatureProvider: ProtocolSignatureProvider {
    public let signatureAlgorithm: ProtocolSigningAlgorithm = .ed25519
    
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
            let keyData: Data
            if privateKeyData.count == 64 {
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
            throw SignatureProviderError.unsupportedKeyHandle(
                "Secure Enclave does not support Ed25519; use P256SePoPProvider for SE keys"
            )
        #endif
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        guard publicKey.count == 32 else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "Ed25519 public key must be 32 bytes, got \(publicKey.count)"
            )
        }
        
        guard signature.count == 64 else {
            throw SignatureProviderError.invalidSignatureFormat(
                "Ed25519 signature must be 64 bytes, got \(signature.count)"
            )
        }
        
        let publicKeyObj = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return publicKeyObj.isValidSignature(signature, for: data)
    }
}

// MARK: - PQCSignatureProvider (ML-DSA-65)

/// PQC 签名 Provider (ML-DSA-65)
public struct PQCSignatureProvider: ProtocolSignatureProvider {
    public let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65
    
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await signWithApplePQC(data, key: key)
        }
        #endif
        
        throw SignatureProviderError.pqcBackendUnavailable(
            "ML-DSA-65 requires iOS 26+ or liboqs integration"
        )
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await verifyWithApplePQC(data, signature: signature, publicKey: publicKey)
        }
        #endif
        
        throw SignatureProviderError.pqcBackendUnavailable(
            "ML-DSA-65 verification requires iOS 26+ or liboqs integration"
        )
    }
    
    #if HAS_APPLE_PQC_SDK
    @available(iOS 26.0, macOS 26.0, *)
    private func signWithApplePQC(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .softwareKey(let privateKeyData):
            // CryptoKit (iOS 26/macOS 26) 约定：MLDSA65.PrivateKey.integrityCheckedRepresentation 为 64 bytes（紧凑格式）
            guard privateKeyData.count == 64 else {
                throw SignatureProviderError.invalidKeyType(
                    expected: "ML-DSA-65 private key (64 bytes integrityCheckedRepresentation)",
                    actual: "\(privateKeyData.count) bytes"
                )
            }
            let privateKey = try MLDSA65.PrivateKey(integrityCheckedRepresentation: privateKeyData)
            return try privateKey.signature(for: data)
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
            
        #if canImport(Security)
        case .secureEnclaveRef:
            throw SignatureProviderError.unsupportedKeyHandle(
                "Secure Enclave does not support ML-DSA-65"
            )
        #endif
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func verifyWithApplePQC(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let publicKeyObj = try MLDSA65.PublicKey(rawRepresentation: publicKey)
        return publicKeyObj.isValidSignature(signature, for: data)
    }
    #endif
}

// MARK: - P256SePoPProvider

/// P-256 ECDSA 签名 Provider（仅用于 Secure Enclave PoP）
public struct P256SePoPProvider: SePoPSignatureProvider {
    public init() {}
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        #if canImport(Security)
        case .secureEnclaveRef(let secKey):
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                secKey,
                .ecdsaSignatureMessageX962SHA256,
                data as CFData,
                &error
            ) as Data? else {
                let errorMessage = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "Unknown error"
                throw SignatureProviderError.signatureFailed(errorMessage)
            }
            return signature
        #endif
            
        case .softwareKey(let privateKeyData):
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: data)
            return signature.derRepresentation
            
        case .callback(let signingCallback):
            return try await signingCallback.sign(data: data)
        }
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let publicKeyObj: P256.Signing.PublicKey
        if publicKey.count == 65 && publicKey.first == 0x04 {
            publicKeyObj = try P256.Signing.PublicKey(x963Representation: publicKey)
        } else if publicKey.count == 33 {
            publicKeyObj = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
        } else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "P-256 public key must be 33 or 65 bytes, got \(publicKey.count)"
            )
        }
        
        let signatureObj = try P256.Signing.ECDSASignature(derRepresentation: signature)
        return publicKeyObj.isValidSignature(signatureObj, for: data)
    }
}

// MARK: - ProtocolSignatureProviderSelector

/// 协议签名 Provider 选择器
public struct ProtocolSignatureProviderSelector {
    private init() {}
    
    public static func select(for algorithm: ProtocolSigningAlgorithm) -> any ProtocolSignatureProvider {
        switch algorithm {
        case .ed25519:
            return ClassicSignatureProvider()
        case .mlDSA65:
            return PQCSignatureProvider()
        }
    }
    
    public static func select(for tier: CryptoTier) -> any ProtocolSignatureProvider {
        switch tier {
        case .nativePQC, .liboqsPQC:
            return PQCSignatureProvider()
        case .classic:
            return ClassicSignatureProvider()
        }
    }
}
