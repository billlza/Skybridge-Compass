//
// ClassicProvider.swift
// SkyBridgeCompassiOS
//
// 经典加密 Provider 实现：
// - X25519 + HPKE Base (ChaCha20-Poly1305) 的封装/解封装
// - Ed25519 的签名/验证
// - 密钥对生成
//
// 作为 PQC 不可用时的兜底方案，也是与 macOS 通信的基础
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - ClassicCryptoProvider

/// 经典加密 Provider - X25519 + Ed25519
/// 作为 PQC 不可用时的兜底方案
@available(iOS 17.0, macOS 14.0, *)
public struct ClassicCryptoProvider: CryptoProvider, Sendable {
    
    // MARK: - CryptoProvider Protocol
    
    public let providerName = "Classic"
    public let tier: CryptoTier = .classic
    public let activeSuite: CryptoSuite = .x25519Ed25519
    
    // MARK: - Constants
    
    private static let nonceSize = 12  // AES-GCM nonce
    private static let tagSize = 16    // AES-GCM tag
    private static let x25519KeySize = 32  // X25519 key size
    private static let ed25519PublicKeySize = 32  // Ed25519 public key size
    private static let ed25519PrivateKeySize = 32  // Ed25519 private key size (seed)
    private static let kemDemExporterOutputByteCount = 32
    private static let kemDemExporterContextPrefix = Data("SkyBridge-KEMDEM-SessionRoot-v1|".utf8)
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - HPKE Operations
    
    /// HPKE 封装 (X25519 + ChaCha20-Poly1305)
    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        // 验证公钥长度
        guard recipientPublicKey.count == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        // 解析接收方公钥
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        // 尝试使用原生 HPKE
        do {
            var sender = try HPKE.Sender(
                recipientKey: peerPublicKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: info
            )
            let ciphertext = try sender.seal(plaintext)
            return HPKESealedBox(
                encapsulatedKey: sender.encapsulatedKey,
                ciphertext: ciphertext,
                tag: Data(),
                nonce: Data()
            )
        } catch {
            // 回退到手动 ECDH + AES-GCM
            let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
            let ephemeralPublic = ephemeralPrivate.publicKey
            
            let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: info,
                outputByteCount: 32
            )
            
