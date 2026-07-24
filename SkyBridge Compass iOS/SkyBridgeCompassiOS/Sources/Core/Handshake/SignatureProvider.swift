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

// MARK: - PQCSignatureProvider (ML-DSA-65 / ML-DSA-87)

public enum PQCSignatureBackend: Sendable {
    case applePQC
    case oqs
    case auto
}

/// 精确绑定 ML-DSA-65 或 ML-DSA-87 的协议签名 Provider。
///
/// Apple CryptoKit 软件密钥支持 65/87。当前 iOS OQS raw-key adapter
/// 只接收 ML-DSA-65；ML-DSA-87 OQS 请求显式失败，不猜测或换后端。
public struct PQCSignatureProvider: ProtocolSignatureProvider {
    private struct AlgorithmContract: Sendable {
        let name: String
        let publicKeyLength: Int
        let signatureLength: Int
        let applePrivateKeyLength: Int
        let oqsPrivateKeyLength: Int
        let supportsOQSRawKeySigning: Bool
        let supportsOQSRawKeyVerification: Bool
    }

    public let signatureAlgorithm: ProtocolSigningAlgorithm
    private let backend: PQCSignatureBackend
    private static let hasLiboqsBackend = OQSPQCCryptoProvider.quickRuntimeProbe()
    private static let mldsa65Contract = AlgorithmContract(
        name: "ML-DSA-65",
        publicKeyLength: 1_952,
        signatureLength: 3_309,
        applePrivateKeyLength: 64,
        oqsPrivateKeyLength: 4_032,
        supportsOQSRawKeySigning: true,
        supportsOQSRawKeyVerification: true
    )
    private static let mldsa87Contract = AlgorithmContract(
        name: "ML-DSA-87",
        publicKeyLength: 2_592,
        signatureLength: 4_627,
        applePrivateKeyLength: 64,
        oqsPrivateKeyLength: 4_896,
        supportsOQSRawKeySigning: false,
        supportsOQSRawKeyVerification: false
    )
    
    public init(
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        backend: PQCSignatureBackend = .auto
    ) {
        self.signatureAlgorithm = algorithm
        self.backend = backend
    }
    
    public func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        let contract = try Self.contract(for: signatureAlgorithm)

        switch key {
        case .callback(let signingCallback):
            // Callback 失败时必须原样失败，不得转用软件密钥或另一后端。
            let signature = try await signingCallback.sign(data: data)
            try Self.validateSignatureLength(signature, contract: contract)
            return signature
        #if canImport(Security)
        case .secureEnclaveRef:
            throw SignatureProviderError.unsupportedKeyHandle(
                "\(contract.name) CryptoKit Secure Enclave keys must use a typed SigningCallback, not SecKey"
            )
        #endif
        case .softwareKey:
            break
        }

        let signature: Data
        switch backend {
        case .applePQC:
            signature = try await signWithApplePQC(data, key: key, contract: contract)
        case .oqs:
            signature = try await signWithOQS(data, key: key, contract: contract)
        case .auto:
            signature = try await signAutomatically(data, key: key, contract: contract)
        }

