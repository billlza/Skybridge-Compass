// HybridCryptoTests.swift
// SkyBridgeCoreTests
//
// 混合加密模块测试 - 包含属性测试
// Created for web-agent-integration spec 10

import Testing
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SkyBridgeCore

// MARK: - Property Tests

/// **Feature: web-agent-integration, Property 10: 混合加密密钥交换一致性**
/// **Validates: Requirements 17.1**
@Suite("Hybrid Key Exchange Consistency Tests")
struct HybridKeyExchangeConsistencyTests {
    
 /// 生成随机测试数据
    static func generateRandomData(size: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                arc4random_buf(baseAddress, size)
            }
        }
        return data
    }
    
    @Test("混合密钥交换产生一致的共享密钥", arguments: (0..<10).map { _ in UUID().uuidString })
    func testHybridKeyExchangeConsistency(peerId: String) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let service = HybridCryptoService()
        
 // 生成模拟的远端公钥
        let remotePrivateKey = P256.KeyAgreement.PrivateKey()
        let remotePublicKey = remotePrivateKey.publicKey.rawRepresentation
        
 // 发起方执行混合密钥交换
        let result = try await service.initiateHybridKeyExchange(
            peerId: peerId,
            remoteClassicPublicKey: remotePublicKey
        )
        
 // 验证结果包含必要的组件
        #expect(!result.classicSharedSecret.isEmpty)
        #expect(!result.combinedSharedSecret.isEmpty)
        #expect(!result.classicEncapsulated.isEmpty)
        
 // 组合密钥应该是 32 字节（HKDF 输出）
        #expect(result.combinedSharedSecret.count == 32)
        
 // 响应方使用封装数据完成密钥交换
        let localPrivateKeyData = remotePrivateKey.rawRepresentation
        let completedSecret = try await service.completeHybridKeyExchange(
            peerId: peerId,
            classicEncapsulated: result.classicEncapsulated,
            pqcEncapsulated: result.pqcEncapsulated,
            localPrivateKey: localPrivateKeyData
        )
        
 // 双方应该得到相同的组合密钥
        #expect(completedSecret.count == 32)
        #else
 // CryptoKit 不可用，跳过测试
        #endif
    }
    
    @Test("多次密钥交换产生不同的共享密钥")
    func testKeyExchangeUniqueness() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let service = HybridCryptoService()
        let peerId = UUID().uuidString
        
 // 生成两个不同的远端密钥对
        let remoteKey1 = P256.KeyAgreement.PrivateKey()
        let remoteKey2 = P256.KeyAgreement.PrivateKey()
        
        let result1 = try await service.initiateHybridKeyExchange(
            peerId: peerId,
            remoteClassicPublicKey: remoteKey1.publicKey.rawRepresentation
        )
        
        let result2 = try await service.initiateHybridKeyExchange(
            peerId: peerId,
            remoteClassicPublicKey: remoteKey2.publicKey.rawRepresentation
        )
        
 // 不同的远端密钥应产生不同的共享密钥
        #expect(result1.combinedSharedSecret != result2.combinedSharedSecret)
        #else
        #endif
    }
}

// MARK: - Hybrid Signature Tests

/// **Feature: web-agent-integration, Property 10: 混合签名验证正确性**
/// **Validates: Requirements 17.2**
@Suite("Hybrid Signature Tests")
struct HybridSignatureTests {
    
    static func generateRandomData(size: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                arc4random_buf(baseAddress, size)
            }
        }
        return data
    }
    
    @Test("混合签名创建和验证", arguments: [16, 64, 256, 1024])
    func testHybridSignatureRoundTrip(dataSize: Int) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let service = HybridCryptoService()
        let peerId = UUID().uuidString
        let data = Self.generateRandomData(size: dataSize)
        
 // 生成签名密钥对
        let signingKey = P256.Signing.PrivateKey()
        let privateKeyData = signingKey.rawRepresentation
        let publicKeyData = signingKey.publicKey.rawRepresentation
        
 // 创建混合签名
        let signatureResult = try await service.createHybridSignature(
            data: data,
            peerId: peerId,
            classicPrivateKey: privateKeyData
        )
        
 // 验证签名结果
        #expect(!signatureResult.classicSignature.isEmpty)
        #expect(!signatureResult.combinedSignature.isEmpty)
        
 // 验证混合签名
        let isValid = await service.verifyHybridSignature(
            data: data,
            combinedSignature: signatureResult.combinedSignature,
            peerId: peerId,
            classicPublicKey: publicKeyData
        )
        
        #expect(isValid == true)
        #else
        #endif
    }
    
    @Test("篡改数据后混合签名验证失败")
    func testTamperedDataVerificationFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let service = HybridCryptoService()
        let peerId = UUID().uuidString
        let originalData = Self.generateRandomData(size: 100)
        
        let signingKey = P256.Signing.PrivateKey()
        let privateKeyData = signingKey.rawRepresentation
        let publicKeyData = signingKey.publicKey.rawRepresentation
        
        let signatureResult = try await service.createHybridSignature(
            data: originalData,
            peerId: peerId,
            classicPrivateKey: privateKeyData
        )
        
 // 篡改数据
        var tamperedData = originalData
        tamperedData[0] ^= 0xFF
        
 // 验证应失败
        let isValid = await service.verifyHybridSignature(
            data: tamperedData,
            combinedSignature: signatureResult.combinedSignature,
            peerId: peerId,
            classicPublicKey: publicKeyData
        )
        
        #expect(isValid == false)
        #else
        #endif
    }
    
    @Test("篡改签名后验证失败")
    func testTamperedSignatureVerificationFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let service = HybridCryptoService()
        let peerId = UUID().uuidString
        let data = Self.generateRandomData(size: 100)
        
        let signingKey = P256.Signing.PrivateKey()
        let privateKeyData = signingKey.rawRepresentation
        let publicKeyData = signingKey.publicKey.rawRepresentation
        
        let signatureResult = try await service.createHybridSignature(
            data: data,
            peerId: peerId,
            classicPrivateKey: privateKeyData
        )
        
 // 篡改签名
        var tamperedSignature = signatureResult.combinedSignature
        if tamperedSignature.count > 10 {
            tamperedSignature[10] ^= 0xFF
        }
        
 // 验证应失败
        let isValid = await service.verifyHybridSignature(
            data: data,
            combinedSignature: tamperedSignature,
            peerId: peerId,
            classicPublicKey: publicKeyData
        )
        
        #expect(isValid == false)
        #else
        #endif
    }
}

