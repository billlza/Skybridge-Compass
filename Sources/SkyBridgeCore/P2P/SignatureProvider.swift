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
// - PQCSignatureProvider：精确的 ML-DSA-65/87 签名（Apple PQC 或明确支持的 OQS 后端）
// - P256SignatureProvider：P-256 ECDSA 签名（仅用于 legacy 验证和 SE PoP）
//
// **设计决策**：
// - 不复用 CryptoProvider，避免职责混淆
// - 每个 Provider 专注于单一签名算法
// - 支持 SigningKeyHandle 的多种形式（软件密钥、Secure Enclave、回调）
//

import Foundation
import CryptoKit
import SkyBridgeProtocolCore
#if canImport(Security)
import Security
#endif

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
 /// 签名算法（只能是 ed25519、mlDSA65 或 mlDSA87，类型层面排除 P-256）
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

 /// 根据精确算法和密钥格式选择已支持的后端
    case auto
}

// MARK: - PQCSignatureProvider (ML-DSA-65 / ML-DSA-87)

/// 精确绑定 ML-DSA-65 或 ML-DSA-87 的协议签名 Provider。
///
/// Apple CryptoKit 软件密钥支持 65/87。OQS raw-key 签名 adapter 只接收 65；
/// OQSBridge 的显式公钥验签支持 65/87。87 raw-key 签名仍必须显式失败。
///
/// **Requirements: 1.2, 7.1, 7.2, 7.3**
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

 /// 底层实现后端
    private let backend: PQCSignatureBackend
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
        supportsOQSRawKeyVerification: true
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
            // Callback 是完整的签名边界（例如 Secure Enclave ML-DSA）。
            // 它失败时必须原样失败，不得转用软件密钥或其他后端。
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

 // MARK: - Private Methods

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
            let signature = try await signWithOQS(data, key: key, contract: contract)
            emitSmokeBackendLog("sign backend=oqs keyFormat=liboqs bytes=\(signature.count)")
            return signature
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

        let signature = try await signWithApplePQC(data, key: key, contract: contract)
        emitSmokeBackendLog("sign backend=apple bytes=\(signature.count)")
        return signature
    }

    private func verifyAutomatically(
        _ data: Data,
        signature: Data,
        publicKey: Data,
        contract: AlgorithmContract
    ) async throws -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            do {
                // Apple 返回 false 是确定性密码学拒绝，不得换实现重验。
                let isValid = try await verifyWithApplePQC(
                    data,
                    signature: signature,
                    publicKey: publicKey,
                    contract: contract
                )
                emitSmokeBackendLog("verify backend=apple ok=\(isValid)")
                return isValid
            } catch let appleError {
                emitSmokeBackendLog("verify apple_failed=\(appleError.localizedDescription)")
                guard Self.shouldRetryVerifyWithLiboqs(
                    algorithm: signatureAlgorithm,
                    signature: signature,
                    publicKey: publicKey
                ) else {
                    throw appleError
                }
                do {
                    let isValid = try await verifyWithOQS(
                        data,
                        signature: signature,
                        publicKey: publicKey,
                        contract: contract
                    )
                    emitSmokeBackendLog("verify backend=oqs ok=\(isValid)")
                    return isValid
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
                "\(contract.name) verification requires Apple CryptoKit on macOS/iOS 26+; liboqs raw-key verification is not connected to this provider"
            )
        }
        let isValid = try await verifyWithOQS(
            data,
            signature: signature,
            publicKey: publicKey,
            contract: contract
        )
        emitSmokeBackendLog("verify backend=oqs ok=\(isValid)")
        return isValid
    }

    #if HAS_APPLE_PQC_SDK
    // internal 以便测试锁定回退决策语义，防止条件被无意放宽。
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
        #if canImport(OQSRAII)
        guard let contract = try? contract(for: algorithm),
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
        #else
        return false
        #endif
    }

    static func shouldRetryVerifyWithLiboqs(
        algorithm: ProtocolSigningAlgorithm = .mlDSA65,
        signature: Data,
        publicKey: Data
    ) -> Bool {
        guard let contract = try? contract(for: algorithm),
              contract.supportsOQSRawKeyVerification else {
            return false
        }
        let lengthsMatch = publicKey.count == contract.publicKeyLength
            && signature.count == contract.signatureLength
        guard lengthsMatch else { return false }

        switch algorithm {
        case .mlDSA65:
            #if canImport(OQSRAII)
            return true
            #else
            return false
            #endif
        case .mlDSA87:
            #if canImport(liboqs)
            return true
            #else
            return false
            #endif
        case .ed25519:
            return false
        }
    }
    #endif

 // MARK: - Apple PQC Implementation

    private func signWithApplePQC(
        _ data: Data,
        key: SigningKeyHandle,
        contract: AlgorithmContract
    ) async throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
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

            #if canImport(Security)
            case .secureEnclaveRef:
                throw SignatureProviderError.unsupportedKeyHandle(
                    "\(contract.name) CryptoKit Secure Enclave keys must use a typed SigningCallback"
                )
            #endif

            case .callback(let signingCallback):
                let signature = try await signingCallback.sign(data: data)
                try Self.validateSignatureLength(signature, contract: contract)
                return signature
            }
        }
        #endif
        throw SignatureProviderError.pqcBackendUnavailable(
            "\(contract.name) Apple CryptoKit requires macOS/iOS 26+ with the PQC SDK"
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
        if #available(macOS 26.0, iOS 26.0, *) {
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
            "\(contract.name) Apple CryptoKit requires macOS/iOS 26+ with the PQC SDK"
        )
    }

 // MARK: - OQS Implementation

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
        switch key {
        case .softwareKey(let privateKeyData):
            guard privateKeyData.count == contract.oqsPrivateKeyLength else {
                throw SignatureProviderError.invalidKeyType(
                    expected: "\(contract.name) liboqs private key (\(contract.oqsPrivateKeyLength) bytes)",
                    actual: "\(privateKeyData.count) bytes"
                )
            }
            return try await OQSMLDSAHelper.sign(data: data, privateKey: privateKeyData)

        #if canImport(Security)
        case .secureEnclaveRef:
            throw SignatureProviderError.unsupportedKeyHandle(
                "\(contract.name) CryptoKit Secure Enclave keys must use a typed SigningCallback"
            )
        #endif

        case .callback(let signingCallback):
            let signature = try await signingCallback.sign(data: data)
            try Self.validateSignatureLength(signature, contract: contract)
            return signature
        }
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
        try Self.validatePublicKeyLength(publicKey, contract: contract)
        try Self.validateSignatureLength(signature, contract: contract)
        switch signatureAlgorithm {
        case .mlDSA65:
            return try await OQSMLDSAHelper.verify(
                data: data,
                signature: signature,
                publicKey: publicKey
            )
        case .mlDSA87:
            #if canImport(liboqs)
            return await OQSBridge.verify(
                data,
                signature: signature,
                publicKey: publicKey,
                algorithm: .mldsa87
            )
            #else
            throw SignatureProviderError.pqcBackendUnavailable(
                "ML-DSA-87 liboqs verification requires the liboqs bridge"
            )
            #endif
        case .ed25519:
            throw SignatureProviderError.internalInvariantViolated(
                "PQCSignatureProvider cannot verify Ed25519"
            )
        }
    }

    private func emitSmokeBackendLog(_ message: String) {
#if DEBUG || SKYBRIDGE_TESTING
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        SkyBridgeLogger.p2p.info("🧪 mac \(signatureAlgorithm.rawValue, privacy: .public) \(message, privacy: .public)")
#endif
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
        case .qperiaptPQC:
            return PQCSignatureProvider(backend: .applePQC)
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
            return PQCSignatureProvider(algorithm: .mlDSA65, backend: .auto)
        case .mlDSA87:
            return PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
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
