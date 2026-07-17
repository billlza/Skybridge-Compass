//
// DeviceIdentityKeyManagerMLDSATests.swift
// SkyBridgeCoreTests
//
// 11.4: ML-DSA Sign-Verify Round Trip Property Tests
// Requirements: 8.7
//
// 验证 ML-DSA-65 签名/验证的正确性：
// - Property 8: ML-DSA Sign-Verify Round Trip
// - 100+ 随机消息
// - sign(data, privateKey) → verify(data, signature, publicKey) == true
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore
#if canImport(OQSRAII)
import OQSRAII
#endif

@available(macOS 14.0, iOS 17.0, *)
final class DeviceIdentityKeyManagerMLDSATests: XCTestCase {
    
 // MARK: - Property 8: ML-DSA Sign-Verify Round Trip
    
 /// Property 8: ML-DSA-65 签名后验证必须成功
 ///
 /// **Validates: Requirements 8.7**
    func testMLDSASignVerifyRoundTrip() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .oqs)
        
 // 生成 ML-DSA-65 密钥对
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        
        let keypairResult = oqs_raii_mldsa65_keypair(
            &publicKeyBytes, pkLen,
            &privateKeyBytes, skLen
        )
        XCTAssertEqual(keypairResult, OQSRAII_SUCCESS, "ML-DSA-65 keypair generation should succeed")
        
        let publicKey = Data(publicKeyBytes)
        let privateKey = Data(privateKeyBytes)
        let keyHandle = SigningKeyHandle.softwareKey(privateKey)
        
 // 100+ 随机消息测试
        for i in 0..<100 {
 // 生成随机长度消息 (1-10000 bytes)
            let messageLength = Int.random(in: 1...10000)
            var messageBytes = [UInt8](repeating: 0, count: messageLength)
            _ = SecRandomCopyBytes(kSecRandomDefault, messageLength, &messageBytes)
            let message = Data(messageBytes)
            
 // 签名
            let signature = try await provider.sign(message, key: keyHandle)
            
 // 验证
            let isValid = try await provider.verify(message, signature: signature, publicKey: publicKey)
            XCTAssertTrue(isValid, "Round trip \(i): signature verification should succeed")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// Property 8.1: 修改消息后验证必须失败
    func testMLDSAModifiedMessageVerificationFails() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .oqs)
        
 // 生成密钥对
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        
        _ = oqs_raii_mldsa65_keypair(&publicKeyBytes, pkLen, &privateKeyBytes, skLen)
        
        let publicKey = Data(publicKeyBytes)
        let privateKey = Data(privateKeyBytes)
        let keyHandle = SigningKeyHandle.softwareKey(privateKey)
        
 // 50 次随机测试
        for _ in 0..<50 {
            let message = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
            let signature = try await provider.sign(message, key: keyHandle)
            
 // 修改消息的一个字节
            var modifiedMessage = message
            let index = Int.random(in: 0..<message.count)
            modifiedMessage[index] ^= 0xFF
            
 // 验证应该失败
            let isValid = try await provider.verify(modifiedMessage, signature: signature, publicKey: publicKey)
            XCTAssertFalse(isValid, "Modified message verification should fail")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// Property 8.2: 修改签名后验证必须失败
    func testMLDSAModifiedSignatureVerificationFails() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .oqs)
        
 // 生成密钥对
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        
        _ = oqs_raii_mldsa65_keypair(&publicKeyBytes, pkLen, &privateKeyBytes, skLen)
        
        let publicKey = Data(publicKeyBytes)
        let privateKey = Data(privateKeyBytes)
        let keyHandle = SigningKeyHandle.softwareKey(privateKey)
        
 // 50 次随机测试
        for _ in 0..<50 {
            let message = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
            let signature = try await provider.sign(message, key: keyHandle)
            
 // 修改签名的一个字节
            var modifiedSignature = signature
            let index = Int.random(in: 0..<signature.count)
            modifiedSignature[index] ^= 0xFF
            
 // 验证应该失败
            let isValid = try await provider.verify(message, signature: modifiedSignature, publicKey: publicKey)
            XCTAssertFalse(isValid, "Modified signature verification should fail")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// Property 8.3: 使用错误公钥验证必须失败
    func testMLDSAWrongPublicKeyVerificationFails() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .oqs)
        
 // 生成两对密钥
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        
        var publicKey1Bytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKey1Bytes = [UInt8](repeating: 0, count: Int(skLen))
        var publicKey2Bytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKey2Bytes = [UInt8](repeating: 0, count: Int(skLen))
        
        _ = oqs_raii_mldsa65_keypair(&publicKey1Bytes, pkLen, &privateKey1Bytes, skLen)
        _ = oqs_raii_mldsa65_keypair(&publicKey2Bytes, pkLen, &privateKey2Bytes, skLen)
        
        let publicKey2 = Data(publicKey2Bytes)
        let privateKey1 = Data(privateKey1Bytes)
        let keyHandle1 = SigningKeyHandle.softwareKey(privateKey1)
        
 // 50 次随机测试
        for _ in 0..<50 {
            let message = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
            
 // 使用密钥1签名
            let signature = try await provider.sign(message, key: keyHandle1)
            
 // 使用密钥2的公钥验证（应该失败）
            let isValid = try await provider.verify(message, signature: signature, publicKey: publicKey2)
            XCTAssertFalse(isValid, "Wrong public key verification should fail")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 // MARK: - DeviceIdentityKeyManager ML-DSA Integration Tests
    
 /// 测试 DeviceIdentityKeyManager.getProtocolSigningKeyHandle(for: .mlDSA65)
    func testDeviceIdentityKeyManagerMLDSAKeyHandle() async throws {
        #if canImport(OQSRAII)
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        defer { XCTAssertNoThrow(try deviceIdentity.reset()) }
        let manager = deviceIdentity.manager
        
 // 获取 ML-DSA-65 密钥句柄
        let keyHandle = try await manager.getProtocolSigningKeyHandle(for: .mlDSA65)
        
 // 验证是软件密钥
        switch keyHandle {
        case .softwareKey(let privateKey):
 // ML-DSA-65 私钥长度：4032 bytes
            let expectedSkLen = oqs_raii_mldsa65_secret_key_length()
            XCTAssertEqual(privateKey.count, Int(expectedSkLen), "ML-DSA-65 private key should be \(expectedSkLen) bytes")
        default:
            XCTFail("ML-DSA-65 key should be software key")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// 测试 DeviceIdentityKeyManager.getProtocolSigningPublicKey(for: .mlDSA65)
    func testDeviceIdentityKeyManagerMLDSAPublicKey() async throws {
        #if canImport(OQSRAII)
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        defer { XCTAssertNoThrow(try deviceIdentity.reset()) }
        let manager = deviceIdentity.manager
        
 // 获取 ML-DSA-65 公钥
        let publicKey = try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
        
 // ML-DSA-65 公钥长度：1952 bytes
        let expectedPkLen = oqs_raii_mldsa65_public_key_length()
        XCTAssertEqual(publicKey.count, Int(expectedPkLen), "ML-DSA-65 public key should be \(expectedPkLen) bytes")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// 测试 ML-DSA 密钥的幂等性（多次调用返回相同密钥）
    func testMLDSAKeyIdempotency() async throws {
        #if canImport(OQSRAII)
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        defer { XCTAssertNoThrow(try deviceIdentity.reset()) }
        let manager = deviceIdentity.manager
        
 // 第一次获取
        let publicKey1 = try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
        let keyHandle1 = try await manager.getProtocolSigningKeyHandle(for: .mlDSA65)
        
 // 第二次获取
        let publicKey2 = try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
        let keyHandle2 = try await manager.getProtocolSigningKeyHandle(for: .mlDSA65)
        
 // 应该返回相同的密钥
        XCTAssertEqual(publicKey1, publicKey2, "Multiple calls should return same public key")
        
 // 验证私钥也相同
        switch (keyHandle1, keyHandle2) {
        case (.softwareKey(let pk1), .softwareKey(let pk2)):
            XCTAssertEqual(pk1, pk2, "Multiple calls should return same private key")
        default:
            XCTFail("Both should be software keys")
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// 测试 ML-DSA 密钥与 Ed25519 密钥独立
    func testMLDSAAndEd25519KeysAreIndependent() async throws {
        #if canImport(OQSRAII)
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        defer { XCTAssertNoThrow(try deviceIdentity.reset()) }
        let manager = deviceIdentity.manager
        
 // 获取两种算法的公钥
        let ed25519PublicKey = try await manager.getProtocolSigningPublicKey(for: .ed25519)
        let mldsaPublicKey = try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
        
 // 长度应该不同
        XCTAssertEqual(ed25519PublicKey.count, 32, "Ed25519 public key should be 32 bytes")
        XCTAssertEqual(mldsaPublicKey.count, Int(oqs_raii_mldsa65_public_key_length()), "ML-DSA-65 public key should be 1952 bytes")
        
 // 内容应该不同
        XCTAssertNotEqual(ed25519PublicKey, mldsaPublicKey, "Ed25519 and ML-DSA-65 keys should be different")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 /// 测试使用 DeviceIdentityKeyManager 的密钥进行签名验证
    func testSignVerifyWithDeviceIdentityKeyManager() async throws {
        #if canImport(OQSRAII)
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        defer { XCTAssertNoThrow(try deviceIdentity.reset()) }
        let manager = deviceIdentity.manager
        let provider = PQCSignatureProvider(backend: .oqs)
        
 // 获取密钥
        let publicKey = try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
        let keyHandle = try await manager.getProtocolSigningKeyHandle(for: .mlDSA65)
        
 // 签名验证测试
        let message = Data("SkyBridge ML-DSA-65 Test Message".utf8)
        let signature = try await provider.sign(message, key: keyHandle)
        let isValid = try await provider.verify(message, signature: signature, publicKey: publicKey)
        
        XCTAssertTrue(isValid, "Signature verification should succeed")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
    
 // MARK: - Key Length Validation Tests
    
 /// 验证 ML-DSA-65 密钥长度符合规范
    func testMLDSAKeyLengths() async throws {
        #if canImport(OQSRAII)
 // ML-DSA-65 标准长度
        let expectedPublicKeyLength = 1952
        let expectedSecretKeyLength = 4032
        let expectedSignatureLength = 3309  // 最大签名长度
        
        let actualPkLen = oqs_raii_mldsa65_public_key_length()
        let actualSkLen = oqs_raii_mldsa65_secret_key_length()
        let actualSigLen = oqs_raii_mldsa65_signature_length()
        
        XCTAssertEqual(Int(actualPkLen), expectedPublicKeyLength, "ML-DSA-65 public key length mismatch")
        XCTAssertEqual(Int(actualSkLen), expectedSecretKeyLength, "ML-DSA-65 secret key length mismatch")
        XCTAssertEqual(Int(actualSigLen), expectedSignatureLength, "ML-DSA-65 signature length mismatch")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }
}

@available(macOS 14.0, iOS 17.0, *)
final class DeviceIdentityMLDSACanonicalStorageTests: XCTestCase {
    func testConcurrentGetOrCreateConvergesOnOneCanonicalFingerprint() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let managers = (0..<8).map { _ in
            makeManager(namespace: namespace)
        }
        let publicKeys = try await withThrowingTaskGroup(
            of: Data.self,
            returning: [Data].self
        ) { group in
            for manager in managers {
                group.addTask {
                    try await manager.getProtocolSigningPublicKey(for: .mlDSA65)
                }
            }
            var keys: [Data] = []
            for try await key in group {
                keys.append(key)
            }
            return keys
        }

        let fingerprints = Set(publicKeys.map { Data(SHA256.hash(data: $0)) })
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertTrue(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))
        XCTAssertEqual(
            DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace),
            publicKeys.first
        )
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testLegacyHalfPairFailsClosedWithoutCreatingCanonicalRecord() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let pair = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: pair.publicKey,
            privateKey: nil
        )

        let manager = makeManager(namespace: namespace)
        await assertIncompleteKeyMaterial {
            _ = try await manager.getOrCreateMLDSASigningKey()
        }
        XCTAssertFalse(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))
        XCTAssertNil(DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace))
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testLegacyPrivateOnlyHalfPairFailsClosedWithoutCreatingCanonicalRecord() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let pair = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: nil,
            privateKey: pair.privateKey
        )

        let manager = makeManager(namespace: namespace)
        await assertIncompleteKeyMaterial {
            _ = try await manager.getOrCreateMLDSASigningKey()
        }
        XCTAssertFalse(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))
        XCTAssertNil(DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace))
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testLegacyMismatchedPairFailsClosedWithoutCreatingCanonicalRecord() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let first = try makeMLDSAKeyPair()
        let second = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: first.publicKey,
            privateKey: second.privateKey
        )

        let manager = makeManager(namespace: namespace)
        await assertAuthorityConflict {
            _ = try await manager.getOrCreateMLDSASigningKey()
        }
        let retryManager = makeManager(namespace: namespace)
        await assertAuthorityConflict {
            _ = try await retryManager.getOrCreateMLDSASigningKey()
        }
        XCTAssertFalse(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))
        XCTAssertNil(DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace))
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testCanonicalRecordRejectsConflictingLegacyRemnantAndRecoversAfterCleanup() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let pair = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: pair.publicKey,
            privateKey: pair.privateKey
        )

        let firstManager = makeManager(namespace: namespace)
        let migrated = try await firstManager.getProtocolSigningPublicKey(for: .mlDSA65)
        XCTAssertEqual(migrated, pair.publicKey)
        XCTAssertTrue(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))

        let unrelatedPair = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: unrelatedPair.publicKey,
            privateKey: unrelatedPair.privateKey
        )
        let secondManager = makeManager(namespace: namespace)
        await assertAuthorityConflict {
            _ = try await secondManager.getProtocolSigningPublicKey(for: .mlDSA65)
        }
        XCTAssertTrue(try DeviceIdentityKeyManager.testingHasCanonicalMLDSARecord(namespace: namespace))
        XCTAssertEqual(
            DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace),
            pair.publicKey
        )

        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: nil,
            privateKey: nil
        )
        let thirdManager = makeManager(namespace: namespace)
        let reloaded = try await thirdManager.getProtocolSigningPublicKey(for: .mlDSA65)
        XCTAssertEqual(reloaded, pair.publicKey)
        XCTAssertNotEqual(reloaded, unrelatedPair.publicKey)
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testUserDefaultsMirrorIsNeverAnAuthority() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let mirrorOnlyPair = try makeMLDSAKeyPair()
        DeviceIdentityKeyManager.testingSetMirroredMLDSAPublicKey(
            mirrorOnlyPair.publicKey,
            namespace: namespace
        )
        let noAuthorityManager = makeManager(namespace: namespace)
        let mirrorOnlyResult = await noAuthorityManager.existingProtocolSigningPublicKey(for: .mlDSA65)
        XCTAssertNil(mirrorOnlyResult)

        let canonicalPair = try makeMLDSAKeyPair()
        var encoded = try encodeRecord(canonicalPair)
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }
        try DeviceIdentityKeyManager.testingSeedCanonicalMLDSAStorage(
            namespace: namespace,
            encodedRecord: encoded
        )

        let canonicalManager = makeManager(namespace: namespace)
        let canonicalResult = await canonicalManager.existingProtocolSigningPublicKey(for: .mlDSA65)
        XCTAssertEqual(canonicalResult, canonicalPair.publicKey)
        XCTAssertEqual(
            DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace),
            canonicalPair.publicKey
        )
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testCorruptCanonicalRecordDoesNotFallBackToValidLegacyPair() async throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace)
        defer {
            XCTAssertNoThrow(try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: namespace))
        }

        let validLegacyPair = try makeMLDSAKeyPair()
        try DeviceIdentityKeyManager.testingSeedLegacyMLDSAStorage(
            namespace: namespace,
            publicKey: validLegacyPair.publicKey,
            privateKey: validLegacyPair.privateKey
        )
        try DeviceIdentityKeyManager.testingSeedCanonicalMLDSAStorage(
            namespace: namespace,
            encodedRecord: Data("not-a-v3-record".utf8)
        )

        let manager = makeManager(namespace: namespace)
        await assertIncompleteKeyMaterial {
            _ = try await manager.getOrCreateMLDSASigningKey()
        }
        XCTAssertNil(DeviceIdentityKeyManager.testingMirroredMLDSAPublicKey(namespace: namespace))
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testCodecRejectsTrailingDataAndFixedLengthMismatch() throws {
        var encoded = try PQCKeyPairRecordCodec.encode(
            PQCKeyPairRecord(
                algorithmIdentifier: "ML-DSA-65",
                publicKey: Data(repeating: 0x11, count: 4),
                privateKey: Data(repeating: 0x22, count: 8)
            )
        )
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }

        XCTAssertThrowsError(
            try PQCKeyPairRecordCodec.decode(
                encoded,
                expectedAlgorithmIdentifier: "ML-DSA-65",
                expectedPublicKeyLength: 5,
                expectedPrivateKeyLength: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? PQCKeyPairRecordCodecError,
                .invalidPublicKeyLength(expected: 5, actual: 4)
            )
        }

        encoded.append(0xff)
        XCTAssertThrowsError(
            try PQCKeyPairRecordCodec.decode(
                encoded,
                expectedAlgorithmIdentifier: "ML-DSA-65",
                expectedPublicKeyLength: 4,
                expectedPrivateKeyLength: 8
            )
        ) { error in
            XCTAssertEqual(error as? PQCKeyPairRecordCodecError, .trailingData)
        }
    }

    func testMetadataInspectionValidatesTheCompleteEnvelopeWithoutReturningKeys() throws {
        var encoded = try PQCKeyPairRecordCodec.encode(
            PQCKeyPairRecord(
                algorithmIdentifier: "liboqs/signature/ML-DSA-65",
                publicKey: Data(repeating: 0x31, count: 17),
                privateKey: Data(repeating: 0x72, count: 29)
            )
        )
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }

        XCTAssertEqual(
            try PQCKeyPairRecordCodec.inspectMetadata(encoded),
            PQCKeyPairRecordMetadata(
                algorithmIdentifier: "liboqs/signature/ML-DSA-65",
                publicKeyLength: 17,
                privateKeyLength: 29
            )
        )

        var trailing = encoded
        defer { PQCKeyPairRecordCodec.wipe(&trailing) }
        trailing.append(0xff)
        XCTAssertThrowsError(try PQCKeyPairRecordCodec.inspectMetadata(trailing)) { error in
            XCTAssertEqual(error as? PQCKeyPairRecordCodecError, .trailingData)
        }

        var truncated = encoded.dropLast()
        defer { PQCKeyPairRecordCodec.wipe(&truncated) }
        XCTAssertThrowsError(try PQCKeyPairRecordCodec.inspectMetadata(truncated)) { error in
            XCTAssertEqual(error as? PQCKeyPairRecordCodecError, .truncatedRecord)
        }
    }

    func testValidatedUnscopedCanonicalRecordPromotesToSharedGroupWithoutRotation() throws {
        #if canImport(OQSRAII)
        let namespace = makeNamespace()
        let accessGroup = "group.com.skybridge.tests.\(namespace)"
        let location = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.mldsa-promotion.\(namespace)",
            account: "canonical"
        )
        let sharedScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: namespace,
            authority: .active,
            authorityDomain: .testing(namespace),
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: location,
                keychainScope: sharedScope,
                includeLegacyKeychain: true
            ),
            recordAlgorithmIdentifier: "ML-DSA-65"
        )
        defer {
            XCTAssertNoThrow(try PQCKeyPairStore.deleteForTesting(descriptor: descriptor))
            XCTAssertNoThrow(
                try PQCBackendAuthorityStore.deleteForTesting(
                    domain: .testing(namespace),
                    scopeSource: .explicitForTesting(sharedScope)
                )
            )
        }

        let pair = try makeMLDSAKeyPair()
        var encoded = try encodeRecord(pair)
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: location.service,
            account: location.account,
            scope: .applicationDefault
        )

        let groupOnlyScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: location.service,
                account: location.account,
                scope: groupOnlyScope
            )
        )

        let loaded = try XCTUnwrap(
            PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: pair.publicKey.count,
                privateKeyLength: pair.privateKey.count,
                validatePair: { record in
                    guard record.publicKey == pair.publicKey,
                          record.privateKey == pair.privateKey else {
                        throw DeviceIdentityKeyError.incompleteKeyMaterial(
                            "promotion test keypair mismatch"
                        )
                    }
                }
            )
        )
        XCTAssertEqual(loaded.publicKey, pair.publicKey)
        XCTAssertEqual(loaded.privateKey, pair.privateKey)

        let promoted = try XCTUnwrap(
            KeychainManager.shared.exportKeyStrict(
                service: location.service,
                account: location.account,
                scope: groupOnlyScope
            )
        )
        XCTAssertEqual(try PQCKeyPairRecordCodec.inspectMetadata(promoted).algorithmIdentifier, "ML-DSA-65")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    private func makeManager(namespace: String) -> DeviceIdentityKeyManager {
        let accessGroup = "group.com.skybridge.tests.device-identity.\(namespace)"
        let keychainScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        return DeviceIdentityKeyManager(
            testingStorageNamespace: namespace,
            keychainScope: keychainScope
        )
    }

    private func makeNamespace() -> String {
        "\(#function)-\(UUID().uuidString)"
    }

    #if canImport(OQSRAII)
    private func makeMLDSAKeyPair() throws -> (publicKey: Data, privateKey: Data) {
        let publicKeyLength = oqs_raii_mldsa65_public_key_length()
        let privateKeyLength = oqs_raii_mldsa65_secret_key_length()
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(publicKeyLength))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(privateKeyLength))
        defer {
            PQCKeyPairRecordCodec.wipe(&publicKeyBytes)
            PQCKeyPairRecordCodec.wipe(&privateKeyBytes)
        }

        guard oqs_raii_mldsa65_keypair(
            &publicKeyBytes,
            publicKeyLength,
            &privateKeyBytes,
            privateKeyLength
        ) == OQSRAII_SUCCESS else {
            throw DeviceIdentityKeyError.keyGenerationFailed("test keypair generation failed")
        }
        return (Data(publicKeyBytes), Data(privateKeyBytes))
    }

    private func encodeRecord(
        _ pair: (publicKey: Data, privateKey: Data)
    ) throws -> Data {
        try PQCKeyPairRecordCodec.encode(
            PQCKeyPairRecord(
                algorithmIdentifier: "ML-DSA-65",
                publicKey: pair.publicKey,
                privateKey: pair.privateKey
            )
        )
    }
    #endif

    private func assertIncompleteKeyMaterial(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected incomplete key material", file: file, line: line)
        } catch DeviceIdentityKeyError.incompleteKeyMaterial {
            return
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertAuthorityConflict(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected identity authority conflict", file: file, line: line)
        } catch DeviceIdentityKeyError.authorityConflict(let reason) {
            XCTAssertTrue(reason.contains("ML-DSA-65"), file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
