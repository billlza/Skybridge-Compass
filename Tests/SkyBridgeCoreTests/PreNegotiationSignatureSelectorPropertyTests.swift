//
// PreNegotiationSignatureSelectorPropertyTests.swift
// SkyBridgeCoreTests
//
// Signature Mechanism Alignment - 2.2, 2.3
// Property tests for Pre-Negotiation Signature Selection
//
// **Property 1: Pre-Negotiation Signature Algorithm Rule**
// **Validates: Requirements 1.1, 1.2, 1.4**
//
// **Property 2: Suite-Signature Compatibility Validation**
// **Validates: Requirements 1.1, 1.2**
//

import XCTest
@testable import SkyBridgeCore

final class PreNegotiationSignatureSelectorPropertyTests: XCTestCase {
    
 // MARK: - Test Data
    
 /// All known PQC suites
    private let pqcSuites: [CryptoSuite] = [.xwingMLDSA, .mlkem768MLDSA65]
    
 /// All known Classic suites
    private let classicSuites: [CryptoSuite] = [.x25519Ed25519, .p256ECDSA]
    
 /// All known suites
    private var allSuites: [CryptoSuite] {
        pqcSuites + classicSuites
    }
    
 // MARK: - Property 1: Pre-Negotiation Signature Algorithm Rule
    
