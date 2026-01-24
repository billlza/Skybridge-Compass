//
// OQSPQCProvider.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 4: OQSPQCProvider (liboqs)
// Requirements: 2.1, 2.4, 2.5
//
// liboqs PQC Provider 实现：
// - ML-KEM-768 封装/解封装 (HPKE)
// - ML-DSA-65 签名/验证
// - 使用 SecureBytes 保护敏感数据
// - 使用 defer 确保资源清理
//

import Foundation
import CryptoKit
#if canImport(OQSRAII)
import OQSRAII
#endif

// MARK: - OQSPQCCryptoProvider

/// liboqs PQC Provider - ML-KEM-768 + ML-DSA-65
/// 用于不支持原生 Apple PQC 的系统
@available(macOS 14.0, iOS 17.0, *)
public struct OQSPQCCryptoProvider: CryptoProvider, Sendable {

 // MARK: - CryptoProvider Protocol

    public let providerName = "liboqs"
    public let tier: CryptoTier = .liboqsPQC
    public let activeSuite: CryptoSuite = .mlkem768MLDSA65

 // MARK: - Constants

    private static let nonceSize = 12  // AES-GCM nonce
    private static let tagSize = 16    // AES-GCM tag
    private static let aesKeySize = 32 // AES-256
    // ⚠️ Interop requirement:
    // Keep KDF parameters identical across ApplePQCCryptoProvider and OQSPQCCryptoProvider,
    // otherwise Apple↔OQS mixed deployments will fail with CryptoKitError (e.g. error 3) when opening MessageB.
    private static let hkdfSaltLabel = "SkyBridge-KDF-Salt-v1|"

    private static func hkdfSalt(info: Data) -> Data {
        var data = Data(hkdfSaltLabel.utf8)
        data.append(info)
        return Data(SHA256.hash(data: data))
    }

 // MARK: - Initialization

    public init() {}

 // MARK: - HPKE Operations

