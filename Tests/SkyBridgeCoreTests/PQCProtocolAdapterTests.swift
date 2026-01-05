// PQCProtocolAdapterTests.swift
// SkyBridgeCoreTests
//
// PQC 跨平台协议适配器测试 - 包含属性测试
// Created for web-agent-integration spec 9

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - Property Tests

/// **Feature: web-agent-integration, Property 7: KEM 封装/解封装 Round-Trip**
/// **Validates: Requirements 14.2**
@Suite("PQC KEM Round-Trip Tests")
struct PQCKEMRoundTripTests {
    
    @Test("ML-KEM-768 封装/解封装 Round-Trip", arguments: (0..<10).map { _ in UUID().uuidString })
    func testMLKEM768RoundTrip(peerId: String) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // 跳过如果 PQC 不可用
        guard await adapter.isPQCAvailable else {
            return
        }
        
 // 设置为 PQC 模式
        try await adapter.setSuite(.pqc)
        
 // 封装
        let (sharedSecret, encapsulated) = try await adapter.kemEncapsulate(
            peerId: peerId,
            variant: .mlkem768
        )
        
 // 验证共享密钥长度
        #expect(sharedSecret.count == CrossPlatformKEMVariant.mlkem768.sharedSecretLength)
        
 // 解封装
        let decapsulated = try await adapter.kemDecapsulate(
            peerId: peerId,
            encapsulated: encapsulated,
            variant: .mlkem768
        )
        
 // 验证 Round-Trip
        #expect(sharedSecret == decapsulated)
    }
    
    @Test("ML-KEM-1024 封装/解封装 Round-Trip", arguments: (0..<10).map { _ in UUID().uuidString })
    func testMLKEM1024RoundTrip(peerId: String) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        let (sharedSecret, encapsulated) = try await adapter.kemEncapsulate(
            peerId: peerId,
            variant: .mlkem1024
        )
        
        #expect(sharedSecret.count == CrossPlatformKEMVariant.mlkem1024.sharedSecretLength)
        
        let decapsulated = try await adapter.kemDecapsulate(
            peerId: peerId,
            encapsulated: encapsulated,
            variant: .mlkem1024
        )
        
        #expect(sharedSecret == decapsulated)
    }
    
    @Test("KEM 封装产生不同的封装数据")
    func testKEMEncapsulationUniqueness() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        let peerId = UUID().uuidString
        
 // 多次封装应产生不同的封装数据（随机性）
        let (_, encapsulated1) = try await adapter.kemEncapsulate(peerId: peerId, variant: .mlkem768)
        let (_, encapsulated2) = try await adapter.kemEncapsulate(peerId: peerId, variant: .mlkem768)
        
 // 封装数据应该不同（除非极小概率碰撞）
        #expect(encapsulated1 != encapsulated2)
    }
}

/// **Feature: web-agent-integration, Property 8: 数字签名验证正确性**
/// **Validates: Requirements 14.3**
@Suite("PQC Digital Signature Tests")
struct PQCDigitalSignatureTests {
    
