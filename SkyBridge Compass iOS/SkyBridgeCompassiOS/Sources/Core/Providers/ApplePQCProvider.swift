//
// ApplePQCProvider.swift
// SkyBridgeCompassiOS
//
// Apple 原生 PQC Provider (iOS 26+)
// 使用 CryptoKit 的 ML-KEM-768、ML-DSA-65 实现
//
// **重要编译约束**：
// - 使用 `#if canImport(CryptoKit)` 和 `@available` 确保兼容性
// - iOS 26+ 时使用原生 CryptoKit PQC
// - iOS 17-25 时回退到 liboqs 或 Classic
//

import Foundation
import CryptoKit

// MARK: - ApplePQCCryptoProvider

/// 重要：必须使用 `#if HAS_APPLE_PQC_SDK` 包裹所有 PQC 类型引用，避免旧 SDK 编译失败。
#if HAS_APPLE_PQC_SDK

/// Apple 原生 PQC Provider - ML-KEM-768 + ML-DSA-65
@available(iOS 26.0, macOS 26.0, *)
public struct ApplePQCCryptoProvider: CryptoProvider, Sendable {
    
    // MARK: - CryptoProvider Protocol
    
    public let providerName = "ApplePQC"
    public let tier: CryptoTier = .nativePQC
    public let activeSuite: CryptoSuite = .mlkem768MLDSA65
    
    // MARK: - Constants
    
    private static let nonceSize = 12  // AES-GCM nonce
    private static let tagSize = 16    // AES-GCM tag
    private static let aesKeySize = 32 // AES-256
    private static let hkdfSaltLabel = "SkyBridge-KDF-Salt-v1|"
    
    // MARK: - Key Size Constants (与 macOS 完全一致)
    
    /// ML-KEM-768 公钥长度 (bytes) - FIPS 203 standard
    public static let mlkem768PublicKeySize = 1184
    /// ML-KEM-768 私钥长度 (bytes) - Apple seed-based compact format
    public static let mlkem768PrivateKeySize = 96
    /// ML-KEM-768 密文长度 (bytes) - FIPS 203 standard
    public static let mlkem768CiphertextSize = 1088
    
    /// ML-DSA-65 公钥长度 (bytes) - FIPS 204 standard
    public static let mldsa65PublicKeySize = 1952
    /// ML-DSA-65 私钥长度 (bytes) - Apple seed-based compact format
    public static let mldsa65PrivateKeySize = 64