 /// HPKE 封装 (ML-KEM-768 + AES-256-GCM)
 /// - Parameters:
 /// - plaintext: 明文数据
 /// - recipientPublicKey: 接收方公钥 (ML-KEM-768 公钥)
 /// - info: 上下文信息 (用于 HKDF)
 /// - Returns: HPKESealedBox
    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        #if canImport(OQSRAII)
 // 1. 验证公钥长度
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedPkLen),
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

 // 2. 使用 ML-KEM-768 封装生成共享密钥
        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()

 // 使用 SecureBytes 保护共享密钥
        let sharedSecretSecure = SecureBytes(count: Int(ssLen))
        var ciphertext = [UInt8](repeating: 0, count: Int(ctLen))

        let encapsResult = recipientPublicKey.withUnsafeBytes { pkPtr -> Int32 in
            guard let pkBase = pkPtr.baseAddress else { return OQSRAII_FAIL }
            return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mlkem768_encaps(
                    pkBase.assumingMemoryBound(to: UInt8.self),
                    recipientPublicKey.count,
                    &ciphertext,
                    ciphertext.count,
                    ssBase.assumingMemoryBound(to: UInt8.self),
                    Int(ssLen)
                )
            }
        }

        guard encapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed
        }

 // 3. 从共享密钥派生对称密钥 (HKDF-SHA256)
        let derivedKey = try deriveSymmetricKey(
            from: sharedSecretSecure.data,
            info: info
        )

 // 4. 生成随机 nonce
        var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed("Failed to generate nonce")
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))

 // 5. AES-GCM 加密
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)

        return HPKESealedBox(
            encapsulatedKey: Data(ciphertext),
            nonce: Data(nonceBytes),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 /// KEM-DEM 封装（导出共享密钥）
    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
 // 1. 验证公钥长度
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedPkLen),
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

 // 2. 使用 ML-KEM-768 封装生成共享密钥
        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()

        let sharedSecretSecure = SecureBytes(count: Int(ssLen))
        var ciphertext = [UInt8](repeating: 0, count: Int(ctLen))

        let encapsResult = recipientPublicKey.withUnsafeBytes { pkPtr -> Int32 in
            guard let pkBase = pkPtr.baseAddress else { return OQSRAII_FAIL }
            return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mlkem768_encaps(
                    pkBase.assumingMemoryBound(to: UInt8.self),
                    recipientPublicKey.count,
                    &ciphertext,
                    ciphertext.count,
                    ssBase.assumingMemoryBound(to: UInt8.self),
                    Int(ssLen)
                )
            }
        }

        guard encapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed
        }

 // 3. 从共享密钥派生对称密钥 (HKDF-SHA256)
        let derivedKey = try deriveSymmetricKey(
            from: sharedSecretSecure.data,
            info: info
        )

 // 4. 生成随机 nonce
        var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed("Failed to generate nonce")
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))

 // 5. AES-GCM 加密
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)

        return (
            sealedBox: HPKESealedBox(
                encapsulatedKey: Data(ciphertext),
                nonce: Data(nonceBytes),
                ciphertext: sealedBox.ciphertext,
                tag: sealedBox.tag
            ),
            sharedSecret: sharedSecretSecure
        )
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 /// HPKE 解封装
 /// - Parameters:
 /// - sealedBox: 密封盒
 /// - privateKey: 接收方私钥 (ML-KEM-768 私钥)
 /// - info: 上下文信息 (用于 HKDF)
 /// - Returns: 解密后的明文
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
        #if canImport(OQSRAII)
 // 1. 验证私钥长度
        let expectedSkLen = oqs_raii_mlkem768_secret_key_length()
        guard privateKey.byteCount == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedSkLen),
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

 // 2. 验证密文长度
        let expectedCtLen = oqs_raii_mlkem768_ciphertext_length()
        guard sealedBox.encapsulatedKey.count == expectedCtLen else {
            throw CryptoProviderError.invalidCiphertextLength(
                expected: Int(expectedCtLen),
                actual: sealedBox.encapsulatedKey.count
            )
        }

 // 3. 使用 ML-KEM-768 解封装恢复共享密钥
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: Int(ssLen))

        let decapsResult = sealedBox.encapsulatedKey.withUnsafeBytes { ctPtr -> Int32 in
            guard let ctBase = ctPtr.baseAddress else { return OQSRAII_FAIL }
            return privateKey.withUnsafeBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                    guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                    return oqs_raii_mlkem768_decaps(
                        ctBase.assumingMemoryBound(to: UInt8.self),
                        sealedBox.encapsulatedKey.count,
                        skBase.assumingMemoryBound(to: UInt8.self),
                        privateKey.byteCount,
                        ssBase.assumingMemoryBound(to: UInt8.self),
                        Int(ssLen)
                    )
                }
            }
        }

        guard decapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.decapsulationFailed
        }

 // 4. 派生对称密钥
        let derivedKey = try deriveSymmetricKey(
            from: sharedSecretSecure.data,
            info: info
        )

 // 5. 构建 AES.GCM.SealedBox
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmSealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )

 // 6. AES-GCM 解密
        let plaintext = try AES.GCM.open(gcmSealedBox, using: derivedKey)
        return plaintext
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 /// KEM-DEM 解封装（导出共享密钥）
    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
 // 1. 验证私钥长度
        let expectedSkLen = oqs_raii_mlkem768_secret_key_length()
        guard privateKey.byteCount == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedSkLen),
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

 // 2. 验证密文长度
        let expectedCtLen = oqs_raii_mlkem768_ciphertext_length()
        guard sealedBox.encapsulatedKey.count == expectedCtLen else {
            throw CryptoProviderError.invalidCiphertextLength(
                expected: Int(expectedCtLen),
                actual: sealedBox.encapsulatedKey.count
            )
        }

 // 3. 使用 ML-KEM-768 解封装恢复共享密钥
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: Int(ssLen))

        let decapsResult = sealedBox.encapsulatedKey.withUnsafeBytes { ctPtr -> Int32 in
            guard let ctBase = ctPtr.baseAddress else { return OQSRAII_FAIL }
            return privateKey.withUnsafeBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                    guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                    return oqs_raii_mlkem768_decaps(
                        ctBase.assumingMemoryBound(to: UInt8.self),
                        sealedBox.encapsulatedKey.count,
                        skBase.assumingMemoryBound(to: UInt8.self),
                        privateKey.byteCount,
                        ssBase.assumingMemoryBound(to: UInt8.self),
                        Int(ssLen)
                    )
                }
            }
        }

        guard decapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.decapsulationFailed
        }

 // 4. 派生对称密钥
        let derivedKey = try deriveSymmetricKey(
            from: sharedSecretSecure.data,
            info: info
        )

 // 5. 构建 AES.GCM.SealedBox
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmSealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )

 // 6. AES-GCM 解密
        let plaintext = try AES.GCM.open(gcmSealedBox, using: derivedKey)
        return (plaintext: plaintext, sharedSecret: sharedSecretSecure)
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 // MARK: - KEM Encapsulation

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedPkLen),
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()

        let sharedSecretSecure = SecureBytes(count: Int(ssLen))
        var ciphertext = [UInt8](repeating: 0, count: Int(ctLen))

        let encapsResult = recipientPublicKey.withUnsafeBytes { pkPtr -> Int32 in
            guard let pkBase = pkPtr.baseAddress else { return OQSRAII_FAIL }
            return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mlkem768_encaps(
                    pkBase.assumingMemoryBound(to: UInt8.self),
                    recipientPublicKey.count,
                    &ciphertext,
                    ciphertext.count,
                    ssBase.assumingMemoryBound(to: UInt8.self),
                    Int(ssLen)
                )
            }
        }

        guard encapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed
        }

        return (encapsulatedKey: Data(ciphertext), sharedSecret: sharedSecretSecure)
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        #if canImport(OQSRAII)
        let expectedSkLen = oqs_raii_mlkem768_secret_key_length()
        guard privateKey.byteCount == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedSkLen),
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let expectedCtLen = oqs_raii_mlkem768_ciphertext_length()
        guard encapsulatedKey.count == expectedCtLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedCtLen),
                actual: encapsulatedKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: Int(ssLen))

        let decapsResult = encapsulatedKey.withUnsafeBytes { ctPtr -> Int32 in
            guard let ctBase = ctPtr.baseAddress else { return OQSRAII_FAIL }
            return privateKey.withUnsafeBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                    guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                    return oqs_raii_mlkem768_decaps(
                        ctBase.assumingMemoryBound(to: UInt8.self),
                        encapsulatedKey.count,
                        skBase.assumingMemoryBound(to: UInt8.self),
                        privateKey.byteCount,
                        ssBase.assumingMemoryBound(to: UInt8.self),
                        Int(ssLen)
                    )
                }
            }
        }

        guard decapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.decapsulationFailed
        }

        return sharedSecretSecure
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 // MARK: - Signature Operations

 /// ML-DSA-65 签名
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
        #if canImport(OQSRAII)
 // 1. 验证私钥长度
        let expectedSkLen = oqs_raii_mldsa65_secret_key_length()
        guard privateKey.count == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedSkLen),
                actual: privateKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }

 // 2. 分配签名缓冲区
        let maxSigLen = oqs_raii_mldsa65_signature_length()
        var signature = [UInt8](repeating: 0, count: Int(maxSigLen))
        var actualSigLen = maxSigLen

 // 3. 执行签名
        let signResult = data.withUnsafeBytes { msgPtr -> Int32 in
            guard let msgBase = msgPtr.baseAddress else { return OQSRAII_FAIL }
            return privateKey.withUnsafeBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mldsa65_sign(
                    msgBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    skBase.assumingMemoryBound(to: UInt8.self),
                    privateKey.count,
                    &signature,
                    &actualSigLen
                )
            }
        }

        guard signResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.signatureFailed
        }

 // 4. 返回实际长度的签名
        return Data(signature.prefix(Int(actualSigLen)))
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 /// ML-DSA-65 验签
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 公钥 (ML-DSA-65 公钥)
 /// - Returns: 是否验证通过
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        #if canImport(OQSRAII)
 // 1. 验证公钥长度
        let expectedPkLen = oqs_raii_mldsa65_public_key_length()
        guard publicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Int(expectedPkLen),
                actual: publicKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }

 // 2. 执行验签
        let isValid = data.withUnsafeBytes { msgPtr -> Bool in
            guard let msgBase = msgPtr.baseAddress else { return false }
            return signature.withUnsafeBytes { sigPtr -> Bool in
                guard let sigBase = sigPtr.baseAddress else { return false }
                return publicKey.withUnsafeBytes { pkPtr -> Bool in
                    guard let pkBase = pkPtr.baseAddress else { return false }
                    return oqs_raii_mldsa65_verify(
                        msgBase.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        sigBase.assumingMemoryBound(to: UInt8.self),
                        signature.count,
                        pkBase.assumingMemoryBound(to: UInt8.self),
                        publicKey.count
                    )
                }
            }
        }

        return isValid
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 // MARK: - Key Generation

 /// 生成密钥对
 /// - Parameter usage: 密钥用途
 /// - Returns: 密钥对
    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        #if canImport(OQSRAII)
        switch usage {
        case .keyExchange:
            return try generateMLKEM768KeyPair()
        case .signing:
            return try generateMLDSA65KeyPair()
        }
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 // MARK: - Private Methods

    #if canImport(OQSRAII)
 /// 生成 ML-KEM-768 密钥对
    private func generateMLKEM768KeyPair() throws -> KeyPair {
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()

        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
 // 使用 SecureBytes 保护私钥
        let privateKeySecure = SecureBytes(count: Int(skLen))

        let result = privateKeySecure.withUnsafeMutableBytes { skPtr -> Int32 in
            guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
            return oqs_raii_mlkem768_keypair(
                &publicKeyBytes,
                publicKeyBytes.count,
                skBase.assumingMemoryBound(to: UInt8.self),
                Int(skLen)
            )
        }

        guard result == OQSRAII_SUCCESS else {
            throw CryptoProviderError.keyGenerationFailed("ML-KEM-768 keypair generation failed")
        }

        return KeyPair(
            publicKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: Data(publicKeyBytes)
            ),
            privateKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: privateKeySecure.data
            )
        )
    }

 /// 生成 ML-DSA-65 密钥对
    private func generateMLDSA65KeyPair() throws -> KeyPair {
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()

        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
 // 使用 SecureBytes 保护私钥
        let privateKeySecure = SecureBytes(count: Int(skLen))

        let result = privateKeySecure.withUnsafeMutableBytes { skPtr -> Int32 in
            guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
            return oqs_raii_mldsa65_keypair(
                &publicKeyBytes,
                publicKeyBytes.count,
                skBase.assumingMemoryBound(to: UInt8.self),
                Int(skLen)
            )
        }

        guard result == OQSRAII_SUCCESS else {
            throw CryptoProviderError.keyGenerationFailed("ML-DSA-65 keypair generation failed")
        }

        return KeyPair(
            publicKey: KeyMaterial(
                suite: activeSuite,
                usage: .signing,
                bytes: Data(publicKeyBytes)
            ),
            privateKey: KeyMaterial(
                suite: activeSuite,
                usage: .signing,
                bytes: privateKeySecure.data
            )
        )
    }
    #endif

 /// 从共享密钥派生对称密钥 (HKDF-SHA256)
    private func deriveSymmetricKey(from sharedSecret: Data, info: Data) throws -> SymmetricKey {
        let inputKey = SymmetricKey(data: sharedSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
    }
}

// MARK: - Additional Error Cases

extension CryptoProviderError {
 /// ML-KEM 封装失败
    static let encapsulationFailed = CryptoProviderError.operationFailed("ML-KEM encapsulation failed")

 /// ML-KEM 解封装失败
    static let decapsulationFailed = CryptoProviderError.operationFailed("ML-KEM decapsulation failed")

 /// 签名失败
    static let signatureFailed = CryptoProviderError.operationFailed("ML-DSA signature failed")

 /// 密文长度无效
    static func invalidCiphertextLength(expected: Int, actual: Int) -> CryptoProviderError {
        .operationFailed("Invalid ciphertext length: expected \(expected), got \(actual)")
    }
}
