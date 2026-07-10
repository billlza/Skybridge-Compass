//
// QPeriaptCryptoProvider.swift
// SkyBridgeCore
//
// Q-Periapt ContextBound hybrid CryptoProvider (ML-KEM-768 + X25519).
//
// This file is a COPY of `OQSPQCProvider.swift` with ONLY the KEM swapped to the
// Q-Periapt hybrid C-ABI (`q_periapt_hybrid_encapsulate` / `q_periapt_hybrid_decapsulate`).
// Everything that is KEM-agnostic is KEPT BYTE-IDENTICAL to `OQSPQCProvider`:
//   - the DEM (HKDF-SHA256 derivation of the AES-256-GCM key from the shared secret,
//     `AES.GCM.seal/open`, `HPKESealedBox` assembly, and nonce handling);
//   - `sign` / `verify` (ML-DSA-65 via liboqs/OQSRAII — signing is independent of the KEM).
// The same `info`/salt/HKDF params, nonce size, error types (`CryptoProviderError`),
// `SecureBytes` usage, and `#if canImport` guards are preserved.
//
// ADDITIVE + STRICTLY ISOLATED: this provider is only ever instantiated when
// Q-Periapt is explicitly requested and the local runtime policy passes
// OS/module/self-test admission (see `QPeriaptPlatformPolicy`). When admission is
// false nothing references this type, so existing behavior is byte-for-byte unchanged.
//
// KEM wire/blob layout (mirrors `QPeriaptKEMProvider`; the privateKey blob is the
// provider's OWN representation and is never placed on the wire):
//   recipientPublicKey       = pk_pq(1184) ‖ pk_trad(32)                       = 1216 B
//   HPKESealedBox.encapsulatedKey (KEM ct) = ct_pq(1088) ‖ ct_trad(32)        = 1120 B
//   privateKey               = sk_pq(2400) ‖ sk_trad(32) ‖ pk_pq(1184) ‖ pk_trad(32) = 3648 B
//   sharedSecret             = secret(32)
//

import Foundation
import CryptoKit
#if canImport(OQSRAII)
import OQSRAII
#endif
#if canImport(CQPeriapt)
import CQPeriapt
#endif
#if canImport(Security)
import Security
#endif

// MARK: - QPeriaptCryptoProvider

/// Q-Periapt ContextBound PQC Provider - (ML-KEM-768 + X25519) hybrid KEM + ML-DSA-65 signing.
///
/// KEM = Q-Periapt context-bound hybrid; DEM + signing copied verbatim from `OQSPQCCryptoProvider`.
@available(macOS 14.0, iOS 17.0, *)
public struct QPeriaptCryptoProvider: CryptoProvider, Sendable {

 // MARK: - CryptoProvider Protocol

    public let providerName = "QPeriaptContextBound"
    public let tier: CryptoTier = .qperiaptPQC
    public let activeSuite: CryptoSuite = .qperiaptContextBound

    public var supportedSuites: [CryptoSuite] { [.qperiaptContextBound] }