 /// **Property 1.1**: If offeredSuites contains ANY PQC/Hybrid suite → ML-DSA-65
 /// **Validates: Requirements 1.1, 1.2**
    func testProperty1_1_PQCSuitesRequireMLDSA65() {
 // For all combinations of suites that include at least one PQC suite
        for pqcSuite in pqcSuites {
 // Single PQC suite
            let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: [pqcSuite])
            XCTAssertEqual(algorithm, .mlDSA65, "Single PQC suite \(pqcSuite.rawValue) should require ML-DSA-65")
            
 // PQC suite mixed with classic suites
            for classicSuite in classicSuites {
                let mixedSuites = [pqcSuite, classicSuite]
                let mixedAlgorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: mixedSuites)
                XCTAssertEqual(mixedAlgorithm, .mlDSA65, "Mixed suites containing PQC should require ML-DSA-65")
            }
        }
    }
    
 /// **Property 1.2**: If offeredSuites contains ONLY Classic suites → Ed25519
 /// **Validates: Requirements 1.1**
    func testProperty1_2_ClassicOnlySuitesRequireEd25519() {
 // Single classic suite
        for classicSuite in classicSuites {
            let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: [classicSuite])
            XCTAssertEqual(algorithm, .ed25519, "Single classic suite \(classicSuite.rawValue) should require Ed25519")
        }
        
 // All classic suites together
        let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: classicSuites)
        XCTAssertEqual(algorithm, .ed25519, "All classic suites should require Ed25519")
    }
    
 /// **Property 1.3**: Empty offeredSuites should default to Ed25519 (no PQC)
    func testProperty1_3_EmptySuitesDefaultToEd25519() {
        let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: [])
        XCTAssertEqual(algorithm, .ed25519, "Empty suites should default to Ed25519")
    }
    
 /// **Property 1.4**: All PQC suites together should require ML-DSA-65
    func testProperty1_4_AllPQCSuitesRequireMLDSA65() {
        let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: pqcSuites)
        XCTAssertEqual(algorithm, .mlDSA65, "All PQC suites should require ML-DSA-65")
    }
    
 /// **Property 1.5**: All suites (PQC + Classic) should require ML-DSA-65 (PQC takes precedence)
    func testProperty1_5_MixedSuitesPQCTakesPrecedence() {
        let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: allSuites)
        XCTAssertEqual(algorithm, .mlDSA65, "Mixed suites should require ML-DSA-65 (PQC takes precedence)")
    }
    
 // MARK: - Property 2: Suite-Signature Compatibility Validation
    
 /// **Property 2.1**: If sigA is ML-DSA-65, selectedSuite MUST be PQC/Hybrid
 /// **Validates: Requirements 1.1, 1.2**
    func testProperty2_1_MLDSA65RequiresPQCSuite() {
 // PQC suites should be compatible with ML-DSA-65
        for pqcSuite in pqcSuites {
            let isCompatible = PreNegotiationSignatureSelector.validateSuiteCompatibility(
                selectedSuite: pqcSuite,
                sigAAlgorithm: .mlDSA65
            )
            XCTAssertTrue(isCompatible, "PQC suite \(pqcSuite.rawValue) should be compatible with ML-DSA-65")
        }
        
 // Classic suites should NOT be compatible with ML-DSA-65
        for classicSuite in classicSuites {
            let isCompatible = PreNegotiationSignatureSelector.validateSuiteCompatibility(
                selectedSuite: classicSuite,
                sigAAlgorithm: .mlDSA65
            )
            XCTAssertFalse(isCompatible, "Classic suite \(classicSuite.rawValue) should NOT be compatible with ML-DSA-65")
        }
    }
    
 /// **Property 2.2**: If sigA is Ed25519, selectedSuite MUST be Classic
 /// **Validates: Requirements 1.1**
    func testProperty2_2_Ed25519RequiresClassicSuite() {
 // Classic suites should be compatible with Ed25519
        for classicSuite in classicSuites {
            let isCompatible = PreNegotiationSignatureSelector.validateSuiteCompatibility(
                selectedSuite: classicSuite,
                sigAAlgorithm: .ed25519
            )
            XCTAssertTrue(isCompatible, "Classic suite \(classicSuite.rawValue) should be compatible with Ed25519")
        }
        
 // PQC suites should NOT be compatible with Ed25519
        for pqcSuite in pqcSuites {
            let isCompatible = PreNegotiationSignatureSelector.validateSuiteCompatibility(
                selectedSuite: pqcSuite,
                sigAAlgorithm: .ed25519
            )
            XCTAssertFalse(isCompatible, "PQC suite \(pqcSuite.rawValue) should NOT be compatible with Ed25519")
        }
    }
    
 /// **Property 2.3**: P-256 ECDSA should never be compatible as sigA algorithm
    func testProperty2_3_P256ECDSANeverCompatibleForSigA() {
 // P-256 ECDSA should not be compatible with any suite for sigA
        for suite in allSuites {
            let isCompatible = PreNegotiationSignatureSelector.validateSuiteCompatibility(
                selectedSuite: suite,
                sigAAlgorithm: .p256ECDSA
            )
            XCTAssertFalse(isCompatible, "P-256 ECDSA should never be compatible for sigA with suite \(suite.rawValue)")
        }
    }
    
 // MARK: - Property 3: Signature Provider Selection
    
 /// **Property 3.1**: ML-DSA-65 algorithm should return PQCSignatureProvider
    func testProperty3_1_MLDSA65ReturnsPQCProvider() {
        let provider = PreNegotiationSignatureSelector.selectProvider(for: SignatureAlgorithm.mlDSA65)
        XCTAssertEqual(provider.signatureAlgorithm, ProtocolSigningAlgorithm.mlDSA65, "ML-DSA-65 should return PQC provider")
        XCTAssertTrue(provider is PQCSignatureProvider, "Should be PQCSignatureProvider instance")
    }
    
 /// **Property 3.2**: Ed25519 algorithm should return ClassicSignatureProvider
    func testProperty3_2_Ed25519ReturnsClassicProvider() {
        let provider = PreNegotiationSignatureSelector.selectProvider(for: SignatureAlgorithm.ed25519)
        XCTAssertEqual(provider.signatureAlgorithm, ProtocolSigningAlgorithm.ed25519, "Ed25519 should return Classic provider")
        XCTAssertTrue(provider is ClassicSignatureProvider, "Should be ClassicSignatureProvider instance")
    }
    
 /// **Property 3.3**: P-256 ECDSA algorithm should return ClassicSignatureProvider (fallback)
 /// Note: P-256 is not allowed for protocol signing, so it falls back to Ed25519/Classic
    func testProperty3_3_P256ECDSAReturnsClassicProviderFallback() {
        let provider = PreNegotiationSignatureSelector.selectProvider(for: SignatureAlgorithm.p256ECDSA)
 // P-256 falls back to ClassicSignatureProvider (Ed25519) since P-256 is not allowed for protocol signing
        XCTAssertEqual(provider.signatureAlgorithm, ProtocolSigningAlgorithm.ed25519, "P-256 ECDSA should fallback to Ed25519 provider")
        XCTAssertTrue(provider is ClassicSignatureProvider, "Should be ClassicSignatureProvider instance (fallback)")
    }
    
 // MARK: - Round-Trip Property: Selection Consistency
    
 /// **Property 4**: For any offeredSuites, the selected algorithm should be compatible
 /// with at least one suite in the offered list (if non-empty)
    func testProperty4_SelectionConsistency() {
 // Test with various combinations
        let testCases: [[CryptoSuite]] = [
            pqcSuites,
            classicSuites,
            allSuites,
            [.xwingMLDSA],
            [.x25519Ed25519],
            [.xwingMLDSA, .x25519Ed25519],
        ]
        
        for offeredSuites in testCases {
            guard !offeredSuites.isEmpty else { continue }
            
            let algorithm = PreNegotiationSignatureSelector.selectForMessageA(offeredSuites: offeredSuites)
            
 // At least one offered suite should be compatible with the selected algorithm
            let hasCompatibleSuite = offeredSuites.contains { suite in
                PreNegotiationSignatureSelector.validateSuiteCompatibility(
                    selectedSuite: suite,
                    sigAAlgorithm: algorithm
                )
            }
            
            XCTAssertTrue(hasCompatibleSuite, 
                "Selected algorithm \(algorithm.rawValue) should be compatible with at least one offered suite")
        }
    }
    
 // MARK: - Convenience Method Tests
    
 /// Test selectAlgorithmAndProvider convenience method
    func testSelectAlgorithmAndProviderConvenience() {
 // PQC suites
        let (pqcAlg, pqcProvider) = PreNegotiationSignatureSelector.selectAlgorithmAndProvider(offeredSuites: pqcSuites)
        XCTAssertEqual(pqcAlg, .mlDSA65)
        XCTAssertEqual(pqcProvider.signatureAlgorithm, .mlDSA65)
        
 // Classic suites
        let (classicAlg, classicProvider) = PreNegotiationSignatureSelector.selectAlgorithmAndProvider(offeredSuites: classicSuites)
        XCTAssertEqual(classicAlg, .ed25519)
        XCTAssertEqual(classicProvider.signatureAlgorithm, .ed25519)
    }
    
 // MARK: - CryptoSuite Extension Tests
    
 /// Test allPQCSuites extension
    func testAllPQCSuitesExtension() {
        let pqcSuites = CryptoSuite.allPQCSuites
        XCTAssertFalse(pqcSuites.isEmpty, "allPQCSuites should not be empty")
        
        for suite in pqcSuites {
            XCTAssertTrue(suite.isPQC || suite.isHybrid, "Suite \(suite.rawValue) should be PQC or Hybrid")
        }
    }
    
 /// Test allClassicSuites extension
    func testAllClassicSuitesExtension() {
        let classicSuites = CryptoSuite.allClassicSuites
        XCTAssertFalse(classicSuites.isEmpty, "allClassicSuites should not be empty")
        
        for suite in classicSuites {
            XCTAssertFalse(suite.isPQC, "Suite \(suite.rawValue) should not be PQC")
            XCTAssertFalse(suite.isHybrid, "Suite \(suite.rawValue) should not be Hybrid")
        }
    }
    
 // MARK: - Wire ID Based Tests
    
 /// Test that wireId-based classification is consistent
    func testWireIdClassificationConsistency() {
 // 0x00xx should be hybrid PQC
        let hybridSuite = CryptoSuite.xwingMLDSA
        XCTAssertTrue(hybridSuite.isHybrid, "0x00xx wireId should be hybrid")
        XCTAssertTrue(hybridSuite.isPQC, "0x00xx wireId should be PQC")
        
 // 0x01xx should be pure PQC
        let purePQCSuite = CryptoSuite.mlkem768MLDSA65
        XCTAssertFalse(purePQCSuite.isHybrid, "0x01xx wireId should not be hybrid")
        XCTAssertTrue(purePQCSuite.isPQC, "0x01xx wireId should be PQC")
        
 // 0x10xx should be classic
        let classicSuite = CryptoSuite.x25519Ed25519
        XCTAssertFalse(classicSuite.isHybrid, "0x10xx wireId should not be hybrid")
        XCTAssertFalse(classicSuite.isPQC, "0x10xx wireId should not be PQC")
    }
    
 // MARK: - Property 2 ( 7.4): offeredSuites-sigAAlgorithm Homogeneity
    
 /// **Property 2.4**: ML-DSA-65 → ALL suites isPQCGroup == true
 /// **Validates: Requirements 1.3, 1.4, 2.1, 2.2, 2.3**
    func testProperty2_4_MLDSA65RequiresAllPQCGroupSuites() {
 // When sigAAlgorithm is ML-DSA-65, all offeredSuites must have isPQCGroup == true
        let sigAAlgorithm = ProtocolSigningAlgorithm.mlDSA65
        
 // Valid: all PQC suites
        for pqcSuite in pqcSuites {
            XCTAssertTrue(pqcSuite.isPQCGroup, 
                "PQC suite \(pqcSuite.rawValue) should have isPQCGroup == true")
        }
        
 // Invalid: any classic suite with ML-DSA-65
        for classicSuite in classicSuites {
            XCTAssertFalse(classicSuite.isPQCGroup,
                "Classic suite \(classicSuite.rawValue) should have isPQCGroup == false")
            
 // Mixing classic with ML-DSA-65 should be a homogeneity violation
            let mixedSuites = pqcSuites + [classicSuite]
            let allPQCGroup = mixedSuites.allSatisfy { $0.isPQCGroup }
            XCTAssertFalse(allPQCGroup,
                "Mixed suites should violate homogeneity for ML-DSA-65")
        }
    }
    
 /// **Property 2.5**: Ed25519 → ALL suites isPQCGroup == false
 /// **Validates: Requirements 1.3, 1.4, 2.1, 2.2, 2.3**
    func testProperty2_5_Ed25519RequiresAllClassicSuites() {
 // When sigAAlgorithm is Ed25519, all offeredSuites must have isPQCGroup == false
        let sigAAlgorithm = ProtocolSigningAlgorithm.ed25519
        
 // Valid: all classic suites
        for classicSuite in classicSuites {
            XCTAssertFalse(classicSuite.isPQCGroup,
                "Classic suite \(classicSuite.rawValue) should have isPQCGroup == false")
        }
        
 // Invalid: any PQC suite with Ed25519
        for pqcSuite in pqcSuites {
            XCTAssertTrue(pqcSuite.isPQCGroup,
                "PQC suite \(pqcSuite.rawValue) should have isPQCGroup == true")
            
 // Mixing PQC with Ed25519 should be a homogeneity violation
            let mixedSuites = classicSuites + [pqcSuite]
            let allClassic = mixedSuites.allSatisfy { !$0.isPQCGroup }
            XCTAssertFalse(allClassic,
                "Mixed suites should violate homogeneity for Ed25519")
        }
    }
    
 /// **Property 2.6**: Homogeneity violation should throw (not crash)
 /// **Validates: Requirements 7.4, 7.5**
    func testProperty2_6_HomogeneityViolationThrows() {
 // Test that HandshakeOfferedSuites.build returns .empty for incompatible strategy
        
 // pqcOnly strategy with only classic suites available
        let classicOnlyResult = HandshakeOfferedSuites.build(
            strategy: .pqcOnly,
            availableSuites: classicSuites
        )
        if case .empty(let strategy) = classicOnlyResult {
            XCTAssertEqual(strategy, .pqcOnly, "Should return empty with pqcOnly strategy")
        } else {
            XCTFail("Should return .empty when no PQC suites available for pqcOnly strategy")
        }
        
 // classicOnly strategy with only PQC suites available
        let pqcOnlyResult = HandshakeOfferedSuites.build(
            strategy: .classicOnly,
            availableSuites: pqcSuites
        )
        if case .empty(let strategy) = pqcOnlyResult {
            XCTAssertEqual(strategy, .classicOnly, "Should return empty with classicOnly strategy")
        } else {
            XCTFail("Should return .empty when no classic suites available for classicOnly strategy")
        }
    }
    
 /// **Property 2.7**: selectForMessageAResult returns .empty for empty suites
 /// **Validates: Requirements 6.3**
    func testProperty2_7_SelectForMessageAResultEmptySuites() {
        let result = PreNegotiationSignatureSelector.selectForMessageAResult(offeredSuites: [])
        XCTAssertEqual(result, .empty, "Empty offeredSuites should return .empty")
    }
    
 /// **Property 2.8**: selectForMessageAResult returns correct algorithm
 /// **Validates: Requirements 1.1, 1.2, 1.4**
    func testProperty2_8_SelectForMessageAResultCorrectAlgorithm() {
 // PQC suites → ML-DSA-65
        let pqcResult = PreNegotiationSignatureSelector.selectForMessageAResult(offeredSuites: pqcSuites)
        if case .success(let algorithm, _) = pqcResult {
            XCTAssertEqual(algorithm, .mlDSA65, "PQC suites should select ML-DSA-65")
        } else {
            XCTFail("Should return .success for non-empty PQC suites")
        }
        
 // Classic suites → Ed25519
        let classicResult = PreNegotiationSignatureSelector.selectForMessageAResult(offeredSuites: classicSuites)
        if case .success(let algorithm, _) = classicResult {
            XCTAssertEqual(algorithm, .ed25519, "Classic suites should select Ed25519")
        } else {
            XCTFail("Should return .success for non-empty classic suites")
        }
    }
    
 // MARK: - HandshakeOfferedSuites.build Tests ( 7.2)
    
 /// Test HandshakeOfferedSuites.build with pqcOnly strategy
    func testHandshakeOfferedSuitesBuildPQCOnly() {
 // With all suites available
        let result = HandshakeOfferedSuites.build(
            strategy: .pqcOnly,
            availableSuites: allSuites
        )
        if case .suites(let suites) = result {
            XCTAssertFalse(suites.isEmpty, "Should have PQC suites")
            for suite in suites {
                XCTAssertTrue(suite.isPQCGroup, "All suites should be PQC group")
            }
        } else {
            XCTFail("Should return .suites when PQC suites available")
        }
    }
    
 /// Test HandshakeOfferedSuites.build with classicOnly strategy
    func testHandshakeOfferedSuitesBuildClassicOnly() {
 // With all suites available
        let result = HandshakeOfferedSuites.build(
            strategy: .classicOnly,
            availableSuites: allSuites
        )
        if case .suites(let suites) = result {
            XCTAssertFalse(suites.isEmpty, "Should have classic suites")
            for suite in suites {
                XCTAssertFalse(suite.isPQCGroup, "All suites should be classic group")
            }
        } else {
            XCTFail("Should return .suites when classic suites available")
        }
    }
}
