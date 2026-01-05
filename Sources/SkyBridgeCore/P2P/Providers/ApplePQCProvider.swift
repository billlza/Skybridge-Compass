//
// ApplePQCProvider.swift
// SkyBridgeCore
//
// Apple PQC Implementation - ML-KEM-768 + ML-DSA-65
// Requirements: 1.1, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5
//
// Apple 原生 PQC Provider (macOS 26+)
// 使用 CryptoKit 的 ML-KEM-768、ML-DSA-65 实现
//
// **重要编译约束**：
// - 必须使用 `#if HAS_APPLE_PQC_SDK` 包裹所有 CryptoKit PQC 类型引用
// - 这确保旧 Xcode/旧 SDK 不会编译失败
// - `@available` 只解决运行时可用性，不解决编译时类型存在性
//

import Foundation
import CryptoKit

// MARK: - ApplePQCProvider

#if HAS_APPLE_PQC_SDK

/// Apple 原生 PQC Provider - ML-KEM-768 + ML-DSA-65
/// 仅在 iOS 26+/macOS 26+ 且 HAS_APPLE_PQC_SDK 定义时编译
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
    
 // MARK: - Key Size Constants
    
 // Note: Apple CryptoKit uses seed-based compact representation for private keys,
 // which is more efficient than the FIPS 203/204 expanded format.
    
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
    
 /// Self-test 验证 API 可用性
 /// 在 CryptoEnvironment.checkApplePQCAvailable() 中调用
    public static func selfTest() -> Bool {
 // 尝试创建密钥对验证 API 可用
 // 如果失败返回 false，让 Factory 选择 fallback
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
 /// Requirements: 3.1, 1.5, 6.1
    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
 // 1. 解析接收方公钥
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
        
 // 2. 执行 KEM 封装
        let sharedSecret: SymmetricKey
        let encapsulatedKey: Data
        do {
            let encapsulationResult = try publicKey.encapsulate()
            sharedSecret = encapsulationResult.sharedSecret
            encapsulatedKey = encapsulationResult.encapsulated
        } catch let encapError {
            throw CryptoProviderError.encapsulationFailed(
                "ML-KEM-768 encapsulation failed: \(encapError.localizedDescription)"
            )
        }
        
 // 3. 使用 HKDF-SHA256 派生 AES 密钥
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
 // 4. AES-GCM 加密
        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            
            return HPKESealedBox(
                encapsulatedKey: encapsulatedKey,
                nonce: Data(nonce),
                ciphertext: sealedBox.ciphertext,
                tag: sealedBox.tag
            )
        } catch let aesError {
            throw CryptoProviderError.operationFailed(
                "AES-GCM encryption failed: \(aesError.localizedDescription)"
            )
        }
    }

 /// KEM-DEM 封装（导出共享密钥）
    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
 // 1. 解析接收方公钥
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
        
 // 2. 执行 KEM 封装
        let sharedSecret: SymmetricKey
        let encapsulatedKey: Data
        do {
            let encapsulationResult = try publicKey.encapsulate()
            sharedSecret = encapsulationResult.sharedSecret
            encapsulatedKey = encapsulationResult.encapsulated
        } catch let encapError {
            throw CryptoProviderError.encapsulationFailed(
                "ML-KEM-768 encapsulation failed: \(encapError.localizedDescription)"
            )
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        
 // 3. 使用 HKDF-SHA256 派生 AES 密钥
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
 // 4. AES-GCM 加密
        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            
            return (
                sealedBox: HPKESealedBox(
                    encapsulatedKey: encapsulatedKey,
                    nonce: Data(nonce),
                    ciphertext: sealedBox.ciphertext,
                    tag: sealedBox.tag
                ),
                sharedSecret: sharedSecretSecure
            )
        } catch let aesError {
            throw CryptoProviderError.operationFailed(
                "AES-GCM encryption failed: \(aesError.localizedDescription)"
            )
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
            let encapsulationResult = try publicKey.encapsulate()
            sharedSecret = encapsulationResult.sharedSecret
            encapsulatedKey = encapsulationResult.encapsulated
        } catch let encapError {
            throw CryptoProviderError.encapsulationFailed(
                "ML-KEM-768 encapsulation failed: \(encapError.localizedDescription)"
            )
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        return (encapsulatedKey: encapsulatedKey, sharedSecret: sharedSecretSecure)
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        let keyData = privateKey.noCopyData()
        let privateKeyObj: MLKEM768.PrivateKey
        do {
            privateKeyObj = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: keyData.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let sharedSecret: SymmetricKey
        do {
            sharedSecret = try privateKeyObj.decapsulate(encapsulatedKey)
        } catch let decapError {
            throw CryptoProviderError.decapsulationFailed(
                "ML-KEM-768 decapsulation failed: \(decapError.localizedDescription)"
            )
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedSecretBytes)
    }
    
 /// HPKE 解封装
 /// Requirements: 3.2, 3.4, 6.1
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        let secureKey = SecureBytes(data: privateKey)
        return try await hpkeOpen(sealedBox: sealedBox, privateKey: secureKey, info: info)
    }
    
 /// HPKE 解封装（SecureBytes 版本）
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
 // 1. 解析私钥 (使用 integrityCheckedRepresentation)
        let myPrivateKey: MLKEM768.PrivateKey
        do {
            let keyData = privateKey.noCopyData()
            myPrivateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
 // 2. 执行 KEM 解封装
        let sharedSecret: SymmetricKey
        do {
            sharedSecret = try myPrivateKey.decapsulate(sealedBox.encapsulatedKey)
        } catch let decapError {
            throw CryptoProviderError.decapsulationFailed(
                "ML-KEM-768 decapsulation failed: \(decapError.localizedDescription)"
            )
        }
        
 // 3. 派生 AES 密钥
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
 // 4. AES-GCM 解密
        do {
            let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
            let gcmBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: sealedBox.ciphertext,
                tag: sealedBox.tag
            )
            return try AES.GCM.open(gcmBox, using: derivedKey)
        } catch let aesError {
            throw CryptoProviderError.operationFailed(
                "AES-GCM decryption failed: \(aesError.localizedDescription)"
            )
        }
    }

 /// KEM-DEM 解封装（导出共享密钥）
    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
 // 1. 解析私钥 (使用 integrityCheckedRepresentation)
        let myPrivateKey: MLKEM768.PrivateKey
        do {
            let keyData = privateKey.noCopyData()
            myPrivateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mlkem768PrivateKeySize,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
 // 2. 执行 KEM 解封装
        let sharedSecret: SymmetricKey
        do {
            sharedSecret = try myPrivateKey.decapsulate(sealedBox.encapsulatedKey)
        } catch let decapError {
            throw CryptoProviderError.decapsulationFailed(
                "ML-KEM-768 decapsulation failed: \(decapError.localizedDescription)"
            )
        }
        
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        
 // 3. 派生 AES 密钥
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
 // 4. AES-GCM 解密
        do {
            let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
            let gcmBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: sealedBox.ciphertext,
                tag: sealedBox.tag
            )
            let plaintext = try AES.GCM.open(gcmBox, using: derivedKey)
            return (plaintext: plaintext, sharedSecret: sharedSecretSecure)
        } catch let aesError {
            throw CryptoProviderError.operationFailed(
                "AES-GCM decryption failed: \(aesError.localizedDescription)"
            )
        }
    }
    
 // MARK: - Signature Operations
    
 /// ML-DSA-65 签名
 /// Requirements: 2.2, 6.1
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
        
 // 解析私钥 (使用 integrityCheckedRepresentation)
        let key: MLDSA65.PrivateKey
        do {
            key = try MLDSA65.PrivateKey(integrityCheckedRepresentation: privateKey)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mldsa65PrivateKeySize,
                actual: privateKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }
        
 // 生成签名
        do {
            let signature = try key.signature(for: data)
            return signature
        } catch let signError {
            throw CryptoProviderError.signatureFailed(
                "ML-DSA-65 signing failed: \(signError.localizedDescription)"
            )
        }
    }
    
 /// ML-DSA-65 验签
 /// Requirements: 2.3, 2.4, 6.1
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // 解析公钥
        let key: MLDSA65.PublicKey
        do {
            key = try MLDSA65.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.mldsa65PublicKeySize,
                actual: publicKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }
        
 // 验证签名 - 返回 false 而非抛错（符合 Requirements 2.4）
        return key.isValidSignature(signature, for: data)
    }
    
 // MARK: - Key Generation
    
 /// 生成密钥对
 /// Requirements: 6.4
    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange:
            return try generateMLKEM768KeyPair()
        case .signing:
            return try generateMLDSA65KeyPair()
        }
    }
    
 /// 生成 ML-KEM-768 密钥对
 /// Requirements: 1.1, 6.1
    private func generateMLKEM768KeyPair() throws -> KeyPair {
        let privateKey: MLKEM768.PrivateKey
        do {
            privateKey = try MLKEM768.PrivateKey()
        } catch let genError {
            throw CryptoProviderError.keyGenerationFailed(
                "ML-KEM-768 key generation failed: \(genError.localizedDescription)"
            )
        }
        let publicKey = privateKey.publicKey
        
        return KeyPair(
            publicKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: publicKey.rawRepresentation
            ),
            privateKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: privateKey.integrityCheckedRepresentation
            )
        )
    }
    
 /// 生成 ML-DSA-65 密钥对
 /// Requirements: 2.1, 6.1
    private func generateMLDSA65KeyPair() throws -> KeyPair {
        let privateKey: MLDSA65.PrivateKey
        do {
            privateKey = try MLDSA65.PrivateKey()
        } catch let genError {
            throw CryptoProviderError.keyGenerationFailed(
                "ML-DSA-65 key generation failed: \(genError.localizedDescription)"
            )
        }
        let publicKey = privateKey.publicKey
        
        return KeyPair(
            publicKey: KeyMaterial(
                suite: activeSuite,
                usage: .signing,
                bytes: publicKey.rawRepresentation
            ),
            privateKey: KeyMaterial(
                suite: activeSuite,
                usage: .signing,
                bytes: privateKey.integrityCheckedRepresentation
            )
        )
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
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
        
        return HPKESealedBox(
            encapsulatedKey: encapsulatedKey,
            nonce: Data(nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
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
        let myPrivateKey = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        
        let sharedSecret = try myPrivateKey.decapsulate(sealedBox.encapsulatedKey)
        
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
        
        guard sealedBox.nonce.count == Self.nonceSize else {
            throw CryptoProviderError.invalidNonceLength(sealedBox.nonce.count)
        }
        
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try AES.GCM.open(gcmBox, using: derivedKey)
    }
    
    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        let publicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey)
        let encapsulationResult = try publicKey.encapsulate()
        let sharedSecretBytes = encapsulationResult.sharedSecret.withUnsafeBytes { Data($0) }
        return (encapsulatedKey: encapsulationResult.encapsulated, sharedSecret: SecureBytes(data: sharedSecretBytes))
    }
    
    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        let keyData = privateKey.noCopyData()
        let myPrivateKey = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        let sharedSecret = try myPrivateKey.decapsulate(encapsulatedKey)
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
        case .keyExchange:
            let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
            let publicKey = privateKey.publicKey
            return KeyPair(
                publicKey: KeyMaterial(suite: activeSuite, usage: .keyExchange, bytes: publicKey.rawRepresentation),
                privateKey: KeyMaterial(suite: activeSuite, usage: .keyExchange, bytes: privateKey.integrityCheckedRepresentation)
            )
        case .signing:
            let privateKey = try MLDSA65.PrivateKey()
            let publicKey = privateKey.publicKey
            return KeyPair(
                publicKey: KeyMaterial(suite: activeSuite, usage: .signing, bytes: publicKey.rawRepresentation),
                privateKey: KeyMaterial(suite: activeSuite, usage: .signing, bytes: privateKey.integrityCheckedRepresentation)
            )
        }
    }
}