    public func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite.wireId == CryptoSuite.qperiaptContextBound.wireId
    }

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

 // MARK: - Q-Periapt KEM Constants (mirror q_periapt.h / QPeriaptKEMProvider)

    /// `profile = 2`: context-bound combiner (Q_PERIAPT_PROFILE_CONTEXT_BOUND).
    private static let qpProfileContextBound = UInt8(Q_PERIAPT_PROFILE_CONTEXT_BOUND)
    private static let qpMlkem768SKLen = Int(Q_PERIAPT_MLKEM768_SK_LEN)
    private static let qpMlkem768PKLen = Int(Q_PERIAPT_MLKEM768_PK_LEN)
    private static let qpMlkem768CTLen = Int(Q_PERIAPT_MLKEM768_CT_LEN)
    private static let qpX25519Len = Int(Q_PERIAPT_X25519_LEN)
    private static let qpSecretLen = Int(Q_PERIAPT_SECRET_LEN)
    private static let qpMlkemSeedLen = 64    // q_periapt_mlkem768_keypair seed length
    private static let qpOkStatus = Int32(Q_PERIAPT_OK)
    private static let qpPolicyVersion: UInt32 = 1

    /// `recipientPublicKey` on the wire: pk_pq ‖ pk_trad.
    private static let qpPublicKeyLen = qpMlkem768PKLen + qpX25519Len             // 1216
    /// KEM ciphertext / `HPKESealedBox.encapsulatedKey`: ct_pq ‖ ct_trad.
    private static let qpEncapsulatedLen = qpMlkem768CTLen + qpX25519Len          // 1120
    /// Provider's own private-key blob: sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad.
    private static let qpPrivateKeyLen = qpMlkem768SKLen + qpX25519Len + qpMlkem768PKLen + qpX25519Len // 3648

    /// suite_id 字节串（ASCII）。
    private static let qpSuiteID = QPeriaptRuntimeContract.expectedSuiteID
    /// context 字节串（ASCII），ContextBound profile 下绑定。
    private static let qpContext: [UInt8] = Array("skybridge-qperiapt/v1".utf8)

 // MARK: - Initialization

    public init() {}

    public static func quickRuntimeProbe() -> Bool {
        #if canImport(CQPeriapt)
        do {
            try QPeriaptRuntimeContract.requireCompatible()
            let provider = QPeriaptCryptoProvider()
            let keyPair = try provider.generateQPeriaptKEMKeyPair()
            guard keyPair.publicKey.bytes.count == qpPublicKeyLen,
                  keyPair.privateKey.bytes.count == qpPrivateKeyLen else {
                return false
            }
            let encapsulated = try provider.qpEncapsulate(recipientPublicKey: keyPair.publicKey.bytes)
            guard encapsulated.encapsulatedKey.count == qpEncapsulatedLen,
                  encapsulated.sharedSecret.byteCount == qpSecretLen else {
                return false
            }
            let decapsulated = try provider.qpDecapsulate(
                encapsulatedKey: encapsulated.encapsulatedKey,
                privateKey: SecureBytes(data: keyPair.privateKey.bytes)
            )
            return decapsulated.byteCount == qpSecretLen &&
                decapsulated.data == encapsulated.sharedSecret.data
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

 // MARK: - Q-Periapt KEM core (the ONLY part swapped vs OQSPQCProvider)

    /// Q-Periapt hybrid encapsulate. Mirrors `QPeriaptKEMProvider.encapsulate` exactly.
    /// - Returns: (encapsulatedKey = ct_pq‖ct_trad (1120 B), sharedSecret (32 B)).
    #if canImport(CQPeriapt)
    private func qpEncapsulate(
        recipientPublicKey: Data
    ) throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try QPeriaptRuntimeContract.requireCompatible()

        guard recipientPublicKey.count == Self.qpPublicKeyLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.qpPublicKeyLen,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let pkPQ = [UInt8](recipientPublicKey.prefix(Self.qpMlkem768PKLen))
        let pkTrad = [UInt8](recipientPublicKey.suffix(Self.qpX25519Len))

        var randPQ = try Self.randomBytes(count: Self.qpX25519Len)   // ML-KEM encaps coins (32 bytes)
        var randTrad = try Self.randomBytes(count: Self.qpX25519Len) // X25519 ephemeral scalar (32 bytes)
        defer {
            Self.wipe(&randPQ)
            Self.wipe(&randTrad)
        }

        var ctPQ = [UInt8](repeating: 0, count: Self.qpMlkem768CTLen)
        var ctTrad = [UInt8](repeating: 0, count: Self.qpX25519Len)
        var secret = [UInt8](repeating: 0, count: Self.qpSecretLen)
        defer { Self.wipe(&secret) }

        let status = Self.qpSuiteID.withUnsafeBufferPointer { suitePtr in
            Self.qpContext.withUnsafeBufferPointer { ctxPtr in
                pkPQ.withUnsafeBufferPointer { pkPQPtr in
                    pkTrad.withUnsafeBufferPointer { pkTradPtr in
                        randPQ.withUnsafeBufferPointer { randPQPtr in
                            randTrad.withUnsafeBufferPointer { randTradPtr in
                                ctPQ.withUnsafeMutableBufferPointer { ctPQPtr in
                                    ctTrad.withUnsafeMutableBufferPointer { ctTradPtr in
                                        secret.withUnsafeMutableBufferPointer { secretPtr in
                                            q_periapt_hybrid_encapsulate(
                                                Self.qpProfileContextBound,
                                                suitePtr.baseAddress, UInt(suitePtr.count),
                                                Self.qpPolicyVersion,
                                                pkPQPtr.baseAddress, UInt(pkPQPtr.count),
                                                pkTradPtr.baseAddress, UInt(pkTradPtr.count),
                                                ctxPtr.baseAddress, UInt(ctxPtr.count),
                                                randPQPtr.baseAddress, UInt(randPQPtr.count),
                                                randTradPtr.baseAddress, UInt(randTradPtr.count),
                                                ctPQPtr.baseAddress, UInt(ctPQPtr.count),
                                                ctTradPtr.baseAddress, UInt(ctTradPtr.count),
                                                secretPtr.baseAddress, UInt(secretPtr.count)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard status == Self.qpOkStatus else {
            throw CryptoProviderError.encapsulationFailed(
                "q_periapt_hybrid_encapsulate failed: \(QPeriaptRuntimeContract.statusDescription(status))"
            )
        }

        // encapsulatedKey = ct_pq ‖ ct_trad
        var encapsulated = Data()
        encapsulated.append(contentsOf: ctPQ)
        encapsulated.append(contentsOf: ctTrad)

        let sharedSecretSecure = SecureBytes(data: Data(secret))
        return (encapsulatedKey: encapsulated, sharedSecret: sharedSecretSecure)
    }

    /// Q-Periapt hybrid decapsulate. Mirrors `QPeriaptKEMProvider.decapsulate` exactly.
    /// - Parameter privateKey: the provider's own blob sk_pq‖sk_trad‖pk_pq‖pk_trad (3648 B).
    private func qpDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) throws -> SecureBytes {
        try QPeriaptRuntimeContract.requireCompatible()

        guard privateKey.byteCount == Self.qpPrivateKeyLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: Self.qpPrivateKeyLen,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        guard encapsulatedKey.count == Self.qpEncapsulatedLen else {
            throw CryptoProviderError.invalidCiphertextLength(
                expected: Self.qpEncapsulatedLen,
                actual: encapsulatedKey.count
            )
        }

        // Split encapsulated = ct_pq ‖ ct_trad
        let ctPQ = [UInt8](encapsulatedKey.prefix(Self.qpMlkem768CTLen))
        let ctTrad = [UInt8](encapsulatedKey.suffix(Self.qpX25519Len))

        var secret = [UInt8](repeating: 0, count: Self.qpSecretLen)
        defer { Self.wipe(&secret) }

        let status: Int32 = privateKey.withUnsafeBytes { privateKeyRaw in
            guard let privateKeyBase = privateKeyRaw.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(Q_PERIAPT_ERR_NULL)
            }
            let skPQ = privateKeyBase
            let skTrad = privateKeyBase.advanced(by: Self.qpMlkem768SKLen)
            let pkPQ = skTrad.advanced(by: Self.qpX25519Len)
            let pkTrad = pkPQ.advanced(by: Self.qpMlkem768PKLen)

            return Self.qpSuiteID.withUnsafeBufferPointer { suitePtr in
                Self.qpContext.withUnsafeBufferPointer { ctxPtr in
                    ctPQ.withUnsafeBufferPointer { ctPQPtr in
                        ctTrad.withUnsafeBufferPointer { ctTradPtr in
                            secret.withUnsafeMutableBufferPointer { secretPtr in
                                q_periapt_hybrid_decapsulate(
                                    Self.qpProfileContextBound,
                                    suitePtr.baseAddress, UInt(suitePtr.count),
                                    Self.qpPolicyVersion,
                                    skPQ, UInt(Self.qpMlkem768SKLen),
                                    ctPQPtr.baseAddress, UInt(ctPQPtr.count),
                                    pkPQ, UInt(Self.qpMlkem768PKLen),
                                    skTrad, UInt(Self.qpX25519Len),
                                    ctTradPtr.baseAddress, UInt(ctTradPtr.count),
                                    pkTrad, UInt(Self.qpX25519Len),
                                    ctxPtr.baseAddress, UInt(ctxPtr.count),
                                    secretPtr.baseAddress, UInt(secretPtr.count)
                                )
                            }
                        }
                    }
                }
            }
        }
        guard status == Self.qpOkStatus else {
            throw CryptoProviderError.decapsulationFailed(
                "q_periapt_hybrid_decapsulate failed: \(QPeriaptRuntimeContract.statusDescription(status))"
            )
        }

        let sharedSecretSecure = SecureBytes(data: Data(secret))
        return sharedSecretSecure
    }
    #endif

 // MARK: - HPKE Operations (DEM identical to OQSPQCProvider)

 /// HPKE 封装 ((ML-KEM-768 + X25519) hybrid KEM + AES-256-GCM)
 /// - Parameters:
 /// - plaintext: 明文数据
 /// - recipientPublicKey: 接收方公钥 (pk_pq ‖ pk_trad, 1216 B)
 /// - info: 上下文信息 (用于 HKDF)
 /// - Returns: HPKESealedBox
    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        #if canImport(CQPeriapt)
 // 1. + 2. 使用 Q-Periapt 混合 KEM 封装生成共享密钥（长度校验在 qpEncapsulate 内）
        let kem = try qpEncapsulate(recipientPublicKey: recipientPublicKey)
        let sharedSecretSecure = kem.sharedSecret
        let ciphertext = kem.encapsulatedKey

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
            encapsulatedKey: ciphertext,
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
        #if canImport(CQPeriapt)
 // 1. + 2. 使用 Q-Periapt 混合 KEM 封装生成共享密钥（长度校验在 qpEncapsulate 内）
        let kem = try qpEncapsulate(recipientPublicKey: recipientPublicKey)
        let sharedSecretSecure = kem.sharedSecret
        let ciphertext = kem.encapsulatedKey

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
                encapsulatedKey: ciphertext,
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
 /// - privateKey: 接收方私钥 (sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad, 3648 B)
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
        #if canImport(CQPeriapt)
 // 1. + 2. + 3. 使用 Q-Periapt 混合 KEM 解封装恢复共享密钥（长度校验在 qpDecapsulate 内）
        let sharedSecretSecure = try qpDecapsulate(
            encapsulatedKey: sealedBox.encapsulatedKey,
            privateKey: privateKey
        )

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
        #if canImport(CQPeriapt)
 // 1. + 2. + 3. 使用 Q-Periapt 混合 KEM 解封装恢复共享密钥（长度校验在 qpDecapsulate 内）
        let sharedSecretSecure = try qpDecapsulate(
            encapsulatedKey: sealedBox.encapsulatedKey,
            privateKey: privateKey
        )

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
        #if canImport(CQPeriapt)
        return try qpEncapsulate(recipientPublicKey: recipientPublicKey)
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        #if canImport(CQPeriapt)
        return try qpDecapsulate(encapsulatedKey: encapsulatedKey, privateKey: privateKey)
        #else
        throw CryptoProviderError.providerNotAvailable(.liboqs)
        #endif
    }

 // MARK: - Signature Operations (ML-DSA-65 — copied verbatim from OQSPQCProvider)

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
        switch usage {
        case .keyExchange:
            #if canImport(CQPeriapt)
            return try generateQPeriaptKEMKeyPair()
            #else
            throw CryptoProviderError.providerNotAvailable(.liboqs)
            #endif
        case .signing:
            #if canImport(OQSRAII)
            return try generateMLDSA65KeyPair()
            #else
            throw CryptoProviderError.providerNotAvailable(.liboqs)
            #endif
        }
    }

 // MARK: - Private Methods

    #if canImport(CQPeriapt)
 /// 生成 Q-Periapt 混合 KEM 密钥对（ML-KEM-768 + X25519）。
 /// 复用 `QPeriaptKEMProvider.generateKeyPair` 的 blob 布局：
 ///   publicKey  = pk_pq ‖ pk_trad
 ///   privateKey = sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad
    private func generateQPeriaptKEMKeyPair() throws -> KeyPair {
        try QPeriaptRuntimeContract.requireCompatible()

        // ML-KEM-768 keypair (deterministic from a 64-byte seed).
        var mlkemSeed = try Self.randomBytes(count: Self.qpMlkemSeedLen)
        defer { Self.wipe(&mlkemSeed) }

        var skPQ = [UInt8](repeating: 0, count: Self.qpMlkem768SKLen)
        defer { Self.wipe(&skPQ) }
        var pkPQ = [UInt8](repeating: 0, count: Self.qpMlkem768PKLen)

        let pqStatus = mlkemSeed.withUnsafeBufferPointer { seedPtr in
            skPQ.withUnsafeMutableBufferPointer { skPtr in
                pkPQ.withUnsafeMutableBufferPointer { pkPtr in
                    q_periapt_mlkem768_keypair(
                        seedPtr.baseAddress, UInt(seedPtr.count),
                        skPtr.baseAddress, UInt(skPtr.count),
                        pkPtr.baseAddress, UInt(pkPtr.count)
                    )
                }
            }
        }
        guard pqStatus == Self.qpOkStatus else {
            throw CryptoProviderError.keyGenerationFailed(
                "q_periapt_mlkem768_keypair failed: \(QPeriaptRuntimeContract.statusDescription(pqStatus))"
            )
        }

        // X25519 keypair (deterministic from a 32-byte scalar).
        var x25519Secret = try Self.randomBytes(count: Self.qpX25519Len)
        defer { Self.wipe(&x25519Secret) }

        var skTrad = [UInt8](repeating: 0, count: Self.qpX25519Len)
        defer { Self.wipe(&skTrad) }
        var pkTrad = [UInt8](repeating: 0, count: Self.qpX25519Len)

        let tradStatus = x25519Secret.withUnsafeBufferPointer { secretPtr in
            skTrad.withUnsafeMutableBufferPointer { skPtr in
                pkTrad.withUnsafeMutableBufferPointer { pkPtr in
                    q_periapt_x25519_keypair(
                        secretPtr.baseAddress, UInt(secretPtr.count),
                        skPtr.baseAddress, UInt(skPtr.count),
                        pkPtr.baseAddress, UInt(pkPtr.count)
                    )
                }
            }
        }
        guard tradStatus == Self.qpOkStatus else {
            throw CryptoProviderError.keyGenerationFailed(
                "q_periapt_x25519_keypair failed: \(QPeriaptRuntimeContract.statusDescription(tradStatus))"
            )
        }

        // publicKey = pk_pq ‖ pk_trad
        var publicKey = Data()
        publicKey.append(contentsOf: pkPQ)
        publicKey.append(contentsOf: pkTrad)

        // privateKey = sk_pq ‖ sk_trad ‖ pk_pq ‖ pk_trad
        var privateKey = Data()
        privateKey.append(contentsOf: skPQ)
        privateKey.append(contentsOf: skTrad)
        privateKey.append(contentsOf: pkPQ)
        privateKey.append(contentsOf: pkTrad)

        return KeyPair(
            publicKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: publicKey
            ),
            privateKey: KeyMaterial(
                suite: activeSuite,
                usage: .keyExchange,
                bytes: privateKey
            )
        )
    }
    #endif

    #if canImport(OQSRAII)
 /// 生成 ML-DSA-65 密钥对（与 OQSPQCProvider 一致）
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

 /// 从共享密钥派生对称密钥 (HKDF-SHA256) — 与 OQSPQCProvider 完全一致
    private func deriveSymmetricKey(from sharedSecret: Data, info: Data) throws -> SymmetricKey {
        let inputKey = SymmetricKey(data: sharedSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Self.hkdfSalt(info: info),
            info: info,
            outputByteCount: Self.aesKeySize
        )
    }

 // MARK: - KEM Helpers (mirror QPeriaptKEMProvider)

    /// 使用系统 CSPRNG 生成随机字节。
    private static func randomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed("SecRandomCopyBytes failed (\(status))")
        }
        #else
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        #endif
        return bytes
    }

    /// 擦除敏感缓冲区，使用与 `SecureBytes` 相同的不可优化实现。
    private static func wipe(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            SecureBytes.wipingFunction(baseAddress, bytes.count)
        }
    }
}