 /// 生成随机测试数据
    static func generateRandomData(size: Int) -> Data {
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                arc4random_buf(baseAddress, size)
            }
        }
        return data
    }
    
    @Test("ML-DSA-65 签名验证正确性", arguments: [16, 64, 256, 1024])
    func testMLDSA65SignatureVerification(dataSize: Int) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        let peerId = UUID().uuidString
        let data = Self.generateRandomData(size: dataSize)
        
 // 签名
        let signature = try await adapter.sign(data: data, peerId: peerId, variant: .mldsa65)
        
 // 验证签名
        let isValid = await adapter.verify(data: data, signature: signature, peerId: peerId, variant: .mldsa65)
        
        #expect(isValid == true)
    }
    
    @Test("ML-DSA-87 签名验证正确性", arguments: [16, 64, 256, 1024])
    func testMLDSA87SignatureVerification(dataSize: Int) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        let peerId = UUID().uuidString
        let data = Self.generateRandomData(size: dataSize)
        
        let signature = try await adapter.sign(data: data, peerId: peerId, variant: .mldsa87)
        let isValid = await adapter.verify(data: data, signature: signature, peerId: peerId, variant: .mldsa87)
        
        #expect(isValid == true)
    }
    
    @Test("篡改数据后签名验证失败")
    func testTamperedDataVerificationFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        let peerId = UUID().uuidString
        let originalData = Self.generateRandomData(size: 100)
        
 // 签名原始数据
        let signature = try await adapter.sign(data: originalData, peerId: peerId, variant: .mldsa65)
        
 // 篡改数据
        var tamperedData = originalData
        tamperedData[0] ^= 0xFF
        
 // 验证应失败
        let isValid = await adapter.verify(data: tamperedData, signature: signature, peerId: peerId, variant: .mldsa65)
        
        #expect(isValid == false)
    }
    
    @Test("篡改签名后验证失败")
    func testTamperedSignatureVerificationFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        let peerId = UUID().uuidString
        let data = Self.generateRandomData(size: 100)
        
        var signature = try await adapter.sign(data: data, peerId: peerId, variant: .mldsa65)
        
 // 篡改签名
        if !signature.isEmpty {
            signature[0] ^= 0xFF
        }
        
        let isValid = await adapter.verify(data: data, signature: signature, peerId: peerId, variant: .mldsa65)
        
        #expect(isValid == false)
    }
}

/// **Feature: web-agent-integration, Property 9: HPKE Seal/Open Round-Trip**
/// **Validates: Requirements 14.4**
@Suite("PQC HPKE Round-Trip Tests")
struct PQCHPKERoundTripTests {
    
    static func generateRandomData(size: Int) -> Data {
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                arc4random_buf(baseAddress, size)
            }
        }
        return data
    }
    
    @Test("HPKE Seal/Open Round-Trip", arguments: [16, 64, 256, 1024, 4096])
    func testHPKERoundTrip(plaintextSize: Int) async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
 // HPKE 需要 hybrid 模式
        let supportedSuites = await adapter.getSupportedSuites()
        guard supportedSuites.contains(.hybrid) else {
 // OQS 后端不支持原生 HPKE，跳过
            return
        }
        
        try await adapter.setSuite(.hybrid)
        
        let peerId = UUID().uuidString
        let plaintext = Self.generateRandomData(size: plaintextSize)
        let aad = Data("test-context-\(UUID().uuidString)".utf8)
        
 // Seal
        let (ciphertext, encapsulatedKey) = try await adapter.hpkeSeal(
            recipientPeerId: peerId,
            plaintext: plaintext,
            associatedData: aad
        )
        
 // 密文应该比明文长（包含认证标签）
        #expect(ciphertext.count >= plaintext.count)
        
 // Open
        let decrypted = try await adapter.hpkeOpen(
            recipientPeerId: peerId,
            ciphertext: ciphertext,
            encapsulatedKey: encapsulatedKey,
            associatedData: aad
        )
        
 // 验证 Round-Trip
        #expect(decrypted == plaintext)
    }
    
    @Test("HPKE 使用不同 AAD 解密失败")
    func testHPKEWithDifferentAADFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        guard await adapter.isPQCAvailable else {
            return
        }
        
        let supportedSuites = await adapter.getSupportedSuites()
        guard supportedSuites.contains(.hybrid) else {
            return
        }
        
        try await adapter.setSuite(.hybrid)
        
        let peerId = UUID().uuidString
        let plaintext = Self.generateRandomData(size: 100)
        let aad1 = Data("context-1".utf8)
        let aad2 = Data("context-2".utf8)
        
        let (ciphertext, encapsulatedKey) = try await adapter.hpkeSeal(
            recipientPeerId: peerId,
            plaintext: plaintext,
            associatedData: aad1
        )
        
 // 使用不同的 AAD 解密应失败
        do {
            _ = try await adapter.hpkeOpen(
                recipientPeerId: peerId,
                ciphertext: ciphertext,
                encapsulatedKey: encapsulatedKey,
                associatedData: aad2
            )
            Issue.record("应该抛出错误")
        } catch {
 // 预期行为
        }
    }
}