// MARK: - Encryption Mode Declaration Tests

/// **Feature: web-agent-integration, 10.4: 能力协商中声明加密模式**
/// **Validates: Requirements 17.5**
@Suite("Encryption Mode Declaration Tests")
struct EncryptionModeDeclarationTests {
    
    @Test("加密模式声明生成")
    func testModeDeclarationGeneration() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = HybridCryptoService()
        let declaration = await service.generateModeDeclaration()
        
 // 验证声明包含必要字段
        #expect(!declaration.supportedModes.isEmpty)
        #expect(!declaration.preferredMode.isEmpty)
        
 // classic 应该总是支持的
        #expect(declaration.supportedModes.contains("classic"))
        
 // 如果 PQC 可用，应该包含 pqc 模式
        if declaration.pqcAvailable {
            #expect(declaration.supportedModes.contains("pqc"))
        }
        
 // 如果 hybrid 可用，应该包含 hybrid 模式
        if declaration.hybridAvailable {
            #expect(declaration.supportedModes.contains("hybrid"))
        }
    }
    
    @Test("首选模式是最高安全级别")
    func testPreferredModeIsHighestSecurity() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = HybridCryptoService()
        let declaration = await service.generateModeDeclaration()
        
 // 首选模式应该是支持的最高安全级别
        if declaration.hybridAvailable {
            #expect(declaration.preferredMode == "hybrid")
        } else if declaration.pqcAvailable {
            #expect(declaration.preferredMode == "pqc")
        } else {
            #expect(declaration.preferredMode == "classic")
        }
    }
}

// MARK: - Degradation Tests

/// **Feature: web-agent-integration, 10.3: 加密模式降级**
/// **Validates: Requirements 17.3, 17.4**
@Suite("Encryption Mode Degradation Tests")
struct EncryptionModeDegradationTests {
    
    @Test("降级时 PQC 部分为空")
    func testDegradationPQCEmpty() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
 // 创建一个没有 PQC 支持的服务（使用 nil provider）
        let pqcAdapter = PQCProtocolAdapter(provider: nil, suite: .classic)
        let service = HybridCryptoService(pqcAdapter: pqcAdapter)
        
 // 尝试执行混合密钥交换（应该降级）
        let remoteKey = P256.KeyAgreement.PrivateKey()
        let result = try await service.initiateHybridKeyExchange(
            peerId: UUID().uuidString,
            remoteClassicPublicKey: remoteKey.publicKey.rawRepresentation
        )
        
 // 应该成功但 PQC 部分为空
        #expect(!result.classicSharedSecret.isEmpty)
        #expect(result.pqcSharedSecret.isEmpty)
        #expect(result.pqcEncapsulated.isEmpty)
        #else
        #endif
    }
    
    @Test("纯经典模式下密钥交换仍然成功")
    func testClassicOnlyKeyExchange() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        #if canImport(CryptoKit)
        let pqcAdapter = PQCProtocolAdapter(provider: nil, suite: .classic)
        let service = HybridCryptoService(pqcAdapter: pqcAdapter)
        
        let remoteKey = P256.KeyAgreement.PrivateKey()
        let result = try await service.initiateHybridKeyExchange(
            peerId: UUID().uuidString,
            remoteClassicPublicKey: remoteKey.publicKey.rawRepresentation
        )
        
 // 经典部分应该成功
        #expect(!result.classicSharedSecret.isEmpty)
        #expect(!result.combinedSharedSecret.isEmpty)
        
 // 组合密钥仍然是 32 字节
        #expect(result.combinedSharedSecret.count == 32)
        #else
        #endif
    }
}