    private static func hkdfSalt(info: Data) -> Data {
        var data = Data(hkdfSaltLabel.utf8)
        data.append(info)
        return Data(SHA256.hash(data: data))
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Self Test
    
    /// Self-test 验证 API 可用性：能生成 MLKEM/MLDSA 密钥则视为可用
    public static func selfTest() -> Bool {
        do {
            let _ = try MLKEM768.PrivateKey()
            let _ = try MLDSA65.PrivateKey()
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - HPKE Operations
    
    /// HPKE 封装 (ML-KEM-768 + AES-256-GCM)
    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        // 1) 解析接收方公钥
        let publicKey: MLKEM768.PublicKey
        do {
            publicKey = try MLKEM768.PublicKey(rawRepresentation: recipientPublicKey)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PublicKeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        // 2) KEM encapsulate
        let sharedSecret: SymmetricKey
        let encapsulatedKey: Data
        do {
            let r = try publicKey.encapsulate()
            sharedSecret = r.sharedSecret
            encapsulatedKey = r.encapsulated
        } catch let e {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed: \(e.localizedDescription)")
        }
        
        // 3) HKDF -> AES key
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
        // 4) AES-GCM seal
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            return HPKESealedBox(
                encapsulatedKey: encapsulatedKey,
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                nonce: Data(nonce)
            )
        } catch let e {
            throw CryptoProviderError.invalidCiphertext("AES-GCM encryption failed: \(e.localizedDescription)")
        }
    }

    /// KEM-DEM 封装（导出共享密钥）
    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        // 与 hpkeSeal 逻辑一致，但返回 SecureBytes sharedSecret（用于派生会话密钥）
        let publicKey: MLKEM768.PublicKey
        do {
            publicKey = try MLKEM768.PublicKey(rawRepresentation: recipientPublicKey)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PublicKeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let sharedSecret: SymmetricKey
        let encapsulatedKey: Data
        do {
            let r = try publicKey.encapsulate()
            sharedSecret = r.sharedSecret
            encapsulatedKey = r.encapsulated
        } catch let e {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed: \(e.localizedDescription)")
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            let box = HPKESealedBox(
                encapsulatedKey: encapsulatedKey,
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                nonce: Data(nonce)
            )
            return (sealedBox: box, sharedSecret: sharedSecretSecure)
        } catch let e {
            throw CryptoProviderError.invalidCiphertext("AES-GCM encryption failed: \(e.localizedDescription)")
        }
    }

    // MARK: - KEM Encapsulation

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        let publicKey: MLKEM768.PublicKey
        do {
            publicKey = try MLKEM768.PublicKey(rawRepresentation: recipientPublicKey)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PublicKeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let sharedSecret: SymmetricKey
        let encapsulatedKey: Data
        do {
            let r = try publicKey.encapsulate()
            sharedSecret = r.sharedSecret
            encapsulatedKey = r.encapsulated
        } catch let e {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed: \(e.localizedDescription)")
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        return (encapsulatedKey: encapsulatedKey, sharedSecret: SecureBytes(data: sharedSecretBytes))
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        let keyData = privateKey.noCopyData()
        let myPrivateKey: MLKEM768.PrivateKey
        do {
            myPrivateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: keyData.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let shared: SymmetricKey
        do {
            shared = try myPrivateKey.decapsulate(encapsulatedKey)
        } catch let e {
            throw CryptoProviderError.decapsulationFailed("ML-KEM-768 decapsulation failed: \(e.localizedDescription)")
        }
        
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedBytes)
    }
    
    /// HPKE 解封装
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        let keyData = privateKey.noCopyData()
        let myPrivateKey: MLKEM768.PrivateKey
        do {
            myPrivateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: keyData.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let shared: SymmetricKey
        do {
            shared = try myPrivateKey.decapsulate(sealedBox.encapsulatedKey)
        } catch let e {
            throw CryptoProviderError.decapsulationFailed("ML-KEM-768 decapsulation failed: \(e.localizedDescription)")
        }
        
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: shared,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
        do {
            guard sealedBox.nonce.count == Self.nonceSize else {
                throw CryptoProviderError.invalidCiphertext("Invalid nonce length: \(sealedBox.nonce.count)")
            }
            let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
            let gcm = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealedBox.ciphertext, tag: sealedBox.tag)
            return try AES.GCM.open(gcm, using: derivedKey)
        } catch let e {
            throw CryptoProviderError.invalidCiphertext("AES-GCM decryption failed: \(e.localizedDescription)")
        }
    }

    /// KEM-DEM 解封装（导出共享密钥）
    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        let keyData = privateKey.noCopyData()
        let myPrivateKey: MLKEM768.PrivateKey
        do {
            myPrivateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: keyData.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let shared: SymmetricKey
        do {
            shared = try myPrivateKey.decapsulate(sealedBox.encapsulatedKey)
        } catch let e {
            throw CryptoProviderError.decapsulationFailed("ML-KEM-768 decapsulation failed: \(e.localizedDescription)")
        }
        
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let sharedSecure = SecureBytes(data: sharedBytes)
        
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: shared,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
        do {
            guard sealedBox.nonce.count == Self.nonceSize else {
                throw CryptoProviderError.invalidCiphertext("Invalid nonce length: \(sealedBox.nonce.count)")
            }
            let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
            let gcm = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealedBox.ciphertext, tag: sealedBox.tag)
            let plaintext = try AES.GCM.open(gcm, using: derivedKey)
            return (plaintext: plaintext, sharedSecret: sharedSecure)
        } catch let e {
            throw CryptoProviderError.invalidCiphertext("AES-GCM decryption failed: \(e.localizedDescription)")
        }
    }
    
    // MARK: - Signature Operations
    
    /// ML-DSA-65 签名
    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        let privateKeyBytes: Data
        switch keyHandle {
        case .softwareKey(let bytes):
            privateKeyBytes = bytes
        case .callback(let callback):
            return try await callback.sign(data: data)
        #if canImport(Security)
        case .secureEnclaveRef:
            throw CryptoProviderError.invalidKeyFormat
        #endif
        }
        
        guard privateKeyBytes.count == Self.mldsa65PrivateKeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mldsa65PrivateKeySize,
                actual: privateKeyBytes.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }
        
        do {
            let key = try MLDSA65.PrivateKey(integrityCheckedRepresentation: privateKeyBytes)
            return try key.signature(for: data)
        } catch let e {
            throw CryptoProviderError.signatureFailed("ML-DSA-65 signing failed: \(e.localizedDescription)")
        }
    }
    
    /// ML-DSA-65 验签
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        do {
            let key = try MLDSA65.PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: data)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mldsa65PublicKeySize,
                actual: publicKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }
    }
    
    // MARK: - Key Generation
    
    /// 生成密钥对
    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange, .ephemeral:
            do {
                let priv = try MLKEM768.PrivateKey()
                return KeyPair(
                    publicKey: priv.publicKey.rawRepresentation,
                    privateKey: priv.integrityCheckedRepresentation
                )
            } catch let e {
                throw CryptoProviderError.keyGenerationFailed("ML-KEM-768 key generation failed: \(e.localizedDescription)")
            }
        case .signing:
            do {
                let priv = try MLDSA65.PrivateKey()
                return KeyPair(
                    publicKey: priv.publicKey.rawRepresentation,
                    privateKey: priv.integrityCheckedRepresentation
                )
            } catch let e {
                throw CryptoProviderError.keyGenerationFailed("ML-DSA-65 key generation failed: \(e.localizedDescription)")
            }
        }
    }

    /// HPKE 解封装（Data 私钥版本）
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: SecureBytes(data: privateKey), info: info)
    }
}