#endif

// MARK: - Documentation

/*
 Apple CryptoKit PQC API (macOS 26 SDK / WWDC 2025 确认)：
 
 ## ML-KEM-768 (FIPS 203 - Key Encapsulation Mechanism)
 
 ### 类型
 - MLKEM768.PrivateKey
 - MLKEM768.PublicKey
 
 ### 密钥生成
 - MLKEM768.PrivateKey.init() throws
 - MLKEM768.PrivateKey.publicKey: MLKEM768.PublicKey
 
 ### 密钥序列化
 - MLKEM768.PublicKey.rawRepresentation: Data (1184 bytes)
 - MLKEM768.PublicKey.init(rawRepresentation:) throws
 - MLKEM768.PrivateKey.integrityCheckedRepresentation: Data (96 bytes, Apple 紧凑格式)
 - MLKEM768.PrivateKey.init(integrityCheckedRepresentation:) throws
 
 ### KEM 操作
 - MLKEM768.PublicKey.encapsulate() throws -> (sharedSecret: SymmetricKey, encapsulated: Data)
 - MLKEM768.PrivateKey.decapsulate(_: Data) throws -> SymmetricKey
 
 ## ML-DSA-65 (FIPS 204 - Digital Signature Algorithm)
 
 ### 类型
 - MLDSA65.PrivateKey
 - MLDSA65.PublicKey
 
 ### 密钥生成
 - MLDSA65.PrivateKey.init() throws
 - MLDSA65.PrivateKey.publicKey: MLDSA65.PublicKey
 
 ### 密钥序列化
 - MLDSA65.PublicKey.rawRepresentation: Data (1952 bytes)
 - MLDSA65.PublicKey.init(rawRepresentation:) throws
 - MLDSA65.PrivateKey.integrityCheckedRepresentation: Data (64 bytes, Apple 紧凑格式)
 - MLDSA65.PrivateKey.init(integrityCheckedRepresentation:) throws
 
 ### 签名操作
 - MLDSA65.PrivateKey.signature(for: Data) throws -> Data
 - MLDSA65.PublicKey.isValidSignature(_: Data, for: Data) -> Bool
 
 ## 密钥长度
 
 ### FIPS 203/204 标准格式
 - ML-KEM-768 公钥: 1184 bytes
 - ML-KEM-768 私钥: 2400 bytes (expanded)
 - ML-KEM-768 密文: 1088 bytes
 - ML-KEM-768 共享密钥: 32 bytes
 - ML-DSA-65 公钥: 1952 bytes
 - ML-DSA-65 私钥: 4032 bytes (expanded)
 - ML-DSA-65 签名: ~3309 bytes (可变)
 
 ### Apple 紧凑格式 (integrityCheckedRepresentation)
 - ML-KEM-768 私钥: 96 bytes (seed-based)
 - ML-DSA-65 私钥: 64 bytes (seed-based)
 
 Note: Apple 使用基于种子的紧凑表示来存储私钥，这比 FIPS 标准的扩展格式更高效。
 导入私钥时必须使用 integrityCheckedRepresentation 初始化器。
 */
