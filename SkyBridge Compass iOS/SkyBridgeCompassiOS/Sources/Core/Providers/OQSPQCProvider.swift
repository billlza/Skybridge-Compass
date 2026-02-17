//
// OQSPQCProvider.swift
// SkyBridgeCompassiOS
//
// liboqs PQC Provider (ML-KEM-768 + ML-DSA-65)
// 用于 iOS 17-25 / macOS < 26 的后量子能力补齐
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif
#if canImport(OQSRAII)
import OQSRAII
#endif

@available(iOS 17.0, macOS 14.0, *)
public struct OQSPQCCryptoProvider: CryptoProvider, Sendable {
    public let providerName = "liboqs"
    public let tier: CryptoTier = .liboqsPQC
    public let activeSuite: CryptoSuite = .mlkem768MLDSA65

    private static let nonceSize = 12
    private static let aesKeySize = 32
    private static let hkdfSaltLabel = "SkyBridge-KDF-Salt-v1|"

    public init() {}

    public static func selfTest() -> Bool {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mlkem768_public_key_length()
        let skLen = oqs_raii_mlkem768_secret_key_length()
        guard pkLen > 0, skLen > 0 else { return false }

        var pk = [UInt8](repeating: 0, count: pkLen)
        var sk = [UInt8](repeating: 0, count: skLen)
        guard oqs_raii_mlkem768_keypair(&pk, pk.count, &sk, sk.count) == OQSRAII_SUCCESS else {
            return false
        }

        let dsaPkLen = oqs_raii_mldsa65_public_key_length()
        let dsaSkLen = oqs_raii_mldsa65_secret_key_length()
        guard dsaPkLen > 0, dsaSkLen > 0 else { return false }

        var dsaPk = [UInt8](repeating: 0, count: dsaPkLen)
        var dsaSk = [UInt8](repeating: 0, count: dsaSkLen)
        guard oqs_raii_mldsa65_keypair(&dsaPk, dsaPk.count, &dsaSk, dsaSk.count) == OQSRAII_SUCCESS else {
            return false
        }
        return true
        #else
        return false
        #endif
    }

    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        #if canImport(OQSRAII)
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedPkLen,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: ssLen)
        var ciphertext = [UInt8](repeating: 0, count: ctLen)

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
                    ssLen
                )
            }
        }

        guard encapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed")
        }

        let derivedKey = deriveSymmetricKey(from: sharedSecretSecure.data, info: info)
        let nonceData = try randomNonceData()
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)

        return HPKESealedBox(
            encapsulatedKey: Data(ciphertext),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            nonce: nonceData
        )
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedPkLen,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: ssLen)
        var ciphertext = [UInt8](repeating: 0, count: ctLen)

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
                    ssLen
                )
            }
        }

        guard encapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed")
        }

        let derivedKey = deriveSymmetricKey(from: sharedSecretSecure.data, info: info)
        let nonceData = try randomNonceData()
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)

        return (
            sealedBox: HPKESealedBox(
                encapsulatedKey: Data(ciphertext),
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                nonce: nonceData
            ),
            sharedSecret: sharedSecretSecure
        )
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
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
        #if canImport(OQSRAII)
        let expectedSkLen = oqs_raii_mlkem768_secret_key_length()
        guard privateKey.byteCount == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedSkLen,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let expectedCtLen = oqs_raii_mlkem768_ciphertext_length()
        guard sealedBox.encapsulatedKey.count == expectedCtLen else {
            throw CryptoProviderError.invalidCiphertext(
                "Invalid encapsulated key length: expected \(expectedCtLen), got \(sealedBox.encapsulatedKey.count)"
            )
        }

        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: ssLen)

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
                        ssLen
                    )
                }
            }
        }

        guard decapsResult == OQSRAII_SUCCESS else {
            throw CryptoProviderError.decapsulationFailed("ML-KEM-768 decapsulation failed")
        }

        let derivedKey = deriveSymmetricKey(from: sharedSecretSecure.data, info: info)
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealedBox.ciphertext, tag: sealedBox.tag)
        return try AES.GCM.open(gcmBox, using: derivedKey)
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
        let plaintext = try await hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
        let shared = try await kemDecapsulate(encapsulatedKey: sealedBox.encapsulatedKey, privateKey: privateKey)
        return (plaintext: plaintext, sharedSecret: shared)
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        #if canImport(OQSRAII)
        let expectedPkLen = oqs_raii_mlkem768_public_key_length()
        guard recipientPublicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedPkLen,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let ctLen = oqs_raii_mlkem768_ciphertext_length()
        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: ssLen)
        var ciphertext = [UInt8](repeating: 0, count: ctLen)

        let result = recipientPublicKey.withUnsafeBytes { pkPtr -> Int32 in
            guard let pkBase = pkPtr.baseAddress else { return OQSRAII_FAIL }
            return sharedSecretSecure.withUnsafeMutableBytes { ssPtr -> Int32 in
                guard let ssBase = ssPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mlkem768_encaps(
                    pkBase.assumingMemoryBound(to: UInt8.self),
                    recipientPublicKey.count,
                    &ciphertext,
                    ciphertext.count,
                    ssBase.assumingMemoryBound(to: UInt8.self),
                    ssLen
                )
            }
        }

        guard result == OQSRAII_SUCCESS else {
            throw CryptoProviderError.encapsulationFailed("ML-KEM-768 encapsulation failed")
        }

        return (encapsulatedKey: Data(ciphertext), sharedSecret: sharedSecretSecure)
        #else
        throw CryptoProviderError.pqcNotAvailable
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
                expected: expectedSkLen,
                actual: privateKey.byteCount,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }

        let expectedCtLen = oqs_raii_mlkem768_ciphertext_length()
        guard encapsulatedKey.count == expectedCtLen else {
            throw CryptoProviderError.invalidCiphertext(
                "Invalid encapsulated key length: expected \(expectedCtLen), got \(encapsulatedKey.count)"
            )
        }

        let ssLen = oqs_raii_mlkem768_shared_secret_length()
        let sharedSecretSecure = SecureBytes(count: ssLen)

        let result = encapsulatedKey.withUnsafeBytes { ctPtr -> Int32 in
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
                        ssLen
                    )
                }
            }
        }

        guard result == OQSRAII_SUCCESS else {
            throw CryptoProviderError.decapsulationFailed("ML-KEM-768 decapsulation failed")
        }
        return sharedSecretSecure
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        #if canImport(OQSRAII)
        let privateKey: Data
        switch keyHandle {
        case .softwareKey(let bytes):
            privateKey = bytes
        case .callback(let callback):
            return try await callback.sign(data: data)
        #if canImport(Security)
        case .secureEnclaveRef:
            throw CryptoProviderError.signatureFailed("Secure Enclave does not support ML-DSA-65")
        #endif
        }

        let expectedSkLen = oqs_raii_mldsa65_secret_key_length()
        guard privateKey.count == expectedSkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedSkLen,
                actual: privateKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }

        let maxSigLen = oqs_raii_mldsa65_signature_length()
        var signature = [UInt8](repeating: 0, count: maxSigLen)
        var actualSigLen = maxSigLen

        let result = data.withUnsafeBytes { msgPtr -> Int32 in
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

        guard result == OQSRAII_SUCCESS else {
            throw CryptoProviderError.signatureFailed("ML-DSA-65 signing failed")
        }

        return Data(signature.prefix(actualSigLen))
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        #if canImport(OQSRAII)
        let expectedPkLen = oqs_raii_mldsa65_public_key_length()
        guard publicKey.count == expectedPkLen else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedPkLen,
                actual: publicKey.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }

        return data.withUnsafeBytes { msgPtr -> Bool in
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
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        #if canImport(OQSRAII)
        switch usage {
        case .keyExchange, .ephemeral:
            let pkLen = oqs_raii_mlkem768_public_key_length()
            let skLen = oqs_raii_mlkem768_secret_key_length()
            var pk = [UInt8](repeating: 0, count: pkLen)
            let sk = SecureBytes(count: skLen)

            let result = sk.withUnsafeMutableBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mlkem768_keypair(
                    &pk,
                    pk.count,
                    skBase.assumingMemoryBound(to: UInt8.self),
                    skLen
                )
            }
            guard result == OQSRAII_SUCCESS else {
                throw CryptoProviderError.keyGenerationFailed("ML-KEM-768 keypair generation failed")
            }
            return KeyPair(publicKey: Data(pk), privateKey: sk.data)

        case .signing:
            let pkLen = oqs_raii_mldsa65_public_key_length()
            let skLen = oqs_raii_mldsa65_secret_key_length()
            var pk = [UInt8](repeating: 0, count: pkLen)
            let sk = SecureBytes(count: skLen)

            let result = sk.withUnsafeMutableBytes { skPtr -> Int32 in
                guard let skBase = skPtr.baseAddress else { return OQSRAII_FAIL }
                return oqs_raii_mldsa65_keypair(
                    &pk,
                    pk.count,
                    skBase.assumingMemoryBound(to: UInt8.self),
                    skLen
                )
            }
            guard result == OQSRAII_SUCCESS else {
                throw CryptoProviderError.keyGenerationFailed("ML-DSA-65 keypair generation failed")
            }
            return KeyPair(publicKey: Data(pk), privateKey: sk.data)
        }
        #else
        throw CryptoProviderError.pqcNotAvailable
        #endif
    }

    private func deriveSymmetricKey(from sharedSecret: Data, info: Data) -> SymmetricKey {
        var saltMaterial = Data(Self.hkdfSaltLabel.utf8)
        saltMaterial.append(info)
        let salt = Data(SHA256.hash(data: saltMaterial))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: Self.aesKeySize
        )
    }

    private func randomNonceData() throws -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: Self.nonceSize)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed("Failed to generate nonce")
        }
        return Data(bytes)
        #else
        return Data((0..<Self.nonceSize).map { _ in UInt8.random(in: .min ... .max) })
        #endif
    }
}