/// Apple 原生 Hybrid Provider - X-Wing(ML-KEM-768+X25519) + ML-DSA-65
/// 仅在 iOS 26+/macOS 26+ 且 HAS_APPLE_PQC_SDK 定义时编译
@available(iOS 26.0, macOS 26.0, *)
public struct AppleXWingCryptoProvider: CryptoProvider, Sendable {

    public let providerName = "AppleXWing"
    public let tier: CryptoTier = .nativePQC
    public let activeSuite: CryptoSuite = .xwingMLDSA

    private static let nonceSize = 12
    private static let aesKeySize = 32
    private static let hkdfSaltLabel = "SkyBridge-KDF-Salt-v1|"

    public init() {}

    public static func selfTest() -> Bool {
        do {
            let _ = try XWingMLKEM768X25519.PrivateKey.generate()
            let _ = try MLDSA65.PrivateKey()
            return true
        } catch {
            return false
        }
    }

    private static func hkdfSalt(info: Data) -> Data {
        var data = Data(hkdfSaltLabel.utf8)
        data.append(info)
        return Data(SHA256.hash(data: data))
    }

    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        let publicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey)

        let encapsulationResult = try publicKey.encapsulate()
        let sharedSecret = encapsulationResult.sharedSecret
        let encapsulatedKey = encapsulationResult.encapsulated

        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)

        return HPKESealedBox(
            encapsulatedKey: encapsulatedKey,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            nonce: Data(nonce)
        )
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: SecureBytes(data: privateKey), info: info)
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        let keyData = privateKey.noCopyData()
        let privateKeyObj = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        let sharedSecret = try privateKeyObj.decapsulate(sealedBox.encapsulatedKey)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        guard sealedBox.nonce.count == Self.nonceSize else {
            throw CryptoProviderError.invalidCiphertext("Invalid nonce length")
        }
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try AES.GCM.open(gcmBox, using: derivedKey)
    }

    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        let publicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey)
        let encapsulationResult = try publicKey.encapsulate()
        let sharedSecret = encapsulationResult.sharedSecret
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecure = SecureBytes(data: sharedSecretBytes)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
        let box = HPKESealedBox(
            encapsulatedKey: encapsulationResult.encapsulated,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            nonce: Data(nonce)
        )
        return (sealedBox: box, sharedSecret: sharedSecure)
    }

    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        let keyData = privateKey.noCopyData()
        let privateKeyObj = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        let sharedSecret = try privateKeyObj.decapsulate(sealedBox.encapsulatedKey)
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecure = SecureBytes(data: sharedSecretBytes)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        guard sealedBox.nonce.count == Self.nonceSize else {
            throw CryptoProviderError.invalidCiphertext("Invalid nonce length")
        }
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        let plaintext = try AES.GCM.open(gcmBox, using: derivedKey)
        return (plaintext: plaintext, sharedSecret: sharedSecure)
    }

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        let publicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey)
        let encapsulationResult = try publicKey.encapsulate()
        let sharedSecretBytes = encapsulationResult.sharedSecret.withUnsafeBytes { Data($0) }
        return (
            encapsulatedKey: encapsulationResult.encapsulated,
            sharedSecret: SecureBytes(data: sharedSecretBytes)
        )
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        let keyData = privateKey.noCopyData()
        let privateKeyObj = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        let sharedSecret = try privateKeyObj.decapsulate(encapsulatedKey)
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedSecretBytes)
    }

    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        let privateKey: Data
        switch keyHandle {
        case .softwareKey(let bytes):
            privateKey = bytes
        case .callback(let callback):
            return try await callback.sign(data: data)
        #if canImport(Security)
        case .secureEnclaveRef:
            throw CryptoProviderError.invalidKeyFormat
        #endif
        }

        let key = try MLDSA65.PrivateKey(integrityCheckedRepresentation: privateKey)
        return try key.signature(for: data)
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let key = try MLDSA65.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: data)
    }

    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange, .ephemeral:
            let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
            return KeyPair(
                publicKey: privateKey.publicKey.rawRepresentation,
                privateKey: privateKey.integrityCheckedRepresentation
            )
        case .signing:
            let privateKey = try MLDSA65.PrivateKey()
            return KeyPair(
                publicKey: privateKey.publicKey.rawRepresentation,
                privateKey: privateKey.integrityCheckedRepresentation
            )
        }
    }
}

#endif // HAS_APPLE_PQC_SDK

// MARK: - PQC Availability Check

/// 检查 Apple PQC 是否可用
public func isApplePQCAvailable() -> Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
        #if HAS_APPLE_PQC_SDK
        return ApplePQCCryptoProvider.selfTest()
        #else
        return false
        #endif
    }
    return false
}