        try Self.validateSignatureLength(signature, contract: contract)
        return signature
    }
    
    public func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let contract = try Self.contract(for: signatureAlgorithm)
        try Self.validatePublicKeyLength(publicKey, contract: contract)
        try Self.validateSignatureLength(signature, contract: contract)

        switch backend {
        case .applePQC:
            return try await verifyWithApplePQC(
                data,
                signature: signature,
                publicKey: publicKey,
                contract: contract
            )
        case .oqs:
            return try await verifyWithOQS(
                data,
                signature: signature,
                publicKey: publicKey,
                contract: contract
            )
        case .auto:
            return try await verifyAutomatically(
                data,
                signature: signature,
                publicKey: publicKey,
                contract: contract
            )
        }
    }

    private static func contract(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> AlgorithmContract {
        switch algorithm {
        case .mlDSA65:
            return mldsa65Contract
        case .mlDSA87:
            return mldsa87Contract
        case .ed25519:
            throw SignatureProviderError.internalInvariantViolated(
                "PQCSignatureProvider cannot be constructed for Ed25519"
            )
        }
    }

    private static func validatePublicKeyLength(
        _ publicKey: Data,
        contract: AlgorithmContract
    ) throws {
        guard publicKey.count == contract.publicKeyLength else {
            throw SignatureProviderError.invalidPublicKeyFormat(
                "\(contract.name) public key must be \(contract.publicKeyLength) bytes, got \(publicKey.count)"
            )
        }
    }

    private static func validateSignatureLength(
        _ signature: Data,
        contract: AlgorithmContract
    ) throws {
        guard signature.count == contract.signatureLength else {
            throw SignatureProviderError.invalidSignatureFormat(
                "\(contract.name) signature must be \(contract.signatureLength) bytes, got \(signature.count)"
            )
        }
    }

    private func signAutomatically(
        _ data: Data,
        key: SigningKeyHandle,
        contract: AlgorithmContract
    ) async throws -> Data {
        guard case .softwareKey(let privateKeyData) = key else {
            throw SignatureProviderError.internalInvariantViolated(
                "non-software ML-DSA key bypassed the signing-handle boundary"
            )
        }

        if privateKeyData.count == contract.oqsPrivateKeyLength {
            guard contract.supportsOQSRawKeySigning else {
                throw SignatureProviderError.pqcBackendUnavailable(
                    "\(contract.name) liboqs raw-key signing is not connected to the protocol provider"
                )
            }
            return try await signWithOQS(data, key: key, contract: contract)
        }

        guard privateKeyData.count == contract.applePrivateKeyLength else {
            throw SignatureProviderError.invalidKeyType(
                expected: "\(contract.name) Apple private key (\(contract.applePrivateKeyLength) bytes)"
                    + (contract.supportsOQSRawKeySigning
                        ? " or liboqs private key (\(contract.oqsPrivateKeyLength) bytes)"
                        : ""),
                actual: "\(privateKeyData.count) bytes"
            )
        }

        return try await signWithApplePQC(data, key: key, contract: contract)
    }

    private func verifyAutomatically(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        contract: AlgorithmContract
    ) async throws -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                // Apple 返回 false 是确定性密码学拒绝，不得换实现重验。
                return try await verifyWithApplePQC(
                    data,
                    signature: signature,
                    publicKey: publicKey,
                    contract: contract
                )
            } catch let appleError {
                guard Self.shouldRetryVerifyWithLiboqs(
                    algorithm: signatureAlgorithm,
                    signature: signature,
                    publicKey: publicKey
                ) else {
                    throw appleError
                }
                do {
                    return try await verifyWithOQS(
                        data,
                        signature: signature,
                        publicKey: publicKey,
                        contract: contract
                    )
                } catch let oqsError {
                    throw SignatureProviderError.verificationFailed(
                        "Apple PQC failed (\(appleError.localizedDescription)); liboqs failed (\(oqsError.localizedDescription))"
                    )
                }
            }
        }
        #endif

        guard contract.supportsOQSRawKeyVerification else {
            throw SignatureProviderError.pqcBackendUnavailable(
                "\(contract.name) verification requires Apple CryptoKit on iOS 26+; liboqs raw-key verification is not connected to this provider"
            )
        }
        return try await verifyWithOQS(
            data,
            signature: signature,
            publicKey: publicKey,
            contract: contract
        )
    }

    #if HAS_APPLE_PQC_SDK
    // internal 以便测试锁定回退决策语义（防止条件被无意放宽，扩大验签/签名回退面）。
    static func shouldUseLiboqsForSigningBeforeApple(
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        key: SigningKeyHandle
    ) -> Bool {
        shouldRetrySignWithLiboqs(algorithm: algorithm, key: key)
    }

    static func shouldRetrySignWithLiboqs(
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        key: SigningKeyHandle
    ) -> Bool {
        guard hasLiboqsBackend,
              let contract = try? contract(for: algorithm),
              contract.supportsOQSRawKeySigning else {
            return false
        }
        switch key {
        case .softwareKey(let privateKeyData):
            return privateKeyData.count == contract.oqsPrivateKeyLength
        case .callback:
            return false
        #if canImport(Security)
        case .secureEnclaveRef:
            return false
        #endif
        }
    }

    static func shouldRetryVerifyWithLiboqs(
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        signature: Data,
        publicKey: Data
    ) -> Bool {
        guard hasLiboqsBackend,
              let contract = try? contract(for: algorithm),
              contract.supportsOQSRawKeyVerification else {
            return false
        }
        return publicKey.count == contract.publicKeyLength
            && signature.count == contract.signatureLength
    }
    #endif

    private func signWithApplePQC(
        _ data: Data,
        key: SigningKeyHandle,
        contract: AlgorithmContract
    ) async throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            switch key {
            case .softwareKey(let privateKeyData):
                guard privateKeyData.count == contract.applePrivateKeyLength else {
                    throw SignatureProviderError.invalidKeyType(
                        expected: "\(contract.name) private key (\(contract.applePrivateKeyLength) bytes integrityCheckedRepresentation)",
                        actual: "\(privateKeyData.count) bytes"
                    )
                }
                switch signatureAlgorithm {
                case .mlDSA65:
                    let privateKey = try MLDSA65.PrivateKey(
                        integrityCheckedRepresentation: privateKeyData
                    )
                    return try privateKey.signature(for: data)
                case .mlDSA87:
                    let privateKey = try MLDSA87.PrivateKey(
                        integrityCheckedRepresentation: privateKeyData
                    )
                    return try privateKey.signature(for: data)
                case .ed25519:
                    throw SignatureProviderError.internalInvariantViolated(
                        "PQCSignatureProvider cannot sign Ed25519"
                    )
                }

            case .callback(let signingCallback):
                let signature = try await signingCallback.sign(data: data)
                try Self.validateSignatureLength(signature, contract: contract)
                return signature

            #if canImport(Security)
            case .secureEnclaveRef:
                throw SignatureProviderError.unsupportedKeyHandle(
                    "\(contract.name) CryptoKit Secure Enclave keys must use a typed SigningCallback"
                )
            #endif
            }
        }
        #endif
        throw SignatureProviderError.pqcBackendUnavailable(
            "\(contract.name) Apple CryptoKit requires iOS 26+ with the PQC SDK"
        )
    }
    
    private func verifyWithApplePQC(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        contract: AlgorithmContract
    ) async throws -> Bool {
        try Self.validatePublicKeyLength(publicKey, contract: contract)
        try Self.validateSignatureLength(signature, contract: contract)
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            switch signatureAlgorithm {
            case .mlDSA65:
                let key = try MLDSA65.PublicKey(rawRepresentation: publicKey)
                return key.isValidSignature(signature, for: data)
            case .mlDSA87:
                let key = try MLDSA87.PublicKey(rawRepresentation: publicKey)
                return key.isValidSignature(signature, for: data)
            case .ed25519:
                throw SignatureProviderError.internalInvariantViolated(
                    "PQCSignatureProvider cannot verify Ed25519"
                )
            }
        }
        #endif
        throw SignatureProviderError.pqcBackendUnavailable(
            "\(contract.name) Apple CryptoKit requires iOS 26+ with the PQC SDK"
        )
    }

    private func signWithOQS(
        _ data: Data,
        key: SigningKeyHandle,
        contract: AlgorithmContract
    ) async throws -> Data {
        guard contract.supportsOQSRawKeySigning else {
            throw SignatureProviderError.pqcBackendUnavailable(
                "\(contract.name) liboqs raw-key signing is not connected to the protocol provider"
            )
        }
        guard Self.hasLiboqsBackend else {
            throw SignatureProviderError.pqcBackendUnavailable("liboqs backend is unavailable")
        }
        guard case .softwareKey(let privateKeyData) = key else {
            throw SignatureProviderError.internalInvariantViolated(
                "non-software ML-DSA key bypassed the signing-handle boundary"
            )
        }
        guard privateKeyData.count == contract.oqsPrivateKeyLength else {
            throw SignatureProviderError.invalidKeyType(
                expected: "\(contract.name) liboqs private key (\(contract.oqsPrivateKeyLength) bytes)",
                actual: "\(privateKeyData.count) bytes"
            )
        }
        return try await OQSPQCCryptoProvider().sign(data: data, using: key)
    }

    private func verifyWithOQS(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        contract: AlgorithmContract
    ) async throws -> Bool {
        guard contract.supportsOQSRawKeyVerification else {
            throw SignatureProviderError.pqcBackendUnavailable(
                "\(contract.name) liboqs raw-key verification is not connected to the protocol provider"
            )
        }
        guard Self.hasLiboqsBackend else {
            throw SignatureProviderError.pqcBackendUnavailable("liboqs backend is unavailable")
        }
        try Self.validatePublicKeyLength(publicKey, contract: contract)
        try Self.validateSignatureLength(signature, contract: contract)
        return try await OQSPQCCryptoProvider().verify(
            data: data,
            signature: signature,
            publicKey: publicKey
        )
    }
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
            return PQCSignatureProvider(algorithm: .mlDSA65, backend: .auto)
        case .mlDSA87:
            return PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        }
    }
    
    public static func select(for tier: CryptoTier) -> any ProtocolSignatureProvider {
        switch tier {
        case .qperiaptPQC:
            return PQCSignatureProvider(algorithm: .mlDSA65, backend: .oqs)
        case .nativePQC:
            return PQCSignatureProvider(algorithm: .mlDSA65, backend: .applePQC)
        case .liboqsPQC:
            return PQCSignatureProvider(algorithm: .mlDSA65, backend: .oqs)
        case .classic:
            return ClassicSignatureProvider()
        }
    }
}