            var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
            let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
            guard status == errSecSuccess else {
                throw CryptoProviderError.keyGenerationFailed("Failed to generate nonce")
            }
            let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
            let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            
            return HPKESealedBox(
                encapsulatedKey: ephemeralPublic.rawRepresentation,
                ciphertext: sealedBox.ciphertext,
                tag: sealedBox.tag,
                nonce: Data(nonceBytes)
            )
        }
    }

    /// KEM-DEM 封装（导出共享密钥）
    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        guard recipientPublicKey.count == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientPublicKey
        ) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        var sender = try HPKE.Sender(
            recipientKey: peerPublicKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        let ciphertext = try sender.seal(plaintext, authenticating: info)
        
        var exporterContext = Self.kemDemExporterContextPrefix
        var suiteWireId = activeSuite.wireId.littleEndian
        exporterContext.append(Data(bytes: &suiteWireId, count: MemoryLayout<UInt16>.size))
        exporterContext.append(info)
        let exported = try sender.exportSecret(
            context: exporterContext,
            outputByteCount: Self.kemDemExporterOutputByteCount
        )
        let sharedSecretForSession = SecureBytes(
            data: exported.withUnsafeBytes { Data($0) }
        )
        
        return (
            sealedBox: HPKESealedBox(
                encapsulatedKey: sender.encapsulatedKey,
                ciphertext: ciphertext,
                tag: Data(),
                nonce: Data()
            ),
            sharedSecret: sharedSecretForSession
        )
    }

    /// HPKE 解封装（Data 私钥版本）
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: SecureBytes(data: privateKey), info: info)
    }
    
    /// HPKE 解封装（SecureBytes 版本）
    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        guard privateKey.byteCount == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let keyData = privateKey.noCopyData()
        guard let myPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        // HPKE 原生格式（nonce 和 tag 为空）
        if sealedBox.nonce.isEmpty && sealedBox.tag.isEmpty {
            var recipient = try HPKE.Recipient(
                privateKey: myPrivateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: info,
                encapsulatedKey: sealedBox.encapsulatedKey
            )
            do {
                return try recipient.open(sealedBox.ciphertext, authenticating: info)
            } catch {
                return try recipient.open(sealedBox.ciphertext)
            }
        }
        
        // 回退到手动 ECDH + AES-GCM
        guard let ephemeralPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealedBox.encapsulatedKey) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmSealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        
        return try AES.GCM.open(gcmSealedBox, using: derivedKey)
    }

    /// KEM-DEM 解封装（导出共享密钥）
    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        guard privateKey.byteCount == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let keyData = privateKey.noCopyData()
        guard let myPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        if sealedBox.nonce.isEmpty && sealedBox.tag.isEmpty {
            var recipient = try HPKE.Recipient(
                privateKey: myPrivateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: info,
                encapsulatedKey: sealedBox.encapsulatedKey
            )
            
            let plaintext = try recipient.open(sealedBox.ciphertext, authenticating: info)
            
            var exporterContext = Self.kemDemExporterContextPrefix
            var suiteWireId = activeSuite.wireId.littleEndian
            exporterContext.append(Data(bytes: &suiteWireId, count: MemoryLayout<UInt16>.size))
            exporterContext.append(info)
            let exported = try recipient.exportSecret(
                context: exporterContext,
                outputByteCount: Self.kemDemExporterOutputByteCount
            )
            let sharedSecretForSession = SecureBytes(
                data: exported.withUnsafeBytes { Data($0) }
            )
            return (plaintext: plaintext, sharedSecret: sharedSecretForSession)
        }
        
        guard let ephemeralPublic = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: sealedBox.encapsulatedKey
        ) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmSealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        
        let plaintext = try AES.GCM.open(gcmSealedBox, using: derivedKey)
        return (plaintext: plaintext, sharedSecret: sharedSecretSecure)
    }

    // MARK: - KEM Encapsulation (Classic X25519)

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        guard recipientPublicKey.count == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientPublicKey
        ) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        let sharedSecretSecure = SecureBytes(data: sharedSecretBytes)
        
        return (encapsulatedKey: ephemeralPublic.rawRepresentation, sharedSecret: sharedSecretSecure)
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        guard privateKey.byteCount == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        guard encapsulatedKey.count == Self.x25519KeySize else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.x25519KeySize,
                actual: encapsulatedKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        
        let keyData = privateKey.noCopyData()
        guard let myPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        guard let ephemeralPublic = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: encapsulatedKey
        ) else {
            throw CryptoProviderError.invalidKeyFormat
        }
        
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let sharedSecretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedSecretBytes)
    }
    
    // MARK: - Signature Operations
    
    /// 签名（softwareKey=Ed25519；secureEnclaveRef/callback=外部签名实现）
    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        switch keyHandle {
        case .softwareKey(let privateKey):
            guard privateKey.count == Self.ed25519PrivateKeySize else {
                throw CryptoProviderError.invalidKeyLength(
                    expected: Self.ed25519PrivateKeySize,
                    actual: privateKey.count,
                    suite: activeSuite.rawValue,
                    usage: .signing
                )
            }
            
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
                throw CryptoProviderError.invalidKeyFormat
            }
            
            let signature = try key.signature(for: data)
            return signature
            
        #if canImport(Security)
        case .secureEnclaveRef(let secKey):
            return try signWithSecKey(secKey, data: data)
        #endif
            
        case .callback(let callback):
            return try await callback.sign(data: data)
        }
    }
    
    /// Ed25519/P-256 验签
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        // Ed25519
        if publicKey.count == Self.ed25519PublicKeySize {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
                throw CryptoProviderError.invalidKeyFormat
            }
            return key.isValidSignature(signature, for: data)
        }
        
        // P-256 ECDSA (用于 Secure Enclave 签名验证)
        if let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            if publicKey.first == 0x30,
               let p256Key = try? P256.Signing.PublicKey(derRepresentation: publicKey) {
                return p256Key.isValidSignature(sig, for: data)
            }
            if publicKey.first == 0x04,
               publicKey.count == 65,
               let p256Key = try? P256.Signing.PublicKey(x963Representation: publicKey) {
                return p256Key.isValidSignature(sig, for: data)
            }
        }
        
        throw CryptoProviderError.invalidKeyLength(
            expected: Self.ed25519PublicKeySize,
            actual: publicKey.count,
            suite: activeSuite.rawValue,
            usage: .signing
        )
    }
    
    // MARK: - Key Generation
    
    /// 生成密钥对
    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange:
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKey = privateKey.publicKey
            
            return KeyPair(
                publicKey: KeyMaterial(data: publicKey.rawRepresentation),
                privateKey: KeyMaterial(data: privateKey.rawRepresentation)
            )
            
        case .signing:
            let privateKey = Curve25519.Signing.PrivateKey()
            let publicKey = privateKey.publicKey
            
            return KeyPair(
                publicKey: KeyMaterial(data: publicKey.rawRepresentation),
                privateKey: KeyMaterial(data: privateKey.rawRepresentation)
            )

        case .ephemeral:
            // Ephemeral 在 classic 下等同于 keyExchange（Curve25519.KeyAgreement）
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKey = privateKey.publicKey
            return KeyPair(
                publicKey: KeyMaterial(data: publicKey.rawRepresentation),
                privateKey: KeyMaterial(data: privateKey.rawRepresentation)
            )
        }
    }
}

// MARK: - Secure Enclave Support

@available(iOS 17.0, macOS 14.0, *)
private extension ClassicCryptoProvider {
    #if canImport(Security)
    func signWithSecKey(_ secKey: SecKey, data: Data) throws -> Data {
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(secKey, .sign, algorithm) else {
            throw CryptoProviderError.signatureFailed("SecKey algorithm not supported")
        }
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(secKey, algorithm, data as CFData, &error) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw CryptoProviderError.signatureFailed(errorDesc)
        }
        
        return signature as Data
    }
    #endif
}

