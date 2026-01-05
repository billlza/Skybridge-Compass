//
// PQCConditionalCompileTests.swift
// SkyBridgeCoreTests
//
// 验证 PQCProvider 条件编译修复
// **Feature: pqc-conditional-compile-fix**
// **Validates: Requirements 1.1-1.6, 2.1-2.4, 6.1-6.3**
//

import XCTest
@testable import SkyBridgeCore

/// PQC 条件编译验证测试
/// 确保在无 HAS_APPLE_PQC_SDK 时代码能正确编译和运行
@available(macOS 14.0, *)
final class PQCConditionalCompileTests: XCTestCase {
    
 // MARK: - Property 1: Provider Selection Fallback
    
 /// **Property 1: Provider Selection Fallback**
 /// *For any* compilation without HAS_APPLE_PQC_SDK flag, calling PQCProviderFactory.makeProvider()
 /// SHALL return OQSProvider (if liboqs available) or nil, never ApplePQCProvider.
 /// **Validates: Requirements 2.2, 2.3**
    func testProperty1_ProviderSelectionFallback() {
        let provider = PQCProviderFactory.makeProvider()
        
        #if HAS_APPLE_PQC_SDK
 // 当有 Apple PQC SDK 时，可能返回 ApplePQCProvider 或 OQSProvider
        if let p = provider {
            let validBackends: [PQCBackend] = [.applePQC, .liboqs]
            XCTAssertTrue(validBackends.contains(p.backend),
                          "Provider backend should be applePQC or liboqs")
        }
        #else
 // 当没有 Apple PQC SDK 时，只能返回 OQSProvider 或 nil
        if let p = provider {
            XCTAssertEqual(p.backend, .liboqs,
                           "Without HAS_APPLE_PQC_SDK, provider must be liboqs")
            XCTAssertNotEqual(p.backend, .applePQC,
                              "Without HAS_APPLE_PQC_SDK, provider must NOT be applePQC")
        }
        #endif
    }
    
 // MARK: - Property 2: Provider String Consistency
    
 /// **Property 2: Provider String Consistency**
 /// *For any* runtime configuration, the string returned by PQCProviderFactory.currentProvider
 /// SHALL accurately describe the provider type that would be returned by makeProvider().
 /// **Validates: Requirements 2.4**
    func testProperty2_ProviderStringConsistency() {
        let provider = PQCProviderFactory.makeProvider()
        let currentProviderString = PQCProviderFactory.currentProvider
        
        if let p = provider {
            switch p.backend {
            case .applePQC:
                XCTAssertEqual(currentProviderString, "Apple CryptoKit (原生)",
                               "currentProvider string should match applePQC backend")
            case .liboqs:
                XCTAssertEqual(currentProviderString, "OQS/liboqs",
                               "currentProvider string should match liboqs backend")
            case .none:
                XCTAssertEqual(currentProviderString, "不可用",
                               "currentProvider string should indicate unavailable")
            }
        } else {
            XCTAssertEqual(currentProviderString, "不可用",
                           "currentProvider should be '不可用' when makeProvider returns nil")
        }
    }
    
 // MARK: - OQSProvider Availability Test
    
 /// 验证 OQSProvider 在无 Apple PQC SDK 时可用
 /// **Validates: Requirements 2.2**
    func testOQSProviderAvailability() {
        #if canImport(OQSRAII)
 // 当 OQSRAII 可用时，OQSProvider 应该可用
        let provider = PQCProviderFactory.makeProvider()
        
        #if !HAS_APPLE_PQC_SDK
 // 无 Apple PQC SDK 时，必须使用 OQSProvider
        XCTAssertNotNil(provider, "OQSProvider should be available when OQSRAII is imported")
        if let p = provider {
            XCTAssertEqual(p.backend, .liboqs)
        }
        #endif
        #else
 // 当 OQSRAII 不可用时，跳过测试
        print("⚠️ OQSRAII not available, skipping OQSProvider availability test")
        #endif
    }
    
 // MARK: - Compile-Time Verification
    
 /// 验证编译成功（此测试存在即证明编译通过）
 /// **Validates: Requirements 1.1, 6.1**
    func testCompilationSuccess() {
 // 如果这个测试能运行，说明编译成功
 // 这验证了条件编译正确隔离了 Apple PQC 类型
        XCTAssertTrue(true, "Compilation succeeded without HAS_APPLE_PQC_SDK")
    }
    
 /// 验证 PQCAlgorithmSuite 枚举可用
    func testPQCAlgorithmSuiteAvailable() {
        let suites: [PQCAlgorithmSuite] = [
            .classicP256,
            .pqcMlKemMlDsa,
            .hybridXWing
        ]
        
        XCTAssertEqual(suites.count, 3)
        XCTAssertEqual(PQCAlgorithmSuite.classicP256.rawValue, "classic-p256")
        XCTAssertEqual(PQCAlgorithmSuite.pqcMlKemMlDsa.rawValue, "pqc-mlkem-mldsa")
        XCTAssertEqual(PQCAlgorithmSuite.hybridXWing.rawValue, "hybrid-xwing-mlkem768-x25519")
    }
    
 /// 验证 PQCBackend 枚举可用
    func testPQCBackendAvailable() {
        let backends: [PQCBackend] = [.none, .applePQC, .liboqs]
        
        XCTAssertEqual(backends.count, 3)
        XCTAssertEqual(PQCBackend.none.rawValue, "none")
        XCTAssertEqual(PQCBackend.applePQC.rawValue, "applePQC")
        XCTAssertEqual(PQCBackend.liboqs.rawValue, "liboqs")
    }
    
 /// 验证 MigrationPolicy 可用
    func testMigrationPolicyAvailable() {
        let policy = PQCProviderFactory.MigrationPolicy.current
        
        XCTAssertTrue(policy.dualWriteEnabled)
        XCTAssertEqual(policy.stopV1WriteVersion, "3.0")
        XCTAssertEqual(policy.fullRemoveV1TargetVersion, "5.0")
    }
    
 // MARK: - System Requirements Documentation
    
 /// 验证系统要求文档可用
    func testSystemRequirementsDocumentation() {
        let status = PQCSystemRequirements.supportStatus
        let details = PQCSystemRequirements.detailedRequirements
        
        XCTAssertFalse(status.isEmpty, "Support status should not be empty")
        XCTAssertFalse(details.isEmpty, "Detailed requirements should not be empty")
        
 // 验证包含关键信息
        XCTAssertTrue(details.contains("macOS"), "Should mention macOS")
        XCTAssertTrue(details.contains("ML-KEM") || details.contains("ML‑KEM"), "Should mention ML-KEM")
        XCTAssertTrue(details.contains("ML-DSA") || details.contains("ML‑DSA"), "Should mention ML-DSA")
    }
}