// MARK: - Capability Negotiation Tests

@Suite("PQC Capability Negotiation Tests")
struct PQCCapabilityNegotiationTests {
    
    @Test("能力声明生成")
    func testCapabilityDeclarationGeneration() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        let declaration = await adapter.generateCapabilityDeclaration()
        
 // 验证声明包含必要字段
        #expect(!declaration.supportedSuites.isEmpty)
        #expect(!declaration.supportedKEMVariants.isEmpty)
        #expect(!declaration.supportedSignatureVariants.isEmpty)
        #expect(!declaration.preferredSuite.isEmpty)
        #expect(!declaration.backend.isEmpty)
    }
    
    @Test("套件协商 - 双方都支持 hybrid")
    func testSuiteNegotiationBothSupportHybrid() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        let remoteCapability = PQCProtocolAdapter.PQCCapabilityDeclaration(
            supportedSuites: ["classic", "pqc", "hybrid"],
            supportedKEMVariants: ["ML-KEM-768", "ML-KEM-1024"],
            supportedSignatureVariants: ["ML-DSA-65", "ML-DSA-87"],
            preferredSuite: "hybrid",
            backend: "applePQC"
        )
        
        let supportedSuites = await adapter.getSupportedSuites()
        guard supportedSuites.contains(.hybrid) else {
            return
        }
        
        let negotiated = try await adapter.negotiateSuite(with: remoteCapability)
        #expect(negotiated == .hybrid)
    }
    
    @Test("套件协商 - 降级到 pqc")
    func testSuiteNegotiationFallbackToPQC() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // 远端只支持 classic 和 pqc
        let remoteCapability = PQCProtocolAdapter.PQCCapabilityDeclaration(
            supportedSuites: ["classic", "pqc"],
            supportedKEMVariants: ["ML-KEM-768"],
            supportedSignatureVariants: ["ML-DSA-65"],
            preferredSuite: "pqc",
            backend: "liboqs"
        )
        
        let supportedSuites = await adapter.getSupportedSuites()
        guard supportedSuites.contains(.pqc) else {
            return
        }
        
        let negotiated = try await adapter.negotiateSuite(with: remoteCapability)
        #expect(negotiated == .pqc)
    }
    
    @Test("套件协商 - 降级到 classic")
    func testSuiteNegotiationFallbackToClassic() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // 远端只支持 classic
        let remoteCapability = PQCProtocolAdapter.PQCCapabilityDeclaration(
            supportedSuites: ["classic"],
            supportedKEMVariants: [],
            supportedSignatureVariants: [],
            preferredSuite: "classic",
            backend: "none"
        )
        
        let negotiated = try await adapter.negotiateSuite(with: remoteCapability)
        #expect(negotiated == .classic)
    }
    
    @Test("套件协商 - 无共同套件抛出错误")
    func testSuiteNegotiationNoCommonSuite() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // 远端只支持一个不存在的套件
        let remoteCapability = PQCProtocolAdapter.PQCCapabilityDeclaration(
            supportedSuites: ["unknown-suite"],
            supportedKEMVariants: [],
            supportedSignatureVariants: [],
            preferredSuite: "unknown-suite",
            backend: "unknown"
        )
        
        do {
            _ = try await adapter.negotiateSuite(with: remoteCapability)
            Issue.record("应该抛出 noCommonSuite 错误")
        } catch let error as PQCProtocolError {
            if case .noCommonSuite = error {
 // 预期行为
            } else {
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
    
    @Test("KEM 变体协商")
    func testKEMVariantNegotiation() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // 测试优先选择更高安全级别
        let variant1 = await adapter.negotiateKEMVariant(with: ["ML-KEM-768", "ML-KEM-1024"])
        #expect(variant1 == .mlkem1024)
        
        let variant2 = await adapter.negotiateKEMVariant(with: ["ML-KEM-768"])
        #expect(variant2 == .mlkem768)
        
        let variant3 = await adapter.negotiateKEMVariant(with: ["unknown"])
        #expect(variant3 == nil)
    }
    
    @Test("签名变体协商")
    func testSignatureVariantNegotiation() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        let variant1 = await adapter.negotiateSignatureVariant(with: ["ML-DSA-65", "ML-DSA-87"])
        #expect(variant1 == .mldsa87)
        
        let variant2 = await adapter.negotiateSignatureVariant(with: ["ML-DSA-65"])
        #expect(variant2 == .mldsa65)
        
        let variant3 = await adapter.negotiateSignatureVariant(with: ["unknown"])
        #expect(variant3 == nil)
    }
}

