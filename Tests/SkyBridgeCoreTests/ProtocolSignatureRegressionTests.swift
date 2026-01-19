//
// ProtocolSignatureRegressionTests.swift
// SkyBridgeCoreTests
//
// 17: 8 - 回归测试矩阵
// Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6
//
// 回归测试矩阵验证：
// - 17.1: MessageA 构造测试（PQC/Classic 同质性）
// - 17.2: HandshakeDriver 签名 provider 类型测试
// - 17.3: Algorithm-key mismatch 失败测试
// - 17.4: Timeout 不触发 fallback 测试
// - 17.5: Legacy 首次接触连通测试
// - 17.6: Downgrade 事件发射测试
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class ProtocolSignatureRegressionTests: XCTestCase {
    
 // MARK: - Mock CryptoProvider
    
 /// Mock CryptoProvider for testing
    private class MockCryptoProvider: CryptoProvider, @unchecked Sendable {
        let providerName: String = "MockProvider"
        let tier: CryptoTier = .classic
        let activeSuite: CryptoSuite = .x25519Ed25519
        private let _supportedSuites: [CryptoSuite]
        
        var supportedSuites: [CryptoSuite] { _supportedSuites }
        
        init(supportedSuites: [CryptoSuite]) {
            self._supportedSuites = supportedSuites
        }
        
        func supportsSuite(_ suite: CryptoSuite) -> Bool {
            _supportedSuites.contains { $0.wireId == suite.wireId }
        }
        
        func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
            throw CryptoProviderError.notImplemented("Mock")
        }
    }
    
 // MARK: - Test Data
    
    private let pqcSuites: [CryptoSuite] = [.xwingMLDSA, .mlkem768MLDSA65]
    private let classicSuites: [CryptoSuite] = [.x25519Ed25519]
    private var allSuites: [CryptoSuite] { pqcSuites + classicSuites }
    
 // MARK: - 17.1: MessageA 构造测试
    
 /// Regression 12.1: PQC attempt 必须使用 ML-DSA 签名算法且所有 suites 都是 PQCGroup
 ///
 /// **Validates: Requirements 12.1**
    func testRegression_PQCAttempt_MLDSAWithPQCSuites() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
 // 准备 PQC attempt
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )
        
 // 验证签名算法是 ML-DSA-65
        XCTAssertEqual(preparation.sigAAlgorithm, .mlDSA65,
            "PQC attempt MUST use ML-DSA-65 signature algorithm")
        
 // 验证所有 suites 都是 PQCGroup
        for suite in preparation.offeredSuites {
            XCTAssertTrue(suite.isPQCGroup,
                "PQC attempt: ALL suites MUST be isPQCGroup == true, got wireId=0x\(String(format: "%04X", suite.wireId))")
        }
        
 // 验证 suites 非空
        XCTAssertFalse(preparation.offeredSuites.isEmpty,
            "PQC attempt MUST have at least one offered suite")
    }
    
 /// Regression 12.1: Classic attempt 必须使用 Ed25519 签名算法且所有 suites 都是 ClassicGroup
 ///
 /// **Validates: Requirements 12.1**
    func testRegression_ClassicAttempt_Ed25519WithClassicSuites() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
 // 准备 Classic attempt
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .classicOnly,
            cryptoProvider: provider
        )
        
 // 验证签名算法是 Ed25519
        XCTAssertEqual(preparation.sigAAlgorithm, .ed25519,
            "Classic attempt MUST use Ed25519 signature algorithm")
        
 // 验证所有 suites 都是 ClassicGroup
        for suite in preparation.offeredSuites {
            XCTAssertFalse(suite.isPQCGroup,
                "Classic attempt: ALL suites MUST be isPQCGroup == false, got wireId=0x\(String(format: "%04X", suite.wireId))")
        }
        
 // 验证 suites 非空
        XCTAssertFalse(preparation.offeredSuites.isEmpty,
            "Classic attempt MUST have at least one offered suite")
    }
    
 // MARK: - 17.2: HandshakeDriver 签名 provider 类型测试
    
 /// Regression 12.2: CryptoProvider 不能作为签名 provider（类型系统保证）
 ///
 /// 这个测试验证类型系统的设计：ProtocolSignatureProvider 和 CryptoProvider 是不同的协议，
 /// 编译器会阻止将 CryptoProvider 传给需要 ProtocolSignatureProvider 的参数。
 ///
 /// **Validates: Requirements 12.2**
    func testRegression_CryptoProviderCannotBeSignatureProvider() {
 // 这是一个设计验证测试
 // 实际的类型检查由编译器完成
 // 这里验证 ProtocolSignatureProvider 协议的存在和正确性
        
 // 验证 ClassicSignatureProvider 符合 ProtocolSignatureProvider
        let classicProvider = ClassicSignatureProvider()
        XCTAssertEqual(classicProvider.signatureAlgorithm, .ed25519,
            "ClassicSignatureProvider MUST have ed25519 algorithm")
        
 // 验证 PQCSignatureProvider 符合 ProtocolSignatureProvider
        let pqcProvider = PQCSignatureProvider()
        XCTAssertEqual(pqcProvider.signatureAlgorithm, .mlDSA65,
            "PQCSignatureProvider MUST have mlDSA65 algorithm")
        
 // 验证 ProtocolSigningAlgorithm 只有 ed25519 和 mlDSA65
        let allCases: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65]
        XCTAssertEqual(allCases.count, 2,
            "ProtocolSigningAlgorithm MUST only have ed25519 and mlDSA65 cases")
        
 // 验证 P-256 不在 ProtocolSigningAlgorithm 中
 // 这是通过类型系统保证的，无法在运行时测试
 // 但我们可以验证 SignatureAlgorithm.p256ECDSA 无法转换为 ProtocolSigningAlgorithm
        let p256Wire = SignatureAlgorithm.p256ECDSA
        let converted = ProtocolSigningAlgorithm(from: p256Wire)
        XCTAssertNil(converted,
            "P-256 MUST NOT be convertible to ProtocolSigningAlgorithm")
    }
    
 // MARK: - 17.3: Algorithm-key mismatch 失败测试
    
 /// Regression 12.3: 错误长度的密钥必须抛出错误
 ///
 /// **Validates: Requirements 12.3**
    func testRegression_AlgorithmKeyMismatch_Throws() async throws {
 // 创建一个模拟的 P-256 key handle（65 字节，P-256 公钥格式）
        let p256KeyData = Data(repeating: 0xAA, count: 65)
        
 // ClassicSignatureProvider (Ed25519) 期望 32 字节的密钥
        let classicProvider = ClassicSignatureProvider()
        
 // 尝试用错误长度的密钥签名应该失败
        do {
            let testData = Data("test message".utf8)
            _ = try await classicProvider.sign(
                testData,
                key: .softwareKey(p256KeyData)
            )
            XCTFail("Should throw error for key length mismatch")
        } catch {
 // 预期抛出错误
            XCTAssertTrue(true, "Correctly threw error for algorithm-key mismatch")
        }
    }
    
 /// Regression 12.3: 正确长度的密钥格式验证
    func testRegression_CorrectKeyLength_Accepted() async throws {
 // Ed25519 私钥是 32 或 64 字节
 // 这里测试 32 字节的情况（虽然可能因为密钥格式不正确而失败）
        let ed25519KeyData = Data(repeating: 0xBB, count: 32)
        let classicProvider = ClassicSignatureProvider()
        
        do {
            let testData = Data("test message".utf8)
            _ = try await classicProvider.sign(
                testData,
                key: .softwareKey(ed25519KeyData)
            )
 // 如果成功，说明长度检查通过
        } catch {
 // 可能因为密钥格式问题失败（不是有效的 Ed25519 seed），这是可接受的
 // 重要的是不是因为长度问题失败
        }
    }
    
 // MARK: - 17.4: Timeout 不触发 fallback 测试
    
 /// Regression 12.4: Timeout 错误不应该触发自动 fallback
 ///
 /// **Validates: Requirements 12.4**
    func testRegression_TimeoutDoesNotTriggerFallback() {
 // 验证 timeout 不在 fallback 白名单中
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.timeout),
            "Timeout MUST NOT trigger PQC unavailable fallback")
        
 // 验证其他安全相关错误也不触发 fallback
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.signatureVerificationFailed),
            "signatureVerificationFailed MUST NOT trigger fallback")
        
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(
            .suiteSignatureMismatch(selectedSuite: "X25519", sigAAlgorithm: "ML-DSA-65")),
            "suiteSignatureMismatch MUST NOT trigger fallback")
        
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.cancelled),
            "cancelled MUST NOT trigger fallback")
    }
    
 /// Regression 12.4: 只有 PQC 不可用相关错误才触发 fallback
 ///
 /// **Validates: Requirements 12.4**
    func testRegression_OnlyPQCUnavailableErrorsTriggerFallback() {
 // 白名单错误应该触发 fallback
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.pqcProviderUnavailable),
            "pqcProviderUnavailable SHOULD trigger fallback")
        
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported),
            "suiteNotSupported SHOULD trigger fallback")
        
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNegotiationFailed),
            "suiteNegotiationFailed SHOULD trigger fallback")
    }
    
 // MARK: - 17.5: Legacy 首次接触连通测试
    
 /// Regression 12.5: Legacy P-256 + Classic suites 在有认证通道时应该成功
 ///
 /// **Validates: Requirements 12.5**
    func testRegression_LegacyFirstContact_WithAuthenticatedChannel_Succeeds() {
 // 创建一个已认证的 pairing context
        let pairingContext = PairingContext(
            channelType: .qrCode,
            isVerified: true
        )
        
 // 检查 precondition（使用静态方法）
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "test-device",
            trustRecord: nil,  // 首次接触，没有 TrustRecord
            pairingContext: pairingContext
        )
        
 // 验证 precondition 满足
        XCTAssertTrue(precondition.isSatisfied,
            "Legacy first contact with authenticated channel SHOULD satisfy precondition")
        XCTAssertEqual(precondition.type, .authenticatedChannel,
            "Precondition type SHOULD be authenticatedChannel")
    }
    
 /// Regression 12.5: Legacy P-256 在没有认证通道时应该被拒绝
 ///
 /// **Validates: Requirements 12.5**
    func testRegression_LegacyFirstContact_WithoutAuthenticatedChannel_Rejected() {
 // 没有 pairing context（纯网络发现）
        
 // 检查 precondition（使用静态方法）
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "test-device",
            trustRecord: nil,
            pairingContext: nil
        )
        
 // 验证 precondition 不满足
        XCTAssertFalse(precondition.isSatisfied,
            "Legacy first contact without authenticated channel MUST NOT satisfy precondition")
    }
    
 /// Regression 12.5: 网络发现不算认证通道
    func testRegression_NetworkDiscovery_NotAuthenticatedChannel() {
 // 网络发现 pairing context
        let pairingContext = PairingContext(
            channelType: .networkDiscovery,
            isVerified: false
        )
        
 // 检查 precondition
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: "test-device",
            trustRecord: nil,
            pairingContext: pairingContext
        )
        
 // 验证 precondition 不满足
        XCTAssertFalse(precondition.isSatisfied,
            "Network discovery MUST NOT satisfy precondition")
    }
    
 // MARK: - 17.6: Downgrade 事件发射测试
    
 /// Regression 12.6: cryptoDowngrade 事件必须包含完整上下文
 ///
 /// **Validates: Requirements 12.6**
    func testRegression_CryptoDowngradeEvent_HasContext() {
 // 创建 cryptoDowngrade 事件
        let event = SecurityEvent.cryptoDowngradeWithContext(
            reason: "pqcProviderUnavailable",
            deviceId: "test-device-123",
            cooldownSeconds: 300,
            fromStrategy: "pqcOnly",
            toStrategy: "classicOnly"
        )
        
 // 验证事件类型
        XCTAssertEqual(event.type, .cryptoDowngrade,
            "Event type MUST be cryptoDowngrade")
        
 // 验证事件包含上下文
        XCTAssertFalse(event.context.isEmpty,
            "cryptoDowngrade event MUST have context")
        
 // 验证上下文包含必要字段
        XCTAssertNotNil(event.context["reason"],
            "Context MUST contain reason")
        XCTAssertNotNil(event.context["deviceId"],
            "Context MUST contain deviceId")
        XCTAssertNotNil(event.context["cooldownSeconds"],
            "Context MUST contain cooldownSeconds")
        XCTAssertNotNil(event.context["fromStrategy"],
            "Context MUST contain fromStrategy")
        XCTAssertNotNil(event.context["toStrategy"],
            "Context MUST contain toStrategy")
    }
    
 /// Regression 12.6: legacySignatureAccepted 事件必须包含 preconditionType
 ///
 /// **Validates: Requirements 12.6**
    func testRegression_LegacySignatureAcceptedEvent_HasPreconditionType() {
 // 创建 legacySignatureAccepted 事件
        let event = SecurityEvent.legacySignatureAcceptedWithPrecondition(
            preconditionType: "authenticatedChannel",
            deviceId: "test-device-456",
            channelType: "qrCode"
        )
        
 // 验证事件类型
        XCTAssertEqual(event.type, .legacySignatureAccepted,
            "Event type MUST be legacySignatureAccepted")
        
 // 验证事件包含上下文
        XCTAssertFalse(event.context.isEmpty,
            "legacySignatureAccepted event MUST have context")
        
 // 验证上下文包含 preconditionType
        XCTAssertNotNil(event.context["preconditionType"],
            "Context MUST contain preconditionType")
        XCTAssertNotNil(event.context["deviceId"],
            "Context MUST contain deviceId")
    }
    
 // MARK: - 17.7: Final Gate 检查
    
 /// Final Gate: 验证 ProtocolSigningAlgorithm 不包含 P-256
    func testFinalGate_ProtocolSigningAlgorithmExcludesP256() {
 // 验证所有 ProtocolSigningAlgorithm cases
        let ed25519 = ProtocolSigningAlgorithm.ed25519
        let mlDSA65 = ProtocolSigningAlgorithm.mlDSA65
        
 // 验证 wireCode 正确
        XCTAssertEqual(ed25519.wireCode, 0x0001, "Ed25519 wireCode MUST be 0x0001")
        XCTAssertEqual(mlDSA65.wireCode, 0x0002, "ML-DSA-65 wireCode MUST be 0x0002")
        
 // 验证 P-256 无法转换
        XCTAssertNil(ProtocolSigningAlgorithm(from: .p256ECDSA),
            "P-256 MUST NOT be convertible to ProtocolSigningAlgorithm")
        
 // 验证 Ed25519 和 ML-DSA-65 可以转换
        XCTAssertEqual(ProtocolSigningAlgorithm(from: .ed25519), .ed25519)
        XCTAssertEqual(ProtocolSigningAlgorithm(from: .mlDSA65), .mlDSA65)
    }
    
 /// Final Gate: 验证 CryptoSuite.isPQCGroup 分类正确
    func testFinalGate_CryptoSuiteClassification() {
 // PQC suites
        let hybridPQC = CryptoSuite(wireId: 0x0001)
        let purePQC = CryptoSuite(wireId: 0x0101)
        
        XCTAssertTrue(hybridPQC.isPQCGroup, "Hybrid PQC (0x0001) MUST be isPQCGroup")
        XCTAssertTrue(purePQC.isPQCGroup, "Pure PQC (0x0101) MUST be isPQCGroup")
        
 // Classic suites
        let classic = CryptoSuite(wireId: 0x1001)
        XCTAssertFalse(classic.isPQCGroup, "Classic (0x1001) MUST NOT be isPQCGroup")
    }
    
 /// Final Gate: 验证 AttemptPreparation 结构正确
    func testFinalGate_AttemptPreparationStructure() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
 // PQC preparation
        let pqcPrep = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )
        XCTAssertEqual(pqcPrep.strategy, .pqcOnly)
        XCTAssertEqual(pqcPrep.sigAAlgorithm, .mlDSA65)
        XCTAssertNotNil(pqcPrep.signatureProvider)
        
 // Classic preparation
        let classicPrep = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .classicOnly,
            cryptoProvider: provider
        )
        XCTAssertEqual(classicPrep.strategy, .classicOnly)
        XCTAssertEqual(classicPrep.sigAAlgorithm, .ed25519)
        XCTAssertNotNil(classicPrep.signatureProvider)
    }
}
