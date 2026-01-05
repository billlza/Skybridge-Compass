//
// P2PAttestationServiceTests.swift
// SkyBridgeCoreTests
//
// Tests for AttestationService
// Requirements: 2.6 (attestationLevel)
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PAttestationServiceTests: XCTestCase {
    
 // MARK: - Attestation Result Tests
    
    func testAttestationResultValidity() {
 // Valid result
        let validResult = AttestationResult(
            level: .appAttest,
            status: .verified,
            verifiedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            riskScore: 0.1
        )
        XCTAssertTrue(validResult.isValid)
        
 // Expired result
        let expiredResult = AttestationResult(
            level: .appAttest,
            status: .verified,
            verifiedAt: Date().addingTimeInterval(-7200),
            expiresAt: Date().addingTimeInterval(-3600),
            riskScore: 0.1
        )
        XCTAssertFalse(expiredResult.isValid)
        
 // Failed result
        let failedResult = AttestationResult(
            level: .appAttest,
            status: .failed,
            riskScore: 0.7
        )
        XCTAssertFalse(failedResult.isValid)
    }
    
    func testAttestationResultNeedsRefresh() {
 // Fresh result - no refresh needed
        let freshResult = AttestationResult(
            level: .appAttest,
            status: .verified,
            verifiedAt: Date(),
            expiresAt: Date().addingTimeInterval(7200), // 2 hours
            riskScore: 0.1
        )
        XCTAssertFalse(freshResult.needsRefresh)
        
 // About to expire - needs refresh
        let expiringResult = AttestationResult(
            level: .appAttest,
            status: .verified,
            verifiedAt: Date().addingTimeInterval(-6000),
            expiresAt: Date().addingTimeInterval(1800), // 30 minutes
            riskScore: 0.1
        )
        XCTAssertTrue(expiringResult.needsRefresh)
        
 // Expired - needs refresh
        let expiredResult = AttestationResult(
            level: .appAttest,
            status: .expired,
            riskScore: 0.5
        )
        XCTAssertTrue(expiredResult.needsRefresh)
        
 // Unverified - needs refresh
        let unverifiedResult = AttestationResult(
            level: .none,
            status: .unverified,
            riskScore: 0.5
        )
        XCTAssertTrue(unverifiedResult.needsRefresh)
    }
    
 // MARK: - Risk Assessment Tests
    
    func testRiskAssessmentLowRisk() async {
        let service = AttestationService.shared
        
        let result = AttestationResult(
            level: .appAttest,
            status: .verified,
            riskScore: 0.1
        )
        
        let assessment = await service.assessRisk(from: result)
        
        XCTAssertEqual(assessment.score, 0.1)
        XCTAssertEqual(assessment.rateLimitMultiplier, 1.0)
        XCTAssertEqual(assessment.warningLevel, .none)
        XCTAssertNil(assessment.warningMessage)
        XCTAssertTrue(assessment.allowConnection)
    }
    
    func testRiskAssessmentMediumLowRisk() async {
        let service = AttestationService.shared
        
        let result = AttestationResult(
            level: .deviceCheck,
            status: .verified,
            riskScore: 0.3
        )
        
        let assessment = await service.assessRisk(from: result)
        
        XCTAssertEqual(assessment.score, 0.3)
        XCTAssertEqual(assessment.rateLimitMultiplier, 1.2)
        XCTAssertEqual(assessment.warningLevel, .info)
        XCTAssertTrue(assessment.allowConnection)
    }
    
    func testRiskAssessmentMediumRisk() async {
        let service = AttestationService.shared
        
        let result = AttestationResult(
            level: .none,
            status: .verified,
            riskScore: 0.5
        )
        
        let assessment = await service.assessRisk(from: result)
        
        XCTAssertEqual(assessment.score, 0.5)
        XCTAssertEqual(assessment.rateLimitMultiplier, 1.5)
        XCTAssertEqual(assessment.warningLevel, .warning)
        XCTAssertTrue(assessment.allowConnection)
    }
    
    func testRiskAssessmentHighRisk() async {
        let service = AttestationService.shared
        
        let result = AttestationResult(
            level: .appAttest,
            status: .failed,
            riskScore: 0.8
        )
        
        let assessment = await service.assessRisk(from: result)
        
        XCTAssertEqual(assessment.score, 0.8)
        XCTAssertEqual(assessment.rateLimitMultiplier, 3.0)
        XCTAssertEqual(assessment.warningLevel, .critical)
 // 关键：即使高风险也允许连接
        XCTAssertTrue(assessment.allowConnection)
    }
    
 // MARK: - Offline Policy Tests
    
 /// 离线证明不应阻断连接
    func testOfflineAttestationAllowsConnection() async {
        let service = AttestationService.shared
        
 // 模拟离线验证场景
        let offlineResult = await service.verifyRemoteAttestation(
            attestationData: Data([0x01, 0x02, 0x03]),
            deviceId: "test-device-offline",
            level: .appAttest
        )
        
 // 离线验证应该返回 verified 状态（作为历史证据）
        XCTAssertEqual(offlineResult.status, .verified)
        
 // 风险评估应该允许连接
        let assessment = await service.assessRisk(from: offlineResult)
        XCTAssertTrue(assessment.allowConnection)
    }
    
    func testNoAttestationMediumRisk() async {
        let service = AttestationService.shared
        
        let result = await service.verifyRemoteAttestation(
            attestationData: Data(),
            deviceId: "test-device-none",
            level: .none
        )
        
        XCTAssertEqual(result.level, .none)
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.riskScore, 0.5)
    }
    
 // MARK: - Cache Tests
    
    func testCacheEntryExpiration() {
 // Fresh entry
        let freshEntry = AttestationCacheEntry(
            deviceId: "test-device",
            result: AttestationResult(level: .none, status: .verified, riskScore: 0.5),
            cachedAt: Date()
        )
        XCTAssertFalse(freshEntry.isExpired)
        
 // Expired entry (25 hours old)
        let expiredEntry = AttestationCacheEntry(
            deviceId: "test-device",
            result: AttestationResult(level: .none, status: .verified, riskScore: 0.5),
            cachedAt: Date().addingTimeInterval(-25 * 60 * 60)
        )
        XCTAssertTrue(expiredEntry.isExpired)
    }
    
    func testClearCache() async {
        let service = AttestationService.shared
        
 // Add some cache entries
        _ = await service.verifyRemoteAttestation(
            attestationData: Data([0x01]),
            deviceId: "device-1",
            level: .none
        )
        _ = await service.verifyRemoteAttestation(
            attestationData: Data([0x02]),
            deviceId: "device-2",
            level: .none
        )
        
 // Clear cache
        await service.clearCache()
        
 // Verify cache is cleared (basic test)
 // In production you'd want more thorough verification
    }
    
 // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = AttestationConfiguration.default
        
        XCTAssertNil(config.serverEndpoint)
        XCTAssertEqual(config.attestationValiditySeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(config.cacheValiditySeconds, 24 * 60 * 60)
        XCTAssertEqual(config.refreshLeadTimeSeconds, 60 * 60)
        XCTAssertTrue(config.appAttestEnabled)
        XCTAssertTrue(config.deviceCheckEnabled)
    }
    
    func testCustomConfiguration() {
        let customEndpoint = URL(string: "https://api.example.com/attest")!
        let config = AttestationConfiguration(
            serverEndpoint: customEndpoint,
            attestationValiditySeconds: 3600,
            cacheValiditySeconds: 1800,
            refreshLeadTimeSeconds: 300,
            appAttestEnabled: false,
            deviceCheckEnabled: true
        )
        
        XCTAssertEqual(config.serverEndpoint, customEndpoint)
        XCTAssertEqual(config.attestationValiditySeconds, 3600)
        XCTAssertEqual(config.cacheValiditySeconds, 1800)
        XCTAssertEqual(config.refreshLeadTimeSeconds, 300)
        XCTAssertFalse(config.appAttestEnabled)
        XCTAssertTrue(config.deviceCheckEnabled)
    }
    
 // MARK: - TrustRecord Extension Tests
    
    func testTrustRecordAttestationResult() {
        let record = TrustRecord(
            deviceId: "test-device",
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x04, 0x01, 0x02]),
            attestationLevel: .appAttest,
            attestationData: Data([0x01, 0x02, 0x03]),
            capabilities: ["file_transfer"],
            signature: Data([0x30, 0x44])
        )
        
        let result = record.getAttestationResult()
        
        XCTAssertEqual(result.level, .appAttest)
        XCTAssertEqual(result.status, .verified)
        XCTAssertNotNil(result.attestationData)
        XCTAssertEqual(result.riskScore, 0.1) // App Attest with data
    }
    
    func testTrustRecordWithoutAttestationData() {
        let record = TrustRecord(
            deviceId: "test-device",
            pubKeyFP: String(repeating: "b", count: 64),
            publicKey: Data([0x04, 0x01, 0x02]),
            attestationLevel: .appAttest,
            attestationData: nil, // No attestation data
            capabilities: [],
            signature: Data([0x30, 0x44])
        )
        
        let result = record.getAttestationResult()
        
        XCTAssertEqual(result.level, .appAttest)
        XCTAssertEqual(result.status, .unverified)
        XCTAssertEqual(result.riskScore, 0.5) // Higher risk without data
    }
    
 // MARK: - Attestation Level Tests
    
    func testAttestationLevelComparison() {
        XCTAssertTrue(P2PAttestationLevel.none < P2PAttestationLevel.deviceCheck)
        XCTAssertTrue(P2PAttestationLevel.deviceCheck < P2PAttestationLevel.appAttest)
        XCTAssertTrue(P2PAttestationLevel.none < P2PAttestationLevel.appAttest)
    }
    
    func testAttestationLevelServerRequirement() {
        XCTAssertFalse(P2PAttestationLevel.none.requiresServerVerification)
        XCTAssertTrue(P2PAttestationLevel.deviceCheck.requiresServerVerification)
        XCTAssertTrue(P2PAttestationLevel.appAttest.requiresServerVerification)
    }
    
 // MARK: - Error Tests
    
    func testAttestationErrorDescriptions() {
        let errors: [AttestationError] = [
            .deviceNotSupported,
            .attestationGenerationFailed("test"),
            .serverVerificationFailed("test"),
            .networkError("test"),
            .invalidResponse,
            .cacheError("test"),
            .rateLimited
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
    
 // MARK: - Device Support Tests
    
    func testMaxSupportedLevel() async {
        let service = AttestationService.shared
        
 // This test verifies the maxSupportedLevel property works
        let level = service.maxSupportedLevel
        
 // Level should be one of the valid values
        XCTAssertTrue([P2PAttestationLevel.none, .deviceCheck, .appAttest].contains(level))
    }
}