// MARK: - Suite Management Tests

@Suite("PQC Suite Management Tests")
struct PQCSuiteManagementTests {
    
    @Test("设置支持的套件成功")
    func testSetSupportedSuite() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
 // classic 应该总是支持的
        try await adapter.setSuite(.classic)
        let currentSuite = await adapter.currentSuite
        #expect(currentSuite == .classic)
    }
    
    @Test("设置不支持的套件失败")
    func testSetUnsupportedSuiteFails() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        let supportedSuites = await adapter.getSupportedSuites()
        
 // 如果不支持 hybrid，尝试设置应该失败
        if !supportedSuites.contains(.hybrid) {
            do {
                try await adapter.setSuite(.hybrid)
                Issue.record("应该抛出 unsupportedSuite 错误")
            } catch let error as PQCProtocolError {
                if case .unsupportedSuite = error {
 // 预期行为
                } else {
                    Issue.record("错误类型不正确")
                }
            } catch {
                Issue.record("未预期的错误类型")
            }
        }
    }
    
    @Test("经典模式下 KEM 操作失败")
    func testKEMInClassicModeFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        try await adapter.setSuite(.classic)
        
        do {
            _ = try await adapter.kemEncapsulate(peerId: "test", variant: .mlkem768)
            Issue.record("应该抛出 operationNotSupportedInClassicMode 错误")
        } catch let error as PQCProtocolError {
            if case .operationNotSupportedInClassicMode = error {
 // 预期行为
            } else {
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
    
    @Test("经典模式下签名操作失败")
    func testSignInClassicModeFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        try await adapter.setSuite(.classic)
        
        do {
            _ = try await adapter.sign(data: Data("test".utf8), peerId: "test", variant: .mldsa65)
            Issue.record("应该抛出 operationNotSupportedInClassicMode 错误")
        } catch let error as PQCProtocolError {
            if case .operationNotSupportedInClassicMode = error {
 // 预期行为
            } else {
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
    
    @Test("非 hybrid 模式下 HPKE 操作失败")
    func testHPKEInNonHybridModeFails() async throws {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        
        let supportedSuites = await adapter.getSupportedSuites()
        guard supportedSuites.contains(.pqc) else {
            return
        }
        
        try await adapter.setSuite(.pqc)
        
        do {
            _ = try await adapter.hpkeSeal(recipientPeerId: "test", plaintext: Data("test".utf8))
            Issue.record("应该抛出 hpkeRequiresHybridMode 错误")
        } catch let error as PQCProtocolError {
            if case .hpkeRequiresHybridMode = error {
 // 预期行为
            } else {
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
}

// MARK: - Status Report Tests

@Suite("PQC Status Report Tests")
struct PQCStatusReportTests {
    
    @Test("状态报告生成")
    func testStatusReportGeneration() async {
        guard #available(macOS 14.0, *) else { return }
        
        let adapter = PQCProtocolAdapter()
        let report = await adapter.generateStatusReport()
        
        #expect(!report.backend.isEmpty)
        #expect(!report.currentSuite.isEmpty)
        #expect(!report.supportedSuites.isEmpty)
        #expect(!report.systemInfo.isEmpty)
    }
}
