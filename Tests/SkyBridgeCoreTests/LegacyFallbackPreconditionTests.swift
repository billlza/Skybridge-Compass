//
// LegacyFallbackPreconditionTests.swift
// SkyBridgeCoreTests
//
// 13.6: Legacy Fallback Security Precondition Property Tests
// Requirements: 11.1, 11.2
//
// 验证 Legacy P-256 fallback 的安全前置条件：
// - Property 7: Legacy Fallback Security Precondition
// - 纯网络陌生人连接 → throw legacyFallbackNotAllowed
// - 有认证通道或已有 TrustRecord → 允许
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class LegacyFallbackPreconditionTests: XCTestCase {
    
 // MARK: - Property 7: Legacy Fallback Security Precondition
    
 /// Property 7.1: 纯网络陌生人连接不允许 legacy fallback
 ///
 /// **Validates: Requirements 11.1, 11.2**
    func testPureNetworkStrangerNotAllowed() async throws {
        let verifier = FirstContactVerifier()
        
 // 创建测试数据
        let testData = Data("test message".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
 // 纯网络陌生人：无 TrustRecord，无认证配对上下文
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "stranger-device-id",
            trustRecord: nil,
            pairingContext: nil
        )
        
 // 前置条件应该不满足
        XCTAssertFalse(precondition.isSatisfied, "Pure network stranger should not satisfy precondition")
        
 // 验证应该抛出错误
        do {
            _ = try await verifier.verify(
                data: testData,
                signature: signature,
                publicKey: publicKey,
                encodingPath: .legacy,
                offeredSuites: [],
                precondition: precondition
            )
            XCTFail("Should throw legacyFallbackNotAllowed for pure network stranger")
        } catch let error as LegacyFallbackError {
            switch error {
            case .preconditionNotSatisfied:
 // 预期的错误
                break
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
    
 /// Property 7.2: 有认证通道（QR）允许 legacy fallback
 ///
 /// **Validates: Requirements 11.1**
    func testAuthenticatedChannelQRAllowed() async throws {
        let verifier = FirstContactVerifier()
        
 // 创建测试数据
        let testData = Data("test message for QR pairing".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
 // QR 码配对上下文（已验证）
        let pairingContext = PairingContext(
            channelType: .qrCode,
            isVerified: true
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "qr-paired-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
 // 前置条件应该满足
        XCTAssertTrue(precondition.isSatisfied, "QR authenticated channel should satisfy precondition")
        XCTAssertEqual(precondition.type, .authenticatedChannel)
        
 // 验证应该成功
        let result = try await verifier.verify(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            encodingPath: .legacy,
            offeredSuites: [],
            precondition: precondition
        )
        
        switch result {
        case .legacyVerified(let pc):
            XCTAssertEqual(pc.type, .authenticatedChannel)
        default:
            XCTFail("Expected legacyVerified result")
        }
    }
    
 /// Property 7.3: 有认证通道（PAKE）允许 legacy fallback
 ///
 /// **Validates: Requirements 11.1**
    func testAuthenticatedChannelPAKEAllowed() async throws {
        let verifier = FirstContactVerifier()
        
        let testData = Data("test message for PAKE pairing".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
 // PAKE 配对上下文（已验证）
        let pairingContext = PairingContext(
            channelType: .pake,
            isVerified: true
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "pake-paired-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
        XCTAssertTrue(precondition.isSatisfied, "PAKE authenticated channel should satisfy precondition")
        
        let result = try await verifier.verify(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            encodingPath: .legacy,
            offeredSuites: [],
            precondition: precondition
        )
        
        switch result {
        case .legacyVerified:
            break // 预期结果
        default:
            XCTFail("Expected legacyVerified result")
        }
    }
    
 /// Property 7.4: 已有 TrustRecord（含 legacy 公钥）允许 legacy fallback
 ///
 /// **Validates: Requirements 11.2**
    func testExistingTrustRecordWithLegacyKeyAllowed() async throws {
        let verifier = FirstContactVerifier()
        
        let testData = Data("test message for existing trust".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
 // 创建包含 legacy P-256 公钥的 TrustRecord
        let trustRecord = TrustRecord(
            deviceId: "trusted-device",
            pubKeyFP: "abc123",
            publicKey: Data(),
            legacyP256PublicKey: publicKey,  // 有 legacy 公钥
            signature: Data()
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "trusted-device",
            trustRecord: trustRecord,
            pairingContext: nil
        )
        
        XCTAssertTrue(precondition.isSatisfied, "Existing TrustRecord with legacy key should satisfy precondition")
        XCTAssertEqual(precondition.type, .existingTrustRecord)
        
        let result = try await verifier.verify(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            encodingPath: .legacy,
            offeredSuites: [],
            precondition: precondition
        )
        
        switch result {
        case .legacyVerified(let pc):
            XCTAssertEqual(pc.type, .existingTrustRecord)
        default:
            XCTFail("Expected legacyVerified result")
        }
    }
    
 /// Property 7.5: 已有 TrustRecord 但无 legacy 公钥不允许 legacy fallback
 ///
 /// **Validates: Requirements 11.2**
    func testExistingTrustRecordWithoutLegacyKeyNotAllowed() async throws {
        let testData = Data("test message".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
 // 创建不含 legacy P-256 公钥的 TrustRecord
        let trustRecord = TrustRecord(
            deviceId: "modern-device",
            pubKeyFP: "def456",
            publicKey: Data(repeating: 0, count: 32),  // Ed25519 公钥
            legacyP256PublicKey: nil,  // 无 legacy 公钥
            signature: Data()
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "modern-device",
            trustRecord: trustRecord,
            pairingContext: nil
        )
        
 // TrustRecord 存在但无 legacy 公钥，不满足前置条件
        XCTAssertFalse(precondition.isSatisfied, "TrustRecord without legacy key should not satisfy precondition")
    }
    
 /// Property 7.6: 网络发现通道不算认证通道
 ///
 /// **Validates: Requirements 11.1**
    func testNetworkDiscoveryNotAuthenticated() async throws {
 // 网络发现配对上下文
        let pairingContext = PairingContext(
            channelType: .networkDiscovery,
            isVerified: false
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "discovered-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
 // 网络发现不算认证通道
        XCTAssertFalse(precondition.isSatisfied, "Network discovery should not satisfy precondition")
    }
    
 /// Property 7.7: 未验证的认证通道不允许 legacy fallback
 ///
 /// **Validates: Requirements 11.1**
    func testUnverifiedAuthenticatedChannelNotAllowed() async throws {
 // QR 码配对上下文（未验证）
        let pairingContext = PairingContext(
            channelType: .qrCode,
            isVerified: false  // 未验证
        )
        
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "unverified-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
 // 未验证的通道不满足前置条件
        XCTAssertFalse(precondition.isSatisfied, "Unverified channel should not satisfy precondition")
    }
    
 // MARK: - Modern Path Tests
    
 /// 测试 Modern 路径不需要前置条件
    func testModernPathNoPreconditionRequired() async throws {
        let verifier = FirstContactVerifier()
        
 // 创建 Ed25519 测试数据
        let testData = Data("test message for modern path".utf8)
        let (publicKey, signature) = try generateEd25519TestSignature(data: testData)
        
 // Modern 路径不需要前置条件
        let result = try await verifier.verify(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            encodingPath: .modern,
            offeredSuites: [.x25519Ed25519],  // Classic suite
            precondition: nil
        )
        
        switch result {
        case .modernVerified(let algorithm):
            XCTAssertEqual(algorithm, ProtocolSigningAlgorithm.ed25519)
        default:
            XCTFail("Expected modernVerified result")
        }
    }
    
 /// 测试 Modern 路径根据 offeredSuites 选择算法
    func testModernPathAlgorithmSelection() async throws {
        let verifier = FirstContactVerifier()
        
 // Classic suites → Ed25519
        let classicAlgorithm = verifier.selectModernAlgorithm(
            offeredSuites: [.x25519Ed25519]
        )
        XCTAssertEqual(classicAlgorithm, ProtocolSigningAlgorithm.ed25519)
        
 // PQC suites → ML-DSA-65
        let pqcAlgorithm = verifier.selectModernAlgorithm(
            offeredSuites: [.mlkem768MLDSA65]
        )
        XCTAssertEqual(pqcAlgorithm, ProtocolSigningAlgorithm.mlDSA65)
        
 // Mixed (has PQC) → ML-DSA-65
        let mixedAlgorithm = verifier.selectModernAlgorithm(
            offeredSuites: [.x25519Ed25519, .mlkem768MLDSA65]
        )
        XCTAssertEqual(mixedAlgorithm, ProtocolSigningAlgorithm.mlDSA65)
    }
    
 /// 测试编码路径判定
    func testEncodingPathDetermination() {
        let verifier = FirstContactVerifier()
        
 // P-256 → Legacy
        XCTAssertEqual(
            verifier.determineEncodingPath(wireAlgorithm: .p256ECDSA),
            .legacy
        )
        
 // Ed25519 → Modern
        XCTAssertEqual(
            verifier.determineEncodingPath(wireAlgorithm: .ed25519),
            .modern
        )
        
 // ML-DSA-65 → Modern
        XCTAssertEqual(
            verifier.determineEncodingPath(wireAlgorithm: .mlDSA65),
            .modern
        )
    }
    
 // MARK: - TrustRecord Update Tests
    
 /// 测试 Legacy 验证后的 TrustRecord 更新建议
    func testLegacyVerificationTrustUpdate() async throws {
        let verifier = FirstContactVerifier()
        
        let testData = Data("test message".utf8)
        let (publicKey, signature) = try generateP256TestSignature(data: testData)
        
        let pairingContext = PairingContext(
            channelType: .qrCode,
            isVerified: true
        )
        
        let (result, trustUpdate) = try await verifier.verifyAndSuggestTrustUpdate(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            wireAlgorithm: .p256ECDSA,
            offeredSuites: [],
            deviceId: "legacy-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
 // 验证结果
        switch result {
        case .legacyVerified:
            break
        default:
            XCTFail("Expected legacyVerified result")
        }
        
 // TrustRecord 更新建议
        XCTAssertNotNil(trustUpdate)
        XCTAssertEqual(trustUpdate?.legacyP256PublicKey, publicKey)
        XCTAssertNil(trustUpdate?.protocolPublicKey)
        XCTAssertEqual(trustUpdate?.signatureAlgorithm, .p256ECDSA)
        XCTAssertTrue(trustUpdate?.requiresUpgrade ?? false)
    }
    
 /// 测试 Modern 验证后的 TrustRecord 更新建议
    func testModernVerificationTrustUpdate() async throws {
        let verifier = FirstContactVerifier()
        
        let testData = Data("test message".utf8)
        let (publicKey, signature) = try generateEd25519TestSignature(data: testData)
        
        let (result, trustUpdate) = try await verifier.verifyAndSuggestTrustUpdate(
            data: testData,
            signature: signature,
            publicKey: publicKey,
            wireAlgorithm: .ed25519,
            offeredSuites: [.x25519Ed25519],
            deviceId: "modern-device",
            trustRecord: nil,
            pairingContext: nil
        )
        
 // 验证结果
        switch result {
        case .modernVerified(let algorithm):
            XCTAssertEqual(algorithm, ProtocolSigningAlgorithm.ed25519)
        default:
            XCTFail("Expected modernVerified result")
        }
        
 // TrustRecord 更新建议
        XCTAssertNotNil(trustUpdate)
        XCTAssertNil(trustUpdate?.legacyP256PublicKey)
        XCTAssertEqual(trustUpdate?.protocolPublicKey, publicKey)
        XCTAssertEqual(trustUpdate?.signatureAlgorithm, .ed25519)
        XCTAssertFalse(trustUpdate?.requiresUpgrade ?? true)
    }
    
 // MARK: - Helper Methods
    
 /// 生成 P-256 测试签名
    private func generateP256TestSignature(data: Data) throws -> (publicKey: Data, signature: Data) {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let signature = try privateKey.signature(for: data).derRepresentation
        return (publicKey, signature)
    }
    
 /// 生成 Ed25519 测试签名
    private func generateEd25519TestSignature(data: Data) throws -> (publicKey: Data, signature: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let signature = try privateKey.signature(for: data)
        return (publicKey, signature)
    }
}

// MARK: - CryptoKit Imports

import CryptoKit
